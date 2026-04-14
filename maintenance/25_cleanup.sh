#!/usr/bin/env bash
set -euo pipefail

# Module: 25_cleanup
# Purpose: 清理 apt 缓存、孤儿包与旧 journal。
# Preconditions: root；Debian 12。
# Steps:
#   1. autoremove 清理无用包
#   2. apt clean 清理包缓存
#   3. 按配置清理旧 journal
# Idempotency:
#   - 重复执行只清理当前可清理内容

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "25_cleanup" "日志与缓存清理"
  require_root
  require_debian12

  run_cmd "Removing unused packages" apt-get autoremove -y

  if is_true "${CLEANUP_APT_CACHE}"; then
    run_cmd "Cleaning apt cache" apt-get clean
  fi

  if [[ "${JOURNAL_VACUUM_DAYS}" =~ ^[0-9]+$ ]] && (( JOURNAL_VACUUM_DAYS > 0 )); then
    run_cmd "Vacuuming journal older than ${JOURNAL_VACUUM_DAYS} days" \
      journalctl --vacuum-time="${JOURNAL_VACUUM_DAYS}d"
  else
    log info "Journal vacuum disabled."
  fi

  set_state "MAINT_LAST_CLEANUP" "$(date -Iseconds)"
}

main "$@"
