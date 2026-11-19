// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The editor stages every field until Save. Hardware is acknowledged first;
/// a failed daemon request must never commit the local window preference.
enum DeviceSettingsSave {
    enum Failure: Error {
        case device(Error)
        case quality(Error)
    }

    static func commit(
        saveDevice: (@escaping (Result<Void, Error>) -> Void) -> Void,
        saveQuality: @escaping () throws -> Void,
        completion: @escaping (Result<Void, Failure>) -> Void
    ) {
        saveDevice { result in
            switch result {
            case .failure(let error): completion(.failure(.device(error)))
            case .success:
                do { try saveQuality(); completion(.success(())) }
                catch { completion(.failure(.quality(error))) }
            }
        }
    }
}
