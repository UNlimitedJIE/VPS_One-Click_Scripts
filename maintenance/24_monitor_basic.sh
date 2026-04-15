#!/usr/bin/env bash
set -euo pipefail

# Module: 24_monitor_basic
# Purpose: 输出 CPU / 内存 / 磁盘 / 网络 / systemd 基本状态。
# Preconditions: root。
# Steps:
#   1. 采集 uptime、load、内存、磁盘
#   2. 采集网络套接字摘要
#   3. 列出失败的 systemd 服务
# Idempotency:
#   - 纯审查模块，可重复执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "24_monitor_basic" "监控 CPU / 内存 / 磁盘 / 网络 / systemd 服务"
  require_root

  local report=""
  local load_avg=""
  local memory_state=""
  local disk_state=""
  local failed_units_count=0
  local passed="yes"

  load_avg="$(uptime 2>/dev/null | sed -n 's/.*load average: //p' || true)"
  memory_state="$(free -h 2>/dev/null | awk '/^Mem:/ {print "used=" $3 ",available=" $7}')"
  disk_state="$(df -h / 2>/dev/null | awk 'NR==2 {print "root_used=" $3 ",root_avail=" $4 ",use%=" $5}')"
  failed_units_count="$(systemctl --failed --no-pager --plain 2>/dev/null | awk 'NR>1 && $1 !~ /^UNIT$/ && NF {count++} END {print count+0}')"

  if [[ "${failed_units_count}" != "0" ]]; then
    passed="no"
  fi

  report="$(readonly_status_block \
    "基础资源与服务健康" \
    "load=${load_avg:-unknown}; ${memory_state:-memory=unknown}; ${disk_state:-disk=unknown}; failed_units=${failed_units_count}" \
    "uptime; free -h; df -h /; ss -s; systemctl --failed" \
    "${passed}")"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/monitor-basic-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

main "$@"
