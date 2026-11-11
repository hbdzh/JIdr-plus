// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct PendingLicense: Decodable, Identifiable {
    let id: String
    let sha256: String
    let text: String
}

/// An immutable record of exactly what the user was shown before installation.
struct SDKInstallPlan {
    let imagePackage: String?
    let licenses: [PendingLicense]

    func consentRequests(reviewed: Bool) throws -> [[String:String]] {
        guard licenses.isEmpty || reviewed else { throw PlanError.consentRequired }
        guard licenses.allSatisfy({ !$0.id.isEmpty && !$0.sha256.isEmpty && !$0.text.isEmpty }) else {
            throw PlanError.invalidLicense
        }
        return licenses.map { ["id":$0.id, "sha256":$0.sha256] }
    }
    var method: String { imagePackage == nil ? "sdk.install" : "image.install" }
    var parameters: [String:Any] {
        imagePackage.map { ["image":$0] } ?? ["packages":["emulator", "platform-tools"]]
    }
    static func wasCancelled(_ message: String, requested: Bool) -> Bool {
        let lower = message.lowercased()
        return requested && (lower.contains("cancelled") || lower.contains("canceled"))
    }
    static func validProgress(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
    }
    enum PlanError: Error { case consentRequired, invalidLicense }
}
