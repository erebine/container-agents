// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Navigation

/// Top-level panes shown in the window sidebar.
/// (Named `Pane` rather than `Section` to avoid colliding with SwiftUI.Section.)
enum Pane: String, CaseIterable, Identifiable, Hashable {
    case setup
    case dashboard
    case settings
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .dashboard: return "Dashboard"
        case .settings: return "Settings"
        case .logs: return "Logs"
        }
    }

    var icon: String {
        switch self {
        case .setup: return "wand.and.stars"
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .settings: return "slider.horizontal.3"
        case .logs: return "text.alignleft"
        }
    }
}

// MARK: - Lifecycle state

/// Whether the agent + its runtime have been installed on this host.
enum InstallState: Equatable {
    case notInstalled
    case installing
    case installed
}

/// launchd service state for the per-user LaunchAgent.
enum ServiceState: String {
    case stopped
    case starting
    case running
    case stopping

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        }
    }

    var isBusy: Bool { self == .starting || self == .stopping }
}

/// Higher-level health derived from launchd state + metrics reachability.
enum AgentHealth {
    case stopped      // not running
    case loading      // running, metrics not reachable yet (model loading)
    case serving      // running, metrics reachable
    case unhealthy    // running but metrics unreachable for too long / crash-looping

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .loading: return "Loading…"
        case .serving: return "Serving"
        case .unhealthy: return "Unhealthy"
        }
    }
}

// MARK: - Install steps

/// The real install pipeline steps, in order.
enum StepKind: CaseIterable {
    case preflight
    case python
    case vllm
    case download
    case shim
    case render
    case start

    var title: String {
        switch self {
        case .preflight: return "Preflight host"
        case .python: return "Provision Python 3.12 (uv)"
        case .vllm: return "Install vllm-metal"
        case .download: return "Download agent binary"
        case .shim: return "Install application"
        case .render: return "Render LaunchAgent"
        case .start: return "Enroll & start service"
        }
    }

    var detail: String {
        switch self {
        case .preflight: return "Verify Apple Silicon (arm64), curl, and uv."
        case .python: return "uv provisions a pinned CPython 3.12 for the venv."
        case .vllm: return "Builds vLLM core from source — this is the slow step."
        case .download: return "Fetch xerotier-xim-agent-Darwin-arm64 from releases."
        case .shim: return "Install supporting application files into the environment."
        case .render: return "Write the wrapper, entrypoint, and plist."
        case .start: return "Enroll with the join key, then run under launchd."
        }
    }

    /// Simulated duration weight; the vLLM build is intentionally the longest.
    var simulatedSeconds: Double {
        switch self {
        case .vllm: return 2.6
        case .download: return 1.2
        case .start: return 1.1
        default: return 0.8
        }
    }
}

enum StepStatus {
    case pending
    case running
    case done
    case failed
}

struct InstallStep: Identifiable {
    let kind: StepKind
    var status: StepStatus = .pending
    var id: StepKind { kind }
    var title: String { kind.title }
    var detail: String { kind.detail }
}

// MARK: - Logs

enum LogStream: String, CaseIterable, Identifiable {
    case out = "stdout"
    case err = "stderr"
    var id: String { rawValue }
}

struct LogLine: Identifiable {
    let id = UUID()
    let timestamp: Date
    let stream: LogStream
    let text: String
}

// MARK: - Settings

/// Mirrors the XEROTIER_AGENT_* environment surface from macos/README.md.
struct AgentSettings: Equatable {
    var joinKey: String = ""
    var preRelease: Bool = false
    var reinstallVLLM: Bool = false
    /// Ceiling for concurrent requests. Empty = the agent auto-configures it
    /// from the GPU/model (usually > 1). XEROTIER_AGENT_MAX_CONCURRENT.
    var maxConcurrent: String = ""
    var logLevel: String = "info"
    var allowInsecure: Bool = false
    var metricsPort: String = "9094"
    var disableMetrics: Bool = false
    /// Fraction (0–1) of the GPU memory budget vLLM may use. Empty = agent
    /// default (0.95). XEROTIER_AGENT_GPU_MEMORY_UTILIZATION.
    var gpuMemoryUtilization: String = ""
    /// Max concurrent sequences vLLM batches. Lower it to free KV-cache memory
    /// for longer context. Empty = agent default (64). XEROTIER_AGENT_MAX_NUM_SEQS.
    var maxNumSeqs: String = ""
    /// Maximum model context length (caps KV-cache allocation). Empty = derived
    /// from the model. XEROTIER_AGENT_MAX_MODEL_LEN.
    var maxModelLen: String = ""
    /// Force a quantization method. Empty = auto-detect. XEROTIER_AGENT_VLLM_QUANTIZATION.
    var quantization: String = ""
    /// KV-cache backend: native | lmcache | none. Empty = agent default.
    /// XEROTIER_AGENT_KV_CACHE_BACKEND.
    var kvCacheBackend: String = ""
    /// Model-cache size cap in GB. Empty = agent default (100).
    /// XEROTIER_AGENT_MODEL_CACHE_MAX_SIZE_GB.
    var modelCacheMaxSizeGB: String = ""
    /// Speculative decoding (env-only on the agent: XEROTIER_AGENT_SPECULATIVE_*).
    var speculativeEnabled: Bool = false
    var speculativeMethod: String = ""
    var speculativeTokens: String = ""
    var vllmArgs: String = ""
    var vllmEnv: String = ""

    static let logLevels = ["trace", "debug", "info", "notice", "warning", "error", "critical"]
    static let quantizations = ["fp8", "awq", "gptq", "bitsandbytes", "bitsandbytes-fp4"]
    static let kvBackends = ["native", "lmcache", "none"]
    static let speculativeMethods = ["ngram", "eagle", "medusa", "deepseek_mtp"]

    /// Human-readable validation problems; empty means valid.
    func validationErrors() -> [String] {
        var errs: [String] = []

        func posInt(_ value: String, _ name: String) {
            let t = value.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            if Int(t).map({ $0 <= 0 }) ?? true { errs.append("\(name) must be a positive whole number.") }
        }
        posInt(maxConcurrent, "Max concurrent requests")
        posInt(maxNumSeqs, "Max sequences")
        posInt(maxModelLen, "Max context length")
        posInt(modelCacheMaxSizeGB, "Model cache size")
        if speculativeEnabled { posInt(speculativeTokens, "Speculative tokens") }

        let portText = metricsPort.trimmingCharacters(in: .whitespaces)
        if !portText.isEmpty, !(Int(portText).map { (1...65535).contains($0) } ?? false) {
            errs.append("Metrics port must be between 1 and 65535.")
        }

        let g = gpuMemoryUtilization.trimmingCharacters(in: .whitespaces)
        if !g.isEmpty {
            if let d = Double(g) {
                let frac = d > 1 ? d / 100 : d
                if frac <= 0 || frac > 1 { errs.append("GPU memory utilization must be between 0 and 1.") }
            } else {
                errs.append("GPU memory utilization must be a number.")
            }
        }
        return errs
    }
}
