#!/usr/bin/env bash
set -euo pipefail

UI_LAST_INPUT="${UI_LAST_INPUT:-}"
UI_TTY_FD="${UI_TTY_FD:-}"
UI_TTY_STATUS="${UI_TTY_STATUS:-unknown}"

ui_trim_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

ui_open_tty() {
  if [[ "${UI_TTY_STATUS}" == "open" ]]; then
    if [[ -n "${UI_TTY_FD:-}" && -e "/dev/fd/${UI_TTY_FD}" ]]; then
      return 0
    fi
    UI_TTY_STATUS="unknown"
    export UI_TTY_STATUS
  fi

  if [[ "${UI_TTY_STATUS}" == "unavailable" ]]; then
    return 1
  fi

  if [[ ! -e /dev/tty ]]; then
    UI_TTY_STATUS="unavailable"
    export UI_TTY_STATUS
    return 1
  fi

  if { exec {UI_TTY_FD}<>/dev/tty; } 2>/dev/null; then
    UI_TTY_STATUS="open"
    export UI_TTY_STATUS
    export UI_TTY_FD
    return 0
  fi

  UI_TTY_STATUS="unavailable"
  export UI_TTY_STATUS
  return 1
}

ui_print_raw() {
  local body="${1:-}"

  if ui_open_tty; then
    printf '%b' "${body}" >"/dev/fd/${UI_TTY_FD}"
    return 0
  fi

  if [[ -t 2 ]]; then
    printf '%b' "${body}" >&2
    return 0
  fi

  if [[ -t 1 ]]; then
    printf '%b' "${body}"
    return 0
  fi

  return 1
}

ui_read_line() {
  local answer=""

  if ui_open_tty; then
    IFS= read -r answer <"/dev/fd/${UI_TTY_FD}" || return 1
  elif [[ -t 0 ]]; then
    IFS= read -r answer || return 1
  else
    return 1
  fi

  UI_LAST_INPUT="${answer}"
  export UI_LAST_INPUT
  return 0
}

ui_is_interactive() {
  if ui_open_tty; then
    return 0
  fi

  [[ -t 0 ]] && ([[ -t 1 ]] || [[ -t 2 ]])
}

ui_use_whiptail() {
  ui_is_interactive || return 1
  command_exists whiptail || return 1
  [[ -n "${TERM:-}" && "${TERM}" != "dumb" ]] || return 1
  [[ -t 2 ]]
}

ui_require_interactive() {
  ui_is_interactive
}

ui_show_text_block() {
  local title="$1"
  local body="$2"

  if ui_use_whiptail; then
    if whiptail --title "${title}" --scrolltext --msgbox "${body}" 24 100; then
      return 0
    fi
  fi

  ui_print_raw "\n${title}\n\n${body}\n\n"
}

ui_warn_message() {
  local title="$1"
  local body="$2"

  ui_print_raw "\n[${title}]\n${body}\n\n"
}

ui_confirm_text() {
  local title="$1"
  local body="$2"

  if ui_use_whiptail; then
    whiptail --title "${title}" --yesno "${body}" 24 100
    return $?
  fi

  ui_require_interactive || return 1

  ui_print_raw "\n${title}\n\n${body}\n\n"
  ui_print_raw "继续执行请输入 yes："
  ui_read_line || return 1
  [[ "$(ui_trim_value "${UI_LAST_INPUT}")" == "yes" ]]
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
    [[ "$(ui_trim_value "${result}")" == "yes" ]]
    return $?
  fi

  ui_require_interactive || return 1

  ui_print_raw "\n${title}\n\n${body}\n\n"
  ui_print_raw "输入 yes 继续执行，输入 0 返回上一级菜单："
  ui_read_line || return 1
  [[ "$(ui_trim_value "${UI_LAST_INPUT}")" == "yes" ]]
}

ui_prompt_input() {
  local title="$1"
  local prompt="$2"
  local default_value="${3:-}"

  UI_LAST_INPUT=""
  export UI_LAST_INPUT

  ui_require_interactive || return 1

  ui_print_raw "\n${title}\n\n${prompt}\n"
  if [[ -n "${default_value}" ]]; then
    ui_print_raw "默认值：${default_value}\n"
  fi
  ui_print_raw "请输入："
  ui_read_line || return 1
  return 0
}

ui_choose_phase() {
  local default_phase="${1:-init}"
  UI_LAST_INPUT=""
  export UI_LAST_INPUT

  ui_require_interactive || return 1

  while true; do
    ui_print_raw $'\nVPS 初始化与维护根菜单\n\n'
    ui_print_raw $'1. 初始化菜单\n'
    ui_print_raw $'   进入初始化 1 到 13 步菜单，按数字执行。\n'
    ui_print_raw $'2. 长期维护菜单\n'
    ui_print_raw $'   进入维护 1 到 10 菜单，10 可继续进入谨慎操作子菜单。\n'
    ui_print_raw $'0. 退出程序\n\n'
    ui_print_raw "请输入编号："
    ui_read_line || return 1

    case "$(ui_trim_value "${UI_LAST_INPUT}")" in
      0)
        UI_LAST_INPUT="0"
        export UI_LAST_INPUT
        return 0
        ;;
      1|init)
        UI_LAST_INPUT="init"
        export UI_LAST_INPUT
        return 0
        ;;
      2|maintain)
        UI_LAST_INPUT="maintain"
        export UI_LAST_INPUT
        return 0
        ;;
      "")
        ui_warn_message "输入为空" "请输入 1、2 或 0。默认流程 ${default_phase} 仅作提示，不会自动代选。"
        ;;
      *)
        ui_warn_message "输入无效" "根菜单只支持输入 1、2 或 0。"
        ;;
    esac
  done
}
