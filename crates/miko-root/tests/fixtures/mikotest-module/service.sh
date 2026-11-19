#!/system/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Miko's test module, written from Magisk's public module guide: Magisk runs
# service.sh in late_start service mode at every boot while the module is on.
echo loaded > /data/local/tmp/mikotest_module.marker
