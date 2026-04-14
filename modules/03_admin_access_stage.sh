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
    if ! ui_prompt_input "${title}" "${body}\n\n输入 yes 继续；输入 0 取消本次执行：" "yes"; then
      return 1
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      yes|YES|y|Y)
        return 0
        ;;
      0)
        return 1
        ;;
      *)
        ui_warn_message "输入无效" "请输入 yes 继续，或输入 0 取消本次执行。"
        ;;
    esac
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
    if ! ui_prompt_input "第 4.1 段 管理用户名" "请输入要创建/使用的管理用户名（仅限字母、数字、下划线、短横线，且不能为 root）：\n${cancel_hint}"; then
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
    ui_warn_message "第 4.1 段 管理用户名待确认" "当前 ADMIN_USER 为空或无效。\n当前配置来源：${config_source}\n\n现在必须重新输入管理用户名。"
    username="$(prompt_stage_admin_user_value "输入 0 返回：")" || return 1
    set_runtime_admin_user "${username}"
    persist_stage_admin_user_selection "${username}"
    log info "Stage 4 will use admin user: ${ADMIN_USER}"
    return 0
  fi

  while true; do
    if ! ui_prompt_input "第 4.1 段 确认管理用户名" "当前默认用户名：${original_admin_user}\n当前配置来源：${config_source}\n\n直接回车：沿用当前默认用户名\n输入 0：返回\n输入任意合法用户名：直接替换 ADMIN_USER" "${original_admin_user}"; then
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
第 4 步会按下面 4 段顺序执行：
1. 第 4.1 段：确认或输入管理用户名
2. 第 4.2 段：单独配置 sudo 行为
   - nopasswd / password
   - 若选择 password，会明确说明：当前 sudo 实际仍使用该用户的账户密码，不是假装有独立 sudo 密码
3. 第 4.3 段：单独配置本地账户密码
   - keep / set / no local password
   - 账户密码影响本地/密码类认证，不影响 SSH 公钥登录
4. 第 4.4 段：配置并验证 SSH 公钥
   - 优先读取固定路径 $(preferred_authorized_keys_source_path)
   - 若没有有效公钥，会进入现场粘贴模式

4 段完成后，本阶段才会执行 SSH 接入准备：
- 默认目标策略：PubkeyAuthentication=yes、PasswordAuthentication=no、KbdInteractiveAuthentication=no
- 只有当目标账户 authorized_keys 已正确安装并通过 safe gate 后，才会真正关闭 SSH 密码登录
- 如果公钥还没准备好，本阶段会临时保留 SSH 密码登录，避免把你锁死
- root 远程登录在本阶段默认仍保持可用，第 5 步才做最终收口

sudo、账户密码、SSH 登录认证是三件不同的事；这一步不会再把它们混在一起。
EOF
}

stage_before_hardening_body() {
  local requested_port=""
  local effective_port=""
  local port_note=""

  requested_port="${SSH_PORT:-22}"
  effective_port="$(effective_ssh_port_for_changes)"

  if [[ "${requested_port}" == "${effective_port}" ]]; then
    port_note="当前 SSH 端口将按 ${effective_port} 生效。"
  else
    port_note="你请求的 SSH 端口是 ${requested_port}，但当前真正会生效的仍是 ${effective_port}。"
  fi

  cat <<EOF
在真正执行 SSH 加固前，请再次确认：
- AUTHORIZED_KEYS_FILE：${AUTHORIZED_KEYS_FILE:-<未设置>}
- 管理用户名：${ADMIN_USER:-<未设置>}
- SSH_PORT：${requested_port}

${port_note}

这一阶段只做 SSH 接入准备，root 远程登录暂时不会关闭。
如果你修改了 SSH 端口，还必须确认云厂商安全组/云防火墙已经同步放行对应端口。
否则即使本机 sshd 已改好，公网访问结果也可能仍然不正确。
EOF
}

stage_connection_summary() {
  local effective_port=""
  local auth_ready="not ready"
  local safe_gate_state=""
  local admin_ready="no"
  local password_policy=""
  local pubkey_policy=""
  local kbd_policy=""
  local root_policy=""
  local password_policy_state=""
  local pubkey_policy_state=""
  local root_policy_state=""
  local target_password_policy=""
  local target_pubkey_policy=""
  local target_kbd_policy=""
  local step5_ready="no"
  local last_auth_method=""
  local last_auth_label=""
  effective_port="$(effective_ssh_port_for_changes)"
  safe_gate_state="$(get_state "SSH_SAFE_GATE_PASSED" || true)"
  password_policy="$(current_password_authentication_mode || true)"
  pubkey_policy="$(current_pubkey_authentication_mode || true)"
  kbd_policy="$(current_kbdinteractive_authentication_mode || true)"
  root_policy="$(current_permit_root_login_mode || true)"
  password_policy_state="$(ssh_policy_enabled_disabled_label "${password_policy}")"
  pubkey_policy_state="$(ssh_policy_enabled_disabled_label "${pubkey_policy}")"
  root_policy_state="$(ssh_root_remote_login_enabled_disabled_label "${root_policy}")"
  target_password_policy="$(get_state "SSH_AUTH_TARGET_PASSWORD" || true)"
  target_pubkey_policy="$(get_state "SSH_AUTH_TARGET_PUBKEY" || true)"
  target_kbd_policy="$(get_state "SSH_AUTH_TARGET_KBD" || true)"
  last_auth_method="$(last_successful_ssh_auth_method_for_user "${ADMIN_USER}")"
  last_auth_label="$(ssh_last_successful_auth_method_label "${last_auth_method}")"

  if [[ -n "${ADMIN_USER:-}" ]] && id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    admin_ready="yes"
  fi

  auth_ready="$(ssh_publickey_login_ready_label_for_user "${ADMIN_USER}")"
  step5_ready="$(ssh_stage5_ready_state_for_user "${ADMIN_USER}")"
  safe_gate_state="${safe_gate_state:-no}"

  cat <<EOF
管理用户接入阶段摘要
- 用户名：${ADMIN_USER:-<未设置>}
- 管理用户已创建：${admin_ready}
- 当前有效 SSH 端口：${effective_port}
- SSH 目标策略：pubkey=$(ssh_policy_enabled_disabled_label "${target_pubkey_policy:-yes}") / password=$(ssh_policy_enabled_disabled_label "${target_password_policy:-no}") / keyboard-interactive=$(ssh_policy_enabled_disabled_label "${target_kbd_policy:-no}")
- 当前 SSH 密码登录：${password_policy_state}
- 当前 SSH 公钥策略：${pubkey_policy_state}
- 当前 root 远程登录：${root_policy_state}
- 当前 pubkeyauthentication 实际值：${pubkey_policy:-unknown}
- 当前 passwordauthentication 实际值：${password_policy:-unknown}
- 当前 kbdinteractiveauthentication 实际值：${kbd_policy:-unknown}
- 当前 permitrootlogin 实际值：${root_policy:-unknown}
- 当前 SSH 公钥登录就绪度：${auth_ready}
- 目标账户 authorized_keys：${auth_ready}
- SSH safe gate：${safe_gate_state:-no}
- 当前是否满足进入第 5 步的条件：${step5_ready}
- Last successful SSH auth for ${ADMIN_USER:-<unset>}: ${last_auth_label}

测试说明：
- 强制只走公钥：$(ssh_force_publickey_test_command "${ADMIN_USER:-<ADMIN_USER>}" "${effective_port}")
- 强制只走密码：$(ssh_force_password_test_command "${ADMIN_USER:-<ADMIN_USER>}" "${effective_port}")
- 若 SSH 密码登录已真正关闭，password-only 测试应失败；若仍成功，说明当前还在走密码认证。

结论：
- 只有当 authorized_keys 已正确安装且 safe gate=yes 时，SSH 密码登录才会默认收紧为 no
- root 远程登录的最终关闭仍留在第 5 步
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

  confirm_stage_admin_user_selection || die "管理用户与 SSH 接入阶段已取消。"
  confirm_stage_checkpoint "管理用户与 SSH 接入阶段" "$(stage_intro_body)" || die "管理用户与 SSH 接入阶段已取消。"

  bash "${SCRIPT_DIR}/03_admin_user.sh"
  bash "${SCRIPT_DIR}/04_ssh_keys.sh"

  confirm_stage_checkpoint "执行 SSH 加固前确认" "$(stage_before_hardening_body)" || die "SSH 加固已取消。"

  bash "${SCRIPT_DIR}/05_ssh_hardening.sh"

  log info "$(stage_connection_summary)"
}

main "$@"
