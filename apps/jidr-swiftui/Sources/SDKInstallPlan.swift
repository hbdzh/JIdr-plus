// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Invalidates late replies when the user cancels installation preparation.
struct SDKPreparationAttempt {
    private(set) var revision = 0
    mutating func begin() -> Int { revision += 1; return revision }
    mutating func cancel() { revision += 1 }
    func isCurrent(_ revision: Int) -> Bool { self.revision == revision }
}

/// Holds a cancellation until the installer reports its job ID, and sends it once.
struct SDKCancellationRequest {
    private(set) var pending = false
    private var dispatchedJob: String?
    mutating func request() -> Bool {
        guard !pending else { return false }
        pending = true
        return true
    }
    mutating func takeJob(_ job: String?) -> String? {
        guard pending, dispatchedJob == nil, let job else { return nil }
        dispatchedJob = job
        return job
    }
    mutating func failed(job: String) -> Bool {
        guard pending, dispatchedJob == job else { return false }
        pending = false; dispatchedJob = nil
        return true
    }
    mutating func reset() { pending = false; dispatchedJob = nil }
}

struct PendingLicense: Decodable, Identifiable {
    let id: String
    let sha256: String
    let text: String
    var accepted: Bool? = nil
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
        return licenses.filter { $0.accepted != true }.map { ["id":$0.id, "sha256":$0.sha256] }
    }
    var method: String { imagePackage == nil ? "sdk.install" : "image.install" }
    var parameters: [String:Any] {
        imagePackage.map { ["image":$0] } ?? ["packages":["emulator", "platform-tools"]]
    }
    /// Existing SDKs are read-only, including when a symlink points inside one.
    static func rootsOverlap(_ first: String, _ second: String) -> Bool {
        func components(_ path: String) -> [String] {
            var url = URL(fileURLWithPath: path).standardizedFileURL
            var missing: [String] = []
            while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" {
                missing.insert(url.lastPathComponent, at: 0)
                url.deleteLastPathComponent()
            }
            return url.resolvingSymlinksInPath().pathComponents + missing
        }
        let a = components(first), b = components(second)
        return a.starts(with: b) || b.starts(with: a)
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

/// Consent is bound to the exact packages and installation destination reviewed.
struct SDKInstallSelection: Equatable {
    let imagePackage: String?
    let destination: String
    let externalSDK: String?
}

struct SDKLicenseReview {
    private(set) var selection: SDKInstallSelection?
    private(set) var licenses: [PendingLicense]?
    private(set) var agreed = false
    private(set) var revision = 0

    mutating func reset() {
        revision += 1
        selection = nil; licenses = nil; agreed = false
    }
    mutating func begin(_ selection: SDKInstallSelection) -> Int {
        reset()
        self.selection = selection
        return revision
    }
    mutating func complete(_ licenses: [PendingLicense], selection: SDKInstallSelection, revision: Int) -> Bool {
        guard self.revision == revision, self.selection == selection else { return false }
        self.licenses = licenses
        return true
    }
    mutating func setAgreed(_ value: Bool) {
        agreed = value && licenses != nil && selection != nil
    }
    func canAgree(to current: SDKInstallSelection?) -> Bool {
        guard let current, selection == current, let licenses else { return false }
        let plan = SDKInstallPlan(imagePackage: current.imagePackage, licenses: licenses)
        return (try? plan.consentRequests(reviewed: true)) != nil
    }
    @discardableResult
    mutating func agree(to current: SDKInstallSelection?) -> Bool {
        guard canAgree(to: current) else { return false }
        agreed = true
        return true
    }
    func authorizedPlan(for current: SDKInstallSelection) -> SDKInstallPlan? {
        guard agreed, selection == current, let licenses else { return nil }
        return SDKInstallPlan(imagePackage: current.imagePackage, licenses: licenses)
    }
    func canBeginInstallation(for current: SDKInstallSelection?, busy: Bool, installing: Bool,
                              overlappingRoots: Bool, imagesLoading: Bool) -> Bool {
        guard !busy, !installing, !overlappingRoots, !imagesLoading,
              let current, let plan = authorizedPlan(for: current) else { return false }
        return (try? plan.consentRequests(reviewed: true)) != nil
    }
}

/// The onboarding installation step never invents progress for a skipped or pending job.
enum SDKOnboardingInstallState: Equatable {
    case skipped, preparing, installing, completed, failed, cancelled

    var showsCancel: Bool { self == .preparing || self == .installing }
    var showsReviewSettings: Bool { self == .skipped || self == .failed || self == .cancelled }
    static func shouldAdvanceAfterSuccess(requested: Bool, step: Int, succeeded: Bool?) -> Bool {
        requested && step == 1 && succeeded == true
    }
    static func nextStepAfterSuccess(requested: Bool, step: Int, succeeded: Bool?) -> Int? {
        shouldAdvanceAfterSuccess(requested: requested, step: step, succeeded: succeeded) ? 3 : nil
    }
    static func shouldDismissAfterSuccess(requested: Bool, step: Int, succeeded: Bool?, standalone: Bool) -> Bool {
        standalone && shouldAdvanceAfterSuccess(requested: requested, step: step, succeeded: succeeded)
    }

    func displayedFraction(_ value: Double?) -> Double? {
        self == .installing ? SDKInstallPlan.validProgress(value) : nil
    }

    static func resolve(requested: Bool, preparing: Bool, running: Bool, succeeded: Bool?, error: String?) -> Self {
        guard requested else { return .skipped }
        if preparing { return .preparing }
        if running { return .installing }
        if let error, !error.isEmpty { return .failed }
        switch succeeded {
        case true: return .completed
        case false: return .cancelled
        case nil: return .preparing
        }
    }
}
