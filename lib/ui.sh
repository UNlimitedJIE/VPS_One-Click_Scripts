#!/usr/bin/env bash
set -euo pipefail

ui_is_interactive() {
  [[ -t 0 && -t 1 ]]
}

ui_use_whiptail() {
  ui_is_interactive && command_exists whiptail
}

ui_require_interactive() {
  ui_is_interactive || die "menu mode requires an interactive terminal."
}

ui_show_text_block() {
  local title="$1"
  local body="$2"

  if ui_use_whiptail; then
    whiptail --title "${title}" --scrolltext --msgbox "${body}" 24 100
    return 0
  fi

  printf '\n%s\n\n%s\n\n' "${title}" "${body}"
}

ui_warn_message() {
  local title="$1"
  local body="$2"

  if ui_use_whiptail; then
    whiptail --title "${title}" --msgbox "${body}" 12 90
    return 0
  fi

  printf '\n[%s]\n%s\n\n' "${title}" "${body}"
}

ui_confirm_text() {
  local title="$1"
  local body="$2"

  if ui_use_whiptail; then
    whiptail --title "${title}" --yesno "${body}" 24 100
    return $?
  fi

  printf '\n%s\n\n%s\n\n' "${title}" "${body}"
  printf '继续执行请输入 yes：'
  local answer=""
  read -r answer
  [[ "${answer}" == "yes" ]]
}

ui_confirm_with_back() {
  local title="$1"
  local body="$2"

  if ui_use_whiptail; then
    local result=""
    result="$(
      whiptail \
        --title "${title}" \
        --inputbox "${body}\n\n输入 yes 继续执行\n输入 0 返回上一级菜单" 28 110 "" \
        3>&1 1>&2 2>&3
    )" || return 1
    [[ "${result}" == "yes" ]]
    return $?
  fi

  printf '\n%s\n\n%s\n\n' "${title}" "${body}"
  printf '输入 yes 继续执行，输入 0 返回上一级菜单：'
  local answer=""
  read -r answer
  [[ "${answer}" == "yes" ]]
}

ui_prompt_input() {
  local title="$1"
  local prompt="$2"
  local default_value="${3:-}"

  if ui_use_whiptail; then
    local result=""
    result="$(
      whiptail \
        --title "${title}" \
        --inputbox "${prompt}" 28 110 "${default_value}" \
        3>&1 1>&2 2>&3
    )" || return 1
    printf '%s\n' "${result}"
    return 0
  fi

  printf '\n%s\n\n%s\n' "${title}" "${prompt}"
  printf '请输入：'
  local answer=""
  read -r answer
  printf '%s\n' "${answer}"
}

ui_choose_phase() {
  local default_phase="${1:-init}"
  ui_require_interactive

  if ui_use_whiptail; then
    whiptail \
      --title "VPS 初始化与维护菜单" \
      --menu "请选择要执行的流程。\n0 = 退出程序" 18 78 6 \
      "0" "退出程序" \
      "init" "初始化流程（直接按编号执行）" \
      "maintain" "长期维护任务（含 9=顺序执行 1-8，10=谨慎操作子菜单）" \
      3>&1 1>&2 2>&3
    return 0
  fi

  printf '请选择流程：\n'
  printf '0. 退出程序\n'
  printf '1. 初始化流程（直接按编号执行）\n'
  printf '2. 长期维护任务（含 9=顺序执行 1-8，10=谨慎操作子菜单）\n'
  printf '默认：%s\n' "${default_phase}"
  printf '输入编号并回车：'
  local answer=""
  read -r answer
  case "${answer:-}" in
    0) echo "0" ;;
    2) echo "maintain" ;;
    *) echo "${default_phase}" ;;
  esac
}
