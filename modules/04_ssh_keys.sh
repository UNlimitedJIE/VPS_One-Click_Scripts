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
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

fail_authorized_keys_install() {
  set_state "AUTHORIZED_KEYS_PRESENT" "no"
  set_state "AUTHORIZED_KEYS_COUNT" "0"
  die "$*"
}

resolve_authorized_keys_source() {
  local source_file=""
  source_file="$(bootstrap_authorized_keys_fallback_path)"
  if [[ -n "${AUTHORIZED_KEYS_FILE:-}" ]]; then
    source_file="${AUTHORIZED_KEYS_FILE}"
  fi

  if [[ -f "${source_file}" && "$(count_valid_ssh_keys_in_file "${source_file}")" -gt 0 ]]; then
    printf '%s\n' "${source_file}"
    return 0
  fi

  return 1
}

authorized_keys_source_status_message() {
  local source_file="$1"

  if [[ ! -e "${source_file}" ]]; then
    printf '当前公钥源文件不存在：%s\n' "${source_file}"
    return 0
  fi

  if [[ ! -s "${source_file}" ]]; then
    printf '当前公钥源文件为空：%s\n' "${source_file}"
    return 0
  fi

  printf '当前公钥源文件里没有检测到有效公钥：%s\n' "${source_file}"
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

capture_authorized_keys_source_via_paste() {
  local source_file=""
  local source_dir=""
  local prompt_body=""
  local pasted_key=""

  source_file="$(preferred_authorized_keys_source_path)"
  source_dir="$(dirname "${source_file}")"

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "[plan] if ${source_file} is missing or invalid, real execution will prompt for a single-line SSH public key and write it to ${source_file}"
    return 1
  fi

  ui_require_interactive || die "当前公钥源文件无效，且当前不是交互式终端，无法现场粘贴 SSH 公钥。请先写入 ${source_file}。"

  prompt_body="$(cat <<EOF
$(authorized_keys_source_status_message "${AUTHORIZED_KEYS_FILE:-${source_file}}")

是否现在粘贴 SSH 公钥？

- yes：现在粘贴一整行公钥
- no：暂不粘贴，跳过本次自动安装
EOF
)"

  if ! ui_confirm_text "SSH 公钥导入源缺失" "${prompt_body}"; then
    return 1
  fi

  while true; do
    UI_LAST_INPUT=""
    export UI_LAST_INPUT

    ui_print_raw "\n粘贴 SSH 公钥\n现在正在等待你粘贴一整行 SSH 公钥，粘贴后按回车。\n例如：ssh-ed25519 ... 或 ssh-rsa ...\n输入 0 取消。\n请输入："
    if ! ui_read_line; then
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
        if single_line_ssh_public_key_is_valid "${pasted_key}"; then
          ensure_directory "${source_dir}" "0755" "root" "root"
          apply_managed_file "${source_file}" "0644" "${pasted_key}" "false"
          AUTHORIZED_KEYS_FILE="${source_file}"
          export_config
          log info "Authorized keys source file prepared: ${source_file}"
          printf '%s\n' "${source_file}"
          return 0
        fi
        ui_warn_message "公钥无效" "只支持一整行 SSH 公钥，例如 ssh-ed25519 ... 或 ssh-rsa ...。你可以重试，或输入 0 取消。"
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

  log info "Authorized keys target file: ${auth_file}"

  source_file="$(resolve_authorized_keys_source || true)"
  if [[ -z "${source_file}" ]]; then
    if [[ "$(count_valid_ssh_keys_in_file "${auth_file}")" -gt 0 ]]; then
      key_count="$(count_valid_ssh_keys_in_file "${auth_file}")"
      set_state "AUTHORIZED_KEYS_PRESENT" "yes"
      set_state "AUTHORIZED_KEYS_COUNT" "${key_count}"
      log info "No authorized_keys source file is currently available, but target authorized_keys already exists for ${ADMIN_USER}."
      log info "Valid authorized_keys count for ${ADMIN_USER}: ${key_count}"
      return 0
    fi

    source_file="$(capture_authorized_keys_source_via_paste || true)"
  fi

  if [[ -z "${source_file}" ]]; then
    log info "No valid authorized_keys source is currently available. SSH public key installation is skipped for now."
    log info "Preferred source path: $(preferred_authorized_keys_source_path)"
    set_state "AUTHORIZED_KEYS_PRESENT" "no"
    set_state "AUTHORIZED_KEYS_COUNT" "0"
    return 0
  fi

  log info "Authorized keys source file: ${source_file}"

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
