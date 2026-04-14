#!/usr/bin/env bash
set -euo pipefail

# Module: 04_ssh_keys
# Purpose: 为管理用户写入 authorized_keys。
# Preconditions: root；管理用户已存在；AUTHORIZED_KEYS_FILE 指向有效公钥文件。
# Steps:
#   1. 检查管理用户
#   2. 校验公钥文件
#   3. 创建 .ssh 目录并合并去重 authorized_keys
#   4. 设置属主与权限
# Idempotency:
#   - 重复执行仅追加新公钥
#   - 已存在相同公钥不会重复写入

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "04_ssh_keys" "配置 SSH 公钥登录"
  require_root
  require_debian12

  if [[ -z "${ADMIN_USER}" ]]; then
    die "ADMIN_USER is empty."
  fi

  if [[ -z "${AUTHORIZED_KEYS_FILE}" ]]; then
    log warn "AUTHORIZED_KEYS_FILE is empty. Skip automatic key installation."
    log warn "Manual action: upload a public key file and rerun 04_ssh_keys before tightening SSH."
    set_state "AUTHORIZED_KEYS_PRESENT" "no"
    return 0
  fi

  validate_authorized_keys_file "${AUTHORIZED_KEYS_FILE}"

  local home_dir ssh_dir auth_file tmp_file
  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    home_dir="$(home_dir_for_user "${ADMIN_USER}")"
  elif is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "Plan/Dry-run note: ${ADMIN_USER} does not exist yet; assume /home/${ADMIN_USER} for preview."
    home_dir="/home/${ADMIN_USER}"
  else
    die "Admin user must exist before configuring SSH keys."
  fi
  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  tmp_file="$(mktemp)"

  ensure_directory "${ssh_dir}" "0700" "${ADMIN_USER}" "${ADMIN_USER}"

  if [[ -f "${auth_file}" ]]; then
    cat "${auth_file}" "${AUTHORIZED_KEYS_FILE}" | awk 'NF && !seen[$0]++' >"${tmp_file}"
  else
    awk 'NF && !seen[$0]++' "${AUTHORIZED_KEYS_FILE}" >"${tmp_file}"
  fi

  if [[ -f "${auth_file}" ]] && cmp -s "${tmp_file}" "${auth_file}"; then
    log info "authorized_keys already up to date."
  elif is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] update ${auth_file} from ${AUTHORIZED_KEYS_FILE}"
  else
    install -m 0600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${tmp_file}" "${auth_file}"
    log info "authorized_keys updated for ${ADMIN_USER}"
  fi

  rm -f "${tmp_file}"

  local key_count
  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    key_count="$(count_valid_ssh_keys_in_file "${AUTHORIZED_KEYS_FILE}")"
  else
    key_count="$(count_valid_ssh_keys_in_file "${auth_file}")"
  fi
  if [[ "${key_count}" -gt 0 ]]; then
    set_state "AUTHORIZED_KEYS_PRESENT" "yes"
    set_state "AUTHORIZED_KEYS_COUNT" "${key_count}"
    log info "Valid authorized_keys count for ${ADMIN_USER}: ${key_count}"
  else
    set_state "AUTHORIZED_KEYS_PRESENT" "no"
    die "No valid keys detected in ${auth_file} after merge."
  fi
}

main "$@"
