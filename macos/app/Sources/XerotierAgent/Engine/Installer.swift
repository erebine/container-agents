// SPDX-License-Identifier: MIT
import Foundation

/// Executes one install-pipeline step for real. The step list and ordering
/// live in StepKind; AppModel drives them and renders status.
enum Installer {
    /// Run a single step. Returns true on success; emits progress to the log.
    static func perform(_ kind: StepKind,
                        settings: AgentSettings,
                        emit: @escaping LogEmit) async -> Bool {
        do {
            switch kind {
            case .preflight: return await preflight(emit: emit)
            case .python:    return await provisionPython(emit: emit)
            case .vllm:      return await installVLLM(force: settings.reinstallVLLM, emit: emit)
            case .download:  try await ReleaseFetcher.download(preRelease: settings.preRelease,
                                                              to: Paths.agentBin, emit: emit)
                             return true
            case .shim:      return await installShim(emit: emit)
            case .render:    try renderArtifacts(settings: settings, emit: emit); return true
            case .start:     return await ServiceController.start(emit: emit)
            }
        } catch {
            emit("ERROR: \(error.localizedDescription)", .err)
            return false
        }
    }

    // MARK: - Steps

    private static func preflight(emit: @escaping LogEmit) async -> Bool {
        let checks = await Preflight.run()
        for c in checks {
            emit("\(c.ok ? "✓" : "✗") \(c.name): \(c.detail)", c.ok ? .out : .err)
        }
        guard Preflight.requiredSatisfied(checks) else {
            emit("ERROR: required host checks failed.", .err)
            return false
        }
        return true
    }

    private static func provisionPython(emit: @escaping LogEmit) async -> Bool {
        var uv = Preflight.locateUV()
        if uv == nil {
            emit("uv not found; installing via the official installer…", .out)
            let code = await Shell.bash("curl -LsSf https://astral.sh/uv/install.sh | sh", emit: emit)
            guard code == 0 else { emit("ERROR: uv install failed.", .err); return false }
            uv = Preflight.locateUV() ?? Paths.binDir.appending(path: "uv").path
        }
        guard let uvPath = uv else { emit("ERROR: uv unavailable.", .err); return false }
        let code = await Shell.run(uvPath, ["python", "install", "3.12"], emit: emit)
        guard code == 0 else { emit("ERROR: could not provision Python 3.12 via uv.", .err); return false }
        return true
    }

    private static func installVLLM(force: Bool, emit: @escaping LogEmit) async -> Bool {
        if !force, FileManager.default.isExecutableFile(atPath: Paths.venvVLLM.path) {
            emit("vllm-metal already present at \(Paths.venv.path) (enable reinstall to rebuild).", .out)
            return true
        }
        emit("Installing vllm-metal (builds vLLM core from source; this can take a while)…", .out)
        let code = await Shell.bash(
            "curl -fsSL https://raw.githubusercontent.com/vllm-project/vllm-metal/main/install.sh | bash",
            emit: emit)
        guard code == 0, FileManager.default.isExecutableFile(atPath: Paths.venvVLLM.path) else {
            emit("ERROR: vllm-metal install did not produce \(Paths.venvVLLM.path).", .err)
            return false
        }
        return true
    }

    private static func installShim(emit: @escaping LogEmit) async -> Bool {
        let (code, raw) = await Shell.capture(Paths.venvPython.path,
            ["-c", "import sysconfig; print(sysconfig.get_path('purelib'))"])
        let site = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0, !site.isEmpty else {
            emit("ERROR: could not resolve venv site-packages.", .err)
            return false
        }
        do {
            let siteURL = URL(fileURLWithPath: site)
            try Templates.hfCompat.write(to: siteURL.appending(path: "xerotier_hf_compat.py"),
                                         atomically: true, encoding: .utf8)
            try "import xerotier_hf_compat\n".write(to: siteURL.appending(path: "xerotier_hf_compat.pth"),
                                                    atomically: true, encoding: .utf8)
        } catch {
            emit("ERROR: \(error.localizedDescription)", .err)
            return false
        }
        emit("Installed application support files into \(site).", .out)
        return true
    }

    private static func renderArtifacts(settings: AgentSettings, emit: @escaping LogEmit) throws {
        let fm = FileManager.default
        for dir in [Paths.binDir, Paths.logDir, Paths.launchAgentsDir, Paths.configDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try Templates.entrypoint.write(to: Paths.entrypoint, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.entrypoint.path)

        let wrapper = Templates.vllmWrapper(venvPython: Paths.venvPython.path)
        try wrapper.write(to: Paths.vllmWrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.vllmWrapper.path)

        try ServiceController.writePlist(settings: settings)
        emit("Rendered wrapper, entrypoint, and LaunchAgent.", .out)
    }
}
