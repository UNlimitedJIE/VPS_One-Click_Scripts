#!/usr/bin/env bash
set -euo pipefail

# Module: 09_fail2ban
# Purpose: 安装并启用 Fail2Ban，对 SSH 做基础防护。
# Preconditions: root；Debian 12。
# Steps:
#   1. 安装 fail2ban
#   2. 生成 sshd jail 配置
#   3. 启用并重启 fail2ban
# Idempotency:
#   - 使用 jail.d drop-in
#   - 重复执行只收敛到受控配置

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "09_fail2ban" "配置 Fail2Ban"
  require_root
  require_debian12

  if is_false "${INSTALL_FAIL2BAN}"; then
    log info "INSTALL_FAIL2BAN=false, skip."
    set_state "FAIL2BAN_ENABLED" "no"
    return 0
  fi

  apt_install_packages fail2ban

  local jail_file content
  jail_file="/etc/fail2ban/jail.d/sshd.local"
  content="$(cat <<EOF
[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
)"

  apply_managed_file "${jail_file}" "0644" "${content}" "true"
  enable_and_start_service "fail2ban"
  restart_service_if_exists "fail2ban"

  if command_exists fail2ban-client && is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    fail2ban-client ping >/dev/null 2>&1 || die "fail2ban-client ping failed."
  fi

  set_state "FAIL2BAN_ENABLED" "yes"
}

main "$@"
