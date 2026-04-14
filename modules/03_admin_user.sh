#!/usr/bin/env bash
set -euo pipefail

# Module: 03_admin_user
# Purpose: 创建管理用户并加入 sudo。
# Preconditions: root；Debian 12；ADMIN_USER 不得为 root。
# Steps:
#   1. 确认目标用户与组
#   2. 不存在则创建用户
#   3. 确保 shell、补充组、home 目录正确
#   4. 锁定本地密码，避免明文密码流程
# Idempotency:
#   - 已存在用户只做必要修正
#   - 已存在组不会重复创建

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

ensure_groups() {
  local groups_csv="$1"
  local group=""
  IFS=',' read -r -a group_list <<<"${groups_csv}"
  for group in "${group_list[@]}"; do
    [[ -n "${group}" ]] || continue
    if ! getent group "${group}" >/dev/null 2>&1; then
      run_cmd "Creating group ${group}" groupadd "${group}"
    fi
  done
}

main() {
  load_config
  init_runtime
  module_banner "03_admin_user" "创建管理用户并加入 sudo"
  require_root
  require_debian12

  if [[ -z "${ADMIN_USER}" ]]; then
    log warn "ADMIN_USER is empty. Skip admin user creation."
    set_state "ADMIN_USER_EXISTS" "no"
    return 0
  fi

  ensure_groups "${ADMIN_USER_GROUPS}"

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    log info "Admin user already exists: ${ADMIN_USER}"
  else
    run_cmd "Creating admin user ${ADMIN_USER}" \
      useradd -m -s "${ADMIN_USER_SHELL}" -G "${ADMIN_USER_GROUPS}" "${ADMIN_USER}"
  fi

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    local current_shell
    current_shell="$(getent passwd "${ADMIN_USER}" | cut -d: -f7)"
    if [[ "${current_shell}" != "${ADMIN_USER_SHELL}" ]]; then
      run_cmd "Updating shell for ${ADMIN_USER}" usermod -s "${ADMIN_USER_SHELL}" "${ADMIN_USER}"
    fi

    run_cmd "Ensuring sudo groups for ${ADMIN_USER}" usermod -aG "${ADMIN_USER_GROUPS}" "${ADMIN_USER}"

    local home_dir
    home_dir="$(home_dir_for_user "${ADMIN_USER}")"
    ensure_directory "${home_dir}" "0750" "${ADMIN_USER}" "${ADMIN_USER}"

    run_cmd "Locking local password for ${ADMIN_USER}" passwd -l "${ADMIN_USER}"
  else
    log info "Plan/Dry-run note: user ${ADMIN_USER} not yet present locally, so post-create checks are skipped."
  fi

  set_state "ADMIN_USER_EXISTS" "yes"
  set_state "ADMIN_USER" "${ADMIN_USER}"
}

main "$@"
