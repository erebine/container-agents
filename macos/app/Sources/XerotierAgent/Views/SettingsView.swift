// SPDX-License-Identifier: MIT
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showReenroll = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Enrollment") {
                TextField("Join key", text: $model.settings.joinKey)
                    .font(.body.monospaced())
                Toggle("Allow prerelease", isOn: $model.settings.preRelease)
                Button("Re-enroll with this join key") { showReenroll = true }
                    .disabled(model.installState != .installed
                              || model.settings.joinKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    .confirmationDialog("Re-enroll the agent?",
                                        isPresented: $showReenroll, titleVisibility: .visible) {
                        Button("Re-enroll", role: .destructive) { Task { await model.reEnroll() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Stops the agent, clears its current enrollment, and re-bootstraps with the join key above — the agent rejoins the router as a fresh enrollment. Use this to switch join keys without a full reinstall.")
                    }
            }

            Section("Runtime") {
                TextField("Max concurrent requests", text: $model.settings.maxConcurrent,
                          prompt: Text("auto"))
                Text("XEROTIER_AGENT_MAX_CONCURRENT. Leave blank to let the agent auto-configure it from the GPU/model (usually > 1).")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Log level", selection: $model.settings.logLevel) {
                    ForEach(AgentSettings.logLevels, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Allow insecure transport", isOn: $model.settings.allowInsecure)
            }

            Section("GPU & model tuning") {
                TextField("GPU memory utilization", text: $model.settings.gpuMemoryUtilization,
                          prompt: Text("0.90"))
                Text("Fraction (0–1) of the \(model.acceleratorName) budget (\(model.vramBudget)) vLLM may use. Accepts 0.9 or 90. Blank = agent default (0.95).")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("Max sequences", text: $model.settings.maxNumSeqs,
                          prompt: Text("64"))
                Text("Max concurrent sequences (--max-num-seqs). Lower it to free KV-cache memory for longer context. Blank = agent default (64).")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("Max context length", text: $model.settings.maxModelLen,
                          prompt: Text("auto"))
                Text("Maximum model context length (--max-model-len). Blank = derived from the model.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Picker("Quantization", selection: $model.settings.quantization) {
                    Text("Auto").tag("")
                    ForEach(AgentSettings.quantizations, id: \.self) { Text($0).tag($0) }
                }
                Picker("KV cache backend", selection: $model.settings.kvCacheBackend) {
                    Text("Default").tag("")
                    ForEach(AgentSettings.kvBackends, id: \.self) { Text($0).tag($0) }
                }
                TextField("Model cache size (GB)", text: $model.settings.modelCacheMaxSizeGB,
                          prompt: Text("100"))
            }

            Section("Speculative decoding") {
                Toggle("Enable speculative decoding", isOn: $model.settings.speculativeEnabled)
                if model.settings.speculativeEnabled {
                    Picker("Method", selection: $model.settings.speculativeMethod) {
                        Text("Default").tag("")
                        ForEach(AgentSettings.speculativeMethods, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Tokens per step", text: $model.settings.speculativeTokens,
                              prompt: Text("5"))
                }
            }

            Section("Metrics") {
                TextField("Metrics port", text: $model.settings.metricsPort)
                    .disabled(model.settings.disableMetrics)
                Toggle("Disable metrics server", isOn: $model.settings.disableMetrics)
            }

            Section("vLLM") {
                TextField("Extra vLLM args", text: $model.settings.vllmArgs,
                          prompt: Text("--enforce-eager"))
                TextField("Extra vLLM env", text: $model.settings.vllmEnv,
                          prompt: Text("KEY=VALUE KEY2=VALUE2"))
                Text("Passed through the xerotier-vllm wrapper to vLLM.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.settingsErrors, id: \.self) { err in
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if model.settingsDirty {
                        Label("Unsaved changes", systemImage: "pencil.circle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Changes apply on the next service restart.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply & Restart") {
                        Task { await model.applyAndRestart() }
                    }
                    .disabled(!model.canApply)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
