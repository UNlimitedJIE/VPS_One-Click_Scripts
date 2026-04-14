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

  local found_tools timers backups report
  found_tools=""
  for tool in restic borg rclone rsnapshot duplicity; do
    if command_exists "${tool}"; then
      found_tools+="${tool} "
    fi
  done

  timers="$(systemctl list-timers --all --no-pager 2>/dev/null | grep -Ei 'backup|restic|borg|rsnapshot' || true)"
  backups="$(find /var/backups -maxdepth 2 -type f -mtime -7 2>/dev/null | head -n 20 || true)"

  report="$(cat <<EOF
Audit time: $(date -Iseconds)
Detected backup tools: ${found_tools:-none}

Relevant timers:
${timers:-none}

Recent files under /var/backups (7 days):
${backups:-none}

Manual reminders:
- Verify at least one recent backup exists outside this VPS.
- Verify restore procedure on a separate test host.
- Keep provider snapshot policy separate from in-guest file backup policy.
EOF
)"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/backup-check-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

main "$@"
