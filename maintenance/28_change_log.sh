#!/usr/bin/env bash
set -euo pipefail

# Module: 28_change_log
# Purpose: 保留变更记录或状态记录。
# Preconditions: root。
# Steps:
#   1. 汇总关键状态
#   2. 追加到 state/change-log.tsv
#   3. 供长期维护与追溯使用
# Idempotency:
#   - 每次执行追加一条带时间戳记录

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "28_change_log" "保留变更记录或状态记录"
  require_root

  local header line nft_state f2b_state au_state swap_state
  nft_state="$(service_enabled "nftables" && echo yes || echo no)"
  f2b_state="$(service_exists "fail2ban" && service_enabled "fail2ban" && echo yes || echo no)"
  au_state="$(service_exists "unattended-upgrades" && service_enabled "unattended-upgrades" && echo yes || echo no)"
  swap_state="$(has_active_swap && echo yes || echo no)"

  header=$'timestamp\tmode\thostname\tos\tssh_port\tnftables\tfail2ban\tauto_updates\tswap'
  line="$(date -Iseconds)\t${RUN_MODE:-manual}\t$(hostnamectl --static 2>/dev/null || hostname)\t$(pretty_os_name)\t$(current_ssh_port)\t${nft_state}\t${f2b_state}\t${au_state}\t${swap_state}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    if [[ ! -f "${CHANGE_LOG_FILE}" ]]; then
      printf '%s\n' "${header}" >"${CHANGE_LOG_FILE}"
    fi
    printf '%b\n' "${line}" >>"${CHANGE_LOG_FILE}"
  else
    log info "[plan] append change log to ${CHANGE_LOG_FILE}: ${line}"
  fi

  log info "Change log entry recorded."
}

main "$@"
