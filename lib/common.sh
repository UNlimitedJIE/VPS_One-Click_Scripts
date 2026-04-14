#!/usr/bin/env bash
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"

# shellcheck source=lib/log.sh
source "${COMMON_DIR}/log.sh"
# shellcheck source=lib/detect.sh
source "${COMMON_DIR}/detect.sh"
# shellcheck source=lib/validate.sh
source "${COMMON_DIR}/validate.sh"

set_default_config() {
  TIMEZONE="${TIMEZONE:-UTC}"
  SSH_PORT="${SSH_PORT:-22}"
  CONFIRM_SSH_PORT_CHANGE="${CONFIRM_SSH_PORT_CHANGE:-false}"
  ADMIN_USER="${ADMIN_USER:-ops}"
  ADMIN_USER_SHELL="${ADMIN_USER_SHELL:-/bin/bash}"
  ADMIN_USER_GROUPS="${ADMIN_USER_GROUPS:-sudo}"
  AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-}"
  DISABLE_PASSWORD_LOGIN="${DISABLE_PASSWORD_LOGIN:-true}"
  DISABLE_ROOT_SSH_PASSWORD="${DISABLE_ROOT_SSH_PASSWORD:-true}"
  INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-true}"
  INSTALL_UNATTENDED_UPGRADES="${INSTALL_UNATTENDED_UPGRADES:-true}"
  ENABLE_SWAP="${ENABLE_SWAP:-auto}"
  SWAP_SIZE="${SWAP_SIZE:-}"
  ENABLE_NODEQUALITY="${ENABLE_NODEQUALITY:-true}"
  NODEQUALITY_FORCE="${NODEQUALITY_FORCE:-false}"
  ENABLE_NFTABLES="${ENABLE_NFTABLES:-true}"
  ENABLE_TIME_SYNC="${ENABLE_TIME_SYNC:-true}"
  ENABLE_SUMMARY="${ENABLE_SUMMARY:-true}"
  PLAN_ONLY="${PLAN_ONLY:-false}"
  DRY_RUN="${DRY_RUN:-false}"
  BASE_PACKAGES="${BASE_PACKAGES:-curl ca-certificates sudo openssh-server nftables rsync unzip git jq lsof procps htop vim-tiny less}"
  SWAP_AUTO_THRESHOLD_MB="${SWAP_AUTO_THRESHOLD_MB:-4096}"
  JOURNAL_VACUUM_DAYS="${JOURNAL_VACUUM_DAYS:-14}"
  CLEANUP_APT_CACHE="${CLEANUP_APT_CACHE:-true}"
  SAFE_TUNING_PROFILE="${SAFE_TUNING_PROFILE:-none}"
  MODULE_REGISTRY_FILE="${MODULE_REGISTRY_FILE:-${PROJECT_ROOT}/config/module-registry.tsv}"
  STATE_DIR="${STATE_DIR:-${PROJECT_ROOT}/state}"
  LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs}"
  CHANGE_LOG_FILE="${CHANGE_LOG_FILE:-${STATE_DIR}/change-log.tsv}"
  SNAPSHOT_REMINDER="${SNAPSHOT_REMINDER:-初始化通过后，请先验证新 SSH 登录，再在云厂商控制台创建快照/备份。}"
}

load_config() {
  set_default_config

  local chosen_config="${CLI_CONFIG_FILE:-${CONFIG_FILE:-${PROJECT_ROOT}/config/default.conf}}"
  CONFIG_FILE="${chosen_config}"
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi

  [[ -n "${CLI_PLAN_ONLY:-}" ]] && PLAN_ONLY="${CLI_PLAN_ONLY}"
  [[ -n "${CLI_DRY_RUN:-}" ]] && DRY_RUN="${CLI_DRY_RUN}"
  [[ -n "${CLI_CONFIG_FILE:-}" ]] && CONFIG_FILE="${CLI_CONFIG_FILE}"

  MODULE_REGISTRY_FILE="${MODULE_REGISTRY_FILE:-${PROJECT_ROOT}/config/module-registry.tsv}"
  STATE_DIR="${STATE_DIR:-${PROJECT_ROOT}/state}"
  LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs}"
  CHANGE_LOG_FILE="${CHANGE_LOG_FILE:-${STATE_DIR}/change-log.tsv}"
}

export_config() {
  export PROJECT_ROOT CONFIG_FILE MODULE_REGISTRY_FILE STATE_DIR LOG_DIR CHANGE_LOG_FILE
  export TIMEZONE SSH_PORT CONFIRM_SSH_PORT_CHANGE
  export ADMIN_USER ADMIN_USER_SHELL ADMIN_USER_GROUPS AUTHORIZED_KEYS_FILE
  export DISABLE_PASSWORD_LOGIN DISABLE_ROOT_SSH_PASSWORD
  export INSTALL_FAIL2BAN INSTALL_UNATTENDED_UPGRADES ENABLE_SWAP SWAP_SIZE
  export ENABLE_NODEQUALITY NODEQUALITY_FORCE ENABLE_NFTABLES ENABLE_TIME_SYNC ENABLE_SUMMARY
  export PLAN_ONLY DRY_RUN BASE_PACKAGES SWAP_AUTO_THRESHOLD_MB JOURNAL_VACUUM_DAYS
  export CLEANUP_APT_CACHE SAFE_TUNING_PROFILE SNAPSHOT_REMINDER
}

init_runtime() {
  mkdir -p "${STATE_DIR}" "${STATE_DIR}/reports" "${STATE_DIR}/tmp" "${LOG_DIR}"

  RUN_ID="${RUN_ID:-$(date '+%Y%m%d-%H%M%S')}"
  LOG_FILE="${LOG_FILE:-${LOG_DIR}/${RUN_ID}-${RUN_MODE:-manual}.log}"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    STATE_FILE="${STATE_FILE:-${STATE_DIR}/tmp/runtime-${RUN_ID}-${RUN_MODE:-manual}.state}"
    STATE_FILE_IS_EPHEMERAL="${STATE_FILE_IS_EPHEMERAL:-true}"
  else
    STATE_FILE="${STATE_FILE:-${STATE_DIR}/runtime.state}"
    STATE_FILE_IS_EPHEMERAL="${STATE_FILE_IS_EPHEMERAL:-false}"
  fi

  export RUN_ID LOG_FILE STATE_FILE STATE_FILE_IS_EPHEMERAL
  export_config
}

cleanup_ephemeral_state() {
  if [[ "${STATE_FILE_IS_EPHEMERAL:-false}" == "true" && -n "${STATE_FILE:-}" && -f "${STATE_FILE}" ]]; then
    rm -f "${STATE_FILE}"
  fi
}

module_banner() {
  local module_id="$1"
  local description="$2"
  log info "===== ${module_id}: ${description} ====="
  if is_true "${PLAN_ONLY}"; then
    log info "Plan mode enabled. Commands will not modify the system."
  elif is_true "${DRY_RUN}"; then
    log info "Dry-run enabled. Commands will not modify the system."
  fi
}

run_cmd() {
  local description="$1"
  shift
  log info "${description}"

  if is_true "${PLAN_ONLY}"; then
    log info "[plan] $(printf '%q ' "$@")"
    return 0
  fi

  if is_true "${DRY_RUN}"; then
    log info "[dry-run] $(printf '%q ' "$@")"
    return 0
  fi

  "$@"
}

run_shell() {
  local description="$1"
  local command_string="$2"
  log info "${description}"

  if is_true "${PLAN_ONLY}"; then
    log info "[plan] ${command_string}"
    return 0
  fi

  if is_true "${DRY_RUN}"; then
    log info "[dry-run] ${command_string}"
    return 0
  fi

  bash -lc "${command_string}"
}

backup_file() {
  local target="$1"
  [[ -f "$target" ]] || return 0

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] backup file: ${target}"
    return 0
  fi

  local backup_path="${target}.bak-${RUN_ID}"
  if [[ ! -f "${backup_path}" ]]; then
    cp -a "$target" "$backup_path"
    log info "Backup created: ${backup_path}"
  fi
}

apply_managed_file() {
  local target="$1"
  local mode="$2"
  local content="$3"
  local backup_existing="${4:-false}"

  local tmp_file=""
  tmp_file="$(mktemp)"
  printf '%s\n' "$content" >"${tmp_file}"

  if [[ -f "${target}" ]] && cmp -s "${tmp_file}" "${target}"; then
    rm -f "${tmp_file}"
    log info "No change required: ${target}"
    return 0
  fi

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] write managed file: ${target}"
    rm -f "${tmp_file}"
    return 0
  fi

  if [[ -f "${target}" && "${backup_existing}" == "true" ]]; then
    backup_file "${target}"
  fi

  install -d -m 0755 "$(dirname "${target}")"
  install -m "${mode}" "${tmp_file}" "${target}"
  rm -f "${tmp_file}"
  log info "Managed file updated: ${target}"
}

ensure_directory() {
  local path="$1"
  local mode="${2:-0755}"
  local owner="${3:-root}"
  local group="${4:-root}"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] mkdir -p ${path} && chmod ${mode} ${path} && chown ${owner}:${group} ${path}"
    return 0
  fi

  install -d -m "${mode}" -o "${owner}" -g "${group}" "${path}"
}

ensure_line_in_file() {
  local file="$1"
  local line="$2"

  if [[ -f "${file}" ]] && grep -Fqx "${line}" "${file}"; then
    log info "Line already present in ${file}: ${line}"
    return 0
  fi

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] append line to ${file}: ${line}"
    return 0
  fi

  printf '%s\n' "${line}" >>"${file}"
  log info "Appended line to ${file}: ${line}"
}

set_state() {
  local key="$1"
  local value="$2"
  local tmp_file=""
  tmp_file="$(mktemp)"

  touch "${STATE_FILE}"
  grep -v "^${key}=" "${STATE_FILE}" >"${tmp_file}" || true
  printf '%s=%s\n' "${key}" "${value}" >>"${tmp_file}"
  mv "${tmp_file}" "${STATE_FILE}"
}

get_state() {
  local key="$1"
  [[ -f "${STATE_FILE}" ]] || return 1
  grep "^${key}=" "${STATE_FILE}" | tail -n1 | cut -d= -f2-
}

apt_update_once() {
  if [[ "$(get_state APT_UPDATED 2>/dev/null || true)" == "true" ]]; then
    log info "apt-get update already completed in this run."
    return 0
  fi

  run_cmd "Refreshing apt package index" apt-get update
  set_state "APT_UPDATED" "true"
}

apt_install_packages() {
  local missing=()
  local pkg=""
  for pkg in "$@"; do
    if ! package_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if ((${#missing[@]} == 0)); then
    log info "All requested packages are already installed."
    return 0
  fi

  apt_update_once
  run_cmd "Installing packages: ${missing[*]}" apt-get install -y --no-install-recommends "${missing[@]}"
}

restart_service_if_exists() {
  local service_name="${1%.service}"
  service_exists "${service_name}" || {
    log warn "Service not found: ${service_name}"
    return 0
  }
  run_cmd "Restarting service ${service_name}" systemctl restart "${service_name}"
}

reload_service_if_exists() {
  local service_name="${1%.service}"
  service_exists "${service_name}" || {
    log warn "Service not found: ${service_name}"
    return 0
  }
  run_cmd "Reloading service ${service_name}" systemctl reload "${service_name}"
}

enable_and_start_service() {
  local service_name="${1%.service}"
  service_exists "${service_name}" || {
    log warn "Service not found: ${service_name}"
    return 0
  }
  run_cmd "Enabling service ${service_name}" systemctl enable "${service_name}"
  run_cmd "Starting service ${service_name}" systemctl start "${service_name}"
}

append_report() {
  local file="$1"
  local content="$2"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] write report: ${file}"
    return 0
  fi

  install -d -m 0755 "$(dirname "${file}")"
  printf '%s\n' "${content}" >>"${file}"
}

registry_file() {
  printf '%s\n' "${MODULE_REGISTRY_FILE:-${PROJECT_ROOT}/config/module-registry.tsv}"
}

require_registry_file() {
  [[ -f "$(registry_file)" ]] || die "Module registry not found: $(registry_file)"
}

registry_lines() {
  local phase="${1:-}"
  require_registry_file

  awk -F '\t' -v phase="${phase}" '
    NR == 1 { next }
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    phase == "" || $3 == phase { print $0 }
  ' "$(registry_file)"
}

registry_find_line() {
  local requested="${1:-}"
  local normalized=""
  normalized="$(basename "${requested}")"
  normalized="${normalized%.sh}"

  require_registry_file
  awk -F '\t' -v key="${normalized}" '
    NR == 1 { next }
    /^[[:space:]]*#/ { next }
    NF < 9 { next }
    {
      script = $9
      gsub(/^.*\//, "", script)
      gsub(/\.sh$/, "", script)
      if ($2 == key || script == key) {
        print $0
        exit
      }
    }
  ' "$(registry_file)"
}

registry_script_abspath_from_line() {
  local line="$1"
  local step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
  IFS=$'\t' read -r step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
  printf '%s\n' "${PROJECT_ROOT}/${script_path}"
}

risk_label_zh() {
  case "${1:-unknown}" in
    high) echo "高" ;;
    medium) echo "中" ;;
    low) echo "低" ;;
    *) echo "未知" ;;
  esac
}

risk_badge_zh() {
  case "${1:-unknown}" in
    high) echo "【高风险】" ;;
    medium) echo "【中风险】" ;;
    low) echo "【低风险】" ;;
    *) echo "【风险未知】" ;;
  esac
}

bool_label_zh() {
  if is_true "${1:-false}"; then
    echo "是"
  else
    echo "否"
  fi
}

phase_label_zh() {
  case "${1:-}" in
    init) echo "初始化" ;;
    maintain) echo "维护" ;;
    cautious) echo "谨慎操作" ;;
    *) echo "未分类" ;;
  esac
}

step_label_zh() {
  local phase="$1"
  local step_no="$2"

  if [[ "${phase}" == "init" && -n "${step_no}" && "${step_no}" != "-" ]]; then
    printf '第 %s 步' "${step_no}"
  else
    printf '维护任务'
  fi
}

optional_field_zh() {
  local value="${1:-}"
  if [[ -z "${value}" || "${value}" == "-" ]]; then
    echo "无"
  else
    echo "${value}"
  fi
}

selection_contains() {
  local needle="$1"
  shift || true
  local item=""
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

ssh_port_change_pending_confirmation() {
  [[ "${SSH_PORT}" != "22" ]] && is_false "${CONFIRM_SSH_PORT_CHANGE}"
}

effective_ssh_port_for_changes() {
  if ssh_port_change_pending_confirmation; then
    local current_port=""
    current_port="$(current_ssh_port 2>/dev/null || true)"
    printf '%s\n' "${current_port:-22}"
    return 0
  fi

  printf '%s\n' "${SSH_PORT}"
}

warn_ssh_port_change_not_confirmed() {
  local current_port=""
  current_port="$(current_ssh_port 2>/dev/null || true)"
  current_port="${current_port:-22}"
  log warn "Requested SSH_PORT=${SSH_PORT}, but CONFIRM_SSH_PORT_CHANGE is not enabled."
  log warn "For safety, SSH hardening and nftables will keep using the current port ${current_port}."
  log warn "After confirming cloud firewall/security-group and external access are ready, set CONFIRM_SSH_PORT_CHANGE=\"true\" and rerun step 6 and step 7."
}

apply_sysctl_dropin() {
  local target="$1"
  local content="$2"
  local description="${3:-Applying sysctl drop-in}"

  apply_managed_file "${target}" "0644" "${content}" "true"
  run_cmd "${description}" sysctl --system
}

apply_sshd_dropin() {
  local target="$1"
  local content="$2"
  local description="${3:-Applying sshd drop-in}"

  apt_install_packages openssh-server
  apply_managed_file "${target}" "0644" "${content}" "true"
  validate_sshd_config

  local ssh_service=""
  ssh_service="$(ssh_service_name)"
  reload_service_if_exists "${ssh_service}"
  log info "${description}: ${target}"
}
