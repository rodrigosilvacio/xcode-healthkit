import Foundation
import HealthKit

// MARK: - Contrato

/// Fonte dos dados de saúde. A versão real usa o HealthKit; a de demonstração usa dados fictícios.
protocol HealthService {
    func requestAuthorization() async throws
    func hasRequestedAuthorization() async -> Bool
    func fetchSummary(for date: Date) async -> DailySummary
}

enum HealthError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "O Apple Saúde não está disponível neste aparelho."
    }
}

// MARK: - Implementação real (HealthKit)

final class HealthKitService: HealthService {
    private let store = HKHealthStore()

    /// Somente leitura: o app nunca grava no Apple Saúde.
    private let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.activeEnergyBurned),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType(),
    ]

    private let bpm = HKUnit.count().unitDivided(by: .minute())

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func hasRequestedAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        return status == .unnecessary
    }

    func fetchSummary(for date: Date) async -> DailySummary {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let today = DateInterval(start: startOfDay, end: max(startOfDay, date))

        // As consultas rodam em paralelo; uma falha não derruba as outras.
        async let steps = sum(.stepCount, unit: .count(), in: today)
        async let energy = sum(.activeEnergyBurned, unit: .kilocalorie(), in: today)
        async let heartRate = heartRateStats(in: today)
        async let resting = latestReading(.restingHeartRate, since: startOfDay.addingTimeInterval(-86_400))
        async let hrv = average(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), in: today)
        async let sleep = sleepSummary(for: date)
        async let workouts = workouts(in: today)

        return DailySummary(
            date: date,
            steps: await steps,
            activeEnergy: await energy,
            heartRate: await heartRate,
            restingHeartRate: await resting,
            hrv: await hrv,
            sleep: await sleep,
            workouts: await workouts
        )
    }

    // MARK: Consultas

    private func statistics(_ id: HKQuantityTypeIdentifier, options: HKStatisticsOptions, in interval: DateInterval) async -> HKStatistics? {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate),
            options: options
        )
        return try? await descriptor.result(for: store)
    }

    /// Soma do dia, já sem duplicar iPhone + Apple Watch.
    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async -> Double? {
        let stats = await statistics(id, options: .cumulativeSum, in: interval)
        return stats?.sumQuantity()?.doubleValue(for: unit)
    }

    private func average(_ id: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async -> Double? {
        let stats = await statistics(id, options: .discreteAverage, in: interval)
        return stats?.averageQuantity()?.doubleValue(for: unit)
    }

    private func heartRateStats(in interval: DateInterval) async -> HeartRateStats? {
        let stats = await statistics(.heartRate, options: [.discreteAverage, .discreteMin, .discreteMax], in: interval)
        guard
            let average = stats?.averageQuantity()?.doubleValue(for: bpm),
            let min = stats?.minimumQuantity()?.doubleValue(for: bpm),
            let max = stats?.maximumQuantity()?.doubleValue(for: bpm)
        else { return nil }
        return HeartRateStats(average: average, min: min, max: max)
    }

    /// A FC em repouso é calculada pelo Watch uma vez ao dia; pegamos a mais recente.
    private func latestReading(_ id: HKQuantityTypeIdentifier, since start: Date) async -> Reading? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        guard let samples = try? await descriptor.result(for: store), let sample = samples.first else { return nil }
        return Reading(value: sample.quantity.doubleValue(for: bpm), date: sample.endDate)
    }

    private func sleepSummary(for date: Date) async -> SleepSummary? {
        let window = SleepSummary.nightWindow(for: date)
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        guard let samples = try? await descriptor.result(for: store) else { return nil }

        var segments: [SleepSegment] = []
        for sample in samples {
            guard let stage = Self.stage(for: sample.value) else { continue }
            segments.append(SleepSegment(stage: stage, start: sample.startDate, end: sample.endDate))
        }
        return SleepSummary.aggregate(segments, in: window)
    }

    /// "Na cama" fica de fora: estar na cama não é dormir.
    private static func stage(for value: Int) -> SleepStage? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .asleepDeep: return .deep
        case .asleepREM: return .rem
        case .asleepCore: return .core
        case .asleepUnspecified: return .unspecified
        case .awake: return .awake
        default: return nil
        }
    }

    private func workouts(in interval: DateInterval) async -> [WorkoutSummary] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        guard let workouts = try? await descriptor.result(for: store) else { return [] }

        return workouts.map { workout in
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie())
            let info = Self.describe(workout.workoutActivityType)
            return WorkoutSummary(
                id: workout.uuid,
                name: info.name,
                symbolName: info.symbol,
                start: workout.startDate,
                duration: workout.duration,
                activeEnergy: energy
            )
        }
    }

    private static func describe(_ type: HKWorkoutActivityType) -> (name: String, symbol: String) {
        switch type {
        case .running: return ("Corrida", "figure.run")
        case .walking: return ("Caminhada", "figure.walk")
        case .cycling: return ("Ciclismo", "figure.outdoor.cycle")
        case .swimming: return ("Natação", "figure.pool.swim")
        case .hiking: return ("Trilha", "figure.hiking")
        case .traditionalStrengthTraining: return ("Musculação", "figure.strengthtraining.traditional")
        case .functionalStrengthTraining: return ("Treino funcional", "figure.strengthtraining.functional")
        case .highIntensityIntervalTraining: return ("HIIT", "figure.highintensity.intervaltraining")
        case .coreTraining: return ("Core", "figure.core.training")
        case .crossTraining: return ("Cross training", "figure.cross.training")
        case .elliptical: return ("Elíptico", "figure.elliptical")
        case .rowing: return ("Remo", "figure.rower")
        case .stairClimbing: return ("Escada", "figure.stairs")
        case .yoga: return ("Yoga", "figure.yoga")
        case .pilates: return ("Pilates", "figure.pilates")
        case .martialArts: return ("Artes marciais", "figure.martial.arts")
        case .boxing: return ("Boxe", "figure.boxing")
        case .soccer: return ("Futebol", "figure.soccer")
        case .tennis: return ("Tênis", "figure.tennis")
        case .socialDance, .cardioDance: return ("Dança", "figure.dance")
        case .cooldown: return ("Desaquecimento", "figure.cooldown")
        default: return ("Treino", "figure.mixed.cardio")
        }
    }
}

// MARK: - Dados de demonstração

/// Usado nos Previews e para apresentar o app sem expor dados reais.
struct MockHealthService: HealthService {
    var empty = false

    func requestAuthorization() async throws {}

    func hasRequestedAuthorization() async -> Bool { true }

    func fetchSummary(for date: Date) async -> DailySummary {
        try? await Task.sleep(nanoseconds: 400_000_000)
        if empty { return DailySummary(date: date) }

        let startOfDay = Calendar.current.startOfDay(for: date)
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            startOfDay.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        }

        let sleep = SleepSummary.aggregate([
            SleepSegment(stage: .core, start: at(-1, -10), end: at(0, 40)),
            SleepSegment(stage: .deep, start: at(0, 40), end: at(1, 45)),
            SleepSegment(stage: .core, start: at(1, 45), end: at(3, 0)),
            SleepSegment(stage: .rem, start: at(3, 0), end: at(3, 50)),
            SleepSegment(stage: .awake, start: at(3, 50), end: at(4, 5)),
            SleepSegment(stage: .core, start: at(4, 5), end: at(5, 30)),
            SleepSegment(stage: .rem, start: at(5, 30), end: at(6, 42)),
        ], in: DateInterval(start: at(-6), end: at(12)))

        return DailySummary(
            date: date,
            steps: 8_432,
            activeEnergy: 512,
            heartRate: HeartRateStats(average: 74, min: 52, max: 158),
            restingHeartRate: Reading(value: 56, date: at(7, 10)),
            hrv: 48,
            sleep: sleep,
            workouts: [
                WorkoutSummary(id: UUID(), name: "Artes marciais", symbolName: "figure.martial.arts",
                               start: at(19), duration: 5_400, activeEnergy: 640),
                WorkoutSummary(id: UUID(), name: "Corrida", symbolName: "figure.run",
                               start: at(6, 50), duration: 2_280, activeEnergy: 318),
            ]
        )
    }
}
