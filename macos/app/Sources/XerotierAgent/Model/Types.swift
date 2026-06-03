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
struct AgentSettings {
    var joinKey: String = ""
    var preRelease: Bool = false
    var reinstallVLLM: Bool = false
    var maxConcurrent: String = "1"
    var logLevel: String = "info"
    var allowInsecure: Bool = false
    var metricsPort: String = "9090"
    var disableMetrics: Bool = false
    var vllmArgs: String = ""
    var vllmEnv: String = ""

    static let logLevels = ["trace", "debug", "info", "warn", "error"]
}
