import SwiftUI

// MARK: - Lógica da tela

@MainActor
@Observable
final class DashboardViewModel {
    private(set) var summary: DailySummary?
    private(set) var isLoading = false
    private(set) var lastUpdated: Date?

    private let service: HealthService

    init(service: HealthService) {
        self.service = service
    }

    /// Nada voltou: pode ser dia sem registros ou leitura negada.
    var showPermissionHint: Bool {
        guard let summary else { return false }
        return !summary.hasAnyData
    }

    var stepProgress: Double? {
        guard let steps = summary?.steps else { return nil }
        return min(steps / AppConfig.dailyStepGoal, 1)
    }

    func start() async {
        if !(await service.hasRequestedAuthorization()) {
            try? await service.requestAuthorization()
        }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        let now = Date()
        summary = await service.fetchSummary(for: now)
        lastUpdated = now
        isLoading = false
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @State private var model: DashboardViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(service: HealthService) {
        _model = State(initialValue: DashboardViewModel(service: service))
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let summary = model.summary {
                    content(summary)
                } else {
                    ProgressView("Lendo o Apple Saúde...")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Hoje")
            .refreshable { await model.refresh() }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            // Voltou para o app: atualiza.
            if phase == .active, model.summary != nil {
                Task { await model.refresh() }
            }
        }
    }

    private func content(_ summary: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(summary)

            if model.showPermissionHint {
                PermissionHintCard()
            }

            LazyVGrid(columns: columns, spacing: 12) {
                MetricCard(
                    metric: .steps,
                    value: summary.steps.map { Format.integer($0) },
                    detail: "Meta: \(Format.integer(AppConfig.dailyStepGoal))",
                    progress: model.stepProgress
                )
                MetricCard(
                    metric: .activeEnergy,
                    value: summary.activeEnergy.map { "\(Format.integer($0)) kcal" }
                )
                MetricCard(
                    metric: .heartRate,
                    value: summary.heartRate.map { "\(Format.integer($0.average)) bpm" },
                    detail: summary.heartRate.map { "Mín \(Format.integer($0.min)) · Máx \(Format.integer($0.max))" }
                )
                MetricCard(
                    metric: .restingHeartRate,
                    value: summary.restingHeartRate.map { "\(Format.integer($0.value)) bpm" },
                    detail: summary.restingHeartRate.map { readingDetail($0.date) }
                )
                MetricCard(
                    metric: .hrv,
                    value: summary.hrv.map { "\(Format.integer($0)) ms" },
                    detail: summary.hrv == nil ? nil : "Média do dia"
                )
            }

            SleepCard(sleep: summary.sleep)
            WorkoutsSection(workouts: summary.workouts)

            Text("Dados lidos do Apple Saúde, somente neste iPhone. Não substitui orientação médica.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding()
    }

    private func header(_ summary: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.dayTitle(summary.date))
                .font(.subheadline.weight(.semibold))
            if let lastUpdated = model.lastUpdated {
                Text("Atualizado às \(Format.time(lastUpdated))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readingDetail(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "Hoje, \(Format.time(date))" : "Ontem, \(Format.time(date))"
    }
}

// MARK: - Aviso de permissão

struct PermissionHintCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Não encontramos dados de hoje", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Pode ser só um dia sem registros ainda. Se você não liberou o acesso, abra o app Saúde, toque na sua foto, depois em Apps > PulsoDoDia, e ative as categorias.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Abrir app Saúde") { openURL(AppConfig.healthAppURL) }
                .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Card de indicador

struct MetricCard: View {
    let metric: HealthMetric
    let value: String?
    var detail: String? = nil
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(metric.title, systemImage: metric.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(metric.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)

            if let value {
                Text(value)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let progress {
                    ProgressView(value: progress)
                        .tint(metric.color)
                }
            } else {
                Text("Sem dados hoje")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(metric.emptyHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sono

struct SleepCard: View {
    let sleep: SleepSummary?

    private let order: [SleepStage] = [.deep, .core, .rem, .unspecified, .awake]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sono da última noite", systemImage: HealthMetric.sleep.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HealthMetric.sleep.color)

            if let sleep {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.duration(sleep.asleep))
                        .font(.title.bold())
                        .monospacedDigit()
                    Spacer()
                    if let bedtime = sleep.bedtime, let wake = sleep.wakeTime {
                        Text("\(Format.time(bedtime)) às \(Format.time(wake))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                stageBar(sleep)
                legend(sleep)
            } else {
                Text("Sem dados de sono")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(HealthMetric.sleep.emptyHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func visibleStages(_ sleep: SleepSummary) -> [SleepStage] {
        order.filter { sleep.duration(of: $0) > 0 }
    }

    private func stageBar(_ sleep: SleepSummary) -> some View {
        let visible = visibleStages(sleep)
        let total = visible.reduce(0.0) { $0 + sleep.duration(of: $1) }
        return GeometryReader { proxy in
            let available = proxy.size.width - CGFloat(visible.count - 1) * 2
            HStack(spacing: 2) {
                ForEach(visible, id: \.self) { stage in
                    stage.color
                        .frame(width: max(2, available * CGFloat(sleep.duration(of: stage) / total)))
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func legend(_ sleep: SleepSummary) -> some View {
        HStack(spacing: 14) {
            ForEach(visibleStages(sleep), id: \.self) { stage in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(stage.color).frame(width: 8, height: 8)
                        Text(stage.title).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Format.duration(sleep.duration(of: stage)))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Treinos

struct WorkoutsSection: View {
    let workouts: [WorkoutSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Treinos de hoje", systemImage: HealthMetric.workouts.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HealthMetric.workouts.color)

            if workouts.isEmpty {
                Text("Nenhum treino registrado hoje")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(workouts) { workout in
                    WorkoutRow(workout: workout)
                    if workout.id != workouts.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct WorkoutRow: View {
    let workout: WorkoutSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.symbolName)
                .font(.title3)
                .foregroundStyle(HealthMetric.workouts.color)
                .frame(width: 40, height: 40)
                .background(HealthMetric.workouts.color.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.name).font(.subheadline.weight(.semibold))
                Text("\(Format.time(workout.start)) · \(Format.duration(workout.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let energy = workout.activeEnergy {
                Text("\(Format.integer(energy)) kcal")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Com dados") {
    DashboardView(service: MockHealthService())
}

#Preview("Sem dados") {
    DashboardView(service: MockHealthService(empty: true))
}
