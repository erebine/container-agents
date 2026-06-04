// SPDX-License-Identifier: MIT
import Foundation
import Metal

/// Live readout of the Apple GPU the agent reports as its accelerator. Mirrors
/// the agent's own GPUResources.detect() on macOS: a single unified-memory
/// device whose budget is MTLDevice.recommendedMaxWorkingSetSize.
struct AcceleratorInfo {
    let name: String
    let workingSetBytes: UInt64
    let unifiedMemory: Bool
    let totalRAMBytes: UInt64

    var budgetDisplay: String { Self.bytes(workingSetBytes) }
    var totalRAMDisplay: String { Self.bytes(totalRAMBytes) }

    /// The Metal recommended working-set budget as a fraction of total unified
    /// memory — a sensible default for vLLM's --gpu-memory-utilization (e.g. an
    /// ~11.8 GB budget on a 16 GB Mac ≈ 0.74).
    var recommendedUtilization: Double {
        guard totalRAMBytes > 0 else { return 0.9 }
        return min(0.95, Double(workingSetBytes) / Double(totalRAMBytes))
    }
    var recommendedUtilizationString: String {
        String(format: "%.2f", recommendedUtilization)
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}

enum Accelerator {
    /// Synchronous and cheap; returns nil on the (Apple-Silicon-impossible)
    /// case of no Metal device.
    static func detect() -> AcceleratorInfo? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return AcceleratorInfo(
            name: device.name,
            workingSetBytes: device.recommendedMaxWorkingSetSize,
            unifiedMemory: device.hasUnifiedMemory,
            totalRAMBytes: ProcessInfo.processInfo.physicalMemory
        )
    }
}
