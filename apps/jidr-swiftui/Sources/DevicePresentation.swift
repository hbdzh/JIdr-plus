// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum DevicePresentation {
    static func imageTag(_ tag: String) -> String {
        let is16KB = tag.hasSuffix("_ps16k")
        let base = is16KB ? String(tag.dropLast(6)) : tag
        let label: String
        switch base {
        case "google_apis": label = "Google APIs"
        case "google_apis_playstore", "playstore": label = "Play Store"
        case "default": label = "AOSP"
        case "aosp_atd": label = "AOSP ATD"
        case "google_atd": label = "Google ATD"
        default: label = base.replacingOccurrences(of: "_", with: " ")
        }
        return label + (is16KB ? " · 16 KB" : "")
    }

    static func imageOrder(_ tag: String) -> Int {
        switch tag {
        case "google_apis": return 0
        case "google_apis_playstore", "playstore": return 1
        case "default": return 2
        default: return tag.hasSuffix("_ps16k") ? 3 : 4
        }
    }

    static func profile(_ id: String) -> String {
        let parts = id.split(separator: "-")
        if parts.count == 3, parts[0] == "phone", Double(parts[1]) != nil {
            let display = parts[2] == "fhd" ? "FHD+" : parts[2].uppercased()
            return "\(parts[1])″ · \(display)"
        }
        return id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}
