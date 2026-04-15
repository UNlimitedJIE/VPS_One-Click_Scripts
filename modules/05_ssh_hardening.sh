#!/usr/bin/env bash
set -euo pipefail

# Module: 05_ssh_hardening
# Purpose: 使用受控主配置块做 SSH 公钥接入准备，并按 safe gate 决定是否关闭密码登录。
# Preconditions: root；Debian 12；openssh-server 可用。

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

  local desired_password_auth="no"
  local desired_pubkey_auth="yes"
  local desired_kbd_auth="no"
  local applied_password_auth="yes"
  local applied_pubkey_auth="yes"
  local applied_kbd_auth="no"
  local current_password_auth="unknown"
  local current_pubkey_auth="unknown"
  local current_kbd_auth="unknown"
  local current_root_auth="unknown"
  local safe_gate_passed="no"
  local safe_gate_reason="waiting-for-authorized-keys"
  local target_keys_ready="no"
  local runtime_port=""
  local target_port_listening="no"
  local last_auth_method=""
  local last_auth_label=""
  local cutover_state=""
  local permit_root_login="yes"
  local current_port=""
  local requested_port=""
  local applied_port=""
  local step5_ready_state="no"
  local port_source=""
  local pubkey_source=""
  local password_source=""
  local kbd_source=""
  local root_source=""

  if [[ -n "${ADMIN_USER:-}" ]] && id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    target_keys_ready="$(ssh_publickey_login_ready_label_for_user "${ADMIN_USER}")"
    safe_gate_passed="$(ssh_safe_gate_state_for_user "${ADMIN_USER}")"
  fi

  if [[ "${safe_gate_passed}" == "yes" ]]; then
    safe_gate_reason="authorized-keys-ready"
  else
    target_keys_ready="not ready"
  fi

  if is_false "${DISABLE_PASSWORD_LOGIN}"; then
    desired_password_auth="yes"
    desired_kbd_auth="no"
  fi

  cutover_state="$(get_state "ADMIN_LOGIN_CUTOVER" || true)"
  if [[ "${cutover_state}" == "yes" || "$(current_permit_root_login_mode)" == "no" ]]; then
    permit_root_login="no"
  fi

  current_port="$(current_ssh_port)"
  requested_port="${SSH_PORT}"
  applied_port="$(effective_ssh_port_for_changes)"

  if ssh_port_change_pending_confirmation; then
    warn_ssh_port_change_not_confirmed
  fi

  if [[ "${safe_gate_passed}" == "yes" && "${desired_password_auth}" == "no" ]]; then
    applied_password_auth="no"
  fi

  log info "本阶段将写入 SSH 策略：pubkey=${applied_pubkey_auth} password=${applied_password_auth} kbd=${applied_kbd_auth} root=${permit_root_login} port=${applied_port}"
  sshd_apply_managed_settings "${applied_port}" "${applied_pubkey_auth}" "${applied_password_auth}" "${applied_kbd_auth}" "${permit_root_login}"

  if [[ "${safe_gate_passed}" != "yes" ]]; then
    log info "safe gate 未通过：当前保持过渡策略 pubkey=yes password=yes kbd=no"
  elif [[ "${applied_password_auth}" == "no" ]]; then
    log info "safe gate 已通过：当前收紧为 pubkey=yes password=no kbd=no"
  fi

  validate_sshd_config
  reload_service_if_exists "$(ssh_service_name)"

  runtime_port="$(current_ssh_port)"
  current_password_auth="$(current_password_authentication_mode || true)"
  current_pubkey_auth="$(current_pubkey_authentication_mode || true)"
  current_kbd_auth="$(current_kbdinteractive_authentication_mode || true)"
  current_root_auth="$(current_permit_root_login_mode || true)"
  port_source="$(sshd_last_directive_source_line "Port" || true)"
  pubkey_source="$(sshd_last_directive_source_line "PubkeyAuthentication" || true)"
  password_source="$(sshd_last_directive_source_line "PasswordAuthentication" || true)"
  kbd_source="$(sshd_last_directive_source_line "KbdInteractiveAuthentication" || true)"
  root_source="$(sshd_last_directive_source_line "PermitRootLogin" || true)"
  if ssh_port_is_listening_locally "${applied_port}"; then
    target_port_listening="yes"
  fi

  set_state "SSH_SAFE_GATE_PASSED" "${safe_gate_passed}"
  set_state "SSH_SAFE_GATE_REASON" "${safe_gate_reason}"
  set_state "SSH_PORT_REQUESTED" "${requested_port}"
  set_state "SSH_PORT_EFFECTIVE" "${applied_port}"
  set_state "SSH_PORT_RUNTIME_EFFECTIVE" "${runtime_port}"
  set_state "SSH_TARGET_PORT_LISTENING" "${target_port_listening}"
  set_state "SSH_PORT_CHANGE_CONFIRMED" "${CONFIRM_SSH_PORT_CHANGE}"
  set_state "SSH_AUTH_TARGET_PASSWORD" "${desired_password_auth}"
  set_state "SSH_AUTH_TARGET_PUBKEY" "${desired_pubkey_auth}"
  set_state "SSH_AUTH_TARGET_KBD" "${desired_kbd_auth}"
  set_state "SSH_AUTH_APPLIED_PASSWORD" "${applied_password_auth}"
  set_state "SSH_AUTH_APPLIED_PUBKEY" "${applied_pubkey_auth}"
  set_state "SSH_AUTH_APPLIED_KBD" "${applied_kbd_auth}"
  set_state "SSH_AUTH_CURRENT_PASSWORD" "${current_password_auth}"
  set_state "SSH_AUTH_CURRENT_PUBKEY" "${current_pubkey_auth}"
  set_state "SSH_AUTH_CURRENT_KBD" "${current_kbd_auth}"
  set_state "SSH_PUBLICKEY_READY" "${target_keys_ready}"
  set_state "SSH_PASSWORD_LOGIN" "${current_password_auth}"
  set_state "ROOT_SSH_MODE" "${current_root_auth}"

  last_auth_method="$(last_successful_ssh_auth_method_for_user "${ADMIN_USER}")"
  last_auth_label="$(ssh_last_successful_auth_method_label "${last_auth_method}")"
  set_state "SSH_LAST_SUCCESSFUL_AUTH_METHOD" "${last_auth_method}"

  step5_ready_state="$(ssh_stage5_ready_state_for_user "${ADMIN_USER}")"
  set_state "SSH_STAGE5_READY" "${step5_ready_state}"

  log info "SSH desired target policy: publickey=$(ssh_policy_enabled_disabled_label "${desired_pubkey_auth}"), password=$(ssh_policy_enabled_disabled_label "${desired_password_auth}"), keyboard-interactive=$(ssh_policy_enabled_disabled_label "${desired_kbd_auth}")"
  log info "SSH applied policy for this stage: publickey=$(ssh_policy_enabled_disabled_label "${applied_pubkey_auth}"), password=$(ssh_policy_enabled_disabled_label "${applied_password_auth}"), keyboard-interactive=$(ssh_policy_enabled_disabled_label "${applied_kbd_auth}")"
  log info "SSH actual policy after reload: pubkey=$(ssh_policy_enabled_disabled_label "${current_pubkey_auth}"), password=$(ssh_policy_enabled_disabled_label "${current_password_auth}"), keyboard-interactive=$(ssh_policy_enabled_disabled_label "${current_kbd_auth}")"
  log info "sshd -T actual values: pubkeyauthentication=${current_pubkey_auth}, passwordauthentication=${current_password_auth}, kbdinteractiveauthentication=${current_kbd_auth}, permitrootlogin=${current_root_auth}, port=${runtime_port}"
  log info "SSH actual permitrootlogin after reload: $(ssh_policy_enabled_disabled_label "${current_root_auth}")"
  log info "SSH safe gate: ${safe_gate_passed} (${safe_gate_reason})"
  log info "Target user authorized_keys readiness: ${target_keys_ready}"
  log info "Current effective SSH port: ${applied_port}"
  log info "Current sshd runtime port: ${runtime_port}"
  log info "Stage 5 readiness for ${ADMIN_USER:-<unset>}: ${step5_ready_state}"
  log info "Last successful SSH auth for ${ADMIN_USER:-<unset>}: ${last_auth_label}"
  log info "Publickey-only test: $(ssh_force_publickey_test_command "${ADMIN_USER:-<ADMIN_USER>}" "${applied_port}")"

  if [[ "${runtime_port}" != "${applied_port}" ]]; then
    die "SSH 实际端口与本阶段目标不一致：expected port=${applied_port}, actual port=${runtime_port}. Source: ${port_source:-not found}"
  fi

  if [[ "${current_pubkey_auth}" != "${applied_pubkey_auth}" ]]; then
    die "SSH 实际 pubkeyauthentication 与本阶段目标不一致：expected ${applied_pubkey_auth}, actual ${current_pubkey_auth}. Source: ${pubkey_source:-not found}"
  fi

  if [[ "${current_password_auth}" != "${applied_password_auth}" ]]; then
    die "SSH 实际 passwordauthentication 与本阶段目标不一致：expected ${applied_password_auth}, actual ${current_password_auth}. Source: ${password_source:-not found}"
  fi

  if [[ "${current_kbd_auth}" != "${applied_kbd_auth}" ]]; then
    die "SSH 实际 kbdinteractiveauthentication 与本阶段目标不一致：expected ${applied_kbd_auth}, actual ${current_kbd_auth}. Source: ${kbd_source:-not found}"
  fi

  if [[ "${current_root_auth}" != "${permit_root_login}" ]]; then
    die "SSH 实际 permitrootlogin 与本阶段目标不一致：expected ${permit_root_login}, actual ${current_root_auth}. Source: ${root_source:-not found}"
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

  if [[ "${current_root_auth}" != "no" ]]; then
    log info "Root remote SSH login is still enabled in this stage; 第 5 步才会做最终收口。"
  fi
}

main "$@"
