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
  bash bootstrap.sh step <step_no[,step_no...]> [--config /path/to/conf] [--dry-run]
  bash bootstrap.sh stepseq <target_step_no> [--config /path/to/conf] [--dry-run]
  bash bootstrap.sh preflight [--config /path/to/conf]
  bash bootstrap.sh plan init|maintain
  bash bootstrap.sh plan run <module_name>
  bash bootstrap.sh show init|maintain [--config /path/to/conf]
  bash bootstrap.sh menu [init|maintain] [--config /path/to/conf] [--dry-run]

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
  bash bootstrap.sh plan init
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

ensure_runtime_initialized() {
  if [[ "${RUNTIME_INITIALIZED}" == "true" ]]; then
    return 0
  fi

  init_runtime
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
        log warn "Selected ${module_id} but missing dependency ${dependency}. The script can still be run, but you should confirm prerequisites manually."
      fi
    done
  done < <(registry_lines "${phase}")
}

run_phase_from_registry() {
  local phase="$1"
  shift || true
  local selected=("$@")
  local line=""
  local module_id=""

  if ((${#selected[@]} > 0)); then
    warn_missing_dependencies "${phase}" "${selected[@]}"
    for module_id in "${selected[@]}"; do
      line="$(registry_find_line "${module_id}" || true)"
      [[ -n "${line}" ]] || die "Module not found in registry: ${module_id}"
      run_module_from_registry_line "${line}"
    done
    return 0
  fi

  while IFS= read -r line; do
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

  header="$(cat <<'EOF'
初始化步骤列表
0. 返回上一级菜单
99. 从第 2 步开始顺序执行到指定步骤

输入规则：
- 输入单个数字，例如 6，直接执行第 6 步
- 输入多个数字，例如 1,2,3，按输入顺序执行这些步骤
- 输入 99，进入“从第 2 步开始顺序执行到指定步骤”模式

EOF
)"

  while IFS= read -r line; do
    IFS=$'\t' read -r step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
    header+="${step_no}. ${title_zh}"
    if [[ "${risk_level}" == "high" ]]; then
      header+=" 【高风险】"
    fi
    header+=$'\n'
    header+="   ${short_desc_zh}"$'\n'
  done < <(registry_lines "init")

  printf '%s' "${header}"
}

render_maintain_menu_prompt() {
  local header=""
  local line=""
  local step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh

  header="$(cat <<'EOF'
长期维护主菜单
0. 返回上一级菜单

输入规则：
- 输入单个数字直接执行对应项目
- 输入多个数字，例如 1,3,5，按输入顺序执行这些项目
- 输入 9，顺序执行 1 到 8
- 输入 10，进入谨慎操作子菜单

EOF
)"

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

  printf '%s' "${header}"
}

render_cautious_menu_prompt() {
  local header=""
  local line=""
  local index=0
  local step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh

  header="$(cat <<'EOF'
谨慎操作子菜单
0. 返回上一级菜单

输入规则：
- 输入单个数字，例如 2，执行 10.2
- 也可以输入完整编号，例如 10.2
- 可输入多个编号，例如 2,10 或 10.2,10.10

EOF
)"

  while IFS= read -r line; do
    index=$((index + 1))
    IFS=$'\t' read -r step_no module_id entry_phase title_zh short_desc_zh risk_level default_enabled depends_on script_path detail_zh <<<"${line}"
    header+="${step_no}. ${title_zh}"
    if [[ "${risk_level}" == "high" ]]; then
      header+=" 【高风险】"
    fi
    header+=$'\n'
    header+="   ${short_desc_zh}"$'\n'
  done < <(registry_lines "cautious")

  printf '%s' "${header}"
}

prompt_init_execution_input() {
  ui_prompt_input "初始化快速执行" "$(render_init_menu_prompt)"
}

prompt_maintain_execution_input() {
  ui_prompt_input "长期维护快速执行" "$(render_maintain_menu_prompt)"
}

prompt_cautious_execution_input() {
  ui_prompt_input "谨慎操作子菜单" "$(render_cautious_menu_prompt)"
}

prompt_init_sequence_selection() {
  local max_step=""
  max_step="$(max_init_step_number)"

  while true; do
    local target_step=""
    target_step="$(ui_prompt_input "顺序执行模式" "请输入目标步骤号。\n0 = 返回上一级菜单\n有效范围：2-${max_step}\n\n说明：将从第 2 步开始，按顺序一直执行到你输入的步骤号。" || true)"
    [[ -n "${target_step}" ]] || return 1
    target_step="$(printf '%s' "${target_step}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ "${target_step}" == "0" ]]; then
      return 1
    fi

    if [[ ! "${target_step}" =~ ^[0-9]+$ ]]; then
      ui_warn_message "输入无效" "请输入数字步骤号。有效范围为 2 到 ${max_step}；输入 0 返回上一级菜单。"
      continue
    fi

    if (( target_step < 2 || target_step > max_step )); then
      ui_warn_message "输入无效" "目标步骤号必须在 2 到 ${max_step} 之间；输入 0 返回上一级菜单。"
      continue
    fi

    local sequence_ids=()
    mapfile -t sequence_ids < <(build_init_sequence_to_step "${target_step}")
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
    raw_input="$(prompt_init_execution_input || true)"
    [[ -n "${raw_input}" ]] || return 0
    raw_input="$(printf '%s' "${raw_input}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ "${raw_input}" == "0" ]]; then
      return 0
    fi

    if [[ "${raw_input}" == "99" ]]; then
      local sequence_ids=()
      mapfile -t sequence_ids < <(prompt_init_sequence_selection || true)
      ((${#sequence_ids[@]} > 0)) || continue
      ensure_runtime_initialized
      run_phase_from_registry "init" "${sequence_ids[@]}"
      return 0
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
    mapfile -t normalized_selection < <(normalize_selection_list_safe "init" "${raw_tokens[@]}" || true)
    ((${#normalized_selection[@]} > 0)) || {
      ui_warn_message "输入无效" "存在无法识别的编号，请按菜单显示的编号输入。"
      continue
    }

    ensure_runtime_initialized
    run_phase_from_registry "init" "${normalized_selection[@]}"
    return 0
  done
}

menu_cautious_phase() {
  while true; do
    local raw_input=""
    raw_input="$(prompt_cautious_execution_input || true)"
    [[ -n "${raw_input}" ]] || return 0
    raw_input="$(printf '%s' "${raw_input}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

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
    mapfile -t normalized_selection < <(normalize_cautious_selection_safe "${raw_tokens[@]}" || true)
    ((${#normalized_selection[@]} > 0)) || {
      ui_warn_message "输入无效" "存在无法识别的谨慎操作编号，请按菜单显示的编号输入。"
      continue
    }

    ensure_runtime_initialized
    run_cautious_modules "${normalized_selection[@]}" || continue
    return 0
  done
}

menu_maintain_phase() {
  while true; do
    local raw_input=""
    raw_input="$(prompt_maintain_execution_input || true)"
    [[ -n "${raw_input}" ]] || return 0
    raw_input="$(printf '%s' "${raw_input}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    case "${raw_input}" in
      0)
        return 0
        ;;
      9)
        local sequence_ids=()
        mapfile -t sequence_ids < <(build_maintain_main_sequence)
        ((${#sequence_ids[@]} > 0)) || die "No maintain modules found for steps 1 to 8."
        confirm_maintain_sequence "${sequence_ids[@]}" || continue
        ensure_runtime_initialized
        run_phase_from_registry "maintain" "${sequence_ids[@]}"
        return 0
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

    if selection_contains "9" "${raw_tokens[@]}" || selection_contains "10" "${raw_tokens[@]}"; then
      ui_warn_message "输入无效" "9 和 10 是特殊入口，请单独输入。"
      continue
    fi

    local normalized_selection=()
    mapfile -t normalized_selection < <(normalize_selection_list_safe "maintain" "${raw_tokens[@]}" || true)
    ((${#normalized_selection[@]} > 0)) || {
      ui_warn_message "输入无效" "存在无法识别的编号，请按菜单显示的编号输入。"
      continue
    }

    ensure_runtime_initialized
    run_phase_from_registry "maintain" "${normalized_selection[@]}"
    return 0
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

  while true; do
    if [[ -z "${current_phase}" ]]; then
      current_phase="$(ui_choose_phase "init" || true)"
    fi

    case "${current_phase}" in
      0|"")
        return 0
        ;;
      init|maintain)
        menu_phase "${current_phase}"
        if [[ -n "${initial_phase}" ]]; then
          return 0
        fi
        current_phase=""
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
      run_phase_from_registry "init"
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
      ensure_runtime_initialized
      local line=""
      line="$(registry_find_line "${BOOTSTRAP_TARGET}" || true)"
      if [[ -n "${line}" ]]; then
        run_module_from_registry_line "${line}"
      else
        local module_path=""
        module_path="$(resolve_module_path "${BOOTSTRAP_TARGET}")" || die "Module not found: ${BOOTSTRAP_TARGET}"
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
      run_phase_from_registry "init" "${selected_init_ids[@]}"
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
      run_phase_from_registry "init" "${sequence_ids[@]}"
      ;;
    plan)
      CLI_PLAN_ONLY="true"
      CLI_DRY_RUN="true"
      case "${BOOTSTRAP_TARGET}" in
        init)
          RUN_MODE="plan-init"
          prepare_context
          ensure_runtime_initialized
          run_phase_from_registry "init"
          ;;
        maintain)
          RUN_MODE="plan-maintain"
          prepare_context
          ensure_runtime_initialized
          run_phase_from_registry "maintain"
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
          die "plan mode requires init, maintain, or run <module>"
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
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
