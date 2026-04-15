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

FAIL2BAN_LAST_OUTPUT=""

fail2ban_run_capture() {
  FAIL2BAN_LAST_OUTPUT=""
  if FAIL2BAN_LAST_OUTPUT="$("$@" 2>&1)"; then
    return 0
  fi
  return 1
}

fail2ban_collect_diagnostics() {
  local output=""
  local diag_output=""

  output="$(systemctl status fail2ban --no-pager -l 2>&1 || true)"
  if [[ -n "${output}" ]]; then
    diag_output+=$'--- systemctl status fail2ban --no-pager -l ---\n'
    diag_output+="${output}"
    diag_output+=$'\n'
  fi

  if command_exists journalctl; then
    output="$(journalctl -u fail2ban -n 100 --no-pager 2>&1 || true)"
    if [[ -n "${output}" ]]; then
      diag_output+=$'--- journalctl -u fail2ban -n 100 --no-pager ---\n'
      diag_output+="${output}"
      diag_output+=$'\n'
    fi
  fi

  if command_exists fail2ban-client; then
    if output="$(fail2ban-client -t 2>&1 || true)"; then
      :
    fi
    if [[ -n "${output}" ]]; then
      diag_output+=$'--- fail2ban-client -t ---\n'
      diag_output+="${output}"
      diag_output+=$'\n'
    else
      output="$(fail2ban-client -d 2>&1 || true)"
      if [[ -n "${output}" ]]; then
        diag_output+=$'--- fail2ban-client -d ---\n'
        diag_output+="${output}"
        diag_output+=$'\n'
      fi
    fi
  fi

  printf '%s' "${diag_output}"
}

fail2ban_failure_reason() {
  local context="${1:-unknown}"
  local text="${2:-}"

  if [[ "${text}" =~ Failed[[:space:]]during[[:space:]]configuration ]] || \
     [[ "${text}" =~ While[[:space:]]reading[[:space:]]from ]] || \
     [[ "${text}" =~ File[[:space:]]contains[[:space:]]parsing[[:space:]]errors ]] || \
     [[ "${text}" =~ No[[:space:]]section: ]] || \
     [[ "${text}" =~ No[[:space:]]option[[:space:]] ]] || \
     [[ "${text}" =~ bad[[:space:]]value[[:space:]]substitution ]] || \
     [[ "${text}" =~ InterpolationError ]] || \
     [[ "${text}" =~ Wrong[[:space:]]value ]] || \
     [[ "${text}" =~ syntax[[:space:]]error ]]; then
    printf '%s\n' "config syntax / jail config error"
    return 0
  fi

  if [[ "${text}" =~ Have[[:space:]]not[[:space:]]found[[:space:]]any[[:space:]]log[[:space:]]file[[:space:]]for[[:space:]]sshd[[:space:]]jail ]] || \
     [[ "${text}" =~ Invalid[[:space:]]journalmatch ]] || \
     [[ "${text}" =~ Failed[[:space:]]to[[:space:]]access[[:space:]]journal ]] || \
     [[ "${text}" =~ No[[:space:]]file\(s\)[[:space:]]found[[:space:]]for[[:space:]]glob ]]; then
    printf '%s\n' "journalmatch / log source error"
    return 0
  fi

  if [[ "${text}" =~ Unknown[[:space:]]backend ]] || \
     [[ "${text}" =~ Unable[[:space:]]to[[:space:]]find[[:space:]]a[[:space:]]corresponding[[:space:]]action ]] || \
     [[ "${text}" =~ No[[:space:]]such[[:space:]]file[[:space:]]or[[:space:]]directory.*action\.d ]] || \
     [[ "${text}" =~ Failed[[:space:]]to[[:space:]]execute[[:space:]].*(iptables|nftables) ]] || \
     [[ "${text}" =~ ERROR.*(banaction|backend|iptables|nftables) ]]; then
    printf '%s\n' "banaction / backend error"
    return 0
  fi

  if [[ "${context}" == "startup-timeout" ]] || \
     [[ "${text}" =~ Server[[:space:]]ready ]] || \
     [[ "${text}" =~ Failed[[:space:]]to[[:space:]]start[[:space:]]Fail2Ban[[:space:]]Service ]] || \
     [[ "${text}" =~ Connection[[:space:]]refused ]] || \
     [[ "${text}" =~ No[[:space:]]such[[:space:]]file[[:space:]]or[[:space:]]directory ]] || \
     [[ "${text}" =~ Could[[:space:]]not[[:space:]]find[[:space:]]server ]] || \
     [[ "${text}" =~ Is[[:space:]]the[[:space:]]server[[:space:]]running ]] || \
     [[ "${text}" =~ activating ]] || \
     [[ "${text}" =~ startup ]]; then
    printf '%s\n' "startup timeout / service not ready"
    return 0
  fi

  printf '%s\n' "unclassified fail2ban startup error"
}

fail2ban_failure_suggestion() {
  local classification="${1:-}"

  case "${classification}" in
    "config syntax / jail config error")
      printf '%s\n' "检查 /etc/fail2ban/jail.d/sshd.local 与 fail2ban-client -t 输出中的具体键名或格式错误。"
      ;;
    "journalmatch / log source error")
      printf '%s\n' "检查 ssh.service/sshd.service 的实际 unit 名称，以及 journalctl 中是否存在 sshd 记录。"
      ;;
    "banaction / backend error")
      printf '%s\n' "检查 fail2ban 的 nftables/iptables action 文件是否存在，并确认当前防火墙后端与 banaction 匹配。"
      ;;
    "startup timeout / service not ready")
      printf '%s\n' "服务在重启后未在超时内 ready；先复查 systemctl status fail2ban 与 journalctl -u fail2ban 的最近启动日志。"
      ;;
    *)
      printf '%s\n' "查看 systemctl status fail2ban、journalctl -u fail2ban 和 fail2ban-client -t 的完整输出定位问题。"
      ;;
  esac
}

fail2ban_extract_key_lines() {
  local text="${1:-}"

  printf '%s\n' "${text}" | awk '
    /Failed during configuration|Have not found any log file|No file\(s\) found for glob|Invalid journalmatch|Failed to access journal|Unknown backend|Unable to find a corresponding action|Failed to execute.*(iptables|nftables)|Failed to start|Main process exited|Connection refused|No such file or directory|Is the server running|ERROR|status=/ {
      gsub(/^[[:space:]]+/, "", $0)
      if (!seen[$0]++) {
        print
        count++
        if (count == 2) {
          exit
        }
      }
    }
  '
}

fail2ban_report_failure() {
  local context="$1"
  local failure_prefix="$2"
  local command_output="${3:-}"
  local diagnostics=""
  local classification=""
  local summary_lines=""
  local suggestion=""
  local line=""

  diagnostics="$(fail2ban_collect_diagnostics)"
  classification="$(fail2ban_failure_reason "${context}" "${command_output}"$'\n'"${diagnostics}")"
  summary_lines="$(fail2ban_extract_key_lines "${command_output}"$'\n'"${diagnostics}")"
  suggestion="$(fail2ban_failure_suggestion "${classification}")"

  log warn "fail2ban failure classification: ${classification}"
  if [[ -n "${summary_lines}" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      log warn "diagnostic summary: $(fail2ban_single_line "${line}")"
    done <<< "${summary_lines}"
  fi
  log warn "next step: ${suggestion}"

  die "${failure_prefix}。classification=${classification}；backend=${FAIL2BAN_BACKEND:-<unset>}；journalmatch=${FAIL2BAN_SSHD_JOURNALMATCH:-<unset>}；banaction=${FAIL2BAN_BANACTION:-<unset>}。"
}

fail2ban_run_checked_command() {
  local description="$1"
  local failure_prefix="$2"
  shift 2

  log info "${description}"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] $(printf '%q ' "$@")"
    return 0
  fi

  if fail2ban_run_capture "$@"; then
    [[ -n "${FAIL2BAN_LAST_OUTPUT}" ]] && log info "$(fail2ban_single_line "${FAIL2BAN_LAST_OUTPUT}")"
    return 0
  fi

  fail2ban_report_failure "command" "${failure_prefix}" "${FAIL2BAN_LAST_OUTPUT}"
}

fail2ban_wait_for_ready() {
  local timeout_seconds="${1:-15}"
  local attempt=1

  log info "Waiting for fail2ban ready (timeout=${timeout_seconds}s)"

  while (( attempt <= timeout_seconds )); do
    if fail2ban_run_capture fail2ban-client ping; then
      [[ -n "${FAIL2BAN_LAST_OUTPUT}" ]] && log info "fail2ban ping: $(fail2ban_single_line "${FAIL2BAN_LAST_OUTPUT}")"
      return 0
    fi

    log info "fail2ban not ready yet (${attempt}/${timeout_seconds})"
    if (( attempt < timeout_seconds )); then
      sleep 1
    fi
    attempt=$((attempt + 1))
  done

  fail2ban_report_failure "startup-timeout" "fail2ban-client ping failed after waiting for readiness" "${FAIL2BAN_LAST_OUTPUT}"
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

  log info "fail2ban service status: ${service_state}"
  log info "sshd jail loaded = yes"
  log info "backend: ${backend}"
  log info "journalmatch: ${journalmatch}"
  log info "banaction: ${banaction}"
  log info "monitored port: ${port}"
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

  FAIL2BAN_BACKEND="${backend}"
  FAIL2BAN_SSHD_JOURNALMATCH="${journalmatch}"
  FAIL2BAN_BANACTION="${banaction}"
  export FAIL2BAN_BACKEND FAIL2BAN_SSHD_JOURNALMATCH FAIL2BAN_BANACTION

  jail_file="/etc/fail2ban/jail.d/sshd.local"
  content="$(fail2ban_render_sshd_local "${backend}" "${journalmatch}" "${banaction}" "${port}" "${maxretry}" "${findtime}" "${bantime}")"

  apply_managed_file "${jail_file}" "0644" "${content}" "true"
  run_cmd "Enabling service fail2ban" systemctl enable fail2ban

  if command_exists fail2ban-client && is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    fail2ban_run_checked_command "Checking fail2ban config" "fail2ban-client -d failed" fail2ban-client -d
    fail2ban_run_checked_command "Restarting fail2ban service" "systemctl restart fail2ban failed" systemctl restart fail2ban
    fail2ban_wait_for_ready 15
    fail2ban_run_checked_command "Checking fail2ban global status" "fail2ban-client status failed" fail2ban-client status
    fail2ban_run_checked_command "Checking fail2ban sshd jail status" "fail2ban-client status sshd failed" fail2ban-client status sshd
    fail2ban_log_summary "${backend}" "${journalmatch}" "${banaction}" "${port}" "${maxretry}" "${findtime}" "${bantime}"
  else
    if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
      log info "backend: ${backend}"
      log info "journalmatch: ${journalmatch}"
      log info "banaction: ${banaction}"
      log info "monitored port: ${port}"
      log info "maxretry: ${maxretry}"
      log info "findtime: ${findtime}"
      log info "bantime: ${bantime}"
    fi
  fi

  set_state "FAIL2BAN_ENABLED" "yes"
}

main "$@"
