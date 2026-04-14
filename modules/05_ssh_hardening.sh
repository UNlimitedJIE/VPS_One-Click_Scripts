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

  local password_auth="yes"
  local kbd_auth="yes"
  if is_true "${DISABLE_PASSWORD_LOGIN}"; then
    if can_disable_password_login "${ADMIN_USER}"; then
      password_auth="no"
      kbd_auth="no"
      log info "Safe gate passed. Password-based SSH login will be disabled."
    else
      log warn "Safe gate not passed. Password login will remain enabled."
      log warn "Required: admin user exists and at least one valid authorized_keys entry is present."
    fi
  fi

  local permit_root_login="yes"

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
PubkeyAuthentication yes
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

  set_state "SSH_PORT_REQUESTED" "${requested_port}"
  set_state "SSH_PORT_EFFECTIVE" "${applied_port}"
  set_state "SSH_PORT_CHANGE_CONFIRMED" "${CONFIRM_SSH_PORT_CHANGE}"
  set_state "SSH_PASSWORD_LOGIN" "${password_auth}"
  set_state "ROOT_SSH_MODE" "${permit_root_login}"
  log info "Root 远程 SSH 登录在本阶段仍保持可用；请先验证管理用户可登录，第 7 步才会正式关闭 root 远程登录。"

  if [[ "${requested_port}" != "${applied_port}" ]]; then
    log warn "SSH port change is pending confirmation. Requested ${requested_port}, still applying ${applied_port}."
  elif [[ "${current_port}" != "${applied_port}" ]]; then
    log warn "SSH port changed from ${current_port} to ${applied_port}."
    log warn "Manual action: test a new SSH session on port ${applied_port} before closing the current one."
  fi
}

main "$@"
