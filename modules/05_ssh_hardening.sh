#!/usr/bin/env bash
set -euo pipefail

# Module: 05_ssh_hardening
# Purpose: 使用 sshd_config.d drop-in 方式做 SSH 接入准备。
# Preconditions: root；Debian 12；openssh-server 可用。
# Steps:
#   1. 确认 sshd 服务存在
#   2. 基于配置生成 drop-in 文件
#   3. 安全门通过后才允许关闭密码登录
#   4. 非 22 端口必须显式确认后才真正切换
#   5. 语法检查后 reload 服务
# Idempotency:
#   - 使用受控 drop-in 文件，重复执行只覆盖本工程管理的配置
#   - 配置未变化时不重复改动

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "05_ssh_hardening" "SSH 接入准备"
  require_root
  require_debian12

  apt_install_packages openssh-server

  local target_password_auth="no"
  local target_pubkey_auth="yes"
  local target_kbd_auth="no"
  local password_auth="yes"
  local pubkey_auth="yes"
  local kbd_auth="yes"
  local safe_gate_passed="no"
  local admin_user_ready="no"
  local target_keys_ready="no"
  local runtime_port=""
  local target_port_listening="no"
  local last_auth_method=""
  local last_auth_label=""
  local cutover_state=""
  local safe_gate_reason="waiting-for-authorized-keys"
  local step5_ready_state="no"

  if [[ -n "${ADMIN_USER}" ]] && id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    admin_user_ready="yes"
    target_keys_ready="$(ssh_publickey_login_ready_label_for_user "${ADMIN_USER}")"
    safe_gate_passed="$(ssh_safe_gate_state_for_user "${ADMIN_USER}")"
  fi

  if [[ "${safe_gate_passed}" == "yes" ]]; then
    target_keys_ready="yes"
    safe_gate_reason="authorized-keys-ready"
  else
    target_keys_ready="no"
  fi

  set_state "SSH_SAFE_GATE_PASSED" "${safe_gate_passed}"
  set_state "SSH_SAFE_GATE_REASON" "${safe_gate_reason}"

  if is_false "${DISABLE_PASSWORD_LOGIN}"; then
    target_password_auth="yes"
    target_kbd_auth="yes"
  fi

  if [[ "${target_password_auth}" == "no" ]]; then
    if [[ "${safe_gate_passed}" == "yes" ]]; then
      password_auth="no"
      kbd_auth="no"
      log info "Safe gate passed. SSH password login will be disabled and pubkey login will remain enabled."
    else
      log info "Safe gate not passed yet. SSH password login will remain enabled temporarily so you are not locked out."
    fi
  fi

  local permit_root_login="yes"
  cutover_state="$(get_state "ADMIN_LOGIN_CUTOVER" || true)"
  if [[ "${cutover_state}" == "yes" || "$(current_permit_root_login_mode)" == "no" ]]; then
    permit_root_login="no"
  fi

  local current_port requested_port applied_port target_file content
  current_port="$(current_ssh_port)"
  requested_port="${SSH_PORT}"
  applied_port="$(effective_ssh_port_for_changes)"

  if ssh_port_change_pending_confirmation; then
    warn_ssh_port_change_not_confirmed
  fi

  target_file="/etc/ssh/sshd_config.d/99-vps-bootstrap.conf"
  content="$(cat <<EOF
# Managed by VPS bootstrap project.
# Purpose: baseline SSH access preparation for Debian 12.

Port ${applied_port}
PubkeyAuthentication ${pubkey_auth}
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication ${kbd_auth}
PermitRootLogin ${permit_root_login}
PermitEmptyPasswords no
UsePAM yes
X11Forwarding no
LoginGraceTime 30
MaxAuthTries 3
EOF
)"

  apply_managed_file "${target_file}" "0644" "${content}" "true"
  validate_sshd_config

  local ssh_service
  ssh_service="$(ssh_service_name)"
  reload_service_if_exists "${ssh_service}"
  runtime_port="$(current_ssh_port)"
  if ssh_port_is_listening_locally "${applied_port}"; then
    target_port_listening="yes"
  fi

  set_state "SSH_PORT_REQUESTED" "${requested_port}"
  set_state "SSH_PORT_EFFECTIVE" "${applied_port}"
  set_state "SSH_PORT_RUNTIME_EFFECTIVE" "${runtime_port}"
  set_state "SSH_TARGET_PORT_LISTENING" "${target_port_listening}"
  set_state "SSH_PORT_CHANGE_CONFIRMED" "${CONFIRM_SSH_PORT_CHANGE}"
  set_state "SSH_AUTH_TARGET_PASSWORD" "${target_password_auth}"
  set_state "SSH_AUTH_TARGET_PUBKEY" "${target_pubkey_auth}"
  set_state "SSH_AUTH_TARGET_KBD" "${target_kbd_auth}"
  set_state "SSH_AUTH_CURRENT_PASSWORD" "${password_auth}"
  set_state "SSH_AUTH_CURRENT_PUBKEY" "${pubkey_auth}"
  set_state "SSH_AUTH_CURRENT_KBD" "${kbd_auth}"
  set_state "SSH_PUBLICKEY_READY" "${target_keys_ready}"
  set_state "SSH_PASSWORD_LOGIN" "${password_auth}"
  set_state "ROOT_SSH_MODE" "${permit_root_login}"
  last_auth_method="$(last_successful_ssh_auth_method_for_user "${ADMIN_USER}")"
  last_auth_label="$(ssh_last_successful_auth_method_label "${last_auth_method}")"
  step5_ready_state="$(ssh_stage5_ready_state_for_user "${ADMIN_USER}")"
  set_state "SSH_STAGE5_READY" "${step5_ready_state}"
  set_state "SSH_LAST_SUCCESSFUL_AUTH_METHOD" "${last_auth_method}"

  log info "SSH safe gate: ${safe_gate_passed} (${safe_gate_reason})"
  log info "SSH target policy: publickey=$(ssh_policy_enabled_disabled_label "${target_pubkey_auth}"), password=$(ssh_policy_enabled_disabled_label "${target_password_auth}"), keyboard-interactive=$(ssh_policy_enabled_disabled_label "${target_kbd_auth}")"
  log info "SSH current policy: publickey=$(ssh_policy_enabled_disabled_label "${pubkey_auth}"), password=$(ssh_policy_enabled_disabled_label "${password_auth}"), keyboard-interactive=$(ssh_policy_enabled_disabled_label "${kbd_auth}")"
  log info "SSH public key login readiness for ${ADMIN_USER:-<unset>}: $(ssh_readiness_label "${target_keys_ready}")"
  log info "Stage 5 readiness for ${ADMIN_USER:-<unset>}: ${step5_ready_state}"
  log info "Current effective SSH port: ${applied_port}"
  log info "Current sshd runtime port: ${runtime_port}"
  log info "Current root remote login policy: $(ssh_policy_enabled_disabled_label "${permit_root_login}")"
  if [[ "${admin_user_ready}" != "yes" ]]; then
    log info "Admin user is not ready yet, so SSH safe gate remains pending."
  fi
  log info "Last successful SSH auth for ${ADMIN_USER:-<unset>}: ${last_auth_label}"
  log info "Publickey-only test: $(ssh_force_publickey_test_command "${ADMIN_USER:-<ADMIN_USER>}" "${applied_port}")"
  log info "Password-only test: $(ssh_force_password_test_command "${ADMIN_USER:-<ADMIN_USER>}" "${applied_port}")"
  if [[ "${permit_root_login}" == "yes" ]]; then
    log info "Root remote SSH login is still enabled in this stage; 第 5 步才会做最终收口。"
  fi

  if [[ "${runtime_port}" != "${applied_port}" ]]; then
    log warn "Configured effective SSH port is ${applied_port}, but sshd -T currently reports ${runtime_port}."
  fi

  if [[ "${target_port_listening}" != "yes" ]]; then
    log warn "Local listening check did not detect SSH on port ${applied_port}. Verify sshd state before closing any existing session."
  fi

  if [[ "${requested_port}" != "${applied_port}" ]]; then
    log warn "SSH port change is pending confirmation. Requested ${requested_port}, still applying ${applied_port}."
  elif [[ "${current_port}" != "${applied_port}" ]]; then
    log warn "SSH port changed from ${current_port} to ${applied_port}."
    log warn "Manual action: test a new SSH session on port ${applied_port} before closing the current one."
  fi
}

main "$@"
