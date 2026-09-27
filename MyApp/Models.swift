import SwiftUI

// MARK: - Configuração

enum AppConfig {
    static let privacyPolicyURL = URL(string: "https://rodrigodasilva.com")!
    static let healthAppURL = URL(string: "x-apple-health://")!
    static let dailyStepGoal: Double = 8_000
}

// MARK: - Resumo do dia

/// Campos nil significam "sem dados" (ou leitura não autorizada, que o iOS não diferencia).
struct DailySummary {
    var date: Date
    var steps: Double?
    var activeEnergy: Double?
    var heartRate: HeartRateStats?
    var restingHeartRate: Reading?
    var hrv: Double?
    var sleep: SleepSummary?
    var workouts: [WorkoutSummary] = []

    var hasAnyData: Bool {
        steps != nil || activeEnergy != nil || heartRate != nil || restingHeartRate != nil
            || hrv != nil || sleep != nil || !workouts.isEmpty
    }
}

struct HeartRateStats {
    let average: Double
    let min: Double
    let max: Double
}

struct Reading {
    let value: Double
    let date: Date
}

struct WorkoutSummary: Identifiable {
    let id: UUID
    let name: String
    let symbolName: String
    let start: Date
    let duration: TimeInterval
    let activeEnergy: Double?
}

// MARK: - Sono

enum SleepStage: CaseIterable {
    case deep, rem, core, awake, unspecified

    var title: String {
        switch self {
        case .deep: return "Profundo"
        case .rem: return "REM"
        case .core: return "Essencial"
        case .awake: return "Acordado"
        case .unspecified: return "Dormindo"
        }
    }

    /// Quando fontes se sobrepõem (Watch e iPhone), vence o estágio mais específico.
    var priority: Int {
        switch self {
        case .deep: return 5
        case .rem: return 4
        case .core: return 3
        case .awake: return 2
        case .unspecified: return 1
        }
    }

    var isAsleep: Bool { self != .awake }

    var color: Color {
        switch self {
        case .deep: return Color(red: 0.23, green: 0.20, blue: 0.62)
        case .rem: return Color(red: 0.36, green: 0.67, blue: 0.98)
        case .core: return Color(red: 0.24, green: 0.45, blue: 0.93)
        case .awake: return Color(red: 1.0, green: 0.52, blue: 0.40)
        case .unspecified: return .indigo
        }
    }
}

struct SleepSegment {
    let stage: SleepStage
    let start: Date
    let end: Date
}

struct SleepSummary {
    var durations: [SleepStage: TimeInterval] = [:]
    var bedtime: Date?
    var wakeTime: Date?

    var asleep: TimeInterval {
        durations.filter { $0.key.isAsleep }.values.reduce(0, +)
    }

    func duration(of stage: SleepStage) -> TimeInterval {
        durations[stage] ?? 0
    }

    /// "Última noite": das 18h de ontem até o meio dia de hoje (ou agora, se antes).
    static func nightWindow(for date: Date) -> DateInterval {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .hour, value: -6, to: startOfDay)!
        let noon = calendar.date(byAdding: .hour, value: 12, to: startOfDay)!
        return DateInterval(start: start, end: max(start, min(noon, date)))
    }

    /// Junta segmentos de várias fontes sem contar o mesmo minuto duas vezes.
    static func aggregate(_ segments: [SleepSegment], in window: DateInterval) -> SleepSummary? {
        var clipped: [SleepSegment] = []
        for segment in segments {
            let start = max(segment.start, window.start)
            let end = min(segment.end, window.end)
            if end > start {
                clipped.append(SleepSegment(stage: segment.stage, start: start, end: end))
            }
        }
        var boundSet = Set<Date>()
        for segment in clipped {
            boundSet.insert(segment.start)
            boundSet.insert(segment.end)
        }
        let bounds = boundSet.sorted()

        var summary = SleepSummary()
        for index in 0..<max(0, bounds.count - 1) {
            let from = bounds[index]
            let to = bounds[index + 1]
            var best: SleepStage?
            for segment in clipped where segment.start <= from && segment.end >= to {
                if best == nil || segment.stage.priority > best!.priority {
                    best = segment.stage
                }
            }
            guard let stage = best else { continue }
            summary.durations[stage, default: 0] += to.timeIntervalSince(from)
            if stage.isAsleep {
                if summary.bedtime == nil { summary.bedtime = from }
                summary.wakeTime = to
            }
        }
        return summary.asleep > 0 ? summary : nil
    }
}

// MARK: - Dados exibidos

enum HealthMetric: CaseIterable, Identifiable {
    case steps, heartRate, restingHeartRate, hrv, sleep, activeEnergy, workouts

    var id: String { title }

    var title: String {
        switch self {
        case .steps: return "Passos"
        case .heartRate: return "Frequência cardíaca"
        case .restingHeartRate: return "FC em repouso"
        case .hrv: return "HRV"
        case .sleep: return "Sono"
        case .activeEnergy: return "Calorias ativas"
        case .workouts: return "Treinos"
        }
    }

    var reason: String {
        switch self {
        case .steps: return "Medir seu nível de movimento no dia."
        case .heartRate: return "Mostrar a média, a mínima e a máxima do dia."
        case .restingHeartRate: return "Indicador de recuperação e condicionamento."
        case .hrv: return "Variabilidade da frequência cardíaca, sinal de estresse e recuperação."
        case .sleep: return "Quanto você dormiu na última noite, por fase."
        case .activeEnergy: return "Energia gasta com atividade física."
        case .workouts: return "Quais atividades você fez hoje, duração e calorias."
        }
    }

    var emptyHint: String {
        switch self {
        case .heartRate, .restingHeartRate, .hrv: return "Registrado pelo Apple Watch."
        case .sleep: return "Use o Apple Watch ou ative o Sono no app Saúde."
        default: return "Nenhum registro ainda."
        }
    }

    var symbol: String {
        switch self {
        case .steps: return "figure.walk"
        case .heartRate: return "heart.fill"
        case .restingHeartRate: return "bed.double.fill"
        case .hrv: return "waveform.path.ecg"
        case .sleep: return "moon.zzz.fill"
        case .activeEnergy: return "flame.fill"
        case .workouts: return "figure.run"
        }
    }

    var color: Color {
        switch self {
        case .steps: return .orange
        case .heartRate: return .red
        case .restingHeartRate: return .pink
        case .hrv: return .teal
        case .sleep: return .indigo
        case .activeEnergy: return Color(red: 1, green: 0.22, blue: 0.37)
        case .workouts: return .green
        }
    }
}

// MARK: - Formatação (sempre em português)

enum Format {
    private static let brazil = Locale(identifier: "pt_BR")

    /// "Domingo, 27 de setembro".
    static func dayTitle(_ date: Date) -> String {
        let text = date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(brazil))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// 27000 s vira "7h 30min"; 2700 s vira "45min".
    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((interval / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)min" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)min"
    }

    static func integer(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.locale(brazil))
    }

    /// "15:25", no formato 24h brasileiro.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(brazil))
    }
}
