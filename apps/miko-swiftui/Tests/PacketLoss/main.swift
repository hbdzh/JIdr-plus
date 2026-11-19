// SPDX-License-Identifier: GPL-3.0-only
import Foundation

precondition(PacketLoss.parse(" 2.5 ") == 2.5)
precondition(PacketLoss.parse("0") == 0 && PacketLoss.parse("100") == 100)
for bad in ["", "-1", "100.1", "nan", "inf", "1,2", "abc"] {
    precondition(PacketLoss.parse(bad) == nil, "invalid loss: \(bad)")
}
print("packet loss input tests passed")
