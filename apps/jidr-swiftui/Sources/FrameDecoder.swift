// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct DecodedFrame {
    let width: Int
    let height: Int
    let rotation: Int
    let pixels: Data
}

/// Decodes the bridge stream without repeatedly growing and slicing frame-sized Data.
final class FrameDecoder {
    private static let headerLength = 20
    private static let maxBytes = 32 * 1024 * 1024
    private var header: [UInt8] = []
    private var metadata: (width: Int, height: Int, rotation: Int)?
    private var pixels = Data()
    private var written = 0

    /// Drops any partially buffered frame, e.g. when a bridge restarts.
    func reset() {
        header.removeAll(keepingCapacity: true)
        metadata = nil
        pixels = Data()
        written = 0
    }

    /// Returns false on an invalid header; the caller must close the stream.
    func consume(_ chunk: Data, onFrame: (DecodedFrame) -> Void) -> Bool {
        chunk.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return true }
            var offset = 0
            while offset < source.count {
                if metadata == nil {
                    let n = min(Self.headerLength - header.count, source.count - offset)
                    header.append(contentsOf: source[offset..<(offset + n)])
                    offset += n
                    guard header.count == Self.headerLength else { continue }
                    // Compare the magic bytes directly: the previous Array
                    // conversions allocated twice per frame for 4 bytes.
                    guard header[0] == UInt8(ascii: "J"), header[1] == UInt8(ascii: "F"),
                          header[2] == UInt8(ascii: "R"), header[3] == UInt8(ascii: "1") else { return false }
                    func integer(_ i: Int) -> Int {
                        (Int(header[i]) << 24) | (Int(header[i + 1]) << 16)
                            | (Int(header[i + 2]) << 8) | Int(header[i + 3])
                    }
                    let width = integer(4), height = integer(8), rotation = integer(12), count = integer(16)
                    guard width > 0, height > 0, width <= 8192, height <= 8192,
                          count <= Self.maxBytes, width * height * 4 == count else { return false }
                    metadata = (width, height, rotation)
                    // One allocation per frame is required: the CGImage data
                    // provider downstream retains this Data, so the payload
                    // buffer cannot be reused. Data(count:) also zero-fills,
                    // keeping the buffer fully initialised for the chunk copies.
                    pixels = Data(count: count)
                    written = 0
                    header.removeAll(keepingCapacity: true)
                }
                guard let current = metadata else { continue }
                let n = min(pixels.count - written, source.count - offset)
                pixels.withUnsafeMutableBytes { destination in
                    guard let target = destination.baseAddress else { return }
                    target.advanced(by: written).copyMemory(from: base.advanced(by: offset), byteCount: n)
                }
                written += n
                offset += n
                if written == pixels.count {
                    let frame = DecodedFrame(width: current.width, height: current.height,
                                             rotation: current.rotation, pixels: pixels)
                    metadata = nil
                    pixels = Data()
                    written = 0
                    onFrame(frame)
                }
            }
            return true
        }
    }
}
