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

_FAIL2BAN_SELECTED_BACKEND="${_FAIL2BAN_SELECTED_BACKEND:-}"
_FAIL2BAN_SELECTED_JOURNALMATCH="${_FAIL2BAN_SELECTED_JOURNALMATCH:-}"
_FAIL2BAN_SELECTED_LOGPATH="${_FAIL2BAN_SELECTED_LOGPATH:-}"
_FAIL2BAN_SYSTEMD_BACKEND_LAST_ERROR="${_FAIL2BAN_SYSTEMD_BACKEND_LAST_ERROR:-}"

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

fail2ban_auth_log_path() {
  local candidate=""

  for candidate in /var/log/auth.log /var/log/secure; do
    [[ -f "${candidate}" ]] || continue
    printf '%s\n' "${candidate}"
    return 0
  done

  return 1
}

fail2ban_python_systemd_module_available() {
  command_exists python3 || return 1
  python3 - <<'PY' >/dev/null 2>&1
import systemd
PY
}

fail2ban_report_dependency_failure() {
  local evidence="${1:-python3-systemd 不可用}"
  local report=""

  report="$(readonly_status_block \
    "Fail2Ban" \
    "service=failed; sshd_jail_loaded=no; backend=systemd" \
    "${evidence}" \
    "no")"
  log info "${report}"

  die "${evidence}"
}

fail2ban_ensure_systemd_backend_available() {
  _FAIL2BAN_SYSTEMD_BACKEND_LAST_ERROR=""

  if fail2ban_python_systemd_module_available; then
    return 0
  fi

  log info "python3-systemd 不可用，尝试安装以启用 fail2ban systemd backend"
  if ! apt_install_packages python3-systemd; then
    _FAIL2BAN_SYSTEMD_BACKEND_LAST_ERROR="python3-systemd 安装失败，无法启用 fail2ban systemd backend"
    log warn "python3-systemd 安装失败，无法启用 fail2ban systemd backend"
    return 1
  fi

  log info "python3-systemd 安装成功，重新检测 systemd backend 可用性"
  if fail2ban_python_systemd_module_available; then
    log info "systemd backend 依赖已满足，继续执行 Fail2Ban 后续配置"
    return 0
  fi

  _FAIL2BAN_SYSTEMD_BACKEND_LAST_ERROR="python3-systemd 安装后再次检测仍不可用，无法继续配置 fail2ban systemd backend"
  log warn "python3-systemd 安装后再次检测仍不可用，无法继续使用 fail2ban systemd backend"
  return 1
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

fail2ban_select_backend() {
  local journalmatch=""
  local logpath=""

  _FAIL2BAN_SELECTED_BACKEND=""
  _FAIL2BAN_SELECTED_JOURNALMATCH=""
  _FAIL2BAN_SELECTED_LOGPATH=""

  journalmatch="$(fail2ban_detect_sshd_journalmatch)"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    _FAIL2BAN_SELECTED_BACKEND="systemd"
    _FAIL2BAN_SELECTED_JOURNALMATCH="${journalmatch}"
    return 0
  fi

  if fail2ban_python_systemd_module_available; then
    _FAIL2BAN_SELECTED_BACKEND="systemd"
    _FAIL2BAN_SELECTED_JOURNALMATCH="${journalmatch}"
    return 0
  fi

  if fail2ban_ensure_systemd_backend_available; then
    _FAIL2BAN_SELECTED_BACKEND="systemd"
    _FAIL2BAN_SELECTED_JOURNALMATCH="${journalmatch}"
    return 0
  fi

  log warn "${_FAIL2BAN_SYSTEMD_BACKEND_LAST_ERROR:-fail2ban systemd backend 不可用}，尝试回退到 SSH 日志文件 backend"
  logpath="$(fail2ban_auth_log_path || true)"
  if [[ -n "${logpath}" ]]; then
    log info "已回退到 SSH 日志文件 backend，继续执行 Fail2Ban 后续配置"
    _FAIL2BAN_SELECTED_BACKEND="auto"
    _FAIL2BAN_SELECTED_LOGPATH="${logpath}"
    return 0
  fi

  fail2ban_report_dependency_failure "${_FAIL2BAN_SYSTEMD_BACKEND_LAST_ERROR:-python3-systemd 不可用}，且当前未找到可回退的 SSH 日志文件"
}

fail2ban_render_sshd_local() {
  local backend="$1"
  local journalmatch="$2"
  local logpath="$3"
  local banaction="$4"
  local port="$5"
  local maxretry="$6"
  local findtime="$7"
  local bantime="$8"

  cat <<EOF
[sshd]
enabled = true
backend = ${backend}
banaction = ${banaction}
port = ${port}
maxretry = ${maxretry}
findtime = ${findtime}
bantime = ${bantime}
EOF
  if [[ -n "${journalmatch}" ]]; then
    printf 'journalmatch = %s\n' "${journalmatch}"
  fi
  if [[ -n "${logpath}" ]]; then
    printf 'logpath = %s\n' "${logpath}"
  fi

  return 0
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

  if [[ "${context}" == "startup-timeout" ]] || \
     [[ "${text}" =~ fail2ban\.sock ]] || \
     [[ "${text}" =~ Failed[[:space:]]to[[:space:]]access[[:space:]]socket[[:space:]]path ]] || \
     [[ "${text}" =~ Connection[[:space:]]refused ]] || \
     [[ "${text}" =~ No[[:space:]]such[[:space:]]file[[:space:]]or[[:space:]]directory ]] || \
     [[ "${text}" =~ Could[[:space:]]not[[:space:]]find[[:space:]]server ]] || \
     [[ "${text}" =~ Is[[:space:]]the[[:space:]]server[[:space:]]running ]] || \
     [[ "${text}" =~ activating ]] || \
     [[ "${text}" =~ startup ]]; then
    printf '%s\n' "startup timeout / service not ready"
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
     [[ "${text}" =~ Backend[[:space:]]\'systemd\'[[:space:]]failed[[:space:]]to[[:space:]]initialize ]] || \
     [[ "${text}" =~ No[[:space:]]module[[:space:]]named[[:space:]]\'systemd\' ]] || \
     [[ "${text}" =~ Unable[[:space:]]to[[:space:]]find[[:space:]]a[[:space:]]corresponding[[:space:]]action ]] || \
     [[ "${text}" =~ No[[:space:]]such[[:space:]]file[[:space:]]or[[:space:]]directory.*action\.d ]] || \
     [[ "${text}" =~ Failed[[:space:]]to[[:space:]]execute[[:space:]].*(iptables|nftables) ]] || \
     [[ "${text}" =~ ERROR.*(banaction|backend|iptables|nftables) ]]; then
    printf '%s\n' "banaction / backend error"
    return 0
  fi

  if [[ "${text}" =~ Server[[:space:]]ready ]] || \
     [[ "${text}" =~ Failed[[:space:]]to[[:space:]]start[[:space:]]Fail2Ban[[:space:]]Service ]]; then
    printf '%s\n' "startup timeout / service not ready"
    return 0
  fi

  printf '%s\n' "unclassified fail2ban startup error"
}

fail2ban_failure_suggestion() {
  local classification="${1:-}"

  case "${classification}" in
    "config syntax / jail config error")
      printf '%s\n' "检查 /etc/fail2ban/jail.d/sshd.local 与 fail2ban-client -t 输出。"
      ;;
    "journalmatch / log source error")
      printf '%s\n' "检查 ssh 日志来源与 journalmatch/logpath。"
      ;;
    "banaction / backend error")
      printf '%s\n' "检查 backend 依赖与 banaction。"
      ;;
    "startup timeout / service not ready")
      printf '%s\n' "服务重启后未在超时内 ready。"
      ;;
    *)
      printf '%s\n' "查看 fail2ban 近期启动摘要。"
      ;;
  esac
}

fail2ban_extract_key_lines() {
  local text="${1:-}"

  printf '%s\n' "${text}" | awk '
    /Failed during configuration|Have not found any log file|No file\(s\) found for glob|Invalid journalmatch|Failed to access journal|Unknown backend|Backend .systemd. failed to initialize|No module named .systemd.|Unable to find a corresponding action|Failed to execute.*(iptables|nftables)|Failed to start|Main process exited|Connection refused|No such file or directory|fail2ban\.sock|Failed to access socket path|Is the server running|ERROR|status=/ {
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
  local line=""
  local compact_summary=""
  local report=""

  diagnostics="$(fail2ban_collect_diagnostics)"
  classification="$(fail2ban_failure_reason "${context}" "${command_output}"$'\n'"${diagnostics}")"
  summary_lines="$(fail2ban_extract_key_lines "${command_output}"$'\n'"${diagnostics}")"
  compact_summary="$(printf '%s\n' "${summary_lines}" | tr '\n' ';' | sed 's/;$/ /; s/;;*/;/g')"

  report="$(readonly_status_block \
    "Fail2Ban" \
    "service=failed; sshd_jail_loaded=no; backend=${FAIL2BAN_BACKEND:-<unset>}" \
    "classification=${classification}; source=${FAIL2BAN_SOURCE_LABEL:-<unset>}; summary=$(fail2ban_single_line "${compact_summary:-no key summary}")" \
    "no")"
  log info "${report}"

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
  local logpath="$3"
  local banaction="$4"
  local port="$5"
  local maxretry="$6"
  local findtime="$7"
  local bantime="$8"
  local service_state=""
  local source_label=""
  local report=""

  service_state="$(systemctl is-active fail2ban 2>/dev/null || true)"
  [[ -n "${service_state}" ]] || service_state="unknown"

  if [[ -n "${journalmatch}" ]]; then
    source_label="journalmatch=${journalmatch}"
  else
    source_label="logpath=${logpath}"
  fi

  report="$(readonly_status_block \
    "Fail2Ban" \
    "service=${service_state}; sshd_jail_loaded=yes; backend=${backend}; banaction=${banaction}; port=${port}" \
    "${source_label}; maxretry=${maxretry}; findtime=${findtime}; bantime=${bantime}" \
    "yes")"
  log info "${report}"
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
  local logpath=""
  local banaction=""
  local port=""
  local maxretry=""
  local findtime=""
  local bantime=""

  fail2ban_select_backend
  backend="${_FAIL2BAN_SELECTED_BACKEND}"
  journalmatch="${_FAIL2BAN_SELECTED_JOURNALMATCH}"
  logpath="${_FAIL2BAN_SELECTED_LOGPATH}"
  banaction="$(fail2ban_detect_banaction)"
  port="$(fail2ban_effective_ssh_port)"
  maxretry="$(fail2ban_jail_maxretry)"
  findtime="$(fail2ban_jail_findtime)"
  bantime="$(fail2ban_jail_bantime)"

  FAIL2BAN_BACKEND="${backend}"
  FAIL2BAN_SSHD_JOURNALMATCH="${journalmatch}"
  FAIL2BAN_LOGPATH="${logpath}"
  FAIL2BAN_SOURCE_LABEL="${journalmatch:-${logpath}}"
  FAIL2BAN_BANACTION="${banaction}"
  export FAIL2BAN_BACKEND FAIL2BAN_SSHD_JOURNALMATCH FAIL2BAN_LOGPATH FAIL2BAN_SOURCE_LABEL FAIL2BAN_BANACTION

  jail_file="/etc/fail2ban/jail.d/sshd.local"
  content="$(fail2ban_render_sshd_local "${backend}" "${journalmatch}" "${logpath}" "${banaction}" "${port}" "${maxretry}" "${findtime}" "${bantime}")"

  apply_managed_file "${jail_file}" "0644" "${content}" "true"
  run_cmd "Enabling service fail2ban" systemctl enable fail2ban

  if command_exists fail2ban-client && is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    fail2ban_run_checked_command "Checking fail2ban config" "fail2ban-client -t failed" fail2ban-client -t
    fail2ban_run_checked_command "Restarting fail2ban service" "systemctl restart fail2ban failed" systemctl restart fail2ban
    fail2ban_wait_for_ready 15
    fail2ban_run_checked_command "Checking fail2ban ping" "fail2ban-client ping failed" fail2ban-client ping
    fail2ban_run_checked_command "Checking fail2ban global status" "fail2ban-client status failed" fail2ban-client status
    fail2ban_run_checked_command "Checking fail2ban sshd jail status" "fail2ban-client status sshd failed" fail2ban-client status sshd
    fail2ban_log_summary "${backend}" "${journalmatch}" "${logpath}" "${banaction}" "${port}" "${maxretry}" "${findtime}" "${bantime}"
  else
    if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
      fail2ban_log_summary "${backend}" "${journalmatch}" "${logpath}" "${banaction}" "${port}" "${maxretry}" "${findtime}" "${bantime}"
    fi
  fi

  set_state "FAIL2BAN_ENABLED" "yes"
}

main "$@"
