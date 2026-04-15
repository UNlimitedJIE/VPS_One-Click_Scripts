#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

confirm_stage_checkpoint() {
  local title="$1"
  local body="$2"
  local answer=""

  if is_true "${PLAN_ONLY:-false}"; then
    log info "[plan] ${title}"
    log info "${body}"
    return 0
  fi

  ui_require_interactive || die "${title} 需要交互确认，请在交互式终端中执行。"

  while true; do
    if ! ui_prompt_input "${title}" "${body}\n输入 y 开始（yes 也可），输入 0 返回："; then
      return 1
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    if ui_input_is_affirmative "${answer}"; then
      return 0
    fi
    if [[ "${answer}" == "0" ]]; then
      return 1
    fi
    ui_warn_message "输入无效" "请输入 y 继续（yes 也可），或输入 0 取消本次执行。"
  done
}

stage_config_source_label() {
  printf '%s\n' "${ACTIVE_CONFIG_CHAIN:-${CONFIG_FILE:-<未设置>}}"
}

stage_persistent_local_config_path() {
  printf '%s/config/local.conf\n' "$(shared_project_root)"
}

persist_stage_admin_user_selection() {
  local username="$1"
  local target_file=""

  target_file="$(stage_persistent_local_config_path)"
  upsert_config_assignment "${target_file}" "ADMIN_USER" "${username}"
  log info "ADMIN_USER persisted to ${target_file}"
  log info "Persistent ADMIN_USER value: ${username}"
}

prompt_stage_admin_user_value() {
  local cancel_hint="${1:-输入 0 返回：}"
  local candidate=""
  local validation_error=""

  while true; do
    if ! ui_prompt_input "第 4.1 段 管理用户名" "当前正在设置：管理用户名\n请输入要创建/使用的管理用户名。\n仅允许字母、数字、下划线、短横线，且不能为 root。\n${cancel_hint}"; then
      return 1
    fi

    candidate="$(ui_trim_value "${UI_LAST_INPUT}")"
    if [[ "${candidate}" == "0" ]]; then
      return 1
    fi

    validation_error="$(admin_user_validation_error "${candidate}")"
    if [[ -n "${validation_error}" ]]; then
      ui_warn_message "输入无效" "${validation_error}"
      continue
    fi

    printf '%s\n' "${candidate}"
    return 0
  done
}

confirm_stage_admin_user_selection() {
  local validation_error=""
  local username=""
  local config_source=""
  local original_admin_user=""

  config_source="$(stage_config_source_label)"
  original_admin_user="${ADMIN_USER:-}"
  validation_error="$(admin_user_validation_error "${ADMIN_USER:-}")"

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    if [[ -z "${validation_error}" ]]; then
      log info "[plan] 当前默认用户名：${ADMIN_USER}"
      log info "[plan] 直接回车将沿用该用户名；输入新的合法用户名将覆盖 ADMIN_USER。"
      log info "[plan] 当前配置来源：${config_source}"
    else
      log info "[plan] 当前 ADMIN_USER 无效，真实执行时将要求重新输入。"
      log info "[plan] 当前配置来源：${config_source}"
    fi
    return 0
  fi

  ui_require_interactive || die "第 4 步需要交互式确认管理用户名，请在交互式终端中执行。"

  if [[ -n "${validation_error}" ]]; then
    ui_warn_message "第 4.1 段 管理用户名" "当前 ADMIN_USER 为空或无效。\n当前配置来源：${config_source}\n现在需要重新输入管理用户名。"
    username="$(prompt_stage_admin_user_value "输入 0 返回：")" || return 1
    set_runtime_admin_user "${username}"
    persist_stage_admin_user_selection "${username}"
    log info "Stage 4 will use admin user: ${ADMIN_USER}"
    return 0
  fi

  while true; do
    if ! ui_prompt_input "第 4.1 段 确认管理用户名" "当前默认用户名：${original_admin_user}\n当前配置来源：${config_source}\n直接回车：沿用当前值\n输入新的合法用户名：直接替换\n输入 0：返回" "${original_admin_user}"; then
      return 1
    fi

    username="$(ui_trim_value "${UI_LAST_INPUT}")"
    if [[ "${username}" == "0" ]]; then
      return 1
    fi

    validation_error="$(admin_user_validation_error "${username}")"
    if [[ -n "${validation_error}" ]]; then
      ui_warn_message "输入无效" "${validation_error}"
      continue
    fi

    set_runtime_admin_user "${username}"
    if [[ "${username}" == "${original_admin_user}" ]]; then
      log info "Stage 4 will keep admin user: ${ADMIN_USER}"
    else
      persist_stage_admin_user_selection "${username}"
      log info "Stage 4 will use updated admin user: ${ADMIN_USER}"
    fi
    return 0
  done
}

stage_intro_body() {
  cat <<EOF
即将开始第 4 步：管理用户接入。
这里还不是设置具体参数，只是确认是否开始。

接下来会依次进入：
1. 4.1 确认管理用户名
2. 4.2 配置 sudo 行为
3. 4.3 配置并验证 SSH 公钥
4. SSH 接入准备

这里不再单独配置账户密码。
如果选择 sudo=password，后续会直接设置该管理用户用于 sudo 验证的本地密码。
EOF
}

stage_before_hardening_body() {
  local requested_port=""
  local effective_port=""
  local port_note=""
  local auth_ready=""

  requested_port="${SSH_PORT:-22}"
  effective_port="$(effective_ssh_port_for_changes)"
  auth_ready="$(ssh_publickey_login_ready_label_for_user "${ADMIN_USER}")"

  if [[ "${requested_port}" == "${effective_port}" ]]; then
    port_note="当前 SSH 端口：${effective_port}"
  else
    port_note="请求的 SSH 端口：${requested_port}；当前实际会按 ${effective_port} 生效"
  fi

  cat <<EOF
即将执行第 4 步里的 SSH 接入准备。
管理用户：${ADMIN_USER:-<未设置>}
当前 authorized_keys：${auth_ready}
SSH 公钥源：${AUTHORIZED_KEYS_FILE:-<未设置>}
${port_note}
这一阶段会按 safe gate 收敛 SSH 策略；root 收口仍在第 5 步。
EOF
}

stage_detect_admin_sudo_mode() {
  local dropin_path=""
  local user_in_sudo_group="no"
  local sudo_group_enabled="no"
  local state_mode=""

  state_mode="$(get_state "ADMIN_SUDO_MODE" || true)"
  case "${state_mode}" in
    nopasswd|password|no-sudo)
      printf '%s\n' "${state_mode}"
      return 0
      ;;
  esac

  if [[ -z "${ADMIN_USER:-}" ]] || ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    printf '%s\n' "unknown"
    return 0
  fi

  dropin_path="/etc/sudoers.d/90-${ADMIN_USER}"
  if [[ -f "${dropin_path}" && "$(grep -Fxc "${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL" "${dropin_path}" 2>/dev/null || true)" -gt 0 ]]; then
    printf '%s\n' "nopasswd"
    return 0
  fi

  if [[ -f "${dropin_path}" && "$(grep -Fxc "${ADMIN_USER} ALL=(ALL:ALL) ALL" "${dropin_path}" 2>/dev/null || true)" -gt 0 ]]; then
    printf '%s\n' "password"
    return 0
  fi

  if id -nG "${ADMIN_USER}" 2>/dev/null | tr ' ' '\n' | grep -Fxq "sudo"; then
    user_in_sudo_group="yes"
  fi
  if grep -RqsE '^[[:space:]]*%sudo[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
    sudo_group_enabled="yes"
  fi

  if [[ "${user_in_sudo_group}" == "yes" && "${sudo_group_enabled}" == "yes" ]]; then
    printf '%s\n' "password"
    return 0
  fi

  printf '%s\n' "no-sudo"
}

stage_connection_summary() {
  local auth_ready="not ready"
  local safe_gate_state=""
  local sudo_mode=""
  local password_policy=""
  local pubkey_policy=""
  local step5_ready="no"

  safe_gate_state="$(get_state "SSH_SAFE_GATE_PASSED" || true)"
  password_policy="$(current_password_authentication_mode || true)"
  pubkey_policy="$(current_pubkey_authentication_mode || true)"
  sudo_mode="$(stage_detect_admin_sudo_mode)"

  auth_ready="$(ssh_publickey_login_ready_label_for_user "${ADMIN_USER}")"
  step5_ready="$(ssh_stage5_ready_state_for_user "${ADMIN_USER}")"
  safe_gate_state="${safe_gate_state:-$(ssh_safe_gate_state_for_user "${ADMIN_USER}")}"

  cat <<EOF
第 4 步当前状态
- 当前管理用户：${ADMIN_USER:-<未设置>}
- 当前 sudo 模式：${sudo_mode}
- 当前 authorized_keys：${auth_ready}
- 当前 pubkeyauthentication：${pubkey_policy:-unknown}
- 当前 passwordauthentication：${password_policy:-unknown}
- 当前 safe gate：${safe_gate_state}
- 当前是否满足进入第 5 步的条件：${step5_ready}
EOF
}

main() {
  load_config
  init_runtime
  module_banner "03_admin_access_stage" "创建并配置管理用户接入"
  require_root
  require_debian12

  log info "ACTIVE_CONFIG_CHAIN=${ACTIVE_CONFIG_CHAIN:-<unset>}"
  log info "ADMIN_USER=${ADMIN_USER:-<unset>}"
  log info "AUTHORIZED_KEYS_FILE=${AUTHORIZED_KEYS_FILE:-<empty>}"
  log info "SSH_PORT=${SSH_PORT:-<unset>}"

  confirm_stage_checkpoint "管理用户与 SSH 接入阶段" "$(stage_intro_body)" || die "管理用户与 SSH 接入阶段已取消。"
  confirm_stage_admin_user_selection || die "管理用户与 SSH 接入阶段已取消。"

  bash "${SCRIPT_DIR}/03_admin_user.sh"
  bash "${SCRIPT_DIR}/04_ssh_keys.sh"
  if ! admin_authorized_keys_ready_for_user "${ADMIN_USER}"; then
    die "第 4.3 段未完成：目标账户 authorized_keys 仍未 ready。"
  fi

  confirm_stage_checkpoint "执行 SSH 加固前确认" "$(stage_before_hardening_body)" || die "SSH 加固已取消。"

  bash "${SCRIPT_DIR}/05_ssh_hardening.sh"

  log info "$(stage_connection_summary)"
}

main "$@"
