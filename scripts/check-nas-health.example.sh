#!/usr/bin/env bash
set -euo pipefail
OUT=""
if grep -qE '\[.*_.*\]' /proc/mdstat; then
  OUT+="RAID degraded\n"
fi
for d in /dev/sdb /dev/sdc; do
  [ -b "$d" ] || continue
  H=$(smartctl -H -A -d sat "$d" 2>/dev/null || true)
  echo "$H" | grep -q 'PASSED' || OUT+="SMART health not PASSED on $d\n"
  echo "$H" | awk '/Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable/ { if ($10+0 > 0) bad=1 } END { exit bad?0:1 }' && OUT+="SMART warning attributes nonzero on $d\n" || true
 done
if [ -n "$OUT" ]; then
  # Replace with your alert destination.
  echo -e "$OUT" | mail -s 'ai-server NAS health alert' you@example.com || true
fi
