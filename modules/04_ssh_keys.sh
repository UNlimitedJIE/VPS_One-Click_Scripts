#!/usr/bin/env bash
set -euo pipefail

# Module: 04_ssh_keys
# Purpose: 为管理用户写入 authorized_keys，并强校验目标账户安装结果。
# Preconditions: root；管理用户已存在。
# Steps:
#   1. 优先读取固定公钥源
#   2. 必要时进入纯终端文本粘贴模式
#   3. 先写入源文件，再安装到目标账户
#   4. 强校验 .ssh / authorized_keys 属主、权限和 key 数
# Idempotency:
#   - 重复执行只会收敛为去重后的 authorized_keys

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

_AUTHORIZED_KEYS_PASTED_SOURCE_FILE="${_AUTHORIZED_KEYS_PASTED_SOURCE_FILE:-}"
_AUTHORIZED_KEYS_RESOLVED_SOURCE_FILE="${_AUTHORIZED_KEYS_RESOLVED_SOURCE_FILE:-}"
_AUTHORIZED_KEYS_CAPTURED_SOURCE_FILE="${_AUTHORIZED_KEYS_CAPTURED_SOURCE_FILE:-}"

fail_authorized_keys_install() {
  local failure_message="$*"

  set_state "AUTHORIZED_KEYS_PRESENT" "no"
  set_state "AUTHORIZED_KEYS_COUNT" "0"
  if is_false "${PLAN_ONLY:-false}" && is_false "${DRY_RUN:-false}" && ui_is_interactive; then
    ui_show_plain_and_wait \
      "第 4.3 段 目标账户 authorized_keys 安装失败" \
      "${failure_message}" \
      "按回车退出当前步骤："
  fi
  die "${failure_message}"
}

resolve_authorized_keys_source() {
  local preferred_source=""

  _AUTHORIZED_KEYS_RESOLVED_SOURCE_FILE=""
  preferred_source="$(preferred_authorized_keys_source_path)"
  if [[ -f "${preferred_source}" && "$(count_valid_ssh_keys_in_file "${preferred_source}")" -gt 0 ]]; then
    _AUTHORIZED_KEYS_RESOLVED_SOURCE_FILE="${preferred_source}"
    return 0
  fi

  return 1
}

authorized_keys_source_status_message() {
  local source_file="$1"

  if [[ ! -e "${source_file}" ]]; then
    printf '未检测到可用公钥源文件：%s\n' "${source_file}"
    return 0
  fi

  if [[ ! -s "${source_file}" ]]; then
    printf '当前公钥源文件为空：%s\n' "${source_file}"
    return 0
  fi

  printf '当前公钥源文件里没有检测到有效 SSH 公钥：%s\n' "${source_file}"
}

confirm_existing_authorized_keys_source_install() {
  local source_file="$1"
  local auth_file="$2"

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "[plan] detected valid authorized_keys source: ${source_file}"
    return 0
  fi

  ui_confirm_enter_or_zero \
    "第 4.3 段 安装 SSH 公钥" \
    "当前目标用户：${ADMIN_USER}\n当前目标文件：${auth_file}\n当前源文件：${source_file}\n已检测到可用公钥源文件。\n按回车继续安装，输入 0 取消"
}

single_line_ssh_public_key_is_valid() {
  local key_line=""
  local tmp_file=""
  local key_count="0"

  key_line="$(ui_trim_value "${1:-}")"
  [[ -n "${key_line}" ]] || return 1
  [[ "${key_line}" != *$'\n'* ]] || return 1

  tmp_file="$(mktemp)"
  printf '%s\n' "${key_line}" >"${tmp_file}"
  key_count="$(count_valid_ssh_keys_in_file "${tmp_file}")"
  rm -f "${tmp_file}"

  [[ "${key_count}" -gt 0 ]]
}

show_source_write_result_and_wait() {
  local source_file="$1"
  local key_count="$2"

  ui_show_plain_and_wait \
    "第 4.3 段 公钥源文件写入结果" \
    "已接收公钥，已写入源文件。\n源文件：${source_file}\n有效公钥数量：${key_count}" \
    "按回车继续安装到目标账户："
}

show_target_install_result_and_wait() {
  local source_file="$1"
  local auth_file="$2"
  local key_count="$3"

  ui_show_plain_and_wait \
    "第 4.3 段 目标账户 authorized_keys 安装结果" \
    "已安装到目标账户 authorized_keys。\n源文件：${source_file}\n目标文件：${auth_file}\n有效公钥数量：${key_count}" \
    "按回车继续："
}

capture_authorized_keys_source_via_paste() {
  local source_file=""
  local source_dir=""
  local auth_file="$1"
  local pasted_key=""
  local key_count="0"

  _AUTHORIZED_KEYS_PASTED_SOURCE_FILE=""
  _AUTHORIZED_KEYS_CAPTURED_SOURCE_FILE=""
  source_file="$(preferred_authorized_keys_source_path)"
  source_dir="$(dirname "${source_file}")"

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "[plan] if ${source_file} is missing or invalid, real execution will prompt for a single-line SSH public key and write it to ${source_file}"
    return 1
  fi

  ui_require_interactive || die "当前公钥源文件无效，且当前不是交互式终端，无法现场粘贴 SSH 公钥。请先写入 ${source_file}。"

  while true; do
    if ! ui_prompt_input \
      "第 4.3 段 粘贴 SSH 公钥" \
      "$(authorized_keys_source_status_message "${source_file}")
当前目标用户：${ADMIN_USER}
当前目标文件：${auth_file}
当前源文件：${source_file}
请现在粘贴一整行 SSH 公钥，粘贴后按回车。
输入 0 取消"; then
      return 1
    fi
    pasted_key="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${pasted_key}" in
      0)
        return 1
        ;;
      "")
        ui_warn_message "未收到公钥" "请粘贴一整行 SSH 公钥，或输入 0 取消。"
        ;;
      *)
        if ! single_line_ssh_public_key_is_valid "${pasted_key}"; then
          ui_warn_message "公钥无效" "只支持一整行 SSH 公钥，例如 ssh-ed25519 ... 或 ssh-rsa ...。"
          continue
        fi

        ensure_directory "${source_dir}" "0755" "root" "root"
        apply_managed_file "${source_file}" "0644" "${pasted_key}" "false"
        AUTHORIZED_KEYS_FILE="${source_file}"
        _AUTHORIZED_KEYS_PASTED_SOURCE_FILE="${source_file}"
        _AUTHORIZED_KEYS_CAPTURED_SOURCE_FILE="${source_file}"
        export_config
        key_count="$(count_valid_ssh_keys_in_file "${source_file}")"
        show_source_write_result_and_wait "${source_file}" "${key_count}"
        return 0
        ;;
    esac
  done
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

install_authorized_keys_to_target() {
  local source_file="$1"
  local ssh_dir="$2"
  local auth_file="$3"
  local tmp_file=""
  local key_count="0"

  ensure_directory "${ssh_dir}" "0700" "${ADMIN_USER}" "${ADMIN_USER}"
  tmp_file="$(mktemp)"

  if [[ -f "${auth_file}" ]]; then
    awk 'NF && !seen[$0]++' "${auth_file}" "${source_file}" >"${tmp_file}"
  else
    awk 'NF && !seen[$0]++' "${source_file}" >"${tmp_file}"
  fi

  if [[ -f "${auth_file}" ]] && cmp -s "${tmp_file}" "${auth_file}"; then
    log info "authorized_keys already up to date for ${ADMIN_USER}."
  elif is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] update ${auth_file} from ${source_file}"
  else
    install -m 0600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${tmp_file}" "${auth_file}"
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "${ssh_dir}"
    chmod 0700 "${ssh_dir}"
    chmod 0600 "${auth_file}"
    log info "authorized_keys installed for ${ADMIN_USER}: ${auth_file}"
  fi

  rm -f "${tmp_file}"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    key_count="$(count_valid_ssh_keys_in_file "${source_file}")"
    if [[ "${key_count}" -gt 0 ]]; then
      set_state "AUTHORIZED_KEYS_PRESENT" "yes"
      set_state "AUTHORIZED_KEYS_COUNT" "${key_count}"
      log info "Plan/Dry-run preview valid key count: ${key_count}"
      return 0
    fi
    fail_authorized_keys_install "No valid keys detected in ${source_file}."
  fi

  validate_authorized_keys_target_install "${ssh_dir}" "${auth_file}"
}

main() {
  load_config
  init_runtime
  module_banner "04_ssh_keys" "配置 SSH 公钥登录"
  require_root
  require_debian12

  if [[ -z "${ADMIN_USER:-}" ]]; then
    die "ADMIN_USER is empty."
  fi

  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    die "Admin user must exist before configuring SSH keys."
  fi

  local home_dir=""
  local ssh_dir=""
  local auth_file=""
  local source_file=""
  local key_count="0"

  home_dir="$(home_dir_for_user "${ADMIN_USER}")"
  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"

  log info "Stage 4.3 authorized_keys target file: ${auth_file}"

  if resolve_authorized_keys_source; then
    source_file="${_AUTHORIZED_KEYS_RESOLVED_SOURCE_FILE}"
  fi

  if [[ -n "${source_file}" ]]; then
    confirm_existing_authorized_keys_source_install "${source_file}" "${auth_file}" || die "第 4.3 段已取消。"
  fi

  if [[ -z "${source_file}" ]]; then
    if capture_authorized_keys_source_via_paste "${auth_file}"; then
      source_file="${_AUTHORIZED_KEYS_CAPTURED_SOURCE_FILE}"
    elif is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
      log info "Plan/Dry-run note: fixed authorized_keys source is not ready; real execution will require pasting a valid SSH public key."
      return 0
    else
      fail_authorized_keys_install "未提供有效 SSH 公钥，无法完成第 4.3 段。请先准备 ${source_file:-$(preferred_authorized_keys_source_path)}，或现场粘贴一整行公钥。"
    fi
  fi

  if [[ -z "${source_file}" ]]; then
    fail_authorized_keys_install "未解析到可用的 SSH 公钥源，无法继续第 4.3 段。"
  fi

  AUTHORIZED_KEYS_FILE="${source_file}"
  export_config
  log info "Authorized keys source file: ${source_file}"

  install_authorized_keys_to_target "${source_file}" "${ssh_dir}" "${auth_file}"
  if ! admin_authorized_keys_install_valid_for_user "${ADMIN_USER}"; then
    fail_authorized_keys_install "目标账户 authorized_keys 仍未 ready：${auth_file}"
  fi

  if ui_is_interactive && is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    key_count="$(admin_authorized_keys_count_for_user "${ADMIN_USER}")"
    show_target_install_result_and_wait "${source_file}" "${auth_file}" "${key_count}"
  fi
}

main "$@"
