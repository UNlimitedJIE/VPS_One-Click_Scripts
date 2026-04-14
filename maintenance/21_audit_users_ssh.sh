#!/usr/bin/env bash
set -euo pipefail

# Module: 21_audit_users_ssh
# Purpose: 审查用户、sudo 成员与 SSH 公钥状态。
# Preconditions: root。
# Steps:
#   1. 列出交互式用户
#   2. 列出 sudo 组成员
#   3. 统计每个用户 authorized_keys 数量
# Idempotency:
#   - 纯审查模块，可重复执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "21_audit_users_ssh" "审查用户、sudo、SSH 密钥"
  require_root

  local report_file
  report_file="${STATE_DIR}/reports/users-ssh-$(date '+%Y%m%d-%H%M%S').txt"

  local report=""
  report+="Audit time: $(date -Iseconds)"$'\n'
  report+="Hostname: $(hostnamectl --static 2>/dev/null || hostname)"$'\n'
  report+="Sudo members: $(sudo_members)"$'\n'
  report+=$'\n'
  report+="Interactive users and authorized_keys counts:"$'\n'

  local user home_dir key_count
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    home_dir="$(home_dir_for_user "${user}")"
    key_count="$(count_valid_ssh_keys_in_file "${home_dir}/.ssh/authorized_keys")"
    report+="- ${user}: home=${home_dir}, keys=${key_count}"$'\n'
  done < <(interactive_users)

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${report_file}"
  fi
}

main "$@"
