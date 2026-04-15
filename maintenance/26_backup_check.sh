#!/usr/bin/env bash
set -euo pipefail

# Module: 26_backup_check
# Purpose: 做备份与恢复能力检查提醒，不直接调用云厂商 API。
# Preconditions: root。
# Steps:
#   1. 查找常见备份工具与定时器
#   2. 查看 /var/backups 最近文件
#   3. 输出恢复演练提醒
# Idempotency:
#   - 纯审查模块，可重复执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "26_backup_check" "备份与恢复检查"
  require_root

  local found_tools timers backups report passed
  found_tools=""
  passed="no"
  for tool in restic borg rclone rsnapshot duplicity; do
    if command_exists "${tool}"; then
      found_tools+="${tool} "
    fi
  done

  timers="$(systemctl list-timers --all --no-pager 2>/dev/null | grep -Ei 'backup|restic|borg|rsnapshot' || true)"
  backups="$(find /var/backups -maxdepth 2 -type f -mtime -7 2>/dev/null | head -n 20 || true)"
  [[ -n "${timers}" || -n "${backups}" ]] && passed="yes"

  report="$(readonly_status_block \
    "备份与恢复检查" \
    "tools=${found_tools:-none}; timers=$( [[ -n "${timers}" ]] && echo yes || echo no ); recent_backups=$( [[ -n "${backups}" ]] && echo yes || echo no )" \
    "command -v restic/borg/rclone/rsnapshot/duplicity; systemctl list-timers; find /var/backups -mtime -7" \
    "${passed}")"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/backup-check-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

main "$@"
