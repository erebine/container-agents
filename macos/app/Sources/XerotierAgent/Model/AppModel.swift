// SPDX-License-Identifier: MIT
import SwiftUI
import Observation

/// Central app state for the Xerotier XIM agent GUI.
///
/// State mutations happen on the main actor; the engine layer (Installer,
/// ServiceController, …) does its blocking work off-main and reports back
/// through `emit`, which hops to the main actor.
@MainActor
@Observable
final class AppModel {
    // Lifecycle
    var installState: InstallState = .notInstalled
    var serviceState: ServiceState = .stopped
    var isEnrolled = false

    // Configuration (shared by Onboarding + Settings)
    var settings = AgentSettings()
    // Snapshot of what's actually applied to the plist, for dirty-tracking.
    var appliedSettings = AgentSettings()

    var settingsErrors: [String] { settings.validationErrors() }
    var settingsDirty: Bool { settings != appliedSettings }
    /// Apply is allowed only when installed, with valid + changed settings.
    var canApply: Bool {
        installState == .installed && settingsDirty && settingsErrors.isEmpty
    }

    // Host inspection
    var preflightChecks: [PreflightCheck] = []

    // Install pipeline
    var steps: [InstallStep] = StepKind.allCases.map { InstallStep(kind: $0) }

    // Observability
    var logs: [LogLine] = []

    // Navigation
    var selection: Pane? = .setup

    // The agent reports Apple Silicon as a single unified-memory accelerator;
    // detected live from Metal on launch.
    var accelerator: AcceleratorInfo?
    var acceleratorName: String { accelerator?.name ?? "Apple Metal" }
    var vramBudget: String { accelerator?.budgetDisplay ?? "unified memory" }

    // Live metrics + health (polled while installed).
    var metrics: MetricsSnapshot?
    var health: AgentHealth = .stopped

    private let tailer = LogTailer()
    private var monitorTask: Task<Void, Never>?

    // Monitoring bookkeeping.
    private var userInitiatedStop = false       // suppress "stopped unexpectedly" alerts
    private var runningSince: Date?
    private var lastMetricsReachable: Date?
    private var prevGenTokens: Double?
    private var prevPromptTokens: Double?
    private var prevSampleAt: Date?
    private var prevRuns: Int?
    private var lastCrashNotify: Date?

    var menuBarSymbol: String {
        serviceState == .running ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
    }

    var statusSummary: String {
        switch installState {
        case .notInstalled: return "Not installed"
        case .installing: return "Installing…"
        case .installed: return serviceState.label
        }
    }

    var requiredPreflightOK: Bool {
        preflightChecks.isEmpty || Preflight.requiredSatisfied(preflightChecks)
    }

    // MARK: - Startup

    /// Inspect the host and reflect any existing install. Safe / side-effect free.
    func bootstrap() async {
        accelerator = Accelerator.detect()
        preflightChecks = await Preflight.run()
        await refreshState()
        if installState == .installed {
            // Reflect the actual running config (incl. join key) so edits +
            // Apply & Restart rewrite a complete plist.
            if let loaded = ServiceController.loadSettings() { settings = loaded }
            // Open the Dashboard rather than the (now irrelevant) Setup pane.
            selection = .dashboard
        }
        // Baseline for dirty-tracking = what's actually on disk.
        appliedSettings = settings
        // Default GPU utilization to the detected Metal budget as a fraction of
        // total memory, unless the user already set one. Shows as a pending change.
        if settings.gpuMemoryUtilization.trimmingCharacters(in: .whitespaces).isEmpty,
           let acc = accelerator {
            settings.gpuMemoryUtilization = acc.recommendedUtilizationString
        }
        startMonitoring()
    }

    // MARK: - Monitoring (status + metrics + alerts)

    func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func tick() async {
        guard installState == .installed else {
            metrics = nil; health = .stopped; return
        }
        // Don't fight in-flight user actions (start/stop set transient states).
        if serviceState.isBusy { return }

        let detail = await ServiceController.statusDetail()
        detectCrashLoop(detail)
        detectUnexpectedStop(newState: detail.state)
        serviceState = detail.state

        if detail.state == .running {
            if runningSince == nil { runningSince = Date() }
            await pollMetrics()
        } else {
            runningSince = nil
            metrics = nil
            health = .stopped
        }
        prevRuns = detail.runs
    }

    private func pollMetrics() async {
        let snap = await Metrics.fetch(port: settings.metricsPort)
        let now = Date()
        guard var snap else {
            // Unreachable: loading while fresh, unhealthy if running a while.
            metrics = nil
            let elapsed = runningSince.map { now.timeIntervalSince($0) } ?? 0
            health = elapsed > 90 ? .unhealthy : .loading
            prevGenTokens = nil; prevPromptTokens = nil; prevSampleAt = nil
            return
        }
        if let dt = prevSampleAt.map({ now.timeIntervalSince($0) }), dt > 0.5 {
            if let g = snap.generationTokensTotal, let pg = prevGenTokens {
                snap.generationTokensPerSec = max(0, (g - pg) / dt)
            }
            if let p = snap.promptTokensTotal, let pp = prevPromptTokens {
                snap.promptTokensPerSec = max(0, (p - pp) / dt)
            }
        }
        prevGenTokens = snap.generationTokensTotal
        prevPromptTokens = snap.promptTokensTotal
        prevSampleAt = now
        lastMetricsReachable = now
        metrics = snap
        health = .serving
    }

    private func detectUnexpectedStop(newState: ServiceState) {
        if serviceState == .running, newState == .stopped, !userInitiatedStop {
            Notifier.post("Xerotier agent stopped",
                          "The agent is no longer running. Open Xerotier to restart it.")
            appendLog("Agent stopped unexpectedly.", stream: .err)
        }
        if newState == .stopped { userInitiatedStop = false }
    }

    private func detectCrashLoop(_ detail: ServiceController.StatusDetail) {
        guard let prev = prevRuns, detail.runs > prev, detail.lastExitCode != 0 else { return }
        let now = Date()
        if let last = lastCrashNotify, now.timeIntervalSince(last) < 60 { return }
        lastCrashNotify = now
        Notifier.post("Xerotier agent crashed",
                      "The agent exited with code \(detail.lastExitCode) and is being restarted.")
        appendLog("Agent crashed (exit \(detail.lastExitCode)); launchd is restarting it.", stream: .err)
    }

    func runPreflight() async {
        preflightChecks = await Preflight.run()
    }

    func refreshState() async {
        if ServiceController.isInstalled() {
            installState = .installed
            isEnrolled = ServiceController.isEnrolled()
            serviceState = await ServiceController.status()
            if serviceState == .running { tailer.start(emit: emit) }
        } else {
            installState = .notInstalled
            isEnrolled = false
            serviceState = .stopped
            for i in steps.indices { steps[i].status = .pending }
        }
    }

    // MARK: - Logging

    /// Thread-safe log sink handed to the engine. Hops to the main actor.
    nonisolated func emit(_ text: String, _ stream: LogStream) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.appendLog(text, stream: stream) }
        }
    }

    func appendLog(_ text: String, stream: LogStream = .out) {
        logs.append(LogLine(timestamp: Date(), stream: stream, text: text))
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
    }

    func clearLogs() { logs.removeAll() }

    // MARK: - Install

    func runInstall() async {
        guard installState != .installing,
              !settings.joinKey.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }

        installState = .installing
        selection = .setup
        for i in steps.indices { steps[i].status = .pending }
        appendLog("Starting Xerotier XIM agent installation…")

        for i in steps.indices {
            steps[i].status = .running
            let ok = await Installer.perform(steps[i].kind, settings: settings, emit: emit)
            steps[i].status = ok ? .done : .failed
            if !ok {
                appendLog("Install halted at: \(steps[i].title)", stream: .err)
                installState = .notInstalled
                return
            }
        }

        isEnrolled = ServiceController.isEnrolled()
        installState = .installed
        appliedSettings = settings
        serviceState = await ServiceController.status()
        if serviceState == .running { tailer.start(emit: emit) }
        selection = .dashboard
        appendLog("Install complete. Service: \(serviceState.label).")
        Notifier.post("Xerotier agent installed", "The agent is enrolled and running.")
    }

    // MARK: - Service control

    func startService() async {
        guard installState == .installed, serviceState == .stopped else { return }
        serviceState = .starting
        let ok = await ServiceController.start(emit: emit)
        if !ok { appendLog("Failed to start service.", stream: .err) }
        serviceState = await ServiceController.status()
        if serviceState == .running { tailer.start(emit: emit) }
    }

    func stopService() async {
        guard serviceState == .running else { return }
        userInitiatedStop = true
        serviceState = .stopping
        tailer.stop()
        await ServiceController.stop(emit: emit)
        serviceState = await ServiceController.status()
    }

    func restartService() async {
        await stopService()
        await startService()
    }

    /// Re-render the plist with current settings, then restart so they apply.
    func applyAndRestart() async {
        guard installState == .installed, settingsErrors.isEmpty else { return }
        do {
            try ServiceController.applyConfig(settings: settings)
            appliedSettings = settings
        } catch {
            appendLog("Failed to apply config: \(error.localizedDescription)", stream: .err)
        }
        await restartService()
    }

    /// Re-bootstrap the installed agent with the current join key: stop, clear
    /// enrollment state, rewrite the plist, and start (which re-enrolls).
    func reEnroll() async {
        guard installState == .installed else { return }
        guard !settings.joinKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            appendLog("Enter a join key before re-enrolling.", stream: .err)
            return
        }
        userInitiatedStop = true
        serviceState = .stopping
        tailer.stop()
        appendLog("Re-enrolling: stopping agent and clearing enrollment state…")
        await ServiceController.stop(emit: emit)
        ServiceController.clearEnrollment()
        isEnrolled = false
        do {
            try ServiceController.applyConfig(settings: settings)
            appliedSettings = settings
        } catch {
            appendLog("Failed to apply config: \(error.localizedDescription)", stream: .err)
        }

        serviceState = .starting
        let ok = await ServiceController.start(emit: emit)
        if !ok { appendLog("Failed to start service.", stream: .err) }
        serviceState = await ServiceController.status()
        isEnrolled = ServiceController.isEnrolled()
        if serviceState == .running { tailer.start(emit: emit) }
        appendLog("Re-enroll complete. Service: \(serviceState.label).")
    }

    func uninstall(purge: Bool = false) async {
        userInitiatedStop = true
        tailer.stop()
        await ServiceController.uninstall(purge: purge, emit: emit)
        await refreshState()
        selection = .setup
    }
}
