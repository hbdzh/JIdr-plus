// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct DeviceBudget: Decodable, Equatable {
    struct Usage: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let expected_mb: UInt64
        let measured_mb: UInt64?
        var countedMB: UInt64 { max(expected_mb, measured_mb ?? 0) }
    }
    let total_mb: UInt64
    let available_mb: UInt64
    let budget_percent: Int
    let budget_mb: UInt64
    let used_mb: UInt64
    let devices: [Usage]

    var fraction: Double { budget_mb == 0 ? 0 : min(1, Double(used_mb) / Double(budget_mb)) }
    static func gigabytes(_ mb: UInt64) -> String { String(format: "%.1f GB", Double(mb) / 1024) }
}

struct BudgetRefusal: Decodable {
    let needed_mb: UInt64
    let used_mb: UInt64
    let budget_mb: UInt64
    var freeMB: UInt64 { budget_mb > used_mb ? budget_mb - used_mb : 0 }
    func message(language: Int) -> String {
        let needed = DeviceBudget.gigabytes(needed_mb), free = DeviceBudget.gigabytes(freeMB)
        return language == 0
            ? "Not enough device memory budget: this device needs \(needed), and \(free) remains. Hibernate or stop another device, or change the budget in Settings."
            : "设备内存预算不足：此设备需要 \(needed)，剩余 \(free)。请休眠或停止其他设备，或在设置中调整预算。"
    }
}
