#!/usr/bin/env bash
set -euo pipefail

is_true() {
  case "${1:-false}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  ! is_true "${1:-false}"
}

require_root() {
  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "Plan/Dry-run mode: skipping root requirement."
    return 0
  fi
  [[ "${EUID}" -eq 0 ]] || die "This script must run as root."
}

require_debian12() {
  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    if ! is_debian12; then
      log warn "Plan/Dry-run mode: skipping strict Debian 12 requirement. Current: $(pretty_os_name 2>/dev/null || echo unknown)"
    fi
    return 0
  fi
  is_debian12 || die "Target system must be Debian 12. Current: $(pretty_os_name)"
}

ssh_port_validation_error() {
  local port="${1:-}"

  if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "SSH_PORT must be a number."
    return 0
  fi

  if (( port < 1 || port > 65535 )); then
    printf '%s\n' "SSH_PORT must be between 1 and 65535."
    return 0
  fi
}

validate_ssh_port() {
  local error_message=""
  error_message="$(ssh_port_validation_error "${SSH_PORT}")"
  [[ -z "${error_message}" ]] || die "${error_message}"
}

port_validation_error_zh() {
  local port="${1:-}"

  if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "端口必须是数字。"
    return 0
  fi

  if (( port < 1 || port > 65535 )); then
    printf '%s\n' "端口范围必须在 1 到 65535 之间。"
    return 0
  fi
}

admin_user_validation_error() {
  local username=""
  username="$(trim_surrounding_whitespace "${1:-}")"

  if [[ -z "${username}" ]]; then
    printf '%s\n' "管理用户名不能为空。"
    return 0
  fi

  if [[ "${username}" == "root" ]]; then
    printf '%s\n' "管理用户名不能为 root。"
    return 0
  fi

  if (( ${#username} < 1 || ${#username} > 32 )); then
    printf '%s\n' "管理用户名长度必须在 1 到 32 个字符之间。"
    return 0
  fi

  if [[ ! "${username}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s\n' "管理用户名只能包含字母、数字、下划线和短横线。"
    return 0
  fi
}

admin_user_needs_prompt() {
  local username=""
  username="$(trim_surrounding_whitespace "${1:-${ADMIN_USER:-}}")"
  [[ -z "${username}" || "${username}" == "${DEFAULT_ADMIN_USER:-ops}" ]]
}

trim_surrounding_whitespace() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "${value}"
}

ssh_public_key_type_allowed() {
  case "${1:-}" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ssh_public_key_line_valid() {
  local line="${1:-}"
  local key_type=""
  local key_blob=""
  local key_comment=""

  read -r key_type key_blob key_comment <<<"${line}"
  [[ -n "${key_type}" && -n "${key_blob}" ]] || return 1
  ssh_public_key_type_allowed "${key_type}" || return 1
  [[ "${key_blob}" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1

  if command_exists ssh-keygen; then
    local tmp_file=""
    tmp_file="$(mktemp)"
    printf '%s\n' "${line}" >"${tmp_file}"
    if ssh-keygen -l -f "${tmp_file}" >/dev/null 2>&1; then
      rm -f "${tmp_file}"
      return 0
    fi
    rm -f "${tmp_file}"
    return 1
  fi

  return 0
}

count_valid_ssh_keys_in_file() {
  local file="$1"
  local count=0
  local line=""
  local normalized_line=""

  [[ -f "${file}" ]] || {
    printf '%s\n' "0"
    return 0
  }

  while IFS= read -r line || [[ -n "${line}" ]]; do
    normalized_line="$(trim_surrounding_whitespace "${line}")"
    [[ -n "${normalized_line}" ]] || continue
    [[ "${normalized_line}" == \#* ]] && continue
    if ssh_public_key_line_valid "${normalized_line}"; then
      count=$((count + 1))
    fi
  done <"${file}"

  printf '%s\n' "${count}"
}

validate_config() {
  validate_ssh_port

  local admin_user_error=""
  local target_keys_ready="no"
  local preferred_source=""
  if [[ -n "${ADMIN_USER}" ]]; then
    admin_user_error="$(admin_user_validation_error "${ADMIN_USER}")"
    [[ -z "${admin_user_error}" ]] || die "${admin_user_error}"
    if admin_authorized_keys_ready_for_user "${ADMIN_USER}"; then
      target_keys_ready="yes"
    fi
  fi
  preferred_source="$(preferred_authorized_keys_source_path)"

  if [[ -n "${AUTHORIZED_KEYS_FILE}" && ! -f "${AUTHORIZED_KEYS_FILE}" ]]; then
    if authorized_keys_source_is_root_only_path "${AUTHORIZED_KEYS_FILE}" && [[ "${EUID}" -ne 0 ]]; then
      if [[ "${target_keys_ready}" == "yes" ]]; then
        log info "AUTHORIZED_KEYS_FILE 当前指向 /root 下路径，非 root 用户不可访问；若目标账户 authorized_keys 已安装，可忽略此提示。"
      else
        log info "AUTHORIZED_KEYS_FILE 当前指向 /root 下路径；正常流程建议改用 ${preferred_source}，第 4 步也可直接粘贴公钥写入该固定路径。"
      fi
    elif [[ "${target_keys_ready}" == "yes" ]]; then
      log info "AUTHORIZED_KEYS_FILE 源文件当前不可访问或不存在，但目标账户 authorized_keys 已安装完成。"
    else
      log info "AUTHORIZED_KEYS_FILE 源文件尚未准备好：${AUTHORIZED_KEYS_FILE}。第 4 步可直接粘贴 SSH 公钥并写入 ${preferred_source}。"
    fi
  fi

  if [[ -n "${AUTHORIZED_KEYS_FILE}" && -f "${AUTHORIZED_KEYS_FILE}" ]]; then
    if [[ "$(count_valid_ssh_keys_in_file "${AUTHORIZED_KEYS_FILE}")" -eq 0 ]]; then
      if [[ "${target_keys_ready}" == "yes" ]]; then
        log info "AUTHORIZED_KEYS_FILE 当前没有有效公钥，但目标账户 authorized_keys 已安装完成。"
      else
        log info "AUTHORIZED_KEYS_FILE 当前没有有效公钥：${AUTHORIZED_KEYS_FILE}。第 4 步可直接粘贴 SSH 公钥并覆盖写入 ${preferred_source}。"
      fi
    fi
  fi
}

validate_authorized_keys_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Authorized keys file not found: ${file}"
  [[ "$(count_valid_ssh_keys_in_file "$file")" -gt 0 ]] || die "No valid public keys found in ${file}"
}

can_disable_password_login() {
  local user="${1:-${ADMIN_USER:-}}"
  [[ -n "$user" ]] || return 1
  id -u "$user" >/dev/null 2>&1 || return 1
  authorized_keys_present_for_user "$user"
}

validate_sshd_config() {
  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "Plan/Dry-run mode: skipping live sshd syntax validation."
    return 0
  fi
  if ! command_exists sshd; then
    die "sshd command not found."
  fi
  sshd -t
}

preflight_print_status() {
  local level="$1"
  local subject="$2"
  local message="$3"
  printf '[%s] %s: %s\n' "${level}" "${subject}" "${message}"
}

preflight_add_issue() {
  local issue_array_name="$1"
  local message="$2"
  local quoted_message=""
  printf -v quoted_message '%q' "${message}"
  eval "${issue_array_name}+=( ${quoted_message} )"
}

run_preflight_checks() {
  local -a errors=()
  local -a pending=()
  local -a warnings=()
  local current_os=""
  local current_user=""
  local port_error=""
  local key_count=0
  local target_keys_ready="no"
  local preferred_source=""
  local pkg=""

  printf 'Preflight 检查结果\n'
  printf '配置文件: %s\n\n' "${CONFIG_FILE:-未设置}"
  preferred_source="$(preferred_authorized_keys_source_path)"

  current_os="$(pretty_os_name 2>/dev/null || echo unknown)"
  if is_debian12; then
    preflight_print_status "OK" "系统" "已检测到 ${current_os}"
  else
    preflight_print_status "ERROR" "系统" "要求 Debian 12，当前为 ${current_os}"
    preflight_add_issue errors "系统不是 Debian 12"
  fi

  current_user="$(id -un 2>/dev/null || echo unknown)"
  if [[ "${EUID}" -eq 0 ]]; then
    preflight_print_status "OK" "运行身份" "当前为 root，可直接执行正式步骤"
  else
    preflight_print_status "WARN" "运行身份" "当前为 ${current_user}，正式执行大多数步骤仍需 root 或 sudo"
    preflight_add_issue warnings "当前不是 root 运行"
  fi

  if admin_user_needs_prompt "${ADMIN_USER}"; then
    preflight_print_status "ERROR" "ADMIN_USER" "当前为空或仍为默认占位值，请先确定管理用户名"
    preflight_add_issue errors "ADMIN_USER 尚未确定"
  else
    local admin_user_error=""
    admin_user_error="$(admin_user_validation_error "${ADMIN_USER}")"
    if [[ -n "${admin_user_error}" ]]; then
      preflight_print_status "ERROR" "ADMIN_USER" "${admin_user_error}"
      preflight_add_issue errors "${admin_user_error}"
    else
      preflight_print_status "OK" "ADMIN_USER" "当前配置为 ${ADMIN_USER}"
      if admin_authorized_keys_ready_for_user "${ADMIN_USER}"; then
        target_keys_ready="yes"
      fi
    fi
  fi

  if [[ -z "${AUTHORIZED_KEYS_FILE}" ]]; then
    preflight_print_status "PENDING" "AUTHORIZED_KEYS_FILE" "当前未设置；第 4 步可直接粘贴 SSH 公钥并写入 ${preferred_source}"
    preflight_add_issue pending "AUTHORIZED_KEYS_FILE 尚未准备好；首次执行第 4 步时可现场粘贴公钥"
  elif [[ ! -f "${AUTHORIZED_KEYS_FILE}" ]]; then
    if authorized_keys_source_is_root_only_path "${AUTHORIZED_KEYS_FILE}" && [[ "${EUID}" -ne 0 ]] && [[ "${target_keys_ready}" == "yes" ]]; then
      preflight_print_status "PENDING" "AUTHORIZED_KEYS_FILE" "当前指向 /root 下路径，非 root 用户不可访问；但目标账户 authorized_keys 已安装，可忽略此提示"
      preflight_add_issue pending "AUTHORIZED_KEYS_FILE 当前位于 /root 下；如需后续维护，建议迁移到 ${preferred_source}"
    elif [[ "${target_keys_ready}" == "yes" ]]; then
      preflight_print_status "PENDING" "AUTHORIZED_KEYS_FILE" "源文件当前不可访问或不存在；但目标账户 authorized_keys 已安装完成"
      preflight_add_issue pending "AUTHORIZED_KEYS_FILE 当前不可访问；如需后续维护，建议迁移到可读路径"
    else
      preflight_print_status "PENDING" "AUTHORIZED_KEYS_FILE" "文件不存在：${AUTHORIZED_KEYS_FILE}；首次执行第 4 步时可直接粘贴 SSH 公钥"
      preflight_add_issue pending "AUTHORIZED_KEYS_FILE 不存在；首次执行第 4 步时可现场粘贴公钥"
    fi
  else
    key_count="$(count_valid_ssh_keys_in_file "${AUTHORIZED_KEYS_FILE}")"
    if (( key_count > 0 )); then
      preflight_print_status "OK" "AUTHORIZED_KEYS_FILE" "检测到 ${key_count} 个有效公钥: ${AUTHORIZED_KEYS_FILE}"
    elif [[ "${target_keys_ready}" == "yes" ]]; then
      preflight_print_status "PENDING" "AUTHORIZED_KEYS_FILE" "源文件中未检测到有效公钥；但目标账户 authorized_keys 已安装完成"
      preflight_add_issue pending "AUTHORIZED_KEYS_FILE 中没有有效公钥；当前不会阻塞后续 SSH 收紧"
    else
      preflight_print_status "PENDING" "AUTHORIZED_KEYS_FILE" "未检测到有效公钥：${AUTHORIZED_KEYS_FILE}；第 4 步可重新粘贴 SSH 公钥"
      preflight_add_issue pending "AUTHORIZED_KEYS_FILE 中没有有效公钥；首次执行第 4 步时可重新粘贴公钥"
    fi
  fi

  port_error="$(ssh_port_validation_error "${SSH_PORT}")"
  if [[ -n "${port_error}" ]]; then
    preflight_print_status "ERROR" "SSH_PORT" "${port_error}"
    preflight_add_issue errors "SSH_PORT 非法: ${SSH_PORT}"
  else
    preflight_print_status "OK" "SSH_PORT" "当前配置为 ${SSH_PORT}"
  fi

  if [[ "${SSH_PORT}" != "22" ]]; then
    if is_true "${CONFIRM_SSH_PORT_CHANGE}"; then
      preflight_print_status "OK" "CONFIRM_SSH_PORT_CHANGE" "已确认非 22 端口切换"
    else
      preflight_print_status "ERROR" "CONFIRM_SSH_PORT_CHANGE" "SSH_PORT=${SSH_PORT}，但未显式确认端口切换"
      preflight_add_issue errors "非 22 端口未设置 CONFIRM_SSH_PORT_CHANGE=true"
    fi
  else
    preflight_print_status "OK" "CONFIRM_SSH_PORT_CHANGE" "SSH 端口保持 22，无需额外确认"
  fi

  for pkg in openssh-server nftables fail2ban unattended-upgrades; do
    if package_installed "${pkg}"; then
      preflight_print_status "OK" "软件包 ${pkg}" "已安装"
    else
      preflight_print_status "WARN" "软件包 ${pkg}" "未安装"
      preflight_add_issue warnings "软件包未安装: ${pkg}"
    fi
  done

  printf '\n汇总\n'
  if ((${#errors[@]} > 0)); then
    preflight_print_status "ERROR" "阻塞问题" "共 ${#errors[@]} 项"
    local item=""
    for item in "${errors[@]}"; do
      printf -- '- %s\n' "${item}"
    done
  else
    preflight_print_status "OK" "阻塞问题" "未发现会阻止正式执行的高风险项"
  fi

  if ((${#warnings[@]} > 0)); then
    preflight_print_status "WARN" "提示项" "共 ${#warnings[@]} 项"
    local item=""
    for item in "${warnings[@]}"; do
      printf -- '- %s\n' "${item}"
    done
  else
    preflight_print_status "OK" "提示项" "无额外提示"
  fi

  if ((${#pending[@]} > 0)); then
    preflight_print_status "PENDING" "待完成项" "共 ${#pending[@]} 项"
    local item=""
    for item in "${pending[@]}"; do
      printf -- '- %s\n' "${item}"
    done
  else
    preflight_print_status "OK" "待完成项" "无首次配置待完成项"
  fi

  ((${#errors[@]} == 0))
}
