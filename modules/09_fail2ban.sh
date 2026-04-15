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

fail2ban_jail_backend() {
  printf '%s\n' "systemd"
}

fail2ban_jail_maxretry() {
  printf '%s\n' "5"
}

fail2ban_jail_findtime() {
  printf '%s\n' "10m"
}

fail2ban_jail_bantime() {
  printf '%s\n' "1h"
}

fail2ban_effective_ssh_port() {
  local port=""

  port="$(current_ssh_port 2>/dev/null || true)"
  if [[ -n "${port}" ]]; then
    printf '%s\n' "${port}"
    return 0
  fi

  printf '%s\n' "${SSH_PORT:-22}"
}

fail2ban_detect_sshd_unit() {
  local candidate=""

  for candidate in "$(ssh_service_name).service" "ssh.service" "sshd.service"; do
    [[ -n "${candidate}" ]] || continue
    if service_exists "${candidate%.service}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    if systemctl cat "${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

fail2ban_detect_sshd_journalmatch() {
  local unit=""

  unit="$(fail2ban_detect_sshd_unit || true)"
  if [[ -n "${unit}" ]]; then
    printf '%s\n' "_SYSTEMD_UNIT=${unit} + _COMM=sshd"
    return 0
  fi

  printf '%s\n' "_COMM=sshd"
}

fail2ban_nftables_in_use() {
  package_installed nftables || return 1
  [[ -f "$(nftables_config_path)" ]] || return 1

  if command_exists nft && nft list ruleset >/dev/null 2>&1; then
    return 0
  fi

  if service_exists "nftables" && ( service_active "nftables" || service_enabled "nftables" ); then
    return 0
  fi

  return 1
}

fail2ban_action_exists() {
  local action_name="${1:-}"
  local action_dir=""

  [[ -n "${action_name}" ]] || return 1

  for action_dir in \
    /etc/fail2ban/action.d \
    /usr/share/fail2ban/action.d \
    /usr/lib/fail2ban/action.d \
    /usr/local/etc/fail2ban/action.d; do
    [[ -f "${action_dir}/${action_name}.conf" ]] && return 0
  done

  return 1
}

fail2ban_detect_banaction() {
  if fail2ban_nftables_in_use; then
    if fail2ban_action_exists "nftables-multiport"; then
      printf '%s\n' "nftables-multiport"
      return 0
    fi

    if fail2ban_action_exists "nftables"; then
      printf '%s\n' "nftables[type=multiport]"
      return 0
    fi

    die "nftables 已启用，但当前系统没有可用的 fail2ban nftables action。"
  fi

  printf '%s\n' "iptables-multiport"
}

fail2ban_render_sshd_local() {
  local backend="$1"
  local journalmatch="$2"
  local banaction="$3"
  local port="$4"
  local maxretry="$5"
  local findtime="$6"
  local bantime="$7"

  cat <<EOF
[sshd]
enabled = true
backend = ${backend}
journalmatch = ${journalmatch}
banaction = ${banaction}
port = ${port}
maxretry = ${maxretry}
findtime = ${findtime}
bantime = ${bantime}
EOF
}

fail2ban_single_line() {
  local value="${1:-}"

  printf '%s' "${value}" | tr '\n' ';' | sed -E 's/[[:space:]]*;[[:space:]]*/; /g; s/[[:space:]]+/ /g; s/; $//'
}

fail2ban_collect_diagnostics() {
  local output=""

  if command_exists journalctl; then
    output="$(journalctl -u fail2ban -n 50 --no-pager 2>&1 || true)"
    [[ -n "${output}" ]] && printf '%s\n' "${output}"
  fi

  output="$(systemctl status --no-pager fail2ban 2>&1 || true)"
  [[ -n "${output}" ]] && printf '%s\n' "${output}"
}

fail2ban_failure_reason() {
  local text="${1:-}"

  if [[ "${text}" =~ Have[[:space:]]not[[:space:]]found[[:space:]]any[[:space:]]log[[:space:]]file[[:space:]]for[[:space:]]sshd[[:space:]]jail ]] || \
     [[ "${text}" =~ journalmatch ]] || \
     [[ "${text}" =~ No[[:space:]]file\(s\)[[:space:]]found[[:space:]]for[[:space:]]glob ]]; then
    printf '%s\n' "日志来源问题"
    return 0
  fi

  if [[ "${text}" =~ banaction ]] || \
     [[ "${text}" =~ iptables ]] || \
     [[ "${text}" =~ nftables ]] || \
     [[ "${text}" =~ backend ]] || \
     [[ "${text}" =~ Definition ]] || \
     [[ "${text}" =~ actionban ]] || \
     [[ "${text}" =~ actionstart ]]; then
    printf '%s\n' "banaction/backend 问题"
    return 0
  fi

  printf '%s\n' "无法自动判定的 fail2ban 配置问题"
}

fail2ban_require_success() {
  local description="$1"
  local failure_prefix="$2"
  shift 2

  local output=""
  local combined=""
  local reason=""

  log info "${description}"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] $(printf '%q ' "$@")"
    return 0
  fi

  if output="$("$@" 2>&1)"; then
    [[ -n "${output}" ]] && log info "$(fail2ban_single_line "${output}")"
    return 0
  fi

  combined="${output}"
  combined+=$'\n'
  combined+="$(fail2ban_collect_diagnostics)"
  reason="$(fail2ban_failure_reason "${combined}")"
  die "${failure_prefix}（${reason}）。backend=$(fail2ban_jail_backend)；journalmatch=${FAIL2BAN_SSHD_JOURNALMATCH:-<unset>}；banaction=${FAIL2BAN_BANACTION:-<unset>}。"
}

fail2ban_log_summary() {
  local backend="$1"
  local journalmatch="$2"
  local banaction="$3"
  local port="$4"
  local maxretry="$5"
  local findtime="$6"
  local bantime="$7"
  local service_state=""

  service_state="$(systemctl is-active fail2ban 2>/dev/null || true)"
  [[ -n "${service_state}" ]] || service_state="unknown"

  log info "fail2ban 服务状态: ${service_state}"
  log info "sshd jail 加载成功: yes"
  log info "backend: ${backend}"
  log info "journalmatch: ${journalmatch}"
  log info "banaction: ${banaction}"
  log info "监控端口: ${port}"
  log info "maxretry: ${maxretry}"
  log info "findtime: ${findtime}"
  log info "bantime: ${bantime}"
}

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
  local backend=""
  local journalmatch=""
  local banaction=""
  local port=""
  local maxretry=""
  local findtime=""
  local bantime=""

  backend="$(fail2ban_jail_backend)"
  journalmatch="$(fail2ban_detect_sshd_journalmatch)"
  banaction="$(fail2ban_detect_banaction)"
  port="$(fail2ban_effective_ssh_port)"
  maxretry="$(fail2ban_jail_maxretry)"
  findtime="$(fail2ban_jail_findtime)"
  bantime="$(fail2ban_jail_bantime)"

  FAIL2BAN_SSHD_JOURNALMATCH="${journalmatch}"
  FAIL2BAN_BANACTION="${banaction}"
  export FAIL2BAN_SSHD_JOURNALMATCH FAIL2BAN_BANACTION

  jail_file="/etc/fail2ban/jail.d/sshd.local"
  content="$(fail2ban_render_sshd_local "${backend}" "${journalmatch}" "${banaction}" "${port}" "${maxretry}" "${findtime}" "${bantime}")"

  apply_managed_file "${jail_file}" "0644" "${content}" "true"
  run_cmd "Enabling service fail2ban" systemctl enable fail2ban

  if command_exists fail2ban-client && is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    fail2ban_require_success "Checking fail2ban config" "fail2ban-client -d failed" fail2ban-client -d
    fail2ban_require_success "Restarting fail2ban service" "systemctl restart fail2ban failed" systemctl restart fail2ban
    fail2ban_require_success "Checking fail2ban ping" "fail2ban-client ping failed" fail2ban-client ping
    fail2ban_require_success "Checking fail2ban global status" "fail2ban-client status failed" fail2ban-client status
    fail2ban_require_success "Checking fail2ban sshd jail status" "fail2ban-client status sshd failed" fail2ban-client status sshd
    fail2ban_log_summary "${backend}" "${journalmatch}" "${banaction}" "${port}" "${maxretry}" "${findtime}" "${bantime}"
  else
    if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
      log info "backend: ${backend}"
      log info "journalmatch: ${journalmatch}"
      log info "banaction: ${banaction}"
      log info "监控端口: ${port}"
      log info "maxretry: ${maxretry}"
      log info "findtime: ${findtime}"
      log info "bantime: ${bantime}"
    fi
  fi

  set_state "FAIL2BAN_ENABLED" "yes"
}

main "$@"
