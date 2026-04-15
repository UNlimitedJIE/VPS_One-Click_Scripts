#!/usr/bin/env bash
set -euo pipefail

# Module: 10_swap
# Purpose: 通过显式交互选择 skip / 1G / 2G / 4G / custom。
# Preconditions: root；Debian 12。
# Steps:
#   1. 展示当前 swap 状态
#   2. 交互选择 skip / 1G / 2G / 4G / custom
#   3. 按选择保留、创建或替换 /swapfile
#   4. 输出 /swapfile、swapon --show 和 fstab 摘要
# Idempotency:
#   - 选择 skip 时不重复改动
#   - 选择同一大小时只会按当前状态做必要修正

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

swap_show_output() {
  swapon --show --noheadings --output NAME,SIZE,USED,PRIO 2>/dev/null || true
}

swap_name_list() {
  swapon --show --noheadings --output NAME 2>/dev/null | sed '/^$/d'
}

active_swap_count() {
  local count="0"
  count="$(swap_name_list | wc -l | tr -d ' ')"
  printf '%s\n' "${count:-0}"
}

swapfile_exists() {
  [[ -f /swapfile ]]
}

managed_swapfile_is_active() {
  swap_name_list | grep -Fxq "/swapfile"
}

prompt_custom_swap_size() {
  local answer=""
  local normalized=""

  while true; do
    if ! ui_prompt_input "自定义 swap 大小" "请输入自定义大小，例如 512M、1G、2G。\n输入 0 返回上一步：" ""; then
      return 1
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    if [[ "${answer}" == "0" ]]; then
      return 1
    fi

    normalized="$(normalize_swap_size_value "${answer}" || true)"
    if [[ -n "${normalized}" ]]; then
      printf '%s\n' "${normalized}"
      return 0
    fi

    ui_warn_message "输入无效" "$(swap_size_validation_error "${answer}")"
  done
}

prompt_swap_selection() {
  local answer=""
  local chosen_size=""
  local current_swap=""

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "[plan] real execution will prompt for swap: skip / 1G / 2G / 4G / custom / 0"
    return 1
  fi

  ui_require_interactive || die "第 11 步需要交互式终端来明确选择 swap 方案。"

  current_swap="$(swap_show_output)"
  [[ -n "${current_swap}" ]] || current_swap="(none)"

  while true; do
    if ! ui_prompt_input \
      "Swap 选择" \
      "当前 active swap:\n${current_swap}\n\n可选项：\n0 = 返回\nskip = 不启用 swap / 保留现状\n1G = 创建或替换为 1G\n2G = 创建或替换为 2G\n4G = 创建或替换为 4G\ncustom = 输入自定义大小" \
      ""; then
      return 1
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      0)
        return 1
        ;;
      skip|SKIP)
        printf '%s\n' "skip"
        return 0
        ;;
      1G|1g|2G|2g|4G|4g)
        printf '%s\n' "${answer^^}"
        return 0
        ;;
      custom|CUSTOM)
        chosen_size="$(prompt_custom_swap_size || true)"
        [[ -n "${chosen_size}" ]] || continue
        printf '%s\n' "${chosen_size}"
        return 0
        ;;
      *)
        ui_warn_message "输入无效" "请输入 0、skip、1G、2G、4G 或 custom。"
        ;;
    esac
  done
}

show_swap_terminal_summary() {
  local action_label="$1"
  local selected_size="$2"
  local swapfile_state="absent"
  local swap_show_state=""
  local fstab_state="no"
  local existing_swap_state="none"
  local summary=""

  if swapfile_exists; then
    swapfile_state="present"
  fi

  swap_show_state="$(swap_show_output)"
  [[ -n "${swap_show_state}" ]] || swap_show_state="(none)"
  if has_active_swap; then
    existing_swap_state="active"
  elif swapfile_exists; then
    existing_swap_state="swapfile-present-but-inactive"
  fi

  if swap_fstab_present; then
    fstab_state="yes"
  fi

  summary="$(cat <<EOF
=== Swap Summary ===
Action: ${action_label}
Selected size: ${selected_size:-<none>}
Existing swap handling: ${existing_swap_state}
/swapfile: ${swapfile_state}
swapon --show:
${swap_show_state}
/etc/fstab has /swapfile entry: ${fstab_state}
EOF
)"

  printf '\n%s\n' "${summary}"
}

record_swap_state() {
  local enabled="$1"
  local status="$2"

  set_state "SWAP_ENABLED" "${enabled}"
  set_state "SWAP_STATUS" "${status}"
}

keep_existing_swap() {
  local action_label="$1"

  record_swap_state "yes" "existing-kept"
  show_swap_terminal_summary "${action_label}" ""
}

skip_swap_setup() {
  local action_label="$1"

  if has_active_swap; then
    keep_existing_swap "${action_label}"
    return 0
  fi

  record_swap_state "no" "skipped"
  show_swap_terminal_summary "${action_label}" ""
}

replace_swapfile_if_needed() {
  if has_active_swap; then
    if [[ "$(active_swap_count)" -ne 1 ]] || ! managed_swapfile_is_active; then
      die "当前已有非 /swapfile 或多个 active swap；脚本不会自动替换，请先手工确认。"
    fi
    run_cmd "Disabling current managed /swapfile" swapoff /swapfile
  fi

  if swapfile_exists; then
    run_cmd "Removing existing /swapfile before recreation" rm -f /swapfile
  fi
}

create_or_replace_swapfile() {
  local target_size="$1"
  local action_label="$2"

  replace_swapfile_if_needed

  run_cmd "Allocating /swapfile (${target_size})" fallocate -l "${target_size}" /swapfile
  run_cmd "Setting /swapfile permissions" chmod 600 /swapfile
  run_cmd "Formatting /swapfile as swap" mkswap /swapfile
  run_cmd "Enabling /swapfile" swapon /swapfile
  ensure_line_in_file "/etc/fstab" "$(swap_fstab_line)"

  if [[ "${action_label}" == "Replace existing swap" ]]; then
    record_swap_state "yes" "replaced-${target_size}"
  else
    record_swap_state "yes" "created-${target_size}"
  fi

  show_swap_terminal_summary "${action_label}" "${target_size}"
}

main() {
  load_config
  init_runtime
  module_banner "10_swap" "显式配置 swap"
  require_root
  require_debian12

  local selection=""
  local current_swap=""
  local action_label=""

  current_swap="$(swap_show_output)"
  if [[ -n "${current_swap}" ]]; then
    log info "Current active swap:"
    printf '%s\n' "${current_swap}"
  else
    log info "Current active swap: none"
  fi

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "[plan] swap choices: skip / 1G / 2G / 4G / custom / 0"
    if has_active_swap; then
      record_swap_state "yes" "existing"
    else
      record_swap_state "no" "skipped"
    fi
    return 0
  fi

  selection="$(prompt_swap_selection || true)"
  [[ -n "${selection}" ]] || die "Swap 配置已取消。"

  case "${selection}" in
    skip)
      if has_active_swap; then
        action_label="Keep existing swap unchanged"
      else
        action_label="Skip swap setup"
      fi
      skip_swap_setup "${action_label}"
      ;;
    *)
      if has_active_swap || swapfile_exists; then
        action_label="Replace existing swap"
      else
        action_label="Create /swapfile"
      fi
      create_or_replace_swapfile "${selection}" "${action_label}"
      ;;
  esac
}

main "$@"
