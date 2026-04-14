#!/usr/bin/env bash
set -euo pipefail

# Module: 03_admin_user
# Purpose: 创建管理用户并加入 sudo，配置 sudo 模式。
# Preconditions: root；Debian 12；ADMIN_USER 不得为 root。
# Steps:
#   1. 确认目标用户与组
#   2. 不存在则创建用户
#   3. 确保 shell、补充组、home 目录正确
#   4. 交互选择 sudo 模式：
#      - 直接回车 = 免密 sudo（写入 sudoers drop-in，锁定密码）
#      - 输入密码 = sudo 需要该密码（设置本地密码，移除 NOPASSWD drop-in）
#   5. 非交互 / plan / dry-run 使用 ADMIN_SUDO_MODE_DEFAULT
# Idempotency:
#   - 已存在用户只做必要修正
#   - 已存在组不会重复创建
#   - nopasswd -> password / password -> nopasswd 均可幂等切换

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

_ADMIN_SUDO_PASSWORD="${_ADMIN_SUDO_PASSWORD:-}"

ensure_groups() {
  local groups_csv="$1"
  local group=""
  IFS=',' read -r -a group_list <<<"${groups_csv}"
  for group in "${group_list[@]}"; do
    [[ -n "${group}" ]] || continue
    if ! getent group "${group}" >/dev/null 2>&1; then
      run_cmd "Creating group ${group}" groupadd "${group}"
    fi
  done
}

sudoers_dropin_path() {
  printf '/etc/sudoers.d/90-%s\n' "${ADMIN_USER}"
}

validate_admin_sudo_mode_default() {
  local mode=""
  mode="$(ui_trim_value "${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}")"

  case "${mode}" in
    nopasswd|password)
      ADMIN_SUDO_MODE_DEFAULT="${mode}"
      ;;
    *)
      die "ADMIN_SUDO_MODE_DEFAULT 只允许 nopasswd 或 password，当前值：${ADMIN_SUDO_MODE_DEFAULT:-<empty>}。"
      ;;
  esac
}

capture_admin_sudo_mode() {
  local default_mode="${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}"
  local password=""

  _ADMIN_SUDO_PASSWORD=""

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    printf '%s\n' "${default_mode}"
    return 0
  fi

  if ! ui_is_interactive; then
    if [[ "${default_mode}" == "password" ]]; then
      die "ADMIN_SUDO_MODE_DEFAULT=password 但当前不是交互式终端，无法安全读取密码。请在交互式终端中执行，或设置 ADMIN_SUDO_MODE_DEFAULT=nopasswd。"
    fi
    printf '%s\n' "${default_mode}"
    return 0
  fi

  if ! ui_read_secret \
    "设置 sudo 模式" \
    "请输入 ${ADMIN_USER} 的 sudo 密码。\n\n直接回车 = 免密 sudo\n输入非空密码 = sudo 需要该密码\n\n注意：这里设置的是本地 sudo 行为，不会自动启用 SSH 密码登录。"; then
    die "无法安全读取 sudo 密码输入，请在交互式终端中执行。"
  fi

  password="${UI_LAST_SECRET}"
  UI_LAST_SECRET=""

  if [[ -z "${password}" ]]; then
    printf '%s\n' "nopasswd"
    return 0
  fi

  _ADMIN_SUDO_PASSWORD="${password}"
  password=""
  printf '%s\n' "password"
}

confirm_admin_sudo_password() {
  local password_confirm=""

  if [[ -z "${_ADMIN_SUDO_PASSWORD}" ]]; then
    die "sudo 模式为 password，但当前没有可用的本地密码输入。"
  fi

  if ! ui_read_secret "确认 sudo 密码" "请再次输入 ${ADMIN_USER} 的 sudo 密码："; then
    _ADMIN_SUDO_PASSWORD=""
    die "无法安全读取 sudo 密码确认输入，请在交互式终端中执行。"
  fi

  password_confirm="${UI_LAST_SECRET}"
  UI_LAST_SECRET=""

  if [[ "${_ADMIN_SUDO_PASSWORD}" != "${password_confirm}" ]]; then
    _ADMIN_SUDO_PASSWORD=""
    password_confirm=""
    die "两次输入的密码不一致。"
  fi

  password_confirm=""
}

apply_nopasswd_sudo() {
  local dropin_path=""
  local content=""

  dropin_path="$(sudoers_dropin_path)"
  content="${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] write sudoers drop-in: ${dropin_path}"
    log info "[plan] content: ${content}"
    log info "[plan] set owner/group root:root and mode 0440 on ${dropin_path}"
    log info "[plan] visudo -c -f ${dropin_path}"
    log info "[plan] passwd -l ${ADMIN_USER}"
    return 0
  fi

  command_exists visudo || die "visudo command not found."

  apply_managed_file "${dropin_path}" "0440" "${content}"
  chown root:root "${dropin_path}"
  chmod 0440 "${dropin_path}"

  if ! visudo -c -f "${dropin_path}" >/dev/null 2>&1; then
    rm -f "${dropin_path}"
    die "visudo 校验失败，已移除 ${dropin_path}。请检查用户名是否合法。"
  fi
  log info "visudo validation passed: ${dropin_path}"

  passwd -l "${ADMIN_USER}" >/dev/null
  log info "Local password locked for ${ADMIN_USER}."
}

apply_sudo_mode() {
  local mode="$1"

  case "${mode}" in
    nopasswd)
      log info "Applying sudo mode: nopasswd (passwordless sudo)"
      apply_nopasswd_sudo
      ;;
    password)
      log info "Applying sudo mode: password (sudo requires password)"
      apply_password_sudo
      ;;
    *)
      die "Unknown sudo mode: ${mode}. Must be nopasswd or password."
      ;;
  esac

  set_state "ADMIN_SUDO_MODE" "${mode}"
}

apply_password_sudo() {
  local dropin_path=""
  dropin_path="$(sudoers_dropin_path)"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] set local password for ${ADMIN_USER} (hidden)"
    log info "[plan] remove sudoers drop-in if exists: ${dropin_path}"
    return 0
  fi

  confirm_admin_sudo_password

  printf '%s:%s\n' "${ADMIN_USER}" "${_ADMIN_SUDO_PASSWORD}" | chpasswd
  _ADMIN_SUDO_PASSWORD=""
  log info "Local password set for ${ADMIN_USER}."

  if [[ -f "${dropin_path}" ]]; then
    rm -f "${dropin_path}"
    log info "Removed sudoers drop-in: ${dropin_path}"
  fi
}

main() {
  load_config
  init_runtime
  module_banner "03_admin_user" "创建管理用户并加入 sudo"
  require_root
  require_debian12

  ADMIN_SUDO_MODE_DEFAULT="${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}"
  validate_admin_sudo_mode_default

  if [[ -z "${ADMIN_USER}" ]]; then
    log warn "ADMIN_USER is empty. Skip admin user creation."
    set_state "ADMIN_USER_EXISTS" "no"
    return 0
  fi

  ensure_groups "${ADMIN_USER_GROUPS}"

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    log info "Admin user already exists: ${ADMIN_USER}"
  else
    run_cmd "Creating admin user ${ADMIN_USER}" \
      useradd -m -s "${ADMIN_USER_SHELL}" -G "${ADMIN_USER_GROUPS}" "${ADMIN_USER}"
  fi

  local current_shell=""
  local home_dir=""
  local sudo_mode=""

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    current_shell="$(getent passwd "${ADMIN_USER}" | cut -d: -f7)"
    home_dir="$(home_dir_for_user "${ADMIN_USER}")"
  elif is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "Plan/Dry-run note: ${ADMIN_USER} does not exist yet; assume /home/${ADMIN_USER} for preview."
    current_shell="${ADMIN_USER_SHELL}"
    home_dir="/home/${ADMIN_USER}"
  else
    die "Admin user ${ADMIN_USER} was not created successfully."
  fi

  if [[ "${current_shell}" != "${ADMIN_USER_SHELL}" ]]; then
    run_cmd "Updating shell for ${ADMIN_USER}" usermod -s "${ADMIN_USER_SHELL}" "${ADMIN_USER}"
  fi

  run_cmd "Ensuring sudo groups for ${ADMIN_USER}" usermod -aG "${ADMIN_USER_GROUPS}" "${ADMIN_USER}"

  ensure_directory "${home_dir}" "0750" "${ADMIN_USER}" "${ADMIN_USER}"

  sudo_mode="$(capture_admin_sudo_mode)"
  apply_sudo_mode "${sudo_mode}"

  set_state "ADMIN_USER_EXISTS" "yes"
  set_state "ADMIN_USER" "${ADMIN_USER}"
}

main "$@"
