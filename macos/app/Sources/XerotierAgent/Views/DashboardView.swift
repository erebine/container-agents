// SPDX-License-Identifier: MIT
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showUninstall = false

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        if model.installState != .installed {
            EmptyState(
                systemImage: "shippingbox",
                title: "No agent installed",
                message: "Install the XIM agent from the Setup pane to see live status here.",
                actionTitle: "Go to Setup",
                action: { model.selection = .setup }
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    LazyVGrid(columns: columns, spacing: 14) {
                        InfoTile("Service", value: model.serviceState.label,
                                 systemImage: "bolt.horizontal.circle",
                                 valueColor: model.serviceState.tint) {
                            StatusPill(text: model.serviceState.label,
                                       tint: model.serviceState.tint,
                                       pulsing: model.serviceState.isBusy)
                        }
                        InfoTile("Enrollment",
                                 value: model.isEnrolled ? "Enrolled" : "Not enrolled",
                                 systemImage: "checkmark.seal")
                        InfoTile("Accelerator", value: model.acceleratorName,
                                 systemImage: "cpu")
                        InfoTile("GPU memory budget", value: model.vramBudget,
                                 systemImage: "memorychip") {
                            if model.accelerator?.unifiedMemory == true {
                                Text("unified").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        InfoTile("Max concurrent",
                                 value: model.settings.maxConcurrent.isEmpty ? "auto" : model.settings.maxConcurrent,
                                 systemImage: "square.stack.3d.up")
                        InfoTile("Metrics", value: model.settings.disableMetrics
                                 ? "Disabled" : ":\(model.settings.metricsPort)",
                                 systemImage: "chart.line.uptrend.xyaxis")
                    }
                    liveSection
                    activityCard
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder private var liveSection: some View {
        if model.serviceState == .running {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Live").font(.title3.weight(.semibold))
                    healthPill
                    Spacer()
                }
                if let m = model.metrics {
                    LazyVGrid(columns: columns, spacing: 14) {
                        InfoTile("Model", value: m.modelName ?? "—", systemImage: "shippingbox.fill")
                        InfoTile("Running", value: intStr(m.requestsRunning),
                                 systemImage: "play.circle")
                        InfoTile("Queued", value: intStr(m.requestsWaiting),
                                 systemImage: "hourglass")
                        InfoTile("KV cache", value: pctStr(m.kvCacheUsage),
                                 systemImage: "memorychip.fill")
                        InfoTile("Generation", value: rateStr(m.generationTokensPerSec),
                                 systemImage: "speedometer")
                        InfoTile("Prompt", value: rateStr(m.promptTokensPerSec),
                                 systemImage: "text.word.spacing")
                    }
                } else {
                    Card {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.health == .unhealthy
                                 ? "Metrics endpoint unreachable on :\(model.settings.metricsPort)."
                                 : "Waiting for the model to load…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var healthPill: some View {
        let tint: Color = {
            switch model.health {
            case .serving: return .green
            case .loading: return .orange
            case .unhealthy: return .red
            case .stopped: return .secondary
            }
        }()
        return StatusPill(text: model.health.label, tint: tint,
                          pulsing: model.health == .loading)
    }

    private func intStr(_ v: Double?) -> String { v.map { String(Int($0)) } ?? "—" }
    private func pctStr(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    private func rateStr(_ v: Double?) -> String { v.map { String(format: "%.0f tok/s", $0) } ?? "—" }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard").font(.largeTitle.weight(.bold))
                Text("com.xerotier.xim-agent").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            controls
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            if model.serviceState == .running {
                Button {
                    Task { await model.stopService() }
                } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button {
                    Task { await model.startService() }
                } label: { Label("Start", systemImage: "play.fill") }
                .disabled(model.serviceState.isBusy)
            }
            Button {
                Task { await model.restartService() }
            } label: { Label("Restart", systemImage: "arrow.clockwise") }
            .disabled(model.serviceState != .running)

            Button(role: .destructive) {
                showUninstall = true
            } label: { Label("Uninstall", systemImage: "trash") }
        }
        .confirmationDialog("Uninstall the XIM agent?",
                            isPresented: $showUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstall() } }
            Button("Uninstall & purge venv + binary", role: .destructive) {
                Task { await model.uninstall(purge: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Uninstall stops the service and removes the LaunchAgent and rendered files. Purge also deletes ~/.venv-vllm-metal and the agent binary (a full reinstall rebuilds vLLM from source).")
        }
    }

    private var activityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Recent activity", systemImage: "waveform.path.ecg").font(.headline)
                    Spacer()
                    Button("View all logs") { model.selection = .logs }
                        .buttonStyle(.link)
                }
                let recent = model.logs.suffix(5).reversed()
                if recent.isEmpty {
                    Text("No activity yet.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(recent)) { line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
