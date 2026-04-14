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

fail_authorized_keys_install() {
  set_state "AUTHORIZED_KEYS_PRESENT" "no"
  set_state "AUTHORIZED_KEYS_COUNT" "0"
  die "$*"
}

resolve_authorized_keys_source() {
  local fallback_file=""

  if [[ -n "${AUTHORIZED_KEYS_FILE}" ]]; then
    validate_authorized_keys_file "${AUTHORIZED_KEYS_FILE}"
    printf '%s\n' "${AUTHORIZED_KEYS_FILE}"
    return 0
  fi

  fallback_file="$(bootstrap_authorized_keys_fallback_path)"
  if [[ -f "${fallback_file}" ]]; then
    if [[ "$(count_valid_ssh_keys_in_file "${fallback_file}")" -gt 0 ]]; then
      log warn "AUTHORIZED_KEYS_FILE is empty. Using temporary fallback source: ${fallback_file}"
      printf '%s\n' "${fallback_file}"
      return 0
    fi
    log warn "Fallback authorized_keys source exists but contains no valid public keys: ${fallback_file}"
  fi

  return 1
}

validate_authorized_keys_target_install() {
  local ssh_dir="$1"
  local auth_file="$2"
  local ssh_meta=""
  local auth_meta=""
  local key_count="0"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] verify ${ssh_dir} exists with ${ADMIN_USER}:${ADMIN_USER} 700"
    log info "[plan] verify ${auth_file} exists with ${ADMIN_USER}:${ADMIN_USER} 600"
    log info "[plan] verify ${auth_file} contains at least one valid public key"
    return 0
  fi

  [[ -d "${ssh_dir}" ]] || fail_authorized_keys_install "SSH directory missing after installation: ${ssh_dir}"
  [[ -f "${auth_file}" ]] || fail_authorized_keys_install "authorized_keys missing after installation: ${auth_file}"

  ssh_meta="$(stat -c '%U:%G %a' "${ssh_dir}" 2>/dev/null || true)"
  [[ "${ssh_meta}" == "${ADMIN_USER}:${ADMIN_USER} 700" ]] || fail_authorized_keys_install "SSH directory ownership/mode mismatch: ${ssh_dir} (${ssh_meta:-unknown})"

  auth_meta="$(stat -c '%U:%G %a' "${auth_file}" 2>/dev/null || true)"
  [[ "${auth_meta}" == "${ADMIN_USER}:${ADMIN_USER} 600" ]] || fail_authorized_keys_install "authorized_keys ownership/mode mismatch: ${auth_file} (${auth_meta:-unknown})"

  key_count="$(count_valid_ssh_keys_in_file "${auth_file}")"
  [[ "${key_count}" -gt 0 ]] || fail_authorized_keys_install "No valid keys detected in ${auth_file} after installation."

  set_state "AUTHORIZED_KEYS_PRESENT" "yes"
  set_state "AUTHORIZED_KEYS_COUNT" "${key_count}"
  log info "Valid authorized_keys count for ${ADMIN_USER}: ${key_count}"
}

main() {
  load_config
  init_runtime
  module_banner "04_ssh_keys" "配置 SSH 公钥登录"
  require_root
  require_debian12

  if [[ -z "${ADMIN_USER}" ]]; then
    die "ADMIN_USER is empty."
  fi

  local home_dir=""
  local ssh_dir=""
  local auth_file=""
  local tmp_file=""
  local source_file=""
  local key_count="0"

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

  source_file="$(resolve_authorized_keys_source || true)"
  if [[ -z "${source_file}" ]]; then
    if [[ "$(count_valid_ssh_keys_in_file "${auth_file}")" -gt 0 ]]; then
      key_count="$(count_valid_ssh_keys_in_file "${auth_file}")"
      set_state "AUTHORIZED_KEYS_PRESENT" "yes"
      set_state "AUTHORIZED_KEYS_COUNT" "${key_count}"
      log warn "No configured authorized_keys source was resolved, but target authorized_keys already exists for ${ADMIN_USER}."
      log info "Valid authorized_keys count for ${ADMIN_USER}: ${key_count}"
      return 0
    fi

    log warn "AUTHORIZED_KEYS_FILE is empty and no valid fallback source is available. Skip automatic key installation."
    log warn "Manual action: upload a public key file or create /root/bootstrap_authorized_keys, then rerun 04_ssh_keys before tightening SSH."
    set_state "AUTHORIZED_KEYS_PRESENT" "no"
    set_state "AUTHORIZED_KEYS_COUNT" "0"
    return 0
  fi

  ensure_directory "${ssh_dir}" "0700" "${ADMIN_USER}" "${ADMIN_USER}"
  tmp_file="$(mktemp)"

  if [[ -f "${auth_file}" ]]; then
    cat "${auth_file}" "${source_file}" | awk 'NF && !seen[$0]++' >"${tmp_file}"
  else
    awk 'NF && !seen[$0]++' "${source_file}" >"${tmp_file}"
  fi

  if [[ -f "${auth_file}" ]] && cmp -s "${tmp_file}" "${auth_file}"; then
    log info "authorized_keys already up to date."
  elif is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] update ${auth_file} from ${source_file}"
  else
    install -m 0600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${tmp_file}" "${auth_file}"
    log info "authorized_keys updated for ${ADMIN_USER}"
  fi

  rm -f "${tmp_file}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    chown "${ADMIN_USER}:${ADMIN_USER}" "${auth_file}"
    chmod 0600 "${auth_file}"
  fi

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    key_count="$(count_valid_ssh_keys_in_file "${source_file}")"
    if [[ "${key_count}" -gt 0 ]]; then
      set_state "AUTHORIZED_KEYS_PRESENT" "yes"
      set_state "AUTHORIZED_KEYS_COUNT" "${key_count}"
      log info "Valid source key count for ${ADMIN_USER}: ${key_count}"
    else
      set_state "AUTHORIZED_KEYS_PRESENT" "no"
      set_state "AUTHORIZED_KEYS_COUNT" "0"
      fail_authorized_keys_install "No valid keys detected in ${source_file}."
    fi
  else
    validate_authorized_keys_target_install "${ssh_dir}" "${auth_file}"
  fi
}

main "$@"
