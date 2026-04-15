#!/usr/bin/env bash
set -euo pipefail

# Module: 025_change_ssh_port
# Purpose: 安全更改 SSH 端口，并同步项目配置。
# Preconditions: root；Debian 12；sshd 可用。
# Steps:
#   1. 读取 sshd 当前实际生效端口
#   2. 输入并校验新端口
#   3. 明确确认云防火墙/安全组放行
#   4. 用受控 SSH 主配置块唯一写入 Port
#   5. 校验 sshd -t、reload、sshd -T，并同步 config/local.conf

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

project_local_config_path() {
  printf '%s/config/local.conf\n' "${PROJECT_ROOT}"
}

show_ssh_port_step_result() {
  local current="$1"
  local evidence="$2"
  local passed="$3"
  local block=""

  block="$(readonly_status_block "第 4 步 SSH 端口" "${current}" "${evidence}" "${passed}")"
  printf '%s' "${block}"
}

fail_ssh_port_step() {
  local current="$1"
  local evidence="$2"

  show_ssh_port_step_result "${current}" "${evidence}" "未通过"
  die "${evidence}"
}

current_sshd_runtime_port_or_die() {
  local current_port=""

  command_exists sshd || die "sshd 命令不存在，无法更改 SSH 端口。"
  validate_sshd_config
  current_port="$(current_ssh_port)"
  [[ "${current_port}" =~ ^[0-9]+$ ]] || die "无法读取当前 sshd 实际生效端口。"
  printf '%s\n' "${current_port}"
}

sshd_is_listening_on_port() {
  local port="${1:-}"
  [[ -n "${port}" ]] || return 1
  ss -ltnpH 2>/dev/null | awk -v port=":${port}" '
    $4 ~ port"$" && /sshd/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

ssh_port_step_validation_error() {
  local port="${1:-}"
  local current_port="${2:-}"
  local error_message=""

  error_message="$(port_validation_error_zh "${port}")"
  if [[ -n "${error_message}" ]]; then
    printf '%s\n' "${error_message}"
    return 0
  fi

  if [[ "${port}" != "${current_port}" ]] && ssh_port_is_listening_locally "${port}" && ! sshd_is_listening_on_port "${port}"; then
    printf '端口 %s 已被本机其他服务占用。\n' "${port}"
    return 0
  fi
}

prompt_target_ssh_port() {
  local current_port="$1"
  local answer=""
  local validation_error=""

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "[plan] 当前实际 SSH 端口：${current_port}"
    log info "[plan] real execution will prompt for the new SSH port and allow 0 to return."
    printf '%s\n' "${SSH_PORT:-${current_port}}"
    return 0
  fi

  ui_require_interactive || die "更改 SSH 端口需要交互式终端。"

  while true; do
    if ! ui_prompt_input \
      "第 4 步 更改 SSH 端口" \
      "当前实际 SSH 端口：${current_port}\n请输入新的 SSH 端口。\n输入 0 返回" \
      "${current_port}"; then
      return 1
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    [[ -n "${answer}" ]] || answer="${current_port}"

    if [[ "${answer}" == "0" ]]; then
      return 1
    fi

    validation_error="$(ssh_port_step_validation_error "${answer}" "${current_port}")"
    if [[ -n "${validation_error}" ]]; then
      ui_warn_message "输入无效" "${validation_error}"
      continue
    fi

    printf '%s\n' "${answer}"
    return 0
  done
}

confirm_ssh_port_change_risk() {
  local current_port="$1"
  local target_port="$2"
  local answer=""

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "[plan] changing SSH port from ${current_port} to ${target_port} requires explicit confirmation."
    return 0
  fi

  ui_require_interactive || die "更改 SSH 端口前需要交互确认。"

  while true; do
    if ! ui_prompt_input \
      "确认更改 SSH 端口" \
      "当前实际 SSH 端口：${current_port}\n目标 SSH 端口：${target_port}\n云厂商安全组 / 云防火墙也必须同步放行新端口。\n若未放行，公网连接可能失败。" \
      ""; then
      return 1
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    if ui_input_is_affirmative "${answer}"; then
      return 0
    fi
    if [[ "${answer}" == "0" ]]; then
      return 1
    fi
    ui_warn_message "输入无效" "请输入 y 继续，或输入 0 返回。"
  done
}

persist_ssh_port_runtime_config() {
  local target_port="$1"
  local config_file=""
  local confirm_value="false"

  config_file="$(project_local_config_path)"
  if [[ "${target_port}" != "22" ]]; then
    confirm_value="true"
  fi

  upsert_config_assignment "${config_file}" "SSH_PORT" "${target_port}"
  upsert_config_assignment "${config_file}" "CONFIRM_SSH_PORT_CHANGE" "${confirm_value}"

  SSH_PORT="${target_port}"
  CONFIRM_SSH_PORT_CHANGE="${confirm_value}"
  export_config

  set_state "SSH_PORT_PERSISTED_FILE" "${config_file}"
  set_state "SSH_PORT_PERSISTED_VALUE" "${target_port}"
  set_state "SSH_PORT_CHANGE_CONFIRMED" "${confirm_value}"

  log info "SSH_PORT persisted to ${config_file}"
  log info "Persistent SSH_PORT value: ${target_port}"
}

main() {
  load_config
  init_runtime
  module_banner "025_change_ssh_port" "更改 SSH 端口"
  require_root
  require_debian12

  apt_install_packages openssh-server

  local current_port=""
  local target_port=""
  local actual_port=""
  local current_pubkey_auth=""
  local current_password_auth=""
  local current_kbd_auth=""
  local current_root_auth=""
  local port_source=""
  local config_file=""
  local current=""
  local evidence=""
  local sync_needed="no"

  current_port="$(current_sshd_runtime_port_or_die)"
  target_port="$(prompt_target_ssh_port "${current_port}" || true)"
  [[ -n "${target_port}" ]] || die "第 4 步已取消。"

  config_file="$(project_local_config_path)"
  if [[ "${SSH_PORT:-}" != "${target_port}" ]]; then
    sync_needed="yes"
  elif [[ "${target_port}" != "22" ]] && is_false "${CONFIRM_SSH_PORT_CHANGE:-false}"; then
    sync_needed="yes"
  fi

  if [[ "${target_port}" == "${current_port}" ]]; then
    if [[ "${sync_needed}" == "yes" ]]; then
      persist_ssh_port_runtime_config "${target_port}"
      evidence="输入端口与当前实际端口一致；未改写 sshd 配置；已同步项目配置为 ${target_port}"
    else
      evidence="输入端口与当前实际端口一致；未改写 sshd 配置；项目配置保持不变"
    fi
    set_state "SSH_PORT_TARGET" "${target_port}"
    set_state "SSH_PORT_RUNTIME_EFFECTIVE" "${current_port}"
    set_state "SSH_PORT_STEP_DONE" "no-change"

    current="当前目标端口=${target_port}; 当前 sshd 实际端口=${current_port}; SSH_PORT 持久配置文件=${config_file}"
    show_ssh_port_step_result "${current}" "${evidence}" "通过"
    return 0
  fi

  confirm_ssh_port_change_risk "${current_port}" "${target_port}" || die "第 4 步已取消。"

  current_pubkey_auth="$(current_pubkey_authentication_mode || true)"
  current_password_auth="$(current_password_authentication_mode || true)"
  current_kbd_auth="$(current_kbdinteractive_authentication_mode || true)"
  current_root_auth="$(current_permit_root_login_mode || true)"
  port_source="$(sshd_last_directive_source_line "Port" || true)"

  [[ "${current_pubkey_auth}" =~ ^(yes|no)$ ]] || die "无法读取当前 pubkeyauthentication，不能安全改写 SSH 配置。"
  [[ "${current_password_auth}" =~ ^(yes|no)$ ]] || die "无法读取当前 passwordauthentication，不能安全改写 SSH 配置。"
  [[ "${current_kbd_auth}" =~ ^(yes|no)$ ]] || die "无法读取当前 kbdinteractiveauthentication，不能安全改写 SSH 配置。"
  [[ -n "${current_root_auth}" && "${current_root_auth}" != "unknown" ]] || die "无法读取当前 permitrootlogin，不能安全改写 SSH 配置。"

  log info "Current sshd effective values before port change: port=${current_port}, pubkey=${current_pubkey_auth}, password=${current_password_auth}, kbd=${current_kbd_auth}, permitrootlogin=${current_root_auth}"

  sshd_apply_managed_settings "${target_port}" "${current_pubkey_auth}" "${current_password_auth}" "${current_kbd_auth}" "${current_root_auth}"
  validate_sshd_config
  reload_service_if_exists "$(ssh_service_name)"

  actual_port="$(current_sshd_runtime_port_or_die)"
  if [[ "${actual_port}" != "${target_port}" ]]; then
    current="当前目标端口=${target_port}; 当前 sshd 实际端口=${actual_port}; SSH_PORT 持久配置文件=${config_file}"
    evidence="sshd -T 读回端口与目标不一致；Port 来源=${port_source:-not found}"
    fail_ssh_port_step "${current}" "${evidence}"
  fi

  if ! ssh_port_is_listening_locally "${target_port}"; then
    current="当前目标端口=${target_port}; 当前 sshd 实际端口=${actual_port}; SSH_PORT 持久配置文件=${config_file}"
    evidence="sshd -T 已返回 ${actual_port}，但本机未检测到 ${target_port} 端口监听"
    fail_ssh_port_step "${current}" "${evidence}"
  fi

  persist_ssh_port_runtime_config "${target_port}"
  set_state "SSH_PORT_TARGET" "${target_port}"
  set_state "SSH_PORT_RUNTIME_EFFECTIVE" "${actual_port}"
  set_state "SSH_PORT_STEP_DONE" "changed"

  current="当前目标端口=${target_port}; 当前 sshd 实际端口=${actual_port}; SSH_PORT 持久配置文件=${config_file}"
  evidence="已通过 sshd -t、reload 和 sshd -T 校验；Port 来源=${port_source:-not found}"
  show_ssh_port_step_result "${current}" "${evidence}" "通过"
}

main "$@"
