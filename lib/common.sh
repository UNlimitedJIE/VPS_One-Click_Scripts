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

set_default_config() {
  DEFAULT_ADMIN_USER="${DEFAULT_ADMIN_USER:-ops}"
  TIMEZONE="${TIMEZONE:-UTC}"
  SSH_PORT="${SSH_PORT:-22}"
  CONFIRM_SSH_PORT_CHANGE="${CONFIRM_SSH_PORT_CHANGE:-false}"
  ADMIN_USER="${ADMIN_USER:-${DEFAULT_ADMIN_USER}}"
  ADMIN_USER_SHELL="${ADMIN_USER_SHELL:-/bin/bash}"
  ADMIN_USER_GROUPS="${ADMIN_USER_GROUPS:-sudo}"
  ADMIN_SUDO_MODE_DEFAULT="${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}"
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
  STATE_DIR="${STATE_DIR:-${PROJECT_ROOT}/state}"
  LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs}"
  CHANGE_LOG_FILE="${CHANGE_LOG_FILE:-${STATE_DIR}/change-log.tsv}"
}

export_config() {
  export PROJECT_ROOT CONFIG_FILE CLI_CONFIG_FILE CLI_PLAN_ONLY CLI_DRY_RUN MODULE_REGISTRY_FILE STATE_DIR LOG_DIR CHANGE_LOG_FILE
  export DEFAULT_ADMIN_USER RUNTIME_ADMIN_USER_OVERRIDE
  export ACTIVE_CONFIG_CHAIN
  export TIMEZONE SSH_PORT CONFIRM_SSH_PORT_CHANGE
  export ADMIN_USER ADMIN_USER_SHELL ADMIN_USER_GROUPS ADMIN_SUDO_MODE_DEFAULT AUTHORIZED_KEYS_FILE
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
  printf '/root/bootstrap_authorized_keys\n'
}

shared_project_root() {
  printf '/opt/VPS_One-Click_Scripts\n'
}

project_root_requires_shared_copy() {
  [[ "${PROJECT_ROOT}" == "/root" || "${PROJECT_ROOT}" == /root/* ]]
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

admin_authorized_keys_ready_for_user() {
  local user="${1:-${ADMIN_USER:-}}"

  [[ -n "${user}" ]] || return 1
  id -u "${user}" >/dev/null 2>&1 || return 1
  [[ "$(admin_authorized_keys_count_for_user "${user}")" -gt 0 ]]
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

current_permit_root_login_mode() {
  local mode=""
  if command_exists sshd; then
    mode="$(sshd -T 2>/dev/null | awk '/^permitrootlogin / {print $2; exit}' || true)"
  fi
  printf '%s\n' "${mode:-unknown}"
}

root_ssh_login_disabled() {
  [[ "$(current_permit_root_login_mode)" == "no" ]]
}

warn_ssh_port_change_not_confirmed() {
  local current_port=""
  current_port="$(current_ssh_port 2>/dev/null || true)"
  current_port="${current_port:-22}"
  log warn "Requested SSH_PORT=${SSH_PORT}, but CONFIRM_SSH_PORT_CHANGE is not enabled."
  log warn "For safety, SSH hardening and nftables will keep using the current port ${current_port}."
  log warn "After confirming cloud firewall/security-group and external access are ready, set CONFIRM_SSH_PORT_CHANGE=\"true\" and rerun the merged admin-access stage plus the nftables step."
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
