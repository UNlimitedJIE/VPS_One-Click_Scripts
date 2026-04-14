#!/usr/bin/env bash
set -euo pipefail

# Module: 23_audit_fail2ban_logs
# Purpose: 检查 Fail2Ban 状态与 SSH 登录失败日志。
# Preconditions: root。
# Steps:
#   1. 检查 fail2ban 是否安装启用
#   2. 读取 fail2ban-client 状态
#   3. 统计近期 SSH 失败登录条目
# Idempotency:
#   - 纯审查模块，可重复执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "23_audit_fail2ban_logs" "检查 Fail2Ban 与登录日志"
  require_root

  if ! service_exists "fail2ban"; then
    log warn "fail2ban is not installed."
    return 0
  fi

  local ssh_unit fail_count jail_status report
  ssh_unit="$(ssh_service_name)"
  fail_count="$(journalctl -u "${ssh_unit}" --since "7 days ago" --no-pager 2>/dev/null | grep -Ec 'Failed password|Invalid user' || true)"

  if command_exists fail2ban-client && service_active "fail2ban"; then
    jail_status="$(fail2ban-client status sshd 2>/dev/null || true)"
  else
    jail_status="fail2ban-client unavailable or service inactive"
  fi

  report="$(cat <<EOF
Audit time: $(date -Iseconds)
Fail2Ban active: $(service_active "fail2ban" && echo yes || echo no)
Recent SSH failures (7 days): ${fail_count}

Fail2Ban sshd status:
${jail_status}
EOF
)"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/fail2ban-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

main "$@"
