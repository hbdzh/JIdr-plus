// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func packet(_ width: UInt32, _ height: UInt32, _ rotation: UInt32, _ payload: [UInt8]) -> Data {
    var data = Data("JFR1".utf8)
    for value in [width, height, rotation, UInt32(payload.count)] {
        data.append(contentsOf: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    data.append(contentsOf: payload)
    return data
}
let decoder = FrameDecoder()
let one = packet(2, 1, 0, [1,2,3,4,5,6,7,8])
let two = packet(1, 1, 1, [9,10,11,12])
let stream = one + two
var frames: [DecodedFrame] = []
for byte in stream {
    precondition(decoder.consume(Data([byte])) { frames.append($0) })
}
precondition(frames.count == 2)
precondition(frames[0].width == 2 && frames[0].height == 1 && frames[0].pixels == Data([1,2,3,4,5,6,7,8]))
precondition(frames[1].rotation == 1 && frames[1].pixels == Data([9,10,11,12]))
let combinedDecoder = FrameDecoder()
var combined: [DecodedFrame] = []
precondition(combinedDecoder.consume(stream) { combined.append($0) } && combined.count == 2)
var bad = packet(1, 1, 0, [0,0,0,0]); bad[0] = 0
precondition(!FrameDecoder().consume(bad) { _ in })
precondition(!FrameDecoder().consume(packet(2, 2, 0, [0,0,0,0])) { _ in })
print("FrameDecoder tests passed")
