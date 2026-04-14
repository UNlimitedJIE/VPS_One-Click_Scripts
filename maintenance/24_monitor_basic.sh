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

  local report
  report="$(cat <<EOF
Report time: $(date -Iseconds)

Uptime:
$(uptime)

Memory:
$(free -h)

Disk:
$(df -h / /var 2>/dev/null || df -h /)

Socket summary:
$(ss -s 2>/dev/null || echo "ss not available")

Failed systemd units:
$(systemctl --failed --no-pager 2>/dev/null || true)
EOF
)"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/monitor-basic-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

main "$@"
