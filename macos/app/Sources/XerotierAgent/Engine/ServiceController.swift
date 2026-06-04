// SPDX-License-Identifier: MIT
import Foundation

/// Manages the per-user LaunchAgent via `launchctl`. (SMAppService is the
/// App-Store-friendly alternative but can't carry the dynamically-rendered
/// plist + join key, so we bootstrap a plist written into ~/Library/LaunchAgents.)
enum ServiceController {
    static func isInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: Paths.agentBin.path)
    }

    static func isEnrolled() -> Bool {
        FileManager.default.fileExists(atPath: Paths.enrollmentState.path)
    }

    /// Inspect launchd for the agent's current state.
    static func status() async -> ServiceState {
        await statusDetail().state
    }

    struct StatusDetail {
        var state: ServiceState
        var runs: Int          // total launch count (climbs on KeepAlive restarts)
        var lastExitCode: Int  // last process exit status (0 = clean)
    }

    /// Like status(), plus launchd's run count and last exit code — used to
    /// detect crash/restart loops.
    static func statusDetail() async -> StatusDetail {
        let (code, out) = await Shell.capture("/bin/launchctl", ["print", Paths.serviceTarget])
        guard code == 0 else { return StatusDetail(state: .stopped, runs: 0, lastExitCode: 0) }
        let running = out.contains("state = running") || out.contains("pid = ")
        return StatusDetail(state: running ? .running : .stopped,
                            runs: intField(out, "runs = "),
                            lastExitCode: intField(out, "last exit code = "))
    }

    private static func intField(_ text: String, _ key: String) -> Int {
        guard let r = text.range(of: key) else { return 0 }
        let rest = text[r.upperBound...].prefix { $0.isNumber || $0 == "-" }
        return Int(rest) ?? 0
    }

    /// Build the LaunchAgent plist from current settings and write it out.
    static func writePlist(settings: AgentSettings) throws {
        var env: [String: String] = [
            "HOME": Paths.home.path,
            "PATH": "\(Paths.venv.path)/bin:\(Paths.binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        func put(_ key: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { env[key] = v }
        }
        // The agent reads these directly from the environment (each option
        // documents an `env:` equivalent), so we set the dedicated vars rather
        // than duplicating vLLM flags via --vllm-arg. Empty values are omitted,
        // which lets the agent apply its own default / auto-configuration.
        put("XEROTIER_AGENT_JOIN_KEY", settings.joinKey)
        put("XEROTIER_AGENT_MAX_CONCURRENT", settings.maxConcurrent)
        put("XEROTIER_AGENT_LOG_LEVEL", settings.logLevel)
        put("XEROTIER_AGENT_METRICS_PORT", settings.metricsPort)
        put("XEROTIER_AGENT_GPU_MEMORY_UTILIZATION", normalizedFraction(settings.gpuMemoryUtilization))
        put("XEROTIER_AGENT_MAX_NUM_SEQS", settings.maxNumSeqs)
        put("XEROTIER_AGENT_MAX_MODEL_LEN", settings.maxModelLen)
        put("XEROTIER_AGENT_VLLM_QUANTIZATION", settings.quantization)
        put("XEROTIER_AGENT_KV_CACHE_BACKEND", settings.kvCacheBackend)
        put("XEROTIER_AGENT_MODEL_CACHE_MAX_SIZE_GB", settings.modelCacheMaxSizeGB)
        put("XEROTIER_AGENT_VLLM_ARGS", settings.vllmArgs)
        put("XEROTIER_AGENT_VLLM_ENV", settings.vllmEnv)
        if settings.allowInsecure { env["XEROTIER_AGENT_ALLOW_INSECURE"] = "1" }
        if settings.disableMetrics { env["XEROTIER_AGENT_DISABLE_METRICS_SERVER"] = "1" }
        if settings.speculativeEnabled {
            env["XEROTIER_AGENT_SPECULATIVE_ENABLED"] = "1"
            put("XEROTIER_AGENT_SPECULATIVE_METHOD", settings.speculativeMethod)
            put("XEROTIER_AGENT_SPECULATIVE_TOKENS", settings.speculativeTokens)
        }

        let plist: [String: Any] = [
            "Label": Paths.label,
            "ProgramArguments": [Paths.entrypoint.path],
            "EnvironmentVariables": env,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": Paths.outLog.path,
            "StandardErrorPath": Paths.errLog.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try FileManager.default.createDirectory(at: Paths.launchAgentsDir,
                                                withIntermediateDirectories: true)
        try data.write(to: Paths.plist)
    }

    /// Enable + (re)bootstrap the agent so it runs now and at login.
    @discardableResult
    static func start(emit: @escaping LogEmit) async -> Bool {
        // Clear any prior disabled state (from stop) before bootstrapping.
        await Shell.run("/bin/launchctl", ["enable", Paths.serviceTarget], emit: { _, _ in })
        await Shell.run("/bin/launchctl", ["bootout", Paths.serviceTarget], emit: { _, _ in })
        let code = await Shell.run("/bin/launchctl",
                                   ["bootstrap", Paths.domainTarget, Paths.plist.path],
                                   emit: emit)
        return code == 0
    }

    /// Stop the agent and forcibly reap everything it spawned. A graceful
    /// `bootout` tells the agent to shut down, but vLLM/MLX worker processes can
    /// outlive it; this escalates to ensure nothing is left holding the GPU.
    static func stop(emit: @escaping LogEmit) async {
        // Remove the job from launchd first so KeepAlive can't relaunch anything
        // we're about to kill.
        await Shell.run("/bin/launchctl", ["bootout", Paths.serviceTarget], emit: emit)
        await Shell.run("/bin/launchctl", ["disable", Paths.serviceTarget], emit: { _, _ in })

        emit("Force-stopping any lingering agent / vLLM processes…", .out)
        await reap(signal: "TERM")
        try? await Task.sleep(for: .seconds(2))
        await reap(signal: "KILL")
    }

    /// Signal lingering processes: the agent binary by absolute path, and
    /// anything launched from the vLLM venv (the wrapper interpreter plus every
    /// vllm/MLX subprocess, which all carry the venv path on their command line).
    private static func reap(signal: String) async {
        for pattern in [Paths.agentBin.path, Paths.venv.path] {
            await Shell.run("/usr/bin/pkill", ["-\(signal)", "-f", pattern], emit: { _, _ in })
        }
    }

    /// (Re)write the entrypoint and plist together. Re-rendering the entrypoint
    /// on every apply ensures existing installs pick up template changes (e.g.
    /// new flag forwarding) without a full reinstall.
    static func applyConfig(settings: AgentSettings) throws {
        try renderEntrypoint()
        try writePlist(settings: settings)
    }

    static func renderEntrypoint() throws {
        try FileManager.default.createDirectory(at: Paths.binDir, withIntermediateDirectories: true)
        try Templates.entrypoint.write(to: Paths.entrypoint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: Paths.entrypoint.path)
    }

    /// Delete the local enrollment state so the next start re-enrolls (used to
    /// re-bootstrap with a new join key).
    static func clearEnrollment() {
        try? FileManager.default.removeItem(at: Paths.enrollmentState)
    }

    /// Read the installed plist's environment back into AgentSettings so the UI
    /// reflects the actual running configuration (and Apply & Restart rewrites a
    /// complete plist instead of wiping the join key with session defaults).
    static func loadSettings() -> AgentSettings? {
        guard let data = try? Data(contentsOf: Paths.plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = obj as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: String]
        else { return nil }

        var s = AgentSettings()
        s.joinKey = env["XEROTIER_AGENT_JOIN_KEY"] ?? ""
        s.maxConcurrent = env["XEROTIER_AGENT_MAX_CONCURRENT"] ?? ""
        if let v = env["XEROTIER_AGENT_LOG_LEVEL"] { s.logLevel = v }
        if let v = env["XEROTIER_AGENT_METRICS_PORT"] { s.metricsPort = v }
        s.gpuMemoryUtilization = env["XEROTIER_AGENT_GPU_MEMORY_UTILIZATION"] ?? ""
        s.maxNumSeqs = env["XEROTIER_AGENT_MAX_NUM_SEQS"] ?? ""
        s.maxModelLen = env["XEROTIER_AGENT_MAX_MODEL_LEN"] ?? ""
        s.quantization = env["XEROTIER_AGENT_VLLM_QUANTIZATION"] ?? ""
        s.kvCacheBackend = env["XEROTIER_AGENT_KV_CACHE_BACKEND"] ?? ""
        s.modelCacheMaxSizeGB = env["XEROTIER_AGENT_MODEL_CACHE_MAX_SIZE_GB"] ?? ""
        s.speculativeEnabled = boolEnv(env["XEROTIER_AGENT_SPECULATIVE_ENABLED"])
        s.speculativeMethod = env["XEROTIER_AGENT_SPECULATIVE_METHOD"] ?? ""
        s.speculativeTokens = env["XEROTIER_AGENT_SPECULATIVE_TOKENS"] ?? ""
        s.vllmArgs = env["XEROTIER_AGENT_VLLM_ARGS"] ?? ""
        s.vllmEnv = env["XEROTIER_AGENT_VLLM_ENV"] ?? ""
        s.allowInsecure = boolEnv(env["XEROTIER_AGENT_ALLOW_INSECURE"])
        s.disableMetrics = boolEnv(env["XEROTIER_AGENT_DISABLE_METRICS_SERVER"])
        return s
    }

    private static func boolEnv(_ v: String?) -> Bool {
        guard let v = v?.lowercased() else { return false }
        return v == "1" || v == "true"
    }

    /// Accept "90" or "0.9" for a 0–1 fraction; values > 1 are treated as a
    /// percentage.
    static func normalizedFraction(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let d = Double(t), d > 1 else { return t }
        return String(d / 100)
    }

    static func uninstall(purge: Bool, emit: @escaping LogEmit) async {
        await stop(emit: emit)
        for url in [Paths.plist, Paths.vllmWrapper, Paths.entrypoint] {
            try? FileManager.default.removeItem(at: url)
        }
        emit("Removed LaunchAgent and rendered files.", .out)
        if purge {
            try? FileManager.default.removeItem(at: Paths.agentBin)
            try? FileManager.default.removeItem(at: Paths.venv)
            emit("Purged agent binary and venv.", .out)
        }
    }
}
