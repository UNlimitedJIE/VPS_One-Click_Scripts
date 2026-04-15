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
# shellcheck source=lib/apt.sh
source "${COMMON_DIR}/apt.sh"

shared_state_dir_path() {
  printf '%s/state\n' "${PROJECT_ROOT}"
}

shared_log_dir_path() {
  printf '%s/logs\n' "${PROJECT_ROOT}"
}

shared_change_log_file_path() {
  printf '%s/change-log.tsv\n' "$(shared_state_dir_path)"
}

shared_runtime_state_file_path() {
  printf '%s/runtime.state\n' "$(shared_state_dir_path)"
}

private_runtime_base_dir() {
  local state_home="${XDG_STATE_HOME:-}"
  local current_user=""
  local current_home="${HOME:-}"

  if [[ -n "${state_home}" ]]; then
    printf '%s/vps-bootstrap\n' "${state_home}"
    return 0
  fi

  if [[ -z "${current_home}" ]]; then
    current_user="$(id -un 2>/dev/null || true)"
    if [[ -n "${current_user}" ]]; then
      current_home="$(getent passwd "${current_user}" | cut -d: -f6)"
    fi
  fi

  if [[ -n "${current_home}" ]]; then
    printf '%s/.local/state/vps-bootstrap\n' "${current_home}"
    return 0
  fi

  printf '/tmp/vps-bootstrap\n'
}

private_state_dir_path() {
  printf '%s\n' "$(private_runtime_base_dir)"
}

private_log_dir_path() {
  printf '%s/logs\n' "$(private_runtime_base_dir)"
}

private_change_log_file_path() {
  printf '%s/change-log.tsv\n' "$(private_state_dir_path)"
}

path_is_within_dir() {
  local path="${1:-}"
  local dir="${2:-}"

  [[ -n "${path}" && -n "${dir}" ]] || return 1
  [[ "${path}" == "${dir}" || "${path}" == "${dir}/"* ]]
}

runtime_storage_mode_for_current_user() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    printf '%s\n' "shared"
  else
    printf '%s\n' "private"
  fi
}

normalize_runtime_storage_paths() {
  local shared_state_dir=""
  local shared_log_dir=""
  local shared_change_log=""
  local private_state_dir=""
  local private_log_dir=""
  local private_change_log=""
  local mode=""

  shared_state_dir="$(shared_state_dir_path)"
  shared_log_dir="$(shared_log_dir_path)"
  shared_change_log="$(shared_change_log_file_path)"
  private_state_dir="$(private_state_dir_path)"
  private_log_dir="$(private_log_dir_path)"
  private_change_log="$(private_change_log_file_path)"
  mode="$(runtime_storage_mode_for_current_user)"

  SHARED_STATE_DIR="${shared_state_dir}"
  SHARED_LOG_DIR="${shared_log_dir}"

  if [[ "${mode}" == "private" ]]; then
    if [[ -z "${STATE_DIR:-}" || "${STATE_DIR}" == "${shared_state_dir}" || "$(path_is_within_dir "${STATE_DIR}" "${shared_state_dir}" && printf yes || printf no)" == "yes" ]]; then
      STATE_DIR="${private_state_dir}"
    fi
    if [[ -z "${LOG_DIR:-}" || "${LOG_DIR}" == "${shared_log_dir}" || "$(path_is_within_dir "${LOG_DIR}" "${shared_log_dir}" && printf yes || printf no)" == "yes" ]]; then
      LOG_DIR="${private_log_dir}"
    fi
    if [[ -z "${CHANGE_LOG_FILE:-}" || "${CHANGE_LOG_FILE}" == "${shared_change_log}" || "$(path_is_within_dir "${CHANGE_LOG_FILE}" "${shared_state_dir}" && printf yes || printf no)" == "yes" ]]; then
      CHANGE_LOG_FILE="${private_change_log}"
    fi
  else
    STATE_DIR="${STATE_DIR:-${shared_state_dir}}"
    LOG_DIR="${LOG_DIR:-${shared_log_dir}}"
    CHANGE_LOG_FILE="${CHANGE_LOG_FILE:-${shared_change_log}}"
  fi

  RUNTIME_STORAGE_MODE="${mode}"
}

ensure_runtime_storage_ready() {
  local target_state_dir="${STATE_DIR:-}"
  local target_log_dir="${LOG_DIR:-}"

  mkdir -p "${target_state_dir}" "${target_state_dir}/reports" "${target_state_dir}/tmp" "${target_log_dir}" 2>/dev/null && return 0

  if [[ "${RUNTIME_STORAGE_MODE:-}" == "private" ]]; then
    STATE_DIR="/tmp/vps-bootstrap/state"
    LOG_DIR="/tmp/vps-bootstrap/logs"
    CHANGE_LOG_FILE="/tmp/vps-bootstrap/state/change-log.tsv"
    mkdir -p "${STATE_DIR}" "${STATE_DIR}/reports" "${STATE_DIR}/tmp" "${LOG_DIR}" 2>/dev/null || true
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    STATE_DIR="$(private_state_dir_path)"
    LOG_DIR="$(private_log_dir_path)"
    CHANGE_LOG_FILE="$(private_change_log_file_path)"
    RUNTIME_STORAGE_MODE="private"
    mkdir -p "${STATE_DIR}" "${STATE_DIR}/reports" "${STATE_DIR}/tmp" "${LOG_DIR}" 2>/dev/null || true
  fi
}

set_default_config() {
  DEFAULT_ADMIN_USER="${DEFAULT_ADMIN_USER:-ops}"
  TIMEZONE="${TIMEZONE:-UTC}"
  SSH_PORT="${SSH_PORT:-22}"
  CONFIRM_SSH_PORT_CHANGE="${CONFIRM_SSH_PORT_CHANGE:-false}"
  ADMIN_USER="${ADMIN_USER:-${DEFAULT_ADMIN_USER}}"
  ADMIN_USER_SHELL="${ADMIN_USER_SHELL:-/bin/bash}"
  ADMIN_USER_GROUPS="${ADMIN_USER_GROUPS:-sudo}"
  ADMIN_SUDO_MODE_DEFAULT="${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}"
  AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-$(preferred_authorized_keys_source_path)}"
  DISABLE_PASSWORD_LOGIN="${DISABLE_PASSWORD_LOGIN:-true}"
  DISABLE_ROOT_SSH_PASSWORD="${DISABLE_ROOT_SSH_PASSWORD:-true}"
  INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-true}"
  INSTALL_UNATTENDED_UPGRADES="${INSTALL_UNATTENDED_UPGRADES:-true}"
  ENABLE_NODEQUALITY="${ENABLE_NODEQUALITY:-true}"
  NODEQUALITY_FORCE="${NODEQUALITY_FORCE:-false}"
  ENABLE_NFTABLES="${ENABLE_NFTABLES:-true}"
  ENABLE_TIME_SYNC="${ENABLE_TIME_SYNC:-true}"
  PLAN_ONLY="${PLAN_ONLY:-false}"
  DRY_RUN="${DRY_RUN:-false}"
  BASE_PACKAGES="${BASE_PACKAGES:-curl ca-certificates sudo openssh-server nftables rsync unzip git jq lsof procps htop vim-tiny less}"
  JOURNAL_VACUUM_DAYS="${JOURNAL_VACUUM_DAYS:-14}"
  CLEANUP_APT_CACHE="${CLEANUP_APT_CACHE:-true}"
  MODULE_REGISTRY_FILE="${MODULE_REGISTRY_FILE:-${PROJECT_ROOT}/config/module-registry.tsv}"
  STATE_DIR="${STATE_DIR:-$(shared_state_dir_path)}"
  LOG_DIR="${LOG_DIR:-$(shared_log_dir_path)}"
  CHANGE_LOG_FILE="${CHANGE_LOG_FILE:-$(shared_change_log_file_path)}"
  SNAPSHOT_REMINDER="${SNAPSHOT_REMINDER:-初始化通过后，请先验证新 SSH 登录，再在云厂商控制台创建快照/备份。}"
}

resolve_config_path() {
  local path="${1:-}"

  [[ -n "${path}" ]] || return 1

  if [[ "${path}" != /* ]]; then
    if [[ -f "${path}" ]]; then
      path="$(cd "$(dirname "${path}")" && pwd)/$(basename "${path}")"
    else
      path="${PROJECT_ROOT}/${path}"
    fi
  fi

  if [[ -f "${path}" ]]; then
    path="$(cd "$(dirname "${path}")" && pwd)/$(basename "${path}")"
  fi

  printf '%s\n' "${path}"
}

append_config_chain_entry() {
  local current="${1:-}"
  local entry="${2:-}"

  if [[ -z "${current}" ]]; then
    printf '%s\n' "${entry}"
  else
    printf '%s -> %s\n' "${current}" "${entry}"
  fi
}

load_config() {
  set_default_config

  local default_config=""
  local local_config=""
  local requested_config_raw=""
  local requested_config=""
  local config_target=""
  local config_chain=""

  default_config="$(resolve_config_path "${PROJECT_ROOT}/config/default.conf")"
  local_config="$(resolve_config_path "${PROJECT_ROOT}/config/local.conf")"
  requested_config_raw="${CLI_CONFIG_FILE:-${CONFIG_FILE:-}}"

  if [[ -f "${default_config}" ]]; then
    # shellcheck disable=SC1090
    source "${default_config}"
    config_chain="$(append_config_chain_entry "${config_chain}" "${default_config}")"
    config_target="${default_config}"
  fi

  if [[ -f "${local_config}" ]]; then
    # shellcheck disable=SC1090
    source "${local_config}"
    if [[ "${local_config}" != "${default_config}" ]]; then
      config_chain="$(append_config_chain_entry "${config_chain}" "${local_config}")"
    fi
    config_target="${local_config}"
  fi

  if [[ -n "${requested_config_raw}" ]]; then
    requested_config="$(resolve_config_path "${requested_config_raw}")"
    if [[ "${requested_config}" != "${default_config}" && "${requested_config}" != "${local_config}" ]]; then
      config_target="${requested_config}"
    fi

    if [[ "${requested_config}" != "${default_config}" && "${requested_config}" != "${local_config}" && -f "${requested_config}" ]]; then
      # shellcheck disable=SC1090
      source "${requested_config}"
      config_chain="$(append_config_chain_entry "${config_chain}" "${requested_config}")"
    fi
  fi

  [[ -n "${CLI_PLAN_ONLY:-}" ]] && PLAN_ONLY="${CLI_PLAN_ONLY}"
  [[ -n "${CLI_DRY_RUN:-}" ]] && DRY_RUN="${CLI_DRY_RUN}"

  if [[ -z "${config_target}" ]]; then
    config_target="${default_config}"
  fi

  ACTIVE_CONFIG_CHAIN="${config_chain:-${config_target}}"
  CONFIG_FILE="${config_target}"
  CLI_CONFIG_FILE="${config_target}"
  [[ -n "${RUNTIME_ADMIN_USER_OVERRIDE:-}" ]] && ADMIN_USER="${RUNTIME_ADMIN_USER_OVERRIDE}"

  MODULE_REGISTRY_FILE="${MODULE_REGISTRY_FILE:-${PROJECT_ROOT}/config/module-registry.tsv}"
  normalize_runtime_storage_paths
}

export_config() {
  export PROJECT_ROOT CONFIG_FILE CLI_CONFIG_FILE CLI_PLAN_ONLY CLI_DRY_RUN MODULE_REGISTRY_FILE STATE_DIR LOG_DIR CHANGE_LOG_FILE
  export DEFAULT_ADMIN_USER RUNTIME_ADMIN_USER_OVERRIDE
  export ACTIVE_CONFIG_CHAIN
  export SHARED_STATE_DIR SHARED_LOG_DIR RUNTIME_STORAGE_MODE
  export TIMEZONE SSH_PORT CONFIRM_SSH_PORT_CHANGE
  export ADMIN_USER ADMIN_USER_SHELL ADMIN_USER_GROUPS ADMIN_SUDO_MODE_DEFAULT AUTHORIZED_KEYS_FILE
  export DISABLE_PASSWORD_LOGIN DISABLE_ROOT_SSH_PASSWORD
  export INSTALL_FAIL2BAN INSTALL_UNATTENDED_UPGRADES
  export ENABLE_NODEQUALITY NODEQUALITY_FORCE ENABLE_NFTABLES ENABLE_TIME_SYNC
  export PLAN_ONLY DRY_RUN BASE_PACKAGES JOURNAL_VACUUM_DAYS
  export CLEANUP_APT_CACHE SNAPSHOT_REMINDER
}

init_runtime() {
  ensure_runtime_storage_ready

  RUN_ID="${RUN_ID:-$(date '+%Y%m%d-%H%M%S')}"
  if [[ "${RUNTIME_STORAGE_MODE:-shared}" == "private" && ( -z "${LOG_FILE:-}" || "$(path_is_within_dir "${LOG_FILE:-}" "${SHARED_LOG_DIR:-}" && printf yes || printf no)" == "yes" ) ]]; then
    LOG_FILE="${LOG_DIR}/${RUN_ID}-${RUN_MODE:-manual}.log"
  else
    LOG_FILE="${LOG_FILE:-${LOG_DIR}/${RUN_ID}-${RUN_MODE:-manual}.log}"
  fi

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    if [[ "${RUNTIME_STORAGE_MODE:-shared}" == "private" && ( -z "${STATE_FILE:-}" || "$(path_is_within_dir "${STATE_FILE:-}" "${SHARED_STATE_DIR:-}" && printf yes || printf no)" == "yes" ) ]]; then
      STATE_FILE="${STATE_DIR}/tmp/runtime-${RUN_ID}-${RUN_MODE:-manual}.state"
    else
      STATE_FILE="${STATE_FILE:-${STATE_DIR}/tmp/runtime-${RUN_ID}-${RUN_MODE:-manual}.state}"
    fi
    STATE_FILE_IS_EPHEMERAL="${STATE_FILE_IS_EPHEMERAL:-true}"
  else
    if [[ "${RUNTIME_STORAGE_MODE:-shared}" == "private" && ( -z "${STATE_FILE:-}" || "$(path_is_within_dir "${STATE_FILE:-}" "${SHARED_STATE_DIR:-}" && printf yes || printf no)" == "yes" ) ]]; then
      STATE_FILE="${STATE_DIR}/runtime.state"
    else
      STATE_FILE="${STATE_FILE:-${STATE_DIR}/runtime.state}"
    fi
    STATE_FILE_IS_EPHEMERAL="${STATE_FILE_IS_EPHEMERAL:-false}"
  fi

  export RUN_ID LOG_FILE STATE_FILE STATE_FILE_IS_EPHEMERAL
  export_config
}

active_config_file_path() {
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    printf '%s\n' "${CONFIG_FILE}"
    return 0
  fi

  if [[ -n "${CLI_CONFIG_FILE:-}" ]]; then
    printf '%s\n' "${CLI_CONFIG_FILE}"
    return 0
  fi

  printf '%s\n' "${PROJECT_ROOT}/config/default.conf"
}

bootstrap_authorized_keys_fallback_path() {
  preferred_authorized_keys_source_path
}

preferred_authorized_keys_source_path() {
  printf '/opt/vps-bootstrap/bootstrap_authorized_keys\n'
}

authorized_keys_source_is_root_only_path() {
  local file="${1:-${AUTHORIZED_KEYS_FILE:-}}"
  [[ -n "${file}" && ( "${file}" == "/root" || "${file}" == /root/* ) ]]
}

shared_project_root() {
  printf '/opt/VPS_One-Click_Scripts\n'
}

runtime_project_candidate_paths() {
  local current_user=""
  local current_home=""

  current_user="$(id -un 2>/dev/null || true)"
  current_home="${HOME:-}"

  if [[ -z "${current_home}" && -n "${current_user}" ]]; then
    current_home="$(getent passwd "${current_user}" | cut -d: -f6)"
  fi

  printf '%s\n' "/opt/VPS_One-Click_Scripts"
  if [[ -n "${current_home}" ]]; then
    printf '%s\n' "${current_home}/VPS_One-Click_Scripts"
  fi
  printf '%s\n' "/root/VPS_One-Click_Scripts"
}

project_copy_is_usable() {
  local path="${1:-}"
  [[ -n "${path}" && -d "${path}" && -x "${path}" && -f "${path}/bootstrap.sh" && -r "${path}/bootstrap.sh" ]]
}

list_detected_project_copies() {
  local candidate=""
  local -a seen_paths=()

  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if project_copy_is_usable "${candidate}" && ! selection_contains "${candidate}" "${seen_paths[@]}"; then
      seen_paths+=("${candidate}")
      printf '%s\n' "${candidate}"
    fi
  done < <(runtime_project_candidate_paths)
}

discover_runtime_project_root() {
  local candidate=""

  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if project_copy_is_usable "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(runtime_project_candidate_paths)

  return 1
}

project_root_requires_shared_copy() {
  [[ "${PROJECT_ROOT}" == "/root" || "${PROJECT_ROOT}" == /root/* ]]
}

sync_project_tree_to_runtime_root() {
  local source_root="${1:-${PROJECT_ROOT}}"
  local target_root="${2:-$(shared_project_root)}"

  [[ -n "${source_root}" ]] || die "项目源目录为空，无法同步运行副本。"
  [[ -d "${source_root}" ]] || die "项目源目录不存在：${source_root}"
  [[ -f "${source_root}/bootstrap.sh" ]] || die "项目源目录缺少 bootstrap.sh：${source_root}"
  [[ -n "${target_root}" ]] || die "目标运行目录为空，无法同步运行副本。"

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "[plan] install -d -m 0755 ${target_root}"
    if [[ "${source_root}" != "${target_root}" ]]; then
      log info "[plan] rsync -a ${source_root}/ ${target_root}/"
    else
      log info "[plan] current project already equals preferred runtime root: ${target_root}"
    fi
    log info "[plan] chmod -R a+rX ${target_root}"
    log info "[plan] env SHORTCUT_FORCE_OVERWRITE=true bash ${target_root}/bootstrap.sh install-shortcut"
    return 0
  fi

  apt_install_packages rsync
  run_cmd "Ensuring preferred runtime root ${target_root}" install -d -m 0755 "${target_root}"
  if [[ "${source_root}" != "${target_root}" ]]; then
    run_cmd "Syncing project from ${source_root} to preferred runtime root ${target_root}" rsync -a "${source_root}/" "${target_root}/"
  else
    log info "Current project already matches the preferred runtime root: ${target_root}"
  fi
  run_cmd "Ensuring preferred runtime root is readable for non-root admins" chmod -R a+rX "${target_root}"
  run_cmd "Refreshing shortcut j from preferred runtime root" env SHORTCUT_FORCE_OVERWRITE=true bash "${target_root}/bootstrap.sh" install-shortcut
}

admin_ssh_dir_for_user() {
  local user="${1:-${ADMIN_USER:-}}"
  local home_dir=""

  [[ -n "${user}" ]] || return 1
  home_dir="$(home_dir_for_user "${user}")"
  [[ -n "${home_dir}" ]] || return 1
  printf '%s/.ssh\n' "${home_dir}"
}

admin_authorized_keys_file_for_user() {
  local user="${1:-${ADMIN_USER:-}}"
  local ssh_dir=""

  ssh_dir="$(admin_ssh_dir_for_user "${user}")" || return 1
  printf '%s/authorized_keys\n' "${ssh_dir}"
}

admin_authorized_keys_count_for_user() {
  local user="${1:-${ADMIN_USER:-}}"
  local auth_file=""

  auth_file="$(admin_authorized_keys_file_for_user "${user}" || true)"
  [[ -n "${auth_file}" ]] || {
    printf '%s\n' "0"
    return 0
  }

  count_valid_ssh_keys_in_file "${auth_file}"
}

admin_authorized_keys_install_valid_for_user() {
  local user="${1:-${ADMIN_USER:-}}"
  local ssh_dir=""
  local auth_file=""
  local ssh_meta=""
  local auth_meta=""
  local key_count="0"

  [[ -n "${user}" ]] || return 1
  id -u "${user}" >/dev/null 2>&1 || return 1

  ssh_dir="$(admin_ssh_dir_for_user "${user}" || true)"
  auth_file="$(admin_authorized_keys_file_for_user "${user}" || true)"
  [[ -n "${ssh_dir}" && -n "${auth_file}" ]] || return 1
  [[ -d "${ssh_dir}" && -f "${auth_file}" ]] || return 1

  ssh_meta="$(stat -c '%U:%G %a' "${ssh_dir}" 2>/dev/null || true)"
  [[ "${ssh_meta}" == "${user}:${user} 700" ]] || return 1

  auth_meta="$(stat -c '%U:%G %a' "${auth_file}" 2>/dev/null || true)"
  [[ "${auth_meta}" == "${user}:${user} 600" ]] || return 1

  key_count="$(count_valid_ssh_keys_in_file "${auth_file}")"
  [[ "${key_count}" -gt 0 ]]
}

admin_authorized_keys_ready_for_user() {
  local user="${1:-${ADMIN_USER:-}}"

  [[ -n "${user}" ]] || return 1
  id -u "${user}" >/dev/null 2>&1 || return 1
  admin_authorized_keys_install_valid_for_user "${user}"
}

user_account_password_state() {
  local user="${1:-${ADMIN_USER:-}}"
  local shadow_entry=""
  local password_field=""

  [[ -n "${user}" ]] || {
    printf '%s\n' "missing"
    return 0
  }

  if ! id -u "${user}" >/dev/null 2>&1; then
    printf '%s\n' "missing"
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && ! -r /etc/shadow ]]; then
    printf '%s\n' "unknown"
    return 0
  fi

  shadow_entry="$(getent shadow "${user}" 2>/dev/null || true)"
  if [[ -z "${shadow_entry}" ]]; then
    printf '%s\n' "unknown"
    return 0
  fi

  password_field="$(printf '%s\n' "${shadow_entry}" | cut -d: -f2)"
  if [[ -z "${password_field}" || "${password_field}" == "!"* || "${password_field}" == "*"* ]]; then
    printf '%s\n' "locked_or_unset"
    return 0
  fi

  printf '%s\n' "set"
}

user_account_password_state_label() {
  case "$(user_account_password_state "${1:-${ADMIN_USER:-}}")" in
    set)
      printf '%s\n' "已设置"
      ;;
    locked_or_unset)
      printf '%s\n' "未设置或已锁定"
      ;;
    missing)
      printf '%s\n' "账户不存在"
      ;;
    *)
      printf '%s\n' "未知"
      ;;
  esac
}

user_account_password_available() {
  [[ "$(user_account_password_state "${1:-${ADMIN_USER:-}}")" == "set" ]]
}

ssh_policy_enabled_disabled_label() {
  case "${1:-unknown}" in
    yes|enabled|true)
      printf '%s\n' "enabled"
      ;;
    no|disabled|false)
      printf '%s\n' "disabled"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

ssh_root_remote_login_enabled_disabled_label() {
  case "${1:-unknown}" in
    no|disabled|false)
      printf '%s\n' "disabled"
      ;;
    yes|enabled|true|prohibit-password|without-password|forced-commands-only)
      printf '%s\n' "enabled"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

ssh_readiness_label() {
  case "${1:-unknown}" in
    yes|ready|true)
      printf '%s\n' "ready"
      ;;
    no|not-ready|false|"")
      printf '%s\n' "not ready"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

ssh_publickey_login_ready_for_user() {
  local user="${1:-${ADMIN_USER:-}}"
  [[ -n "${user}" ]] || return 1
  admin_authorized_keys_ready_for_user "${user}"
}

ssh_publickey_login_ready_label_for_user() {
  local user="${1:-${ADMIN_USER:-}}"

  if ssh_publickey_login_ready_for_user "${user}"; then
    printf '%s\n' "ready"
    return 0
  fi

  printf '%s\n' "not ready"
}

ssh_safe_gate_state_for_user() {
  local user="${1:-${ADMIN_USER:-}}"

  if ssh_publickey_login_ready_for_user "${user}"; then
    printf '%s\n' "yes"
  else
    printf '%s\n' "no"
  fi
}

ssh_stage5_ready_state_for_user() {
  local user="${1:-${ADMIN_USER:-}}"
  local safe_gate_state=""
  local current_password_auth=""
  local current_pubkey_auth=""

  safe_gate_state="$(get_state "SSH_SAFE_GATE_PASSED" || true)"
  if [[ -z "${safe_gate_state}" ]]; then
    safe_gate_state="$(ssh_safe_gate_state_for_user "${user}")"
  fi

  current_password_auth="$(current_password_authentication_mode || true)"
  current_pubkey_auth="$(current_pubkey_authentication_mode || true)"

  if ssh_publickey_login_ready_for_user "${user}" && [[ "${safe_gate_state}" == "yes" ]] && [[ "${current_password_auth}" == "no" ]] && [[ "${current_pubkey_auth}" == "yes" ]]; then
    printf '%s\n' "yes"
  else
    printf '%s\n' "no"
  fi
}

ssh_last_successful_auth_method_label() {
  case "${1:-unknown}" in
    publickey|password|keyboard-interactive/pam)
      printf '%s\n' "${1}"
      ;;
    *)
      printf '%s\n' "unable to determine from current logs"
      ;;
  esac
}

ssh_port_is_listening_locally() {
  local port="${1:-}"
  [[ -n "${port}" ]] || return 1
  listening_tcp_ports | grep -Fxq "${port}"
}

swap_fstab_line() {
  printf '%s\n' "/swapfile none swap sw 0 0"
}

swap_fstab_present() {
  grep -Fqx "$(swap_fstab_line)" /etc/fstab 2>/dev/null
}

set_runtime_admin_user() {
  local username="$1"
  ADMIN_USER="${username}"
  RUNTIME_ADMIN_USER_OVERRIDE="${username}"
  export_config
}

upsert_config_assignment() {
  local file="$1"
  local key="$2"
  local value="$3"
  local assignment_line=""
  local target_dir=""
  local tmp_file=""

  assignment_line="${key}=\"${value}\""

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] write ${assignment_line} to ${file}"
    return 0
  fi

  target_dir="$(dirname "${file}")"
  install -d -m 0755 "${target_dir}"
  tmp_file="$(mktemp "${target_dir}/.${key}.XXXXXX")"

  if [[ -f "${file}" ]]; then
    awk -v key="${key}" -v assignment_line="${assignment_line}" '
      BEGIN { updated = 0 }
      $0 ~ "^[[:space:]]*" key "=" {
        if (!updated) {
          print assignment_line
          updated = 1
        }
        next
      }
      { print }
      END {
        if (!updated) {
          print assignment_line
        }
      }
    ' "${file}" >"${tmp_file}"

    if cmp -s "${tmp_file}" "${file}"; then
      rm -f "${tmp_file}"
      log info "No change required: ${file}"
      return 0
    fi
  else
    printf '%s\n' "${assignment_line}" >"${tmp_file}"
  fi

  mv "${tmp_file}" "${file}"
  log info "Config updated: ${file} (${assignment_line})"
}

cleanup_ephemeral_state() {
  if [[ "${STATE_FILE_IS_EPHEMERAL:-false}" == "true" && -n "${STATE_FILE:-}" && -f "${STATE_FILE}" ]]; then
    rm -f "${STATE_FILE}" 2>/dev/null || true
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

replace_file_with_tmp_if_changed() {
  local target="$1"
  local tmp_file="$2"
  local backup_existing="${3:-false}"

  if [[ -f "${target}" ]] && cmp -s "${tmp_file}" "${target}"; then
    rm -f "${tmp_file}"
    log info "No change required: ${target}"
    return 0
  fi

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] update file: ${target}"
    rm -f "${tmp_file}"
    return 0
  fi

  if [[ -f "${target}" && "${backup_existing}" == "true" ]]; then
    backup_file "${target}"
  fi

  mv "${tmp_file}" "${target}"
  log info "Managed file updated: ${target}"
}

remove_file_if_exists() {
  local target="${1:-}"

  [[ -n "${target}" ]] || return 0
  [[ -e "${target}" ]] || return 0

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] remove file if exists: ${target}"
    return 0
  fi

  rm -f "${target}"
  log info "Removed file: ${target}"
}

replace_managed_block_in_file() {
  local target="$1"
  local begin_marker="$2"
  local end_marker="$3"
  local block_content="$4"
  local backup_existing="${5:-false}"
  local tmp_file=""
  local block_file=""

  [[ -n "${target}" && -n "${begin_marker}" && -n "${end_marker}" ]] || die "replace_managed_block_in_file requires target and markers."

  tmp_file="$(mktemp)"
  block_file="$(mktemp)"
  {
    printf '%s\n' "${begin_marker}"
    if [[ -n "${block_content}" ]]; then
      printf '%s\n' "${block_content}"
    fi
    printf '%s\n' "${end_marker}"
  } >"${block_file}"

  if [[ -f "${target}" ]]; then
    awk -v begin_marker="${begin_marker}" -v end_marker="${end_marker}" -v block_file="${block_file}" '
      index($0, begin_marker) {
        while ((getline line < block_file) > 0) {
          print line
        }
        in_block = 1
        replaced = 1
        next
      }
      in_block {
        if (index($0, end_marker)) {
          in_block = 0
        }
        next
      }
      { print }
      END {
        if (!replaced) {
          if (NR > 0) {
            print ""
          }
          while ((getline line < block_file) > 0) {
            print line
          }
        }
      }
    ' "${target}" >"${tmp_file}"
  else
    cat "${block_file}" >"${tmp_file}"
  fi

  rm -f "${block_file}"
  replace_file_with_tmp_if_changed "${target}" "${tmp_file}" "${backup_existing}"
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

  [[ -n "${STATE_FILE:-}" ]] || {
    rm -f "${tmp_file}"
    return 0
  }

  mkdir -p "$(dirname "${STATE_FILE}")" 2>/dev/null || true
  if ! touch "${STATE_FILE}" 2>/dev/null; then
    rm -f "${tmp_file}"
    return 0
  fi

  grep -v "^${key}=" "${STATE_FILE}" 2>/dev/null >"${tmp_file}" || true
  printf '%s=%s\n' "${key}" "${value}" >>"${tmp_file}"
  mv "${tmp_file}" "${STATE_FILE}" 2>/dev/null || {
    rm -f "${tmp_file}"
    return 0
  }

  if [[ "${STATE_FILE}" == "$(shared_runtime_state_file_path)" || "${STATE_FILE}" == "$(shared_state_dir_path)"/* ]]; then
    chmod 0644 "${STATE_FILE}" 2>/dev/null || true
  fi
}

state_file_candidates() {
  local shared_state_file=""
  local current_state_file="${STATE_FILE:-}"

  if [[ -n "${current_state_file}" ]]; then
    printf '%s\n' "${current_state_file}"
  fi

  shared_state_file="$(shared_runtime_state_file_path)"
  if [[ -n "${shared_state_file}" && "${shared_state_file}" != "${current_state_file}" ]]; then
    printf '%s\n' "${shared_state_file}"
  fi
}

state_value_from_file() {
  local file="$1"
  local key="$2"

  [[ -r "${file}" ]] || return 1

  awk -v key="${key}" '
    index($0, key "=") == 1 {
      value = substr($0, length(key) + 2)
      found = 1
    }
    END {
      if (found) {
        print value
      } else {
        exit 1
      }
    }
  ' "${file}" 2>/dev/null
}

get_state() {
  local key="$1"
  local candidate=""
  local value=""

  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    value="$(state_value_from_file "${candidate}" "${key}" || true)"
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  done < <(state_file_candidates)

  return 1
}

module_completion_state_found() {
  local module_id="${1:-}"

  case "${module_id}" in
    00_nodequality)
      [[ -n "$(get_state "NODEQUALITY_DONE" || true)" ]]
      ;;
    01_detect_system)
      [[ -n "$(get_state "DETECT_SYSTEM_DONE" || true)" ]]
      ;;
    02_update_base)
      [[ -n "$(get_state "BASE_UPDATED" || true)" ]]
      ;;
    025_change_ssh_port)
      [[ -n "$(get_state "SSH_PORT_STEP_DONE" || true)" || -n "$(get_state "SSH_PORT_PERSISTED_VALUE" || true)" ]]
      ;;
    03_admin_access_stage)
      [[ -n "$(get_state "AUTHORIZED_KEYS_PRESENT" || true)" || -n "$(get_state "SSH_SAFE_GATE_PASSED" || true)" || -n "$(get_state "AUTHORIZED_KEYS_COUNT" || true)" ]]
      ;;
    06_nftables)
      [[ -n "$(get_state "NFTABLES_ENABLED" || true)" ]]
      ;;
    07_switch_admin_login)
      [[ -n "$(get_state "ADMIN_LOGIN_CUTOVER" || true)" || -n "$(get_state "ROOT_SSH_MODE" || true)" ]]
      ;;
    07_time_sync)
      [[ -n "$(get_state "TIMESYNCD_ENABLED" || true)" ]]
      ;;
    08_auto_updates)
      [[ -n "$(get_state "AUTO_UPDATES_ENABLED" || true)" ]]
      ;;
    09_fail2ban)
      [[ -n "$(get_state "FAIL2BAN_ENABLED" || true)" ]]
      ;;
    10_swap)
      [[ -n "$(get_state "SWAP_ENABLED" || true)" ]]
      ;;
    11_verify)
      [[ -n "$(get_state "VERIFY_FAILURES" || true)" || -n "$(get_state "VERIFY_WARNINGS" || true)" || -n "$(get_state "VERIFY_PENDING" || true)" ]]
      ;;
    20_update_system)
      [[ -n "$(get_state "MAINT_LAST_UPDATE" || true)" ]]
      ;;
    30_xanmod_bbr3)
      [[ -n "$(get_state "NETWORK_XANMOD_KERNEL_DONE" || true)" ]]
      ;;
    31_bbr_landing_optimization)
      [[ -n "$(get_state "NETWORK_BBR_TUNED" || true)" ]]
      ;;
    32_dns_purification)
      [[ -n "$(get_state "NETWORK_DNS_PURIFIED" || true)" ]]
      ;;
    33_realm_timeout_fix)
      [[ -n "$(get_state "NETWORK_REALM_TIMEOUT_FIXED" || true)" ]]
      ;;
    34_ipv6_management)
      [[ -n "$(get_state "NETWORK_IPV6_MANAGED" || true)" ]]
      ;;
    35_network_tuning_all)
      [[ -n "$(get_state "NETWORK_TUNING_ALL_DONE" || true)" ]]
      ;;
    36_network_tuning_status)
      [[ -n "$(get_state "NETWORK_TUNING_STATUS_REVIEWED" || true)" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

nodequality_prerequisite_conditions_satisfied() {
  local tool=""
  local os_name=""

  if is_false "${ENABLE_NODEQUALITY:-true}"; then
    return 0
  fi

  [[ -r "${PROJECT_ROOT}/bootstrap.sh" ]] || return 1
  [[ -r "$(registry_file)" ]] || return 1

  for tool in awk sed grep cut mktemp getent uname; do
    command_exists "${tool}" || return 1
  done

  os_name="$(pretty_os_name 2>/dev/null || echo unknown)"
  [[ -n "${os_name}" && "${os_name}" != "unknown" ]]
}

detect_system_prerequisite_conditions_satisfied() {
  local detected_os=""
  local detected_version=""
  local pretty_name=""

  detected_os="$(os_id 2>/dev/null || echo unknown)"
  detected_version="$(os_version_id 2>/dev/null || echo unknown)"
  pretty_name="$(pretty_os_name 2>/dev/null || echo unknown)"

  [[ -n "${pretty_name}" && "${pretty_name}" != "unknown" ]] || return 1
  [[ -n "${detected_os}" && "${detected_os}" != "unknown" ]] || return 1
  [[ -n "${detected_version}" && "${detected_version}" != "unknown" ]] || return 1
  is_debian12
}

update_base_prerequisite_conditions_satisfied() {
  local pkg=""
  local tool=""
  local -a critical_packages=(
    ca-certificates
    curl
    sudo
    rsync
    git
    procps
  )
  local -a critical_tools=(
    apt-get
    dpkg
    useradd
    usermod
    install
    stat
    visudo
  )

  detect_system_prerequisite_conditions_satisfied || return 1

  for pkg in "${critical_packages[@]}"; do
    package_installed "${pkg}" || return 1
  done

  for tool in "${critical_tools[@]}"; do
    command_exists "${tool}" || return 1
  done

  return 0
}

admin_access_prerequisite_conditions_satisfied() {
  [[ -n "${ADMIN_USER:-}" ]] || return 1
  id -u "${ADMIN_USER}" >/dev/null 2>&1 || return 1
  admin_authorized_keys_ready_for_user "${ADMIN_USER}" || return 1
  command_exists sshd || return 1
  sshd -t >/dev/null 2>&1
}

ssh_port_change_prerequisite_conditions_satisfied() {
  command_exists sshd || return 1
  sshd -t >/dev/null 2>&1 || return 1
  current_ssh_port >/dev/null 2>&1
}

nftables_prerequisite_conditions_satisfied() {
  if is_false "${ENABLE_NFTABLES:-true}"; then
    return 0
  fi

  package_installed nftables || return 1
  [[ -f "$(nftables_config_path)" ]] || return 1
  service_enabled "nftables" || return 1
  service_active "nftables"
}

admin_cutover_prerequisite_conditions_satisfied() {
  root_ssh_login_disabled || return 1
  [[ -n "${ADMIN_USER:-}" ]] || return 1
  id -u "${ADMIN_USER}" >/dev/null 2>&1 || return 1
  admin_authorized_keys_ready_for_user "${ADMIN_USER}" || return 1
  command_exists sshd || return 1
  sshd -t >/dev/null 2>&1
}

time_sync_prerequisite_conditions_satisfied() {
  if is_false "${ENABLE_TIME_SYNC:-true}"; then
    return 0
  fi

  package_installed systemd-timesyncd || return 1
  service_enabled "systemd-timesyncd" || return 1
  service_active "systemd-timesyncd"
}

auto_updates_prerequisite_conditions_satisfied() {
  if is_false "${INSTALL_UNATTENDED_UPGRADES:-true}"; then
    return 0
  fi

  package_installed unattended-upgrades || return 1
  package_installed apt-listchanges || return 1
  [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] || return 1
  service_exists "unattended-upgrades" || return 1
  service_enabled "unattended-upgrades" || return 1
  service_active "unattended-upgrades"
}

fail2ban_prerequisite_conditions_satisfied() {
  if is_false "${INSTALL_FAIL2BAN:-true}"; then
    return 0
  fi

  package_installed fail2ban || return 1
  [[ -f /etc/fail2ban/jail.d/sshd.local ]] || return 1
  service_enabled "fail2ban" || return 1
  service_active "fail2ban"
}

swap_prerequisite_conditions_satisfied() {
  if has_active_swap; then
    return 0
  fi

  case "$(get_state "SWAP_STATUS" || true)" in
    skipped|disabled|existing|existing-kept|created-*|replaced-*|manual-review)
      return 0
      ;;
  esac

  [[ ! -e /swapfile ]]
}

verify_prerequisite_conditions_satisfied() {
  command_exists sshd || return 1
  sshd -t >/dev/null 2>&1 || return 1
  [[ -n "${ADMIN_USER:-}" ]] || return 0
  id -u "${ADMIN_USER}" >/dev/null 2>&1 || return 1
  return 0
}

maintain_update_prerequisite_conditions_satisfied() {
  detect_system_prerequisite_conditions_satisfied || return 1
  command_exists apt-get || return 1
  command_exists dpkg || return 1
  [[ -d /var/lib/apt/lists ]] || return 1
  return 0
}

network_xanmod_prerequisite_conditions_satisfied() {
  detect_system_prerequisite_conditions_satisfied || return 1
  command_exists apt-get || return 1
  command_exists dpkg || return 1
  command_exists gpg || return 1
  command_exists wget || return 1
  return 0
}

network_bbr_prerequisite_conditions_satisfied() {
  network_tuning_kernel_supports_bbr || return 1
  [[ -f "$(network_tuning_bbr_sysctl_file)" ]] || return 1
  return 0
}

network_dns_prerequisite_conditions_satisfied() {
  [[ -f "$(network_tuning_dns_dropin_path)" ]] || return 1
  [[ "$(network_tuning_dns_mode_label)" != "未启用" ]]
}

network_realm_prerequisite_conditions_satisfied() {
  local service_name=""
  local config_path=""

  service_name="$(network_tuning_realm_service_name || true)"
  config_path="$(network_tuning_realm_config_path || true)"
  [[ -n "${config_path}" && -f "${config_path}" ]] || return 1
  [[ -z "${service_name}" || "$(network_tuning_service_state "${service_name}")" == "active" ]]
}

network_ipv6_prerequisite_conditions_satisfied() {
  [[ "$(network_tuning_ipv6_state_label)" != "无法判定" ]]
}

network_status_prerequisite_conditions_satisfied() {
  command_exists uname || return 1
  command_exists sysctl || return 1
}

module_prerequisite_conditions_satisfied() {
  local module_id="${1:-}"

  case "${module_id}" in
    00_nodequality) nodequality_prerequisite_conditions_satisfied ;;
    01_detect_system) detect_system_prerequisite_conditions_satisfied ;;
    02_update_base) update_base_prerequisite_conditions_satisfied ;;
    025_change_ssh_port) ssh_port_change_prerequisite_conditions_satisfied ;;
    03_admin_access_stage) admin_access_prerequisite_conditions_satisfied ;;
    06_nftables) nftables_prerequisite_conditions_satisfied ;;
    07_switch_admin_login) admin_cutover_prerequisite_conditions_satisfied ;;
    07_time_sync) time_sync_prerequisite_conditions_satisfied ;;
    08_auto_updates) auto_updates_prerequisite_conditions_satisfied ;;
    09_fail2ban) fail2ban_prerequisite_conditions_satisfied ;;
    10_swap) swap_prerequisite_conditions_satisfied ;;
    11_verify) verify_prerequisite_conditions_satisfied ;;
    20_update_system) maintain_update_prerequisite_conditions_satisfied ;;
    30_xanmod_bbr3) network_xanmod_prerequisite_conditions_satisfied ;;
    31_bbr_landing_optimization) network_bbr_prerequisite_conditions_satisfied ;;
    32_dns_purification) network_dns_prerequisite_conditions_satisfied ;;
    33_realm_timeout_fix) network_realm_prerequisite_conditions_satisfied ;;
    34_ipv6_management) network_ipv6_prerequisite_conditions_satisfied ;;
    35_network_tuning_all) network_ipv6_prerequisite_conditions_satisfied ;;
    36_network_tuning_status) network_status_prerequisite_conditions_satisfied ;;
    *)
      return 1
      ;;
  esac
}

dependency_assessment_status() {
  local module_id="${1:-}"

  if dependency_token_is_placeholder "${module_id}"; then
    printf '%s\n' "completion_state_found"
    return 0
  fi

  if module_completion_state_found "${module_id}"; then
    printf '%s\n' "completion_state_found"
    return 0
  fi

  if module_prerequisite_conditions_satisfied "${module_id}"; then
    printf '%s\n' "state_missing_but_conditions_satisfied"
    return 0
  fi

  printf '%s\n' "prerequisite_conditions_not_satisfied"
}

registry_unique_dependencies() {
  local phase="${1:-}"

  registry_lines "${phase}" | awk -F '\t' '
    {
      deps = $8
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", deps)
      if (deps == "" || deps == "-" || deps == "无") {
        next
      }
      count = split(deps, items, ",")
      for (i = 1; i <= count; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", items[i])
        if (items[i] != "" && items[i] != "-" && items[i] != "无" && !seen[items[i]]++) {
          print items[i]
        }
      }
    }
  '
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

registry_find_line_by_phase_step() {
  local phase="${1:-}"
  local requested_step="${2:-}"

  require_registry_file
  awk -F '\t' -v phase="${phase}" -v step="${requested_step}" '
    NR == 1 { next }
    /^[[:space:]]*#/ { next }
    NF < 9 { next }
    $3 == phase && $1 == step {
      print $0
      exit
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
    network) echo "网络调优" ;;
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
  if dependency_token_is_placeholder "${value}"; then
    echo "无"
  else
    echo "${value}"
  fi
}

shell_trim_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "${value}"
}

dependency_token_is_placeholder() {
  local value=""
  value="$(shell_trim_value "${1:-}")"

  case "${value}" in
    ""|"-"|无|none|None|NONE|n/a|N/A)
      return 0
      ;;
  esac

  return 1
}

readonly_status_block() {
  local title="${1:-}"
  local current="${2:-}"
  local evidence="${3:-}"
  local passed="${4:-}"

  cat <<EOF
[${title}]
当前状态：${current}
依据：${evidence}
是否通过：${passed}

EOF
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

sshd_main_config_path() {
  printf '/etc/ssh/sshd_config\n'
}

sshd_managed_begin_marker() {
  printf '# BEGIN VPS BOOTSTRAP MANAGED SSH SETTINGS\n'
}

sshd_managed_end_marker() {
  printf '# END VPS BOOTSTRAP MANAGED SSH SETTINGS\n'
}

sshd_legacy_dropin_paths() {
  printf '%s\n' "/etc/ssh/sshd_config.d/99-vps-bootstrap.conf"
  printf '%s\n' "/etc/ssh/sshd_config.d/999-vps-root-login-cutover.conf"
}

sshd_managed_directive_names() {
  cat <<'EOF'
Port
PubkeyAuthentication
PasswordAuthentication
KbdInteractiveAuthentication
PermitRootLogin
EOF
}

sshd_build_managed_settings_block() {
  local port="${1:-22}"
  local pubkey_auth="${2:-yes}"
  local password_auth="${3:-yes}"
  local kbd_auth="${4:-no}"
  local permit_root_login="${5:-yes}"

  cat <<EOF
# Managed by VPS bootstrap project.
Port ${port}
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
}

sshd_strip_managed_directives_from_file() {
  local target="${1:-}"
  local tmp_file=""
  local directives_file=""

  [[ -n "${target}" && -f "${target}" ]] || return 0

  tmp_file="$(mktemp)"
  directives_file="$(mktemp)"
  sshd_managed_directive_names >"${directives_file}"

  awk \
    -v begin_marker="$(sshd_managed_begin_marker)" \
    -v end_marker="$(sshd_managed_end_marker)" \
    -v directives_file="${directives_file}" '
      BEGIN {
        while ((getline directive < directives_file) > 0) {
          managed[tolower(directive)] = 1
        }
        close(directives_file)
      }
      index($0, begin_marker) {
        in_block = 1
        next
      }
      in_block {
        if (index($0, end_marker)) {
          in_block = 0
        }
        next
      }
      /^[[:space:]]*#/ {
        print
        next
      }
      {
        if (tolower($1) == "match") {
          in_match = 1
          print
          next
        }
        if (in_match) {
          print
          next
        }
        key = tolower($1)
        if (key in managed) {
          next
        }
        print
      }
    ' "${target}" >"${tmp_file}"

  rm -f "${directives_file}"
  replace_file_with_tmp_if_changed "${target}" "${tmp_file}" "true"
}

sshd_strip_managed_directives_from_all_sources() {
  local file=""

  while IFS= read -r file; do
    [[ -n "${file}" && -f "${file}" ]] || continue
    sshd_strip_managed_directives_from_file "${file}"
  done < <(sshd_config_source_files)
}

sshd_apply_managed_settings() {
  local port="${1:-22}"
  local pubkey_auth="${2:-yes}"
  local password_auth="${3:-yes}"
  local kbd_auth="${4:-no}"
  local permit_root_login="${5:-yes}"
  local legacy_dropin=""
  local target=""
  local block_content=""

  target="$(sshd_main_config_path)"
  block_content="$(sshd_build_managed_settings_block "${port}" "${pubkey_auth}" "${password_auth}" "${kbd_auth}" "${permit_root_login}")"

  if [[ ! -f "${target}" ]]; then
    die "sshd 主配置不存在：${target}"
  fi

  while IFS= read -r legacy_dropin; do
    [[ -n "${legacy_dropin}" ]] || continue
    remove_file_if_exists "${legacy_dropin}"
  done < <(sshd_legacy_dropin_paths)

  sshd_strip_managed_directives_from_all_sources

  replace_managed_block_in_file \
    "${target}" \
    "$(sshd_managed_begin_marker)" \
    "$(sshd_managed_end_marker)" \
    "${block_content}" \
    "true"
}

sshd_config_source_files() {
  local dropin=""

  for dropin in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "${dropin}" ]] || continue
    printf '%s\n' "${dropin}"
  done | awk '!seen[$0]++'
  printf '%s\n' "$(sshd_main_config_path)"
}

sshd_directive_source_lines() {
  local directive="${1:-}"
  local file=""
  local normalized=""

  [[ -n "${directive}" ]] || return 1
  normalized="$(printf '%s\n' "${directive}" | tr '[:upper:]' '[:lower:]')"

  while IFS= read -r file; do
    [[ -r "${file}" ]] || continue
    awk -v file="${file}" -v normalized="${normalized}" '
      /^[[:space:]]*#/ { next }
      {
        key = tolower($1)
        if (key == normalized) {
          print file ":" NR ": " $0
        }
      }
    ' "${file}"
  done < <(sshd_config_source_files)
}

sshd_last_directive_source_line() {
  local directive="${1:-}"
  local last_line=""

  while IFS= read -r last_line; do
    [[ -n "${last_line}" ]] || continue
  done < <(sshd_directive_source_lines "${directive}" || true)

  [[ -n "${last_line}" ]] && printf '%s\n' "${last_line}"
}

current_permit_root_login_mode() {
  local mode=""
  mode="$(sshd_effective_value "permitrootlogin" "$(sshd_effective_config || true)")"
  printf '%s\n' "${mode:-unknown}"
}

root_ssh_login_disabled() {
  [[ "$(current_permit_root_login_mode)" == "no" ]]
}

sshd_effective_config() {
  command_exists sshd || return 1
  sshd -T 2>/dev/null
}

sshd_effective_value() {
  local key="${1:-}"
  local sshd_output="${2:-}"

  if [[ -z "${sshd_output}" ]]; then
    sshd_output="$(sshd_effective_config || true)"
  fi

  printf '%s\n' "${sshd_output}" | awk -v key="${key}" '$1 == key { print $2; exit }'
}

current_password_authentication_mode() {
  sshd_effective_value "passwordauthentication" "$(sshd_effective_config || true)"
}

current_pubkey_authentication_mode() {
  sshd_effective_value "pubkeyauthentication" "$(sshd_effective_config || true)"
}

current_kbdinteractive_authentication_mode() {
  sshd_effective_value "kbdinteractiveauthentication" "$(sshd_effective_config || true)"
}

ssh_last_successful_auth_line_from_auth_log() {
  local user="${1:-${ADMIN_USER:-}}"
  [[ -n "${user}" && -r /var/log/auth.log ]] || return 1

  grep -E 'Accepted (publickey|password|keyboard-interactive/pam)' /var/log/auth.log 2>/dev/null \
    | grep -F " for ${user} " \
    | tail -n 1
}

ssh_last_successful_auth_line_from_journal() {
  local user="${1:-${ADMIN_USER:-}}"
  [[ -n "${user}" ]] || return 1
  command_exists journalctl || return 1

  journalctl --no-pager -n 4000 -o cat -u ssh -u ssh.service -u sshd -u sshd.service 2>/dev/null \
    | grep -E 'Accepted (publickey|password|keyboard-interactive/pam)' \
    | grep -F " for ${user} " \
    | tail -n 1
}

last_successful_ssh_auth_line_for_user() {
  local user="${1:-${ADMIN_USER:-}}"
  local line=""

  line="$(ssh_last_successful_auth_line_from_journal "${user}" || true)"
  if [[ -n "${line}" ]]; then
    printf '%s\n' "${line}"
    return 0
  fi

  line="$(ssh_last_successful_auth_line_from_auth_log "${user}" || true)"
  if [[ -n "${line}" ]]; then
    printf '%s\n' "${line}"
    return 0
  fi

  return 1
}

last_successful_ssh_auth_method_for_user() {
  local user="${1:-${ADMIN_USER:-}}"
  local line=""

  line="$(last_successful_ssh_auth_line_for_user "${user}" || true)"
  case "${line}" in
    *"Accepted publickey for "*)
      printf '%s\n' "publickey"
      ;;
    *"Accepted password for "*)
      printf '%s\n' "password"
      ;;
    *"Accepted keyboard-interactive/pam for "*)
      printf '%s\n' "keyboard-interactive/pam"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

ssh_force_publickey_test_command() {
  local user="${1:-${ADMIN_USER:-<ADMIN_USER>}}"
  local port="${2:-$(effective_ssh_port_for_changes)}"
  printf 'ssh -p %s -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes -o PasswordAuthentication=no -i ~/.ssh/id_ed25519 %s@server\n' "${port}" "${user}"
}

ssh_force_password_test_command() {
  local user="${1:-${ADMIN_USER:-<ADMIN_USER>}}"
  local port="${2:-$(effective_ssh_port_for_changes)}"
  printf 'ssh -p %s -o PreferredAuthentications=password -o PubkeyAuthentication=no -o PasswordAuthentication=yes %s@server\n' "${port}" "${user}"
}

warn_ssh_port_change_not_confirmed() {
  local current_port=""
  current_port="$(current_ssh_port 2>/dev/null || true)"
  current_port="${current_port:-22}"
  log warn "Requested SSH_PORT=${SSH_PORT}, but CONFIRM_SSH_PORT_CHANGE is not enabled."
  log warn "For safety, SSH hardening and nftables will keep using the current port ${current_port}."
  log warn "After confirming cloud firewall/security-group and external access are ready, run the SSH port change step or set CONFIRM_SSH_PORT_CHANGE=\"true\" before rerunning the admin-access and nftables steps."
}

nftables_config_path() {
  printf '/etc/nftables.conf\n'
}

nftables_extra_ports_begin_marker() {
  printf '# BEGIN VPS EXTRA TCP PORTS\n'
}

nftables_extra_ports_end_marker() {
  printf '# END VPS EXTRA TCP PORTS\n'
}

normalize_numeric_port_list() {
  printf '%s\n' "$@" | awk '
    /^[0-9]+$/ {
      if (!seen[$0]++) {
        print $0
      }
    }
  ' | sort -n
}

render_nftables_extra_port_lines() {
  local port=""
  for port in "$@"; do
    printf '    tcp dport %s accept comment "VPS extra port"\n' "${port}"
  done
}

nftables_list_managed_extra_tcp_ports() {
  local file=""
  local begin_marker=""
  local end_marker=""

  file="$(nftables_config_path)"
  begin_marker="$(nftables_extra_ports_begin_marker)"
  end_marker="$(nftables_extra_ports_end_marker)"

  [[ -f "${file}" ]] || return 0

  awk -v begin_marker="${begin_marker}" -v end_marker="${end_marker}" '
    index($0, begin_marker) { in_block = 1; next }
    index($0, end_marker) { in_block = 0; next }
    in_block {
      if (match($0, /tcp dport ([0-9]+)/, matched)) {
        print matched[1]
      }
    }
  ' "${file}" | sort -n | uniq
}

nftables_ensure_extra_ports_block() {
  local file=""
  local begin_marker=""
  local end_marker=""
  local tmp_file=""

  file="$(nftables_config_path)"
  begin_marker="$(nftables_extra_ports_begin_marker)"
  end_marker="$(nftables_extra_ports_end_marker)"

  [[ -f "${file}" ]] || die "nftables 配置不存在：${file}。请先完成初始化中的 nftables 步骤。"

  if grep -Fq "${begin_marker}" "${file}" && grep -Fq "${end_marker}" "${file}"; then
    return 0
  fi

  tmp_file="$(mktemp)"
  awk -v begin_marker="${begin_marker}" -v end_marker="${end_marker}" '
    /chain input[[:space:]]*\{/ { in_input = 1 }
    in_input && /^[[:space:]]*}$/ && !inserted {
      print "    " begin_marker
      print "    " end_marker
      inserted = 1
      in_input = 0
    }
    { print }
    END {
      if (!inserted) {
        exit 1
      }
    }
  ' "${file}" >"${tmp_file}" || {
    rm -f "${tmp_file}"
    die "无法在 ${file} 中插入受控端口块，请先检查当前 nftables 配置格式。"
  }

  replace_file_with_tmp_if_changed "${file}" "${tmp_file}" "true"
}

nftables_write_managed_extra_tcp_ports() {
  local file=""
  local begin_marker=""
  local end_marker=""
  local tmp_file=""
  local block_file=""
  local normalized_ports=()

  file="$(nftables_config_path)"
  begin_marker="$(nftables_extra_ports_begin_marker)"
  end_marker="$(nftables_extra_ports_end_marker)"

  nftables_ensure_extra_ports_block

  if (($# > 0)); then
    mapfile -t normalized_ports < <(normalize_numeric_port_list "$@")
  fi

  tmp_file="$(mktemp)"
  block_file="$(mktemp)"
  if ((${#normalized_ports[@]} > 0)); then
    render_nftables_extra_port_lines "${normalized_ports[@]}" >"${block_file}"
  else
    : >"${block_file}"
  fi

  awk -v begin_marker="${begin_marker}" -v end_marker="${end_marker}" -v block_file="${block_file}" '
    {
      if (index($0, begin_marker)) {
        print
        while ((getline line < block_file) > 0) {
          print line
        }
        in_block = 1
        next
      }
      if (in_block) {
        if (index($0, end_marker)) {
          print
          in_block = 0
        }
        next
      }
      print
    }
  ' "${file}" >"${tmp_file}"

  rm -f "${block_file}"
  replace_file_with_tmp_if_changed "${file}" "${tmp_file}" "true"
}

nftables_reload_and_validate() {
  local file=""
  file="$(nftables_config_path)"

  [[ -f "${file}" ]] || die "nftables 配置不存在：${file}。"

  require_root
  require_debian12
  apt_install_packages nftables
  run_cmd "Checking nftables syntax" nft -c -f "${file}"
  enable_and_start_service "nftables"
  run_cmd "Loading nftables rules" nft -f "${file}"
}

nftables_open_tcp_ports() {
  local existing_ports=()
  local requested_ports=()
  local merged_ports=()

  mapfile -t existing_ports < <(nftables_list_managed_extra_tcp_ports)
  mapfile -t requested_ports < <(normalize_numeric_port_list "$@")
  mapfile -t merged_ports < <(normalize_numeric_port_list "${existing_ports[@]}" "${requested_ports[@]}")

  nftables_write_managed_extra_tcp_ports "${merged_ports[@]}"
  nftables_reload_and_validate
}

nftables_close_tcp_ports() {
  local existing_ports=()
  local requested_ports=()
  local remaining_ports=()
  local port=""

  mapfile -t existing_ports < <(nftables_list_managed_extra_tcp_ports)
  mapfile -t requested_ports < <(normalize_numeric_port_list "$@")

  for port in "${existing_ports[@]}"; do
    if ! selection_contains "${port}" "${requested_ports[@]}"; then
      remaining_ports+=("${port}")
    fi
  done

  nftables_write_managed_extra_tcp_ports "${remaining_ports[@]}"
  nftables_reload_and_validate
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

network_tuning_state_root() {
  printf '/var/lib/vps-network-tuning\n'
}

network_tuning_bbr_sysctl_file() {
  printf '/etc/sysctl.d/90-vps-network-bbr.conf\n'
}

network_tuning_fq_service_name() {
  printf 'vps-network-fq\n'
}

network_tuning_fq_service_path() {
  printf '/etc/systemd/system/%s.service\n' "$(network_tuning_fq_service_name)"
}

network_tuning_fq_script_path() {
  printf '/usr/local/lib/vps-network-tuning/apply-fq.sh\n'
}

network_tuning_dns_dropin_path() {
  printf '/etc/systemd/resolved.conf.d/90-vps-network-dns.conf\n'
}

network_tuning_ipv6_sysctl_file() {
  printf '/etc/sysctl.d/90-vps-network-ipv6.conf\n'
}

network_tuning_current_kernel() {
  uname -r 2>/dev/null || printf 'unknown\n'
}

network_tuning_kernel_is_xanmod() {
  network_tuning_current_kernel | grep -qi 'xanmod'
}

network_tuning_cpu_flags() {
  awk -F: '/^flags[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo 2>/dev/null
}

network_tuning_cpu_has_all_flags() {
  local flags=""
  local required=""

  flags=" $(network_tuning_cpu_flags) "
  for required in "$@"; do
    [[ "${flags}" == *" ${required} "* ]] || return 1
  done
  return 0
}

network_tuning_xanmod_level() {
  local arch=""

  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  [[ "${arch}" == "amd64" || "${arch}" == "x86_64" ]] || return 1

  if network_tuning_cpu_has_all_flags avx avx2 bmi1 bmi2 f16c fma movbe xsave abm; then
    printf '%s\n' "x64v3"
    return 0
  fi

  printf '%s\n' "x64v2"
}

network_tuning_xanmod_preferred_packages() {
  local arch=""
  local level=""

  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  case "${arch}" in
    amd64|x86_64)
      level="$(network_tuning_xanmod_level || true)"
      if [[ "${level}" == "x64v3" ]]; then
        printf '%s\n' \
          linux-xanmod-x64v3 \
          linux-xanmod-lts-x64v3 \
          linux-xanmod-x64v2 \
          linux-xanmod-lts-x64v2 \
          linux-xanmod-x64v1 \
          linux-xanmod-lts-x64v1
      else
        printf '%s\n' \
          linux-xanmod-x64v2 \
          linux-xanmod-lts-x64v2 \
          linux-xanmod-x64v1 \
          linux-xanmod-lts-x64v1
      fi
      ;;
    arm64|aarch64)
      printf '%s\n' \
        linux-xanmod-arm64 \
        linux-xanmod-lts-arm64
      ;;
    *)
      return 1
      ;;
  esac
}

network_tuning_xanmod_available_packages() {
  command_exists apt-cache || return 1
  apt-cache pkgnames 2>/dev/null | grep '^linux-xanmod-' | awk 'NF && !seen[$0]++'
}

network_tuning_xanmod_matching_packages() {
  local candidate=""
  local -a available=()
  local -a matched=()

  mapfile -t available < <(network_tuning_xanmod_available_packages || true)
  ((${#available[@]} > 0)) || return 1

  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    selection_contains "${candidate}" "${available[@]}" || continue
    matched+=("${candidate}")
  done < <(network_tuning_xanmod_preferred_packages || true)

  ((${#matched[@]} > 0)) || return 1
  printf '%s\n' "${matched[@]}"
}

network_tuning_select_xanmod_package_from_repo() {
  local selected=""
  selected="$(network_tuning_xanmod_matching_packages 2>/dev/null | head -n 1 || true)"
  [[ -n "${selected}" ]] || return 1
  printf '%s\n' "${selected}"
}

network_tuning_xanmod_package_name() {
  local selected=""
  selected="$(network_tuning_select_xanmod_package_from_repo || true)"
  [[ -n "${selected}" ]] || return 1
  printf '%s\n' "${selected}"
}

network_tuning_xanmod_repo_keyring_path() {
  printf '/etc/apt/keyrings/xanmod-archive-keyring.gpg\n'
}

network_tuning_xanmod_repo_list_path() {
  printf '/etc/apt/sources.list.d/xanmod-release.list\n'
}

network_tuning_distribution_codename() {
  local codename=""

  codename="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")"
  if [[ -n "${codename}" ]]; then
    printf '%s\n' "${codename}"
    return 0
  fi

  if command_exists lsb_release; then
    codename="$(lsb_release -sc 2>/dev/null || true)"
    [[ -n "${codename}" ]] && printf '%s\n' "${codename}"
  fi
}

network_tuning_xanmod_repo_line() {
  local codename=""
  codename="$(network_tuning_distribution_codename)"
  [[ -n "${codename}" ]] || die "Unable to determine distribution codename for XanMod repository."
  printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' "$(network_tuning_xanmod_repo_keyring_path)" "${codename}"
}

network_tuning_tcp_available_congestion_control() {
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || printf 'unknown\n'
}

network_tuning_tcp_congestion_control() {
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || printf 'unknown\n'
}

network_tuning_default_qdisc() {
  sysctl -n net.core.default_qdisc 2>/dev/null || cat /proc/sys/net/core/default_qdisc 2>/dev/null || printf 'unknown\n'
}

network_tuning_sysctl_value() {
  local key="${1:-}"
  [[ -n "${key}" ]] || return 1
  sysctl -n "${key}" 2>/dev/null || printf 'unknown\n'
}

network_tuning_kernel_supports_bbr() {
  printf '%s\n' "$(network_tuning_tcp_available_congestion_control)" | grep -qw 'bbr'
}

network_tuning_kernel_supports_bbr3() {
  network_tuning_kernel_is_xanmod && network_tuning_kernel_supports_bbr
}

network_tuning_highest_installed_xanmod_kernel() {
  local image=""

  for image in /boot/vmlinuz-*xanmod*; do
    [[ -e "${image}" ]] || continue
    basename "${image}" | sed 's/^vmlinuz-//'
  done | sort -V | tail -n 1
}

network_tuning_reboot_required_for_xanmod() {
  local installed=""
  local current=""

  installed="$(network_tuning_highest_installed_xanmod_kernel || true)"
  current="$(network_tuning_current_kernel)"
  [[ -n "${installed}" && "${installed}" != "${current}" ]]
}

network_tuning_default_route_interfaces() {
  ip route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i+1)}' | awk 'NF && !seen[$0]++'
}

network_tuning_tc_qdisc_summary() {
  tc qdisc show 2>/dev/null || printf 'unavailable\n'
}

network_tuning_service_state() {
  local service_name="${1:-}"
  [[ -n "${service_name}" ]] || return 1
  systemctl is-active "${service_name}" 2>/dev/null || printf 'unknown\n'
}

network_tuning_service_enabled_state() {
  local service_name="${1:-}"
  [[ -n "${service_name}" ]] || return 1
  systemctl is-enabled "${service_name}" 2>/dev/null || printf 'unknown\n'
}

network_tuning_resolved_stack_type() {
  local resolv_target=""

  if [[ -L /etc/resolv.conf ]]; then
    resolv_target="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
    case "${resolv_target}" in
      /run/systemd/resolve/*)
        printf '%s\n' "systemd-resolved"
        return 0
        ;;
      /run/NetworkManager/*|/run/resolvconf/*)
        printf '%s\n' "external-manager"
        return 0
        ;;
    esac
  fi

  if service_exists "systemd-resolved" || command_exists resolvectl; then
    printf '%s\n' "systemd-resolved"
    return 0
  fi

  if [[ -f /etc/resolv.conf ]]; then
    printf '%s\n' "static-resolv.conf"
    return 0
  fi

  printf '%s\n' "unknown"
}

network_tuning_dns_current_servers() {
  local stack=""

  stack="$(network_tuning_resolved_stack_type)"
  case "${stack}" in
    systemd-resolved)
      if command_exists resolvectl; then
        resolvectl dns 2>/dev/null | awk '
          {
            for (i = 2; i <= NF; i++) {
              if (!seen[$i]++) {
                values[count++] = $i
              }
            }
          }
          END {
            if (count == 0) {
              print "unknown"
            } else {
              for (i = 0; i < count; i++) {
                printf "%s%s", values[i], (i + 1 < count ? " " : "\n")
              }
            }
          }
        '
        return 0
      fi
      ;;
    static-resolv.conf|external-manager)
      awk '/^nameserver / {print $2}' /etc/resolv.conf 2>/dev/null | awk '!seen[$0]++' | paste -sd ' ' - || printf 'unknown\n'
      return 0
      ;;
  esac

  printf '%s\n' "unknown"
}

network_tuning_dns_dot_state() {
  if [[ -f "$(network_tuning_dns_dropin_path)" ]]; then
    awk -F= '
      tolower($1) ~ /^[[:space:]]*dnsovertls[[:space:]]*$/ {
        value = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        found = 1
        exit
      }
      END {
        if (!found) {
          print "unknown"
        }
      }
    ' "$(network_tuning_dns_dropin_path)" 2>/dev/null
    return 0
  fi

  printf '%s\n' "unknown"
}

network_tuning_dns_mode_label() {
  local servers=""
  local dot_state=""

  servers="$(network_tuning_dns_current_servers)"
  dot_state="$(network_tuning_dns_dot_state)"

  if [[ -f "$(network_tuning_dns_dropin_path)" ]]; then
    if printf '%s\n' "${servers}" | grep -Eq '8\.8\.8\.8|1\.1\.1\.1|8\.8\.4\.4|1\.0\.0\.1'; then
      printf '%s\n' "国外"
      return 0
    fi
    if printf '%s\n' "${servers}" | grep -Eq '223\.5\.5\.5|119\.29\.29\.29|223\.6\.6\.6|182\.254\.116\.116'; then
      printf '%s\n' "国内"
      return 0
    fi
  fi

  if [[ "${dot_state}" == "yes" || "${dot_state}" == "opportunistic" ]]; then
    printf '%s\n' "国外"
    return 0
  fi

  if [[ "${servers}" == "unknown" ]]; then
    printf '%s\n' "无法判定"
    return 0
  fi

  printf '%s\n' "未启用"
}

network_tuning_ipv6_disable_all() {
  network_tuning_sysctl_value net.ipv6.conf.all.disable_ipv6
}

network_tuning_ipv6_disable_default() {
  network_tuning_sysctl_value net.ipv6.conf.default.disable_ipv6
}

network_tuning_ipv6_disable_lo() {
  network_tuning_sysctl_value net.ipv6.conf.lo.disable_ipv6
}

network_tuning_ipv6_state_label() {
  local all_value=""
  local default_value=""
  local lo_value=""

  all_value="$(network_tuning_ipv6_disable_all)"
  default_value="$(network_tuning_ipv6_disable_default)"
  lo_value="$(network_tuning_ipv6_disable_lo)"

  if [[ -f "$(network_tuning_ipv6_sysctl_file)" ]] && [[ "${all_value}" == "1" && "${default_value}" == "1" ]]; then
    printf '%s\n' "永久禁用"
    return 0
  fi

  if [[ ! -f "$(network_tuning_ipv6_sysctl_file)" ]] && [[ "${all_value}" == "1" || "${default_value}" == "1" || "${lo_value}" == "1" ]]; then
    printf '%s\n' "临时禁用"
    return 0
  fi

  if [[ "${all_value}" == "0" && "${default_value}" == "0" && "${lo_value}" == "0" ]]; then
    printf '%s\n' "恢复"
    return 0
  fi

  printf '%s\n' "无法判定"
}

network_tuning_realm_service_name() {
  local unit=""

  if service_exists "realm"; then
    printf '%s\n' "realm"
    return 0
  fi

  unit="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^realm(@.*)?\.service$/ {sub(/\.service$/, "", $1); print $1; exit}')"
  [[ -n "${unit}" ]] && printf '%s\n' "${unit}"
}

network_tuning_realm_execstart() {
  local service_name="${1:-}"
  [[ -n "${service_name}" ]] || service_name="$(network_tuning_realm_service_name || true)"
  [[ -n "${service_name}" ]] || return 1

  systemctl cat "${service_name}" 2>/dev/null | awk '
    /^ExecStart=/ {
      line = $0
    }
    END {
      if (line != "") {
        print line
      }
    }
  '
}

network_tuning_realm_config_path() {
  local execstart=""
  local path=""

  execstart="$(network_tuning_realm_execstart || true)"
  path="$(printf '%s\n' "${execstart}" | sed -nE 's/.*(--config|-c)[[:space:]]+([^[:space:]]+).*/\2/p' | tail -n 1)"
  if [[ -n "${path}" ]]; then
    printf '%s\n' "${path}"
    return 0
  fi

  for path in /etc/realm/config.toml /etc/realm/config.json /opt/realm/config.toml /opt/realm/config.json /root/realm/config.toml /root/realm/config.json; do
    [[ -f "${path}" ]] && printf '%s\n' "${path}" && return 0
  done

  return 1
}

network_tuning_realm_config_format() {
  local file="${1:-}"
  [[ -n "${file}" ]] || file="$(network_tuning_realm_config_path || true)"

  case "${file}" in
    *.toml) printf '%s\n' "toml" ;;
    *.json) printf '%s\n' "json" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

network_tuning_snapshot_file() {
  local file="${1:-}"
  local snapshot_dir="${2:-}"
  local encoded_name=""

  [[ -n "${file}" && -n "${snapshot_dir}" ]] || die "network_tuning_snapshot_file requires source file and snapshot dir."

  encoded_name="$(printf '%s' "${file}" | sed 's#/#__#g')"
  install -d -m 0755 "${snapshot_dir}"
  if [[ -e "${file}" ]]; then
    cp -a "${file}" "${snapshot_dir}/${encoded_name}.bak"
  else
    : >"${snapshot_dir}/${encoded_name}.absent"
  fi
}

network_tuning_restore_file_snapshot() {
  local file="${1:-}"
  local snapshot_dir="${2:-}"
  local encoded_name=""
  local backup_file=""
  local absent_file=""

  [[ -n "${file}" && -n "${snapshot_dir}" ]] || die "network_tuning_restore_file_snapshot requires source file and snapshot dir."

  encoded_name="$(printf '%s' "${file}" | sed 's#/#__#g')"
  backup_file="${snapshot_dir}/${encoded_name}.bak"
  absent_file="${snapshot_dir}/${encoded_name}.absent"

  if [[ -f "${backup_file}" ]]; then
    install -d -m 0755 "$(dirname "${file}")"
    rm -rf "${file}"
    cp -a "${backup_file}" "${file}"
    return 0
  fi

  if [[ -f "${absent_file}" ]]; then
    rm -f "${file}"
  fi
}
