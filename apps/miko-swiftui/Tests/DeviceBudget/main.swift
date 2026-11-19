// SPDX-License-Identifier: GPL-3.0-only
import Foundation

let payload = #"{"total_mb":16384,"available_mb":4096,"budget_percent":75,"budget_mb":12288,"used_mb":9000,"devices":[{"id":"a","name":"Phone","expected_mb":4096,"measured_mb":5000},{"id":"b","name":"Tablet","expected_mb":4000}]}"#
let budget = try JSONDecoder().decode(DeviceBudget.self, from: Data(payload.utf8))
precondition(budget.devices[0].countedMB == 5000)
precondition(budget.devices[1].countedMB == 4000)
precondition(budget.fraction > 0.73 && budget.fraction < 0.74)
let refusal = try JSONDecoder().decode(BudgetRefusal.self, from: Data(#"{"needed_mb":4096,"used_mb":13000,"budget_mb":12288}"#.utf8))
precondition(refusal.freeMB == 0)
precondition(refusal.message(language: 1).contains("4.0 GB"))
precondition(refusal.message(language: 0).contains("0.0 GB"))
print("device budget tests passed")
