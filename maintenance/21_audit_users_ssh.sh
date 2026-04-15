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

  local report_file=""
  local sudo_list=""
  local current=""
  local evidence=""
  local passed="no"
  local report=""
  local key_summary=""
  local interactive_list=""
  local user=""
  local home_dir=""
  local key_count=""

  report_file="${STATE_DIR}/reports/users-ssh-$(date '+%Y%m%d-%H%M%S').txt"
  sudo_list="$(sudo_members)"

  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    home_dir="$(home_dir_for_user "${user}")"
    key_count="$(count_valid_ssh_keys_in_file "${home_dir}/.ssh/authorized_keys")"
    [[ -n "${interactive_list}" ]] && interactive_list+=", "
    interactive_list+="${user}"
    [[ -n "${key_summary}" ]] && key_summary+=", "
    key_summary+="${user}:${key_count}"
  done < <(interactive_users)

  [[ -n "${interactive_list}" ]] || interactive_list="none"
  [[ -n "${key_summary}" ]] || key_summary="none"
  [[ -n "${sudo_list}" ]] || sudo_list="none"

  if [[ "${sudo_list}" != "none" ]]; then
    passed="yes"
  fi

  current="interactive_users=${interactive_list}; sudo_members=${sudo_list}; authorized_keys=${key_summary}"
  evidence="/etc/passwd; sudo group membership; ~/.ssh/authorized_keys"
  report="$(readonly_status_block "用户 / sudo / SSH 密钥审查" "${current}" "${evidence}" "${passed}")"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${report_file}"
  fi
}

main "$@"
