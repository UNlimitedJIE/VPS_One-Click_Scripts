#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/ui.sh
source "${SCRIPT_DIR}/lib/ui.sh"

usage() {
  cat <<'EOF'
Usage:
  bash bootstrap.sh init [--config /path/to/conf] [--dry-run]
  bash bootstrap.sh maintain [--config /path/to/conf] [--dry-run]
  bash bootstrap.sh run <module_name> [--config /path/to/conf] [--dry-run]
  bash bootstrap.sh sync-runtime-copy [--dry-run]
  bash bootstrap.sh step <step_no[,step_no...]> [--config /path/to/conf] [--dry-run]
  bash bootstrap.sh stepseq <target_step_no> [--config /path/to/conf] [--dry-run]
  bash bootstrap.sh preflight [--config /path/to/conf]
  bash bootstrap.sh plan init|maintain|install-shortcut|sync-runtime-copy
  bash bootstrap.sh plan run <module_name>
  bash bootstrap.sh show init|maintain [--config /path/to/conf]
  bash bootstrap.sh menu [init|maintain] [--config /path/to/conf] [--dry-run]
  bash bootstrap.sh install-shortcut [--dry-run]

Menu shortcuts:
  Root menu: 0 = 退出程序
  Any submenu: 0 = 返回上一级菜单
  Init list menu: 99 = 从第 2 步开始顺序执行到指定步骤
  Maintain menu: 9 = 顺序执行 1 到 8
  Maintain menu: 10 = 谨慎操作子菜单

Menu purpose:
  menu = 快速直接执行
  show = 详细查看
  plan = 预演输出

Examples:
  bash bootstrap.sh show init
  bash bootstrap.sh menu init
  bash bootstrap.sh install-shortcut
  bash bootstrap.sh sync-runtime-copy
  bash bootstrap.sh plan init
  bash bootstrap.sh plan install-shortcut
  bash bootstrap.sh preflight --config config/local.conf
  bash bootstrap.sh step 2 --config config/local.conf
  bash bootstrap.sh step 2,3,4 --config config/local.conf
  bash bootstrap.sh stepseq 7 --config config/local.conf
  sudo bash bootstrap.sh init
  sudo bash bootstrap.sh run 05_ssh_hardening
EOF
}

parse_args() {
  CLI_CONFIG_FILE=""
  CLI_PLAN_ONLY=""
  CLI_DRY_RUN=""
  RUNTIME_INITIALIZED="false"

  local positionals=()
  while (($# > 0)); do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config requires a file path"
        CLI_CONFIG_FILE="$2"
        shift 2
        ;;
      --dry-run)
        CLI_DRY_RUN="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        positionals+=("$1")
        shift
        ;;
    esac
  done

  set -- "${positionals[@]}"
  [[ $# -ge 1 ]] || {
    usage
    exit 1
  }

  BOOTSTRAP_ACTION="$1"
  BOOTSTRAP_TARGET="${2:-}"
  BOOTSTRAP_TARGET_EXTRA="${3:-}"
}

prepare_context() {
  export CLI_CONFIG_FILE CLI_PLAN_ONLY CLI_DRY_RUN
  RUN_MODE="${RUN_MODE:-bootstrap}"
  load_config
  validate_config
}

prepare_shortcut_context() {
  export CLI_CONFIG_FILE CLI_PLAN_ONLY CLI_DRY_RUN
  RUN_MODE="${RUN_MODE:-bootstrap}"
  load_config
}

ensure_runtime_initialized() {
  if [[ "${RUNTIME_INITIALIZED}" == "true" ]]; then
    return 0
  fi

  init_runtime
  if [[ "${RUNTIME_STORAGE_MODE:-shared}" == "private" ]]; then
    log info "Runtime storage mode: private (state=${STATE_FILE}, log=${LOG_FILE})"
  else
    log info "Runtime storage mode: shared (state=${STATE_FILE}, log=${LOG_FILE})"
  fi
  trap cleanup_ephemeral_state EXIT
  RUNTIME_INITIALIZED="true"
}

resolve_module_path() {
  local requested="$1"
  local line=""
  line="$(registry_find_line "${requested}" || true)"
  if [[ -n "${line}" ]]; then
    registry_script_abspath_from_line "${line}"
    return 0
  fi

  local normalized="${requested%.sh}.sh"
  local candidate=""
  for candidate in \
    "${PROJECT_ROOT}/modules/${normalized}" \
    "${PROJECT_ROOT}/maintenance/${normalized}" \
    "${PROJECT_ROOT}/roles/${normalized}"
  do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

format_step_header() {
  local phase="$1"
  local step_no="$2"

  if [[ "${phase}" == "init" ]]; then
    printf '[第 %s 步]' "${step_no}"
  elif [[ "${phase}" == "maintain" && -n "${step_no}" && "${step_no}" != "-" ]]; then
    printf '[维护 %s]' "${step_no}"
  elif [[ "${phase}" == "cautious" && -n "${step_no}" && "${step_no}" != "-" ]]; then
    printf '[谨慎 %s]' "${step_no}"
  else
    printf '[%s]' "$(phase_label_zh "${phase}")"
  fi
}

print_module_overview() {
  local line="$1"
  local step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
  IFS=$'\t' read -r step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"

  cat <<EOF
$(format_step_header "${phase}" "${step_no}") ${title_zh} $(risk_badge_zh "${risk_level}")
说明：${detail_zh}
风险：$(risk_label_zh "${risk_level}")
默认执行：$(bool_label_zh "${default_enabled}")
依赖：$(optional_field_zh "${depends_on}")
脚本：${script_path}

EOF
}

print_plan_card() {
  local line="$1"
  local step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
  IFS=$'\t' read -r step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"

  cat <<EOF
$(format_step_header "${phase}" "${step_no}") ${title_zh} $(risk_badge_zh "${risk_level}")
作用：${short_desc_zh}
风险：$(risk_label_zh "${risk_level}")
脚本：${script_path}

EOF
}

show_phase_overview() {
  local phase="$1"
  if [[ "${phase}" == "maintain" ]]; then
    printf '%s\n' "$(render_phase_overview "maintain")"
    cat <<'EOF'
[维护 9] 顺序执行 1 到 8 【中风险】
说明：先展示长期维护 1 到 8 的执行清单，确认后再按顺序执行。
风险：中
默认执行：否
依赖：1 到 8
脚本：菜单快捷模式

[维护 10] 谨慎操作入口 【高风险】
说明：进入 10.1 到 10.10 的谨慎操作子菜单。这里的项目主要覆盖 UseDNS、Ciphers、ICMP/Ping 控制以及各类 sysctl / 网络参数调优项。
风险：高
默认执行：否
依赖：按具体子项而定
脚本：菜单子菜单

EOF
    printf '%s\n' "$(render_phase_overview "cautious")"
    return 0
  fi

  printf '%s\n' "$(render_phase_overview "${phase}")"
}

render_phase_overview() {
  local phase="$1"
  local line=""
  local output=""
  while IFS= read -r line; do
    output+=$(print_module_overview "${line}")
    output+=$'\n'
  done < <(registry_lines "${phase}")
  printf '%s' "${output}"
}

run_script_path() {
  local path="$1"
  local name
  name="$(basename "${path}")"
  log info "Running module: ${name}"
  bash "${path}"
}

run_module_from_registry_line() {
  local line="$1"
  local step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
  IFS=$'\t' read -r step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    print_plan_card "${line}"
  else
    print_module_overview "${line}"
  fi

  run_script_path "${PROJECT_ROOT}/${script_path}"
}

resolve_selection_token() {
  local phase="$1"
  local token="$2"
  local normalized=""
  normalized="$(basename "${token}")"
  normalized="${normalized%.sh}"

  local line=""
  local index=0
  local numeric_token=""
  numeric_token="$(printf '%s' "${normalized}" | sed 's/^0*//')"
  [[ -n "${numeric_token}" ]] || numeric_token="0"

  while IFS= read -r line; do
    index=$((index + 1))
    local step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
    IFS=$'\t' read -r step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"

    if [[ "${normalized}" == "${module_id}" ]]; then
      printf '%s\n' "${module_id}"
      return 0
    fi

    if [[ -n "${step_no}" && "${step_no}" =~ ^[0-9]+$ && "${numeric_token}" == "${step_no}" ]]; then
      printf '%s\n' "${module_id}"
      return 0
    fi

    if [[ "${phase}" == "maintain" && "${numeric_token}" == "${index}" ]]; then
      printf '%s\n' "${module_id}"
      return 0
    fi
  done < <(registry_lines "${phase}")

  return 1
}

normalize_selection_list_safe() {
  local phase="$1"
  shift || true
  local token="" module_id=""
  local normalized_ids=()

  for token in "$@"; do
    [[ -n "${token}" ]] || continue
    module_id="$(resolve_selection_token "${phase}" "${token}" || true)"
    [[ -n "${module_id}" ]] || return 1
    if ! selection_contains "${module_id}" "${normalized_ids[@]}"; then
      normalized_ids+=("${module_id}")
    fi
  done

  printf '%s\n' "${normalized_ids[@]}"
}

log_missing_dependency_notice() {
  local module_id="$1"
  local dependency="$2"
  local assessment=""

  assessment="$(dependency_assessment_status "${dependency}")"
  case "${assessment}" in
    completion_state_found)
      return 0
      ;;
    state_missing_but_conditions_satisfied)
      log info "Selected ${module_id}: dependency state for ${dependency} was not found, but prerequisite conditions appear satisfied."
      ;;
    *)
      log warn "Selected ${module_id} but missing dependency ${dependency}; prerequisite conditions are not satisfied, so you should confirm the risk before continuing."
      ;;
  esac
}

warn_missing_dependencies() {
  local phase="$1"
  shift || true
  local selected=("$@")
  local line=""

  while IFS= read -r line; do
    local step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
    IFS=$'\t' read -r step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
    selection_contains "${module_id}" "${selected[@]}" || continue
    [[ -n "${depends_on}" ]] || continue

    local dependency=""
    IFS=',' read -r -a dep_list <<<"${depends_on}"
    for dependency in "${dep_list[@]}"; do
      [[ -n "${dependency}" ]] || continue
      if ! selection_contains "${dependency}" "${selected[@]}"; then
        log_missing_dependency_notice "${module_id}" "${dependency}"
      fi
    done
  done < <(registry_lines "${phase}")
}

run_phase_from_registry() {
  local phase="$1"
  shift || true
  local cancel_mode="command"
  if (($# > 0)) && [[ "$1" == "menu" || "$1" == "command" ]]; then
    cancel_mode="$1"
    shift
  fi
  local selected=("$@")
  local line=""
  local module_id=""

  if ((${#selected[@]} > 0)); then
    warn_missing_dependencies "${phase}" "${selected[@]}"
    for module_id in "${selected[@]}"; do
      line="$(registry_find_line "${module_id}" || true)"
      [[ -n "${line}" ]] || die "Module not found in registry: ${module_id}"
      if ! is_true "${PLAN_ONLY:-false}" && registry_line_requires_admin_user "${line}"; then
        ensure_admin_user_for_execution "${cancel_mode}" || return 130
      fi
      run_module_from_registry_line "${line}"
    done
    return 0
  fi

  while IFS= read -r line; do
    if ! is_true "${PLAN_ONLY:-false}" && registry_line_requires_admin_user "${line}"; then
      ensure_admin_user_for_execution "${cancel_mode}" || return 130
    fi
    run_module_from_registry_line "${line}"
  done < <(registry_lines "${phase}")
}

split_menu_input_tokens() {
  local raw_input="$1"
  printf '%s\n' "${raw_input}" | tr ', ' '\n\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

display_number_for_module_id() {
  local phase="$1"
  local module_id="$2"

  local line=""
  line="$(registry_find_line "${module_id}" || true)"
  if [[ -n "${line}" ]]; then
    local step_no=""
    step_no="$(printf '%s\n' "${line}" | cut -f1)"
    if [[ -n "${step_no}" && "${step_no}" != "-" ]]; then
      printf '%s\n' "${step_no}"
      return 0
    fi
  fi

  local index=0
  while IFS= read -r line; do
    index=$((index + 1))
    if [[ "$(printf '%s\n' "${line}" | cut -f2)" == "${module_id}" ]]; then
      printf '%s\n' "${index}"
      return 0
    fi
  done < <(registry_lines "${phase}")

  return 1
}

render_execution_summary() {
  local phase="$1"
  shift || true
  local module_id="" line="" output=""
  local step_no entry_module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh

  for module_id in "$@"; do
    line="$(registry_find_line "${module_id}" || true)"
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r step_no entry_module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
    output+="$(display_number_for_module_id "${phase}" "${module_id}"). ${title_zh}"
    if [[ "${risk_level}" == "high" ]]; then
      output+=" 【高风险】"
    fi
    output+=$'\n'
    output+="   ${short_desc_zh}"$'\n'
  done

  printf '%s' "${output}"
}

init_module_requires_admin_user() {
  case "${1:-}" in
    03_admin_access_stage|03_admin_user|04_ssh_keys|05_ssh_hardening|07_switch_admin_login)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

init_selection_requires_admin_user() {
  local module_id=""
  for module_id in "$@"; do
    init_module_requires_admin_user "${module_id}" && return 0
  done
  return 1
}

registry_line_requires_admin_user() {
  local line="$1"
  local step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
  IFS=$'\t' read -r step_no module_id phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
  [[ "${phase}" == "init" ]] || return 1
  init_module_requires_admin_user "${module_id}"
}

module_path_requires_admin_user() {
  local path="$1"
  local module_name=""
  module_name="$(basename "${path}")"
  module_name="${module_name%.sh}"
  init_module_requires_admin_user "${module_name}"
}

prompt_admin_user_value() {
  local cancel_mode="${1:-command}"
  local cancel_hint=""
  local candidate=""
  local validation_error=""

  if [[ "${cancel_mode}" == "menu" ]]; then
    cancel_hint="输入 0 返回上一级菜单。"
  else
    cancel_hint="输入 0 取消当前操作。"
  fi

  while true; do
    if ! ui_prompt_input "管理用户名" "请输入要创建/使用的管理用户名（仅限字母、数字、下划线、短横线，且不能为 root）：\n${cancel_hint}"; then
      return 1
    fi

    candidate="$(ui_trim_value "${UI_LAST_INPUT}")"
    if [[ "${candidate}" == "0" ]]; then
      return 1
    fi

    validation_error="$(admin_user_validation_error "${candidate}")"
    if [[ -n "${validation_error}" ]]; then
      ui_warn_message "输入无效" "${validation_error}"
      continue
    fi

    printf '%s\n' "${candidate}"
    return 0
  done
}

prompt_admin_user_persist_choice() {
  local username="$1"
  local target_file=""
  local answer=""

  target_file="$(active_config_file_path)"

  while true; do
    if ! ui_prompt_input "保存管理用户名" "是否将该用户名写入 ${target_file} 作为后续默认值？\n请输入 yes 或 no：" "no"; then
      return 0
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      yes|YES|y|Y)
        upsert_config_assignment "${target_file}" "ADMIN_USER" "${username}"
        return 0
        ;;
      no|NO|n|N|""|0)
        return 0
        ;;
      *)
        ui_warn_message "输入无效" "请输入 yes 或 no；直接回车默认 no。"
        ;;
    esac
  done
}

ensure_admin_user_for_execution() {
  local cancel_mode="${1:-command}"
  local username=""
  local validation_error=""

  validation_error="$(admin_user_validation_error "${ADMIN_USER:-}")"
  if [[ -n "${ADMIN_USER:-}" && -z "${validation_error}" ]]; then
    return 0
  fi

  if ! ui_require_interactive; then
    die "当前 ADMIN_USER 为空或无效。请使用交互式终端输入管理用户名，或在配置文件中设置有效的 ADMIN_USER。"
  fi

  username="$(prompt_admin_user_value "${cancel_mode}" || true)"
  [[ -n "${username}" ]] || return 1

  set_runtime_admin_user "${username}"
  prompt_admin_user_persist_choice "${username}"
  return 0
}

menu_action_summary() {
  local phase="$1"
  shift || true
  local -a selected=("$@")
  local count="${#selected[@]}"

  if (( count == 0 )); then
    printf '%s\n' "$(phase_label_zh "${phase}")"
    return 0
  fi

  local first_line=""
  first_line="$(registry_find_line "${selected[0]}" || true)"
  [[ -n "${first_line}" ]] || {
    printf '%s\n' "$(phase_label_zh "${phase}")"
    return 0
  }

  local step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
  IFS=$'\t' read -r step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${first_line}"

  if (( count == 1 )); then
    case "${phase}" in
      init)
        printf '第 %s 步 %s\n' "${step_no}" "${title_zh}"
        ;;
      maintain)
        printf '%s %s\n' "${step_no}" "${title_zh}"
        ;;
      cautious)
        printf '%s %s\n' "${step_no}" "${title_zh}"
        ;;
      *)
        printf '%s\n' "${title_zh}"
        ;;
    esac
    return 0
  fi

  local numbers=""
  local selected_id="" selected_line="" selected_step=""
  for selected_id in "${selected[@]}"; do
    selected_line="$(registry_find_line "${selected_id}" || true)"
    [[ -n "${selected_line}" ]] || continue
    selected_step="$(printf '%s\n' "${selected_line}" | cut -f1)"
    [[ -n "${selected_step}" ]] || continue
    if [[ -n "${numbers}" ]]; then
      numbers+=","
    fi
    numbers+="${selected_step}"
  done

  case "${phase}" in
    init)
      printf '初始化 %s 项（%s）\n' "${count}" "${numbers}"
      ;;
    maintain)
      printf '长期维护 %s 项（%s）\n' "${count}" "${numbers}"
      ;;
    cautious)
      printf '谨慎操作 %s 项（%s）\n' "${count}" "${numbers}"
      ;;
    *)
      printf '%s %s 项\n' "$(phase_label_zh "${phase}")" "${count}"
      ;;
  esac
}

menu_show_action_result() {
  local result="$1"
  local summary="$2"
  local body=""

  case "${result}" in
    success)
      body="已完成：${summary}"
      ;;
    *)
      body=$'执行未完成：'"${summary}"$'\n请查看上方输出或日志，然后返回菜单继续操作。'
      ;;
  esac

  ui_print_raw $'\n'"${body}"$'\n'
  ui_wait_for_enter "按回车返回菜单：" || true
}

menu_execute_with_feedback() {
  local summary="$1"
  shift || true
  local status=0

  ensure_runtime_initialized

  set +e
  (
    set -e
    "$@"
  )
  status=$?
  set -e

  if (( status == 130 )); then
    return 0
  fi

  if (( status == 0 )); then
    menu_show_action_result "success" "${summary}"
    return 0
  fi

  menu_show_action_result "incomplete" "${summary}"
  return 1
}

shortcut_target_path() {
  printf '/usr/local/bin/j\n'
}

render_shortcut_wrapper() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

preferred_runtime_root() {
  printf '%s\n' "/opt/VPS_One-Click_Scripts"
}

project_copy_is_usable() {
  local path="${1:-}"
  [[ -n "${path}" && -d "${path}" && -x "${path}" && -f "${path}/bootstrap.sh" && -r "${path}/bootstrap.sh" ]]
}

list_project_roots() {
  local current_user=""
  local current_home=""
  local candidate=""
  local -a seen_paths=()

  current_user="$(id -un 2>/dev/null || true)"
  current_home="${HOME:-}"

  if [[ -z "${current_home}" && -n "${current_user}" ]]; then
    current_home="$(getent passwd "${current_user}" | cut -d: -f6)"
  fi

  for candidate in \
    "/opt/VPS_One-Click_Scripts" \
    "${current_home:+${current_home}/VPS_One-Click_Scripts}" \
    "/root/VPS_One-Click_Scripts"
  do
    [[ -n "${candidate}" ]] || continue
    if project_copy_is_usable "${candidate}"; then
      case " ${seen_paths[*]:-} " in
        *" ${candidate} "*) ;;
        *)
          seen_paths+=("${candidate}")
          printf '%s\n' "${candidate}"
          ;;
      esac
    fi
  done
}

resolve_project_root() {
  local candidate=""

  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    printf '%s\n' "${candidate}"
    return 0
  done < <(list_project_roots)

  return 1
}

PROJECT_ROOT="$(resolve_project_root || true)"
if [[ -z "${PROJECT_ROOT}" ]]; then
  printf '%s\n' "Unable to locate a readable VPS_One-Click_Scripts project directory." >&2
  exit 1
fi

printf '%s\n' "[j] Runtime project root: ${PROJECT_ROOT}" >&2
if [[ "${PROJECT_ROOT}" == "$(preferred_runtime_root)" ]]; then
  printf '%s\n' "[j] Preferred runtime directory is active. Future git/grep/code updates should be done in ${PROJECT_ROOT}." >&2
fi

mapfile -t PROJECT_COPIES < <(list_project_roots)
if ((${#PROJECT_COPIES[@]} > 1)); then
  printf '%s\n' "[j] Multiple project copies detected. Active runtime copy: ${PROJECT_ROOT}" >&2
  for candidate in "${PROJECT_COPIES[@]}"; do
    [[ "${candidate}" == "${PROJECT_ROOT}" ]] || printf '%s\n' "[j] Other project copy: ${candidate}" >&2
  done
  if [[ -d "/opt/VPS_One-Click_Scripts" && -d "/root/VPS_One-Click_Scripts" ]]; then
    printf '%s\n' "[j] Warning: update directory and runtime directory may diverge. Prefer maintaining only /opt/VPS_One-Click_Scripts." >&2
  fi
fi

cd "${PROJECT_ROOT}"

if [[ -r "${PROJECT_ROOT}/config/local.conf" ]]; then
  exec bash "${PROJECT_ROOT}/bootstrap.sh" menu --config "${PROJECT_ROOT}/config/local.conf" "$@"
fi

exec bash "${PROJECT_ROOT}/bootstrap.sh" menu "$@"
EOF
}

log_runtime_project_context() {
  local runtime_root=""
  local current_dir=""
  local copy=""
  local -a copies=()

  runtime_root="$(discover_runtime_project_root || true)"
  current_dir="$(pwd -P 2>/dev/null || pwd)"

  log info "Current PROJECT_ROOT: ${PROJECT_ROOT}"
  if [[ -n "${runtime_root}" ]]; then
    log info "Preferred runtime project root: ${runtime_root}"
  else
    log warn "No readable runtime project root was detected in /opt, \$HOME, or /root."
  fi

  if [[ -n "${runtime_root}" && "${PROJECT_ROOT}" != "${runtime_root}" ]]; then
    log warn "Current execution root differs from the preferred runtime root. Active runtime copy for j is ${runtime_root}."
  fi

  if [[ -n "${runtime_root}" && "${current_dir}" != "${runtime_root}" ]]; then
    log info "Current shell directory: ${current_dir}"
  fi

  mapfile -t copies < <(list_detected_project_copies)
  if ((${#copies[@]} > 1)); then
    log warn "Multiple project copies detected. Active runtime copy: ${runtime_root:-${PROJECT_ROOT}}"
    for copy in "${copies[@]}"; do
      [[ "${copy}" == "${runtime_root:-${PROJECT_ROOT}}" ]] || log warn "Other project copy: ${copy}"
    done
    if selection_contains "$(shared_project_root)" "${copies[@]}" && selection_contains "/root/VPS_One-Click_Scripts" "${copies[@]}"; then
      log warn "更新目录与运行目录可能不一致。建议只保留 /opt/VPS_One-Click_Scripts 作为长期运行和维护目录。"
    fi
  fi

  if [[ "${runtime_root:-}" == "$(shared_project_root)" ]]; then
    log info "Maintenance guidance: future git/grep/code edits should be done in $(shared_project_root)."
  fi
}

log_shortcut_runtime_guidance() {
  local runtime_root=""

  runtime_root="$(discover_runtime_project_root || true)"
  log info "Shortcut runtime priority: $(shared_project_root) > \$HOME/VPS_One-Click_Scripts > /root/VPS_One-Click_Scripts"
  if [[ -n "${runtime_root}" ]]; then
    log info "Current shortcut runtime root: ${runtime_root}"
  fi
  log info "If the system has switched to /opt runtime, future git/grep/code edits should be done in $(shared_project_root)."
}

install_shortcut() {
  local target=""
  local temp_file=""
  local wrapper_content=""

  target="$(shortcut_target_path)"
  temp_file="$(mktemp)"
  wrapper_content="$(render_shortcut_wrapper)"
  printf '%s\n' "${wrapper_content}" >"${temp_file}"

  if [[ -e "${target}" ]] && cmp -s "${temp_file}" "${target}"; then
    log info "Shortcut already installed: ${target}"
    log info "Shortcut will prefer config/local.conf when present."
    log_shortcut_runtime_guidance
    rm -f "${temp_file}"
    return 0
  fi

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    if [[ -e "${target}" ]]; then
      log info "[plan] shortcut target exists and would require overwrite confirmation: ${target}"
    else
      log info "[plan] shortcut would be installed: ${target}"
    fi
    printf '\n将写入 %s:\n\n%s\n' "${target}" "${wrapper_content}"
    rm -f "${temp_file}"
    return 0
  fi

  if [[ ! -e "${target}" && "${EUID}" -ne 0 ]]; then
    rm -f "${temp_file}"
    die "install-shortcut requires root to write ${target}. Use: sudo bash bootstrap.sh install-shortcut"
  fi

  if [[ -e "${target}" ]]; then
    if [[ "${EUID}" -ne 0 ]]; then
      rm -f "${temp_file}"
      die "install-shortcut requires root to overwrite ${target}. Use: sudo bash bootstrap.sh install-shortcut"
    fi

    log warn "Shortcut already exists: ${target}"
    if [[ "${SHORTCUT_FORCE_OVERWRITE:-false}" == "true" ]]; then
      log info "SHORTCUT_FORCE_OVERWRITE=true, shortcut will be overwritten without interactive confirmation."
    elif ! ui_require_interactive; then
      rm -f "${temp_file}"
      die "${target} already exists. Rerun in an interactive terminal to confirm overwrite, or remove it manually."
    elif ! ui_confirm_text "覆盖 j 命令" "${target} 已存在。\n\n输入 yes 覆盖；输入其他内容跳过安装。"; then
      log info "Skipped installing shortcut: ${target}"
      rm -f "${temp_file}"
      return 0
    fi
  fi

  install -d -m 0755 "$(dirname "${target}")"
  install -m 0755 "${temp_file}" "${target}"
  rm -f "${temp_file}"

  log info "Shortcut installed: ${target}"
  log info "Shortcut will prefer config/local.conf when present."
  log_shortcut_runtime_guidance
  log info "You can now run: j"
}

sync_runtime_copy() {
  local target_root=""
  target_root="$(shared_project_root)"

  if is_false "${PLAN_ONLY:-false}" && is_false "${DRY_RUN:-false}" && [[ "${EUID}" -ne 0 ]]; then
    die "sync-runtime-copy requires root to write ${target_root}. Use: sudo bash bootstrap.sh sync-runtime-copy"
  fi

  sync_project_tree_to_runtime_root "${PROJECT_ROOT}" "${target_root}"
  log info "Preferred runtime directory: ${target_root}"
  log info "Future git/grep/code updates should be done in ${target_root}."
}

max_init_step_number() {
  registry_lines "init" | awk -F '\t' '
    $1 ~ /^[0-9]+$/ && $1 > max { max = $1 }
    END { print max + 0 }
  '
}

build_phase_sequence_by_numeric_range() {
  local phase="$1"
  local range_start="$2"
  local range_end="$3"

  registry_lines "${phase}" | awk -F '\t' -v range_start="${range_start}" -v range_end="${range_end}" '
    $1 ~ /^[0-9]+$/ && $1 >= range_start && $1 <= range_end { print $2 }
  '
}

build_init_sequence_to_step() {
  local target_step="$1"
  build_phase_sequence_by_numeric_range "init" "2" "${target_step}"
}

resolve_init_step_selection() {
  local raw_selection="$1"
  local max_step=""
  local token=""
  local line=""
  local module_id=""
  local step_no=""
  local -a raw_tokens=()
  local -a normalized_ids=()
  RESOLVED_INIT_STEP_IDS=()

  max_step="$(max_init_step_number)"
  while IFS= read -r token; do
    raw_tokens+=("${token}")
  done < <(split_menu_input_tokens "${raw_selection}")
  ((${#raw_tokens[@]} > 0)) || die "step mode requires at least one init step number."

  for token in "${raw_tokens[@]}"; do
    [[ "${token}" =~ ^[0-9]+$ ]] || die "Invalid init step token: ${token}. Use numbers like 2 or 2,3,4."
    step_no=$((10#${token}))
    if (( step_no < 1 || step_no > max_step )); then
      die "Invalid init step number: ${step_no}. Valid init steps: 1-${max_step}."
    fi

    line="$(registry_find_line_by_phase_step "init" "${step_no}" || true)"
    [[ -n "${line}" ]] || die "Init step ${step_no} not found in registry."
    module_id="$(printf '%s\n' "${line}" | cut -f2)"
    if ((${#normalized_ids[@]} == 0)) || ! selection_contains "${module_id}" "${normalized_ids[@]}"; then
      normalized_ids+=("${module_id}")
    fi
  done

  if ((${#normalized_ids[@]} > 0)); then
    RESOLVED_INIT_STEP_IDS=("${normalized_ids[@]}")
  fi
}

render_execution_list_with_scripts() {
  local module_id=""
  local line=""
  local output=""
  local step_no entry_module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh

  for module_id in "$@"; do
    line="$(registry_find_line "${module_id}" || true)"
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r step_no entry_module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
    output+="第 ${step_no} 步: ${title_zh}"$'\n'
    output+="脚本: ${script_path}"$'\n'
    output+=$'\n'
  done

  printf '%s' "${output}"
}

confirm_terminal_yes() {
  local title="$1"
  local body="$2"
  local answer=""

  printf '\n%s\n\n%s\n' "${title}" "${body}"
  printf '继续执行请输入 yes：'
  read -r answer || return 1
  [[ "${answer}" == "yes" ]]
}

build_maintain_main_sequence() {
  build_phase_sequence_by_numeric_range "maintain" "1" "8"
}

render_init_menu_prompt() {
  local header=""
  local line=""
  local step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh

  while IFS= read -r line; do
    IFS=$'\t' read -r step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
    header+="${step_no}. ${title_zh}"
    if [[ "${risk_level}" == "high" ]]; then
      header+=" 【高风险】"
    fi
    header+=$'\n'
    header+="   ${short_desc_zh}"$'\n'
  done < <(registry_lines "init")

  header+=$'99. 从第 2 步开始顺序执行到指定步骤\n'
  header+=$'   从第 2 步起，按顺序执行到你指定的目标步骤。\n'
  header+=$'0. 返回上一级菜单\n\n'
  header+=$'输入规则：\n'
  header+=$'- 输入单个数字，例如 6，直接执行第 6 步\n'
  header+=$'- 输入多个数字，例如 2,3,4，按输入顺序执行这些步骤\n'
  header+=$'- 输入 99，进入“从第 2 步开始顺序执行到指定步骤”模式\n'

  printf '%s' "${header}"
}

render_maintain_menu_prompt() {
  local header=""
  local line=""
  local step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh

  while IFS= read -r line; do
    IFS=$'\t' read -r step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
    header+="${step_no}. ${title_zh}"
    if [[ "${risk_level}" == "high" ]]; then
      header+=" 【高风险】"
    fi
    header+=$'\n'
    header+="   ${short_desc_zh}"$'\n'
  done < <(registry_lines "maintain")

  header+=$'9. 顺序执行 1 到 8\n'
  header+=$'   先展示 1 到 8 的清单，确认后按顺序执行。\n'
  header+=$'10. 谨慎操作入口\n'
  header+=$'   进入 10.1 到 10.10 的谨慎操作子菜单。\n'
  header+=$'0. 返回上一级菜单\n\n'
  header+=$'输入规则：\n'
  header+=$'- 输入单个数字直接执行对应项目\n'
  header+=$'- 输入 3，进入端口管理子菜单；顺序执行时第 3 项只做查看，不进入子菜单\n'
  header+=$'- 输入多个数字，例如 1,2,3，按输入顺序执行这些项目\n'
  header+=$'- 输入 9，顺序执行 1 到 8\n'
  header+=$'- 输入 10，进入谨慎操作子菜单\n'

  printf '%s' "${header}"
}

render_cautious_menu_prompt() {
  local header=""
  local line=""
  local step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh

  while IFS= read -r line; do
    IFS=$'\t' read -r step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
    header+="${step_no} ${title_zh}"
    if [[ "${risk_level}" == "high" ]]; then
      header+=" 【高风险】"
    fi
    header+=$'\n'
    header+="   ${short_desc_zh}"$'\n'
  done < <(registry_lines "cautious")

  header+=$'0. 返回上一级菜单\n\n'
  header+=$'输入规则：\n'
  header+=$'- 输入单个数字，例如 2，执行 10.2\n'
  header+=$'- 也可以输入完整编号，例如 10.2\n'
  header+=$'- 可输入多个编号，例如 2,10 或 10.2,10.10\n'

  printf '%s' "${header}"
}

prompt_init_execution_input() {
  ui_prompt_input "初始化菜单" "$(render_init_menu_prompt)"
}

prompt_maintain_execution_input() {
  ui_prompt_input "长期维护菜单" "$(render_maintain_menu_prompt)"
}

prompt_cautious_execution_input() {
  ui_prompt_input "谨慎操作子菜单" "$(render_cautious_menu_prompt)"
}

split_port_input_tokens() {
  local raw_input="$1"
  printf '%s\n' "${raw_input}" | tr ', ' '\n\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

normalize_port_input_list_safe() {
  local raw_input="$1"
  local token=""
  local error_message=""
  local normalized_ports=()

  while IFS= read -r token; do
    [[ -n "${token}" ]] || continue
    error_message="$(port_validation_error_zh "${token}")"
    [[ -z "${error_message}" ]] || return 1
    normalized_ports+=("$((10#${token}))")
  done < <(split_port_input_tokens "${raw_input}")

  ((${#normalized_ports[@]} > 0)) || return 1
  normalize_numeric_port_list "${normalized_ports[@]}"
}

port_management_notice_text() {
  cat <<'EOF'
注意：
- 这里只会修改服务器内部的 nftables 规则
- 如果云厂商还有安全组/云防火墙，也必须去控制台同步放行或关闭
- 否则公网访问结果可能与本机规则不一致
EOF
}

render_port_management_prompt() {
  cat <<'EOF'
1. 查看当前监听端口与当前 nftables 规则
2. 开放一个端口
3. 关闭一个端口
4. 批量开放端口
5. 批量关闭端口
6. 重载并验证 nftables
0. 返回上一级菜单

输入规则：
- 输入 1 查看当前监听端口和 nftables 规则
- 输入 2/3 对单个端口做开放或关闭
- 输入 4/5 可输入多个端口，例如 80,443
- 所有开放/关闭动作都只修改本机 nftables，云厂商安全组/云防火墙也必须同步处理
EOF
}

prompt_port_management_input() {
  ui_prompt_input "端口管理子菜单" "$(render_port_management_prompt)"
}

run_port_management_overview() {
  printf '\n%s\n\n' "$(port_management_notice_text)"
  run_script_path "${PROJECT_ROOT}/maintenance/22_audit_firewall.sh"
}

prompt_port_list_for_management() {
  local title="$1"
  local prompt="$2"
  local allow_multiple="${3:-false}"
  local raw_input=""
  local ports=()

  while true; do
    if ! ui_prompt_input "${title}" "${prompt}\n0 = 返回上一级菜单"; then
      return 1
    fi

    raw_input="$(ui_trim_value "${UI_LAST_INPUT}")"
    if [[ "${raw_input}" == "0" ]]; then
      return 1
    fi

    if [[ -z "${raw_input}" ]]; then
      ui_warn_message "输入为空" "请输入端口号；多个端口可用逗号分隔。"
      continue
    fi

    mapfile -t ports < <(normalize_port_input_list_safe "${raw_input}" || true)
    ((${#ports[@]} > 0)) || {
      ui_warn_message "输入无效" "端口必须是 1 到 65535 之间的数字；多个端口请用逗号分隔。"
      continue
    }

    if [[ "${allow_multiple}" != "true" && ${#ports[@]} -ne 1 ]]; then
      ui_warn_message "输入无效" "这里只允许输入一个端口。"
      continue
    fi

    printf '%s\n' "${ports[@]}"
    return 0
  done
}

confirm_port_management_change() {
  local title="$1"
  shift || true
  local ports_text=""
  local port=""

  for port in "$@"; do
    if [[ -n "${ports_text}" ]]; then
      ports_text+=", "
    fi
    ports_text+="${port}"
  done

  ui_confirm_with_back "${title}" "$(port_management_notice_text)\n\n目标端口：${ports_text}"
}

menu_port_management_phase() {
  while true; do
    local raw_input=""
    if ! prompt_port_management_input; then
      return 0
    fi
    raw_input="$(ui_trim_value "${UI_LAST_INPUT}")"

    case "${raw_input}" in
      0)
        return 0
        ;;
      1)
        menu_execute_with_feedback "查看当前监听端口与 nftables 规则" run_port_management_overview || true
        ;;
      2)
        local ports=()
        mapfile -t ports < <(prompt_port_list_for_management "开放一个端口" "请输入要开放的端口号：" "false" || true)
        ((${#ports[@]} > 0)) || continue
        confirm_port_management_change "确认开放端口" "${ports[@]}" || continue
        menu_execute_with_feedback "开放端口 ${ports[0]}" nftables_open_tcp_ports "${ports[@]}" || true
        ;;
      3)
        local ports=()
        mapfile -t ports < <(prompt_port_list_for_management "关闭一个端口" "请输入要关闭的端口号：" "false" || true)
        ((${#ports[@]} > 0)) || continue
        confirm_port_management_change "确认关闭端口" "${ports[@]}" || continue
        menu_execute_with_feedback "关闭端口 ${ports[0]}" nftables_close_tcp_ports "${ports[@]}" || true
        ;;
      4)
        local ports=()
        mapfile -t ports < <(prompt_port_list_for_management "批量开放端口" "请输入要批量开放的端口，多个端口可用逗号分隔，例如 80,443：" "true" || true)
        ((${#ports[@]} > 0)) || continue
        confirm_port_management_change "确认批量开放端口" "${ports[@]}" || continue
        menu_execute_with_feedback "批量开放端口" nftables_open_tcp_ports "${ports[@]}" || true
        ;;
      5)
        local ports=()
        mapfile -t ports < <(prompt_port_list_for_management "批量关闭端口" "请输入要批量关闭的端口，多个端口可用逗号分隔，例如 80,443：" "true" || true)
        ((${#ports[@]} > 0)) || continue
        confirm_port_management_change "确认批量关闭端口" "${ports[@]}" || continue
        menu_execute_with_feedback "批量关闭端口" nftables_close_tcp_ports "${ports[@]}" || true
        ;;
      6)
        ui_confirm_with_back "确认重载 nftables" "$(port_management_notice_text)\n\n即将重新校验并加载 /etc/nftables.conf。" || continue
        menu_execute_with_feedback "重载并验证 nftables" nftables_reload_and_validate || true
        ;;
      *)
        ui_warn_message "输入无效" "端口管理子菜单只支持输入 1、2、3、4、5、6 或 0。"
        ;;
    esac
  done
}

prompt_init_sequence_selection() {
  local max_step=""
  max_step="$(max_init_step_number)"

  while true; do
    local target_step=""
    local target_step_num=0
    if ! ui_prompt_input "顺序执行模式" "请输入目标步骤号。\n0 = 返回上一级菜单\n有效范围：2-${max_step}\n\n说明：将从第 2 步开始，按顺序一直执行到你输入的步骤号。"; then
      return 1
    fi
    target_step="$(ui_trim_value "${UI_LAST_INPUT}")"

    if [[ -z "${target_step}" ]]; then
      ui_warn_message "输入为空" "请输入 2 到 ${max_step} 之间的目标步骤号；输入 0 返回上一级菜单。"
      continue
    fi

    if [[ "${target_step}" == "0" ]]; then
      return 1
    fi

    if [[ ! "${target_step}" =~ ^[0-9]+$ ]]; then
      ui_warn_message "输入无效" "请输入数字步骤号。有效范围为 2 到 ${max_step}；输入 0 返回上一级菜单。"
      continue
    fi

    target_step_num=$((10#${target_step}))

    if (( target_step_num < 2 || target_step_num > max_step )); then
      ui_warn_message "输入无效" "目标步骤号必须在 2 到 ${max_step} 之间；输入 0 返回上一级菜单。"
      continue
    fi

    local sequence_ids=()
    mapfile -t sequence_ids < <(build_init_sequence_to_step "${target_step_num}")
    ((${#sequence_ids[@]} > 0)) || {
      ui_warn_message "无法执行" "没有找到可执行的步骤范围，请检查模块注册表。"
      return 1
    }

    local summary=""
    summary="$(render_execution_summary "init" "${sequence_ids[@]}")"
    ui_confirm_with_back "确认顺序执行" "你将按顺序执行以下步骤：\n\n${summary}" || return 1

    printf '%s\n' "${sequence_ids[@]}"
    return 0
  done
}

confirm_maintain_sequence() {
  local sequence_ids=("$@")
  local summary=""
  summary="$(render_execution_summary "maintain" "${sequence_ids[@]}")"
  ui_confirm_with_back "确认顺序执行 1 到 8" "你将按顺序执行以下长期维护项目：\n\n${summary}"
}

resolve_cautious_selection_token() {
  local token="$1"
  local normalized=""
  normalized="$(basename "${token}")"
  normalized="${normalized%.sh}"

  local line=""
  local index=0
  while IFS= read -r line; do
    index=$((index + 1))
    local step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
    IFS=$'\t' read -r step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"

    if [[ "${normalized}" == "${module_id}" ]]; then
      printf '%s\n' "${module_id}"
      return 0
    fi

    if [[ "${normalized}" == "${step_no}" || "${normalized}" == "${index}" ]]; then
      printf '%s\n' "${module_id}"
      return 0
    fi

    if [[ "${step_no}" == 10.* && "${normalized}" == "${step_no#10.}" ]]; then
      printf '%s\n' "${module_id}"
      return 0
    fi
  done < <(registry_lines "cautious")

  return 1
}

normalize_cautious_selection_safe() {
  local token="" module_id=""
  local normalized_ids=()

  for token in "$@"; do
    [[ -n "${token}" ]] || continue
    module_id="$(resolve_cautious_selection_token "${token}" || true)"
    [[ -n "${module_id}" ]] || return 1
    if ! selection_contains "${module_id}" "${normalized_ids[@]}"; then
      normalized_ids+=("${module_id}")
    fi
  done

  printf '%s\n' "${normalized_ids[@]}"
}

is_cautious_read_only_module() {
  [[ "${1:-}" == "38_status_review" ]]
}

confirm_cautious_module_execution() {
  local module_id="$1"
  local line=""
  line="$(registry_find_line "${module_id}" || true)"
  [[ -n "${line}" ]] || die "Cautious module not found: ${module_id}"

  if is_cautious_read_only_module "${module_id}"; then
    return 0
  fi

  local step_no entry_module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh
  IFS=$'\t' read -r step_no entry_module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"

  ui_confirm_with_back \
    "确认执行 ${step_no}" \
    "即将执行：${step_no} ${title_zh}\n风险：$(risk_label_zh "${risk_level}")\n脚本：${script_path}\n\n作用：${short_desc_zh}\n\n将进行的修改：${detail_zh}"
}

run_cautious_modules() {
  local selected=("$@")
  local module_id=""

  for module_id in "${selected[@]}"; do
    confirm_cautious_module_execution "${module_id}" || return 1
    run_phase_from_registry "cautious" "${module_id}"
  done
}

menu_init_phase() {
  while true; do
    local raw_input=""
    if ! prompt_init_execution_input; then
      return 0
    fi
    raw_input="$(ui_trim_value "${UI_LAST_INPUT}")"

    if [[ -z "${raw_input}" ]]; then
      ui_warn_message "输入为空" "请输入步骤编号，例如 6、2,3,4 或 99。"
      continue
    fi

    if [[ "${raw_input}" == "0" ]]; then
      return 0
    fi

    if [[ "${raw_input}" == "99" ]]; then
      local sequence_ids=()
      local sequence_summary=""
      mapfile -t sequence_ids < <(prompt_init_sequence_selection || true)
      ((${#sequence_ids[@]} > 0)) || continue
      sequence_summary="$(menu_action_summary "init" "${sequence_ids[@]}")"
      menu_execute_with_feedback "${sequence_summary}" run_phase_from_registry "init" "menu" "${sequence_ids[@]}" || true
      continue
    fi

    local raw_tokens=()
    mapfile -t raw_tokens < <(split_menu_input_tokens "${raw_input}")
    ((${#raw_tokens[@]} > 0)) || {
      ui_warn_message "输入无效" "请输入单个编号，或多个逗号分隔的编号。例如：6 或 1,2,3。"
      continue
    }

    local token=""
    for token in "${raw_tokens[@]}"; do
      if [[ ! "${token}" =~ ^[0-9]+$ ]]; then
        ui_warn_message "输入无效" "只支持输入数字编号。示例：6 或 1,2,3。"
        continue 2
      fi
    done

    if selection_contains "0" "${raw_tokens[@]}"; then
      ui_warn_message "输入无效" "如果要返回上一级菜单，请只输入 0。"
      continue
    fi

    if selection_contains "99" "${raw_tokens[@]}"; then
      ui_warn_message "输入无效" "99 只适用于初始化菜单，且必须单独输入。"
      continue
    fi

    local normalized_selection=()
    local selection_summary=""
    mapfile -t normalized_selection < <(normalize_selection_list_safe "init" "${raw_tokens[@]}" || true)
    ((${#normalized_selection[@]} > 0)) || {
      ui_warn_message "输入无效" "存在无法识别的编号，请按菜单显示的编号输入。"
      continue
    }

    selection_summary="$(menu_action_summary "init" "${normalized_selection[@]}")"
    menu_execute_with_feedback "${selection_summary}" run_phase_from_registry "init" "menu" "${normalized_selection[@]}" || true
  done
}

menu_cautious_phase() {
  while true; do
    local raw_input=""
    if ! prompt_cautious_execution_input; then
      return 0
    fi
    raw_input="$(ui_trim_value "${UI_LAST_INPUT}")"

    if [[ -z "${raw_input}" ]]; then
      ui_warn_message "输入为空" "请输入谨慎操作编号，例如 2、10.2 或 10.10。"
      continue
    fi

    if [[ "${raw_input}" == "0" ]]; then
      return 0
    fi

    local raw_tokens=()
    mapfile -t raw_tokens < <(split_menu_input_tokens "${raw_input}")
    ((${#raw_tokens[@]} > 0)) || {
      ui_warn_message "输入无效" "请输入单个编号，或多个逗号分隔的编号。例如：2、10.2 或 2,10。"
      continue
    }

    local token=""
    for token in "${raw_tokens[@]}"; do
      if [[ ! "${token}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        ui_warn_message "输入无效" "只支持输入数字编号，例如 2、10.2 或 2,10。"
        continue 2
      fi
    done

    if selection_contains "0" "${raw_tokens[@]}"; then
      ui_warn_message "输入无效" "如果要返回上一级菜单，请只输入 0。"
      continue
    fi

    local normalized_selection=()
    local selection_summary=""
    mapfile -t normalized_selection < <(normalize_cautious_selection_safe "${raw_tokens[@]}" || true)
    ((${#normalized_selection[@]} > 0)) || {
      ui_warn_message "输入无效" "存在无法识别的谨慎操作编号，请按菜单显示的编号输入。"
      continue
    }

    selection_summary="$(menu_action_summary "cautious" "${normalized_selection[@]}")"
    menu_execute_with_feedback "${selection_summary}" run_cautious_modules "${normalized_selection[@]}" || true
  done
}

menu_maintain_phase() {
  while true; do
    local raw_input=""
    if ! prompt_maintain_execution_input; then
      return 0
    fi
    raw_input="$(ui_trim_value "${UI_LAST_INPUT}")"

    if [[ -z "${raw_input}" ]]; then
      ui_warn_message "输入为空" "请输入维护编号，例如 1、1,2,3、9 或 10。"
      continue
    fi

    case "${raw_input}" in
      0)
        return 0
        ;;
      3)
        menu_port_management_phase
        continue
        ;;
      9)
        local sequence_ids=()
        local sequence_summary=""
        mapfile -t sequence_ids < <(build_maintain_main_sequence)
        ((${#sequence_ids[@]} > 0)) || die "No maintain modules found for steps 1 to 8."
        confirm_maintain_sequence "${sequence_ids[@]}" || continue
        sequence_summary="$(menu_action_summary "maintain" "${sequence_ids[@]}")"
        menu_execute_with_feedback "${sequence_summary}" run_phase_from_registry "maintain" "menu" "${sequence_ids[@]}" || true
        continue
        ;;
      10)
        menu_cautious_phase
        continue
        ;;
    esac

    local raw_tokens=()
    mapfile -t raw_tokens < <(split_menu_input_tokens "${raw_input}")
    ((${#raw_tokens[@]} > 0)) || {
      ui_warn_message "输入无效" "请输入单个编号，或多个逗号分隔的编号。例如：1 或 1,3,5。"
      continue
    }

    local token=""
    for token in "${raw_tokens[@]}"; do
      if [[ ! "${token}" =~ ^[0-9]+$ ]]; then
        ui_warn_message "输入无效" "只支持输入数字编号。示例：1 或 1,3,5。"
        continue 2
      fi
    done

    if selection_contains "0" "${raw_tokens[@]}"; then
      ui_warn_message "输入无效" "如果要返回上一级菜单，请只输入 0。"
      continue
    fi

    if selection_contains "3" "${raw_tokens[@]}" || selection_contains "9" "${raw_tokens[@]}" || selection_contains "10" "${raw_tokens[@]}"; then
      ui_warn_message "输入无效" "3、9 和 10 是特殊入口，请单独输入。"
      continue
    fi

    local normalized_selection=()
    local selection_summary=""
    mapfile -t normalized_selection < <(normalize_selection_list_safe "maintain" "${raw_tokens[@]}" || true)
    ((${#normalized_selection[@]} > 0)) || {
      ui_warn_message "输入无效" "存在无法识别的编号，请按菜单显示的编号输入。"
      continue
    }

    selection_summary="$(menu_action_summary "maintain" "${normalized_selection[@]}")"
    menu_execute_with_feedback "${selection_summary}" run_phase_from_registry "maintain" "menu" "${normalized_selection[@]}" || true
  done
}

menu_phase() {
  local phase="$1"

  case "${phase}" in
    init)
      menu_init_phase
      ;;
    maintain)
      menu_maintain_phase
      ;;
    *)
      die "Unsupported menu phase: ${phase}"
      ;;
  esac
}

menu_root() {
  local initial_phase="${1:-}"
  local current_phase="${initial_phase}"

  if ! ui_require_interactive; then
    printf '%s\n' "menu mode requires an interactive terminal or /dev/tty." >&2
    return 1
  fi

  log_runtime_project_context

  while true; do
    if [[ -z "${current_phase}" ]]; then
      if ! ui_choose_phase "init"; then
        return 0
      fi
      current_phase="${UI_LAST_INPUT}"
    fi

    case "${current_phase}" in
      0|"")
        return 0
        ;;
      init|maintain)
        menu_phase "${current_phase}"
        current_phase=""
        initial_phase=""
        continue
        ;;
      *)
        die "Unsupported menu phase: ${current_phase}"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  case "${BOOTSTRAP_ACTION}" in
    init)
      RUN_MODE="init"
      prepare_context
      ensure_runtime_initialized
      local init_status=0
      set +e
      run_phase_from_registry "init" "command"
      init_status=$?
      set -e
      if (( init_status == 130 )); then
        return 0
      fi
      (( init_status == 0 )) || return "${init_status}"
      ;;
    maintain)
      RUN_MODE="maintain"
      prepare_context
      ensure_runtime_initialized
      run_phase_from_registry "maintain"
      ;;
    run)
      [[ -n "${BOOTSTRAP_TARGET}" ]] || die "run mode requires a module name"
      RUN_MODE="run"
      prepare_context
      local line=""
      line="$(registry_find_line "${BOOTSTRAP_TARGET}" || true)"
      if [[ -n "${line}" ]]; then
        local run_status=0
        set +e
        if ! is_true "${PLAN_ONLY:-false}" && registry_line_requires_admin_user "${line}"; then
          ensure_admin_user_for_execution "command" || run_status=$?
        fi
        set -e
        if (( run_status == 1 )); then
          return 0
        fi
        (( run_status == 0 )) || return "${run_status}"
        ensure_runtime_initialized
        run_module_from_registry_line "${line}"
      else
        local module_path=""
        module_path="$(resolve_module_path "${BOOTSTRAP_TARGET}")" || die "Module not found: ${BOOTSTRAP_TARGET}"
        local run_status=0
        set +e
        if ! is_true "${PLAN_ONLY:-false}" && module_path_requires_admin_user "${module_path}"; then
          ensure_admin_user_for_execution "command" || run_status=$?
        fi
        set -e
        if (( run_status == 1 )); then
          return 0
        fi
        (( run_status == 0 )) || return "${run_status}"
        ensure_runtime_initialized
        run_script_path "${module_path}"
      fi
      ;;
    step)
      [[ -n "${BOOTSTRAP_TARGET}" ]] || die "step mode requires init step number(s), for example: step 2 or step 2,3,4"
      RUN_MODE="step"
      prepare_context
      resolve_init_step_selection "${BOOTSTRAP_TARGET}"
      local selected_init_ids=()
      if ((${#RESOLVED_INIT_STEP_IDS[@]} > 0)); then
        selected_init_ids=("${RESOLVED_INIT_STEP_IDS[@]}")
      fi
      ((${#selected_init_ids[@]} > 0)) || die "No init steps selected."
      ensure_runtime_initialized
      local step_status=0
      set +e
      run_phase_from_registry "init" "command" "${selected_init_ids[@]}"
      step_status=$?
      set -e
      if (( step_status == 130 )); then
        return 0
      fi
      (( step_status == 0 )) || return "${step_status}"
      ;;
    stepseq)
      [[ -n "${BOOTSTRAP_TARGET}" ]] || die "stepseq mode requires a target init step number, for example: stepseq 7"
      RUN_MODE="stepseq"
      prepare_context

      local max_step=""
      local target_step=0
      max_step="$(max_init_step_number)"
      [[ "${BOOTSTRAP_TARGET}" =~ ^[0-9]+$ ]] || die "stepseq target must be a number between 2 and ${max_step}."
      target_step=$((10#${BOOTSTRAP_TARGET}))
      if (( target_step < 2 || target_step > max_step )); then
        die "stepseq target must be between 2 and ${max_step}."
      fi

      local sequence_ids=()
      local sequence_line=""
      local stepseq_status=0
      while IFS= read -r sequence_line; do
        [[ -n "${sequence_line}" ]] && sequence_ids+=("${sequence_line}")
      done < <(build_init_sequence_to_step "${target_step}")
      ((${#sequence_ids[@]} > 0)) || die "No init steps found for range 2-${target_step}."

      local preview=""
      local confirmation_body=""
      preview="$(render_execution_list_with_scripts "${sequence_ids[@]}")"
      confirmation_body="$(cat <<EOF
将从初始化第 2 步顺序执行到第 ${target_step} 步:

${preview}
EOF
)"

      confirm_terminal_yes "stepseq 确认" "${confirmation_body}" || die "stepseq aborted by user."
      ensure_runtime_initialized
      set +e
      run_phase_from_registry "init" "command" "${sequence_ids[@]}"
      stepseq_status=$?
      set -e
      if (( stepseq_status == 130 )); then
        return 0
      fi
      (( stepseq_status == 0 )) || return "${stepseq_status}"
      ;;
    plan)
      CLI_PLAN_ONLY="true"
      CLI_DRY_RUN="true"
      case "${BOOTSTRAP_TARGET}" in
        init)
          RUN_MODE="plan-init"
          prepare_context
          ensure_runtime_initialized
          run_phase_from_registry "init" "command"
          ;;
        maintain)
          RUN_MODE="plan-maintain"
          prepare_context
          ensure_runtime_initialized
          run_phase_from_registry "maintain" "command"
          ;;
        install-shortcut)
          RUN_MODE="plan-install-shortcut"
          prepare_shortcut_context
          install_shortcut
          ;;
        sync-runtime-copy)
          RUN_MODE="plan-sync-runtime-copy"
          prepare_shortcut_context
          sync_runtime_copy
          ;;
        run)
          [[ -n "${BOOTSTRAP_TARGET_EXTRA}" ]] || die "plan run requires a module name"
          RUN_MODE="plan-run"
          prepare_context
          ensure_runtime_initialized
          local line=""
          line="$(registry_find_line "${BOOTSTRAP_TARGET_EXTRA}" || true)"
          if [[ -n "${line}" ]]; then
            run_module_from_registry_line "${line}"
          else
            local module_path=""
            module_path="$(resolve_module_path "${BOOTSTRAP_TARGET_EXTRA}")" || die "Module not found: ${BOOTSTRAP_TARGET_EXTRA}"
            run_script_path "${module_path}"
          fi
          ;;
        *)
          die "plan mode requires init, maintain, install-shortcut, sync-runtime-copy, or run <module>"
          ;;
      esac
      ;;
    show)
      case "${BOOTSTRAP_TARGET}" in
        init|maintain)
          RUN_MODE="show-${BOOTSTRAP_TARGET}"
          prepare_context
          show_phase_overview "${BOOTSTRAP_TARGET}"
          ;;
        *)
          die "show mode requires init or maintain"
          ;;
      esac
      ;;
    preflight)
      RUN_MODE="preflight"
      load_config
      if ! ensure_admin_user_for_execution "command"; then
        return 0
      fi
      run_preflight_checks || exit 1
      ;;
    menu)
      RUN_MODE="menu"
      prepare_context
      case "${BOOTSTRAP_TARGET}" in
        "")
          menu_root
          ;;
        init|maintain)
          menu_root "${BOOTSTRAP_TARGET}"
          ;;
        *)
          die "menu mode requires init, maintain, or no phase"
          ;;
      esac
      ;;
    install-shortcut)
      RUN_MODE="install-shortcut"
      prepare_shortcut_context
      install_shortcut
      ;;
    sync-runtime-copy)
      RUN_MODE="sync-runtime-copy"
      prepare_shortcut_context
      sync_runtime_copy
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
