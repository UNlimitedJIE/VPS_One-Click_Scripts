#!/usr/bin/env bash
set -euo pipefail

# Module: 07_time_sync
# Purpose: 配置时区并启用 systemd-timesyncd。
# Preconditions: root；Debian 12。
# Steps:
#   1. 安装/确认 systemd-timesyncd
#   2. 设置时区
#   3. 启用 NTP 与 timesyncd
# Idempotency:
#   - 重复执行只会收敛到目标状态

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

timedatectl_value() {
  local key="${1:-}"
  timedatectl show --property="${key}" --value 2>/dev/null || true
}

timezone_choice_value() {
  case "${1:-}" in
    1) printf '%s\n' "UTC" ;;
    2) printf '%s\n' "Asia/Shanghai" ;;
    3) printf '%s\n' "Asia/Tokyo" ;;
    4) printf '%s\n' "Asia/Singapore" ;;
    5) printf '%s\n' "America/New_York" ;;
    6) printf '%s\n' "Europe/London" ;;
    *) return 1 ;;
  esac
}

timezone_value_is_valid() {
  local timezone="${1:-}"
  [[ -n "${timezone}" ]] || return 1
  timedatectl list-timezones 2>/dev/null | grep -Fx -- "${timezone}" >/dev/null
}

prompt_timezone_selection() {
  local current_timezone="${1:-UTC}"
  local choice=""
  local selected_timezone=""
  local custom_timezone=""

  ui_require_interactive || {
    printf '%s\n' "${current_timezone}"
    return 0
  }

  while true; do
    if ! ui_prompt_input \
      "第 7 步 配置时区" \
      "请选择时区：\n1. UTC\n2. Asia/Shanghai\n3. Asia/Tokyo\n4. Asia/Singapore\n5. America/New_York\n6. Europe/London\n7. 自定义输入\n0. 返回\n当前默认：${current_timezone}" \
      ""; then
      return 1
    fi

    choice="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${choice}" in
      "")
        selected_timezone="${current_timezone}"
        ;;
      0)
        return 1
        ;;
      1|2|3|4|5|6)
        selected_timezone="$(timezone_choice_value "${choice}")"
        ;;
      7)
        while true; do
          if ! ui_prompt_input "第 7 步 自定义时区" "请输入完整时区名称，例如 Asia/Hong_Kong\n输入 0 返回上一步"; then
            return 1
          fi
          custom_timezone="$(ui_trim_value "${UI_LAST_INPUT}")"
          [[ "${custom_timezone}" == "0" ]] && break
          if timezone_value_is_valid "${custom_timezone}"; then
            printf '%s\n' "${custom_timezone}"
            return 0
          fi
          ui_warn_message "时区无效" "请输入系统可识别的时区名称，例如 Asia/Hong_Kong。"
        done
        continue
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、3、4、5、6、7 或 0。"
        continue
        ;;
    esac

    if timezone_value_is_valid "${selected_timezone}"; then
      printf '%s\n' "${selected_timezone}"
      return 0
    fi

    ui_warn_message "时区无效" "当前选择的时区不可用，请重新选择。"
  done
}

main() {
  load_config
  init_runtime
  module_banner "07_time_sync" "时间同步与时区配置"
  require_root
  require_debian12

  local selected_timezone=""
  local current_timezone=""
  local ntp_service_state=""
  local ntp_sync_state=""

  if is_false "${ENABLE_TIME_SYNC}"; then
    log info "ENABLE_TIME_SYNC=false, skip."
    set_state "TIMESYNCD_ENABLED" "no"
    return 0
  fi

  apt_install_packages systemd-timesyncd tzdata

  current_timezone="$(timedatectl_value "Timezone")"
  [[ -n "${current_timezone}" ]] || current_timezone="${TIMEZONE:-UTC}"
  selected_timezone="$(prompt_timezone_selection "${current_timezone}" || true)"
  [[ -n "${selected_timezone}" ]] || {
    log info "时区选择已取消。"
    return 0
  }

  run_cmd "Setting timezone to ${selected_timezone}" timedatectl set-timezone "${selected_timezone}"

  run_cmd "Enabling NTP sync via timedatectl" timedatectl set-ntp true
  enable_and_start_service "systemd-timesyncd"

  ntp_service_state="$(systemctl is-enabled systemd-timesyncd 2>/dev/null || true)/$(systemctl is-active systemd-timesyncd 2>/dev/null || true)"
  ntp_sync_state="$(timedatectl_value "NTPSynchronized")"

  log info "当前时区: $(timedatectl_value "Timezone")"
  log info "NTP 服务状态: ${ntp_service_state:-unknown}"
  log info "是否同步: ${ntp_sync_state:-unknown}"

  set_state "TIMESYNCD_ENABLED" "yes"
  set_state "TIMEZONE" "${selected_timezone}"
}

main "$@"
