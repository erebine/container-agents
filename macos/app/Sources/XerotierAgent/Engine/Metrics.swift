// SPDX-License-Identifier: MIT
import Foundation

/// One parsed Prometheus sample: `name{labels} value`.
struct MetricSample {
    let name: String
    let labels: [String: String]
    let value: Double
}

/// The subset of agent/vLLM metrics the dashboard surfaces. Counters are raw
/// totals; per-second rates are computed by the poller from successive reads.
struct MetricsSnapshot {
    var modelName: String?
    var requestsRunning: Double?
    var requestsWaiting: Double?
    var kvCacheUsage: Double?            // 0–1
    var promptTokensTotal: Double?
    var generationTokensTotal: Double?

    // Filled in by the poller from deltas:
    var generationTokensPerSec: Double?
    var promptTokensPerSec: Double?
}

enum Metrics {
    /// Fetch + parse the agent's Prometheus endpoint. Returns nil when the
    /// endpoint is unreachable (agent down, still loading, or metrics disabled).
    static func fetch(port: String) async -> MetricsSnapshot? {
        let p = port.trimmingCharacters(in: .whitespaces).isEmpty ? "9094" : port
        guard let url = URL(string: "http://127.0.0.1:\(p)/metrics") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return snapshot(from: parse(text))
    }

    static func parse(_ text: String) -> [MetricSample] {
        var out: [MetricSample] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let lastSpace = line.lastIndex(of: " "),
                  let value = Double(line[line.index(after: lastSpace)...]) else { continue }
            let lhs = line[..<lastSpace]
            if let brace = lhs.firstIndex(of: "{"), let end = lhs.lastIndex(of: "}") {
                let name = String(lhs[..<brace]).trimmingCharacters(in: .whitespaces)
                let labels = parseLabels(String(lhs[lhs.index(after: brace)..<end]))
                out.append(MetricSample(name: name, labels: labels, value: value))
            } else {
                out.append(MetricSample(name: String(lhs).trimmingCharacters(in: .whitespaces),
                                        labels: [:], value: value))
            }
        }
        return out
    }

    private static func parseLabels(_ s: String) -> [String: String] {
        var labels: [String: String] = [:]
        // key="value",key2="value2" — naive split is fine for vLLM's label set.
        for pair in s.split(separator: ",") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<eq].trimmingCharacters(in: .whitespaces)
            var val = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            labels[key] = val
        }
        return labels
    }

    /// Metric names drift across vLLM versions, so match by substring with sums
    /// across labelsets where appropriate.
    private static func snapshot(from samples: [MetricSample]) -> MetricsSnapshot {
        func first(_ needle: String) -> Double? {
            samples.first { $0.name.contains(needle) }?.value
        }
        func sum(_ needle: String) -> Double? {
            let matches = samples.filter { $0.name.contains(needle) }
            return matches.isEmpty ? nil : matches.reduce(0) { $0 + $1.value }
        }
        var snap = MetricsSnapshot()
        snap.requestsRunning = first("num_requests_running")
        snap.requestsWaiting = first("num_requests_waiting")
        snap.kvCacheUsage = first("gpu_cache_usage") ?? first("kv_cache_usage")
        snap.promptTokensTotal = sum("prompt_tokens_total")
        snap.generationTokensTotal = sum("generation_tokens_total")
        snap.modelName = samples.compactMap { $0.labels["model_name"] }
            .first { !$0.isEmpty }
        return snap
    }
}
