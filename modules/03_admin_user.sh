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

apply_nopasswd_sudo() {
  local dropin_path=""
  dropin_path="$(sudoers_dropin_path)"
  local content="${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] write sudoers drop-in: ${dropin_path}"
    log info "[plan] content: ${content}"
    log info "[plan] passwd -l ${ADMIN_USER}"
    return 0
  fi

  printf '%s\n' "${content}" > "${dropin_path}"
  chown root:root "${dropin_path}"
  chmod 0440 "${dropin_path}"
  log info "Sudoers drop-in written: ${dropin_path}"

  if ! visudo -c -f "${dropin_path}" >/dev/null 2>&1; then
    rm -f "${dropin_path}"
    die "visudo 校验失败，已回滚 ${dropin_path}。请检查用户名是否合法。"
  fi
  log info "visudo validation passed: ${dropin_path}"

  passwd -l "${ADMIN_USER}"
  log info "Local password locked for ${ADMIN_USER}."
}

apply_password_sudo() {
  local dropin_path=""
  dropin_path="$(sudoers_dropin_path)"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] set local password for ${ADMIN_USER} (hidden)"
    log info "[plan] remove sudoers drop-in if exists: ${dropin_path}"
    return 0
  fi

  # Read password interactively — caller must ensure interactive availability
  local password=""
  local password_confirm=""

  if ! ui_read_secret "设置 sudo 密码" "请输入 ${ADMIN_USER} 的 sudo 密码："; then
    die "无法读取密码输入，请在交互式终端中执行。"
  fi
  password="${UI_LAST_SECRET}"
  UI_LAST_SECRET=""

  if [[ -z "${password}" ]]; then
    die "密码不能为空。"
  fi

  if ! ui_read_secret "确认 sudo 密码" "请再次输入相同的密码："; then
    die "无法读取密码输入，请在交互式终端中执行。"
  fi
  password_confirm="${UI_LAST_SECRET}"
  UI_LAST_SECRET=""

  if [[ "${password}" != "${password_confirm}" ]]; then
    password=""
    password_confirm=""
    die "两次输入的密码不一致。"
  fi
  password_confirm=""

  # Set local password via chpasswd — password never appears in ps or logs
  printf '%s:%s\n' "${ADMIN_USER}" "${password}" | chpasswd
  password=""
  log info "Local password set for ${ADMIN_USER}."

  # Remove NOPASSWD drop-in if it exists
  if [[ -f "${dropin_path}" ]]; then
    rm -f "${dropin_path}"
    log info "Removed sudoers drop-in: ${dropin_path}"
  fi
}

prompt_sudo_mode() {
  # Returns: nopasswd or password
  # Direct Enter = nopasswd; any non-empty input triggers password flow
  local default_mode="${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}"

  # Non-interactive or plan/dry-run: use default
  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "Plan/Dry-run mode: using default sudo mode: ${default_mode}"
    printf '%s\n' "${default_mode}"
    return 0
  fi

  if ! ui_is_interactive; then
    if [[ "${default_mode}" == "password" ]]; then
      die "ADMIN_SUDO_MODE_DEFAULT=password 但当前不是交互式终端，无法安全读取密码。请在交互式终端中执行，或设置 ADMIN_SUDO_MODE_DEFAULT=nopasswd。"
    fi
    log info "Non-interactive mode: using default sudo mode: ${default_mode}"
    printf '%s\n' "${default_mode}"
    return 0
  fi

  ui_print_raw "\nsudo 模式选择\n\n"
  ui_print_raw "请选择 ${ADMIN_USER} 的 sudo 模式：\n"
  ui_print_raw "- 直接回车 = 免密 sudo（推荐，仅允许公钥登录时最安全）\n"
  ui_print_raw "- 输入任意密码 = sudo 需要该密码\n\n"
  ui_print_raw "注意：设置 sudo 密码不会自动启用 SSH 密码登录，SSH 登录策略由其他步骤控制。\n\n"
  ui_print_raw "请输入 sudo 密码（直接回车 = 免密 sudo）："

  local answer=""
  if ui_open_tty; then
    IFS= read -rs answer <"/dev/fd/${UI_TTY_FD}" || answer=""
    printf '\n' >"/dev/fd/${UI_TTY_FD}"
  elif [[ -t 0 ]]; then
    IFS= read -rs answer || answer=""
    printf '\n' >&2
  else
    answer=""
  fi

  if [[ -z "${answer}" ]]; then
    printf '%s\n' "nopasswd"
  else
    # Store the initial password for verification inside apply_password_sudo
    # This avoids asking the password a third time
    _SUDO_INITIAL_PASSWORD="${answer}"
    answer=""
    printf '%s\n' "password"
  fi
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
      apply_password_sudo_with_initial
      ;;
    *)
      die "Unknown sudo mode: ${mode}. Must be nopasswd or password."
      ;;
  esac

  set_state "ADMIN_SUDO_MODE" "${mode}"
}

apply_password_sudo_with_initial() {
  local dropin_path=""
  dropin_path="$(sudoers_dropin_path)"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] set local password for ${ADMIN_USER} (hidden)"
    log info "[plan] remove sudoers drop-in if exists: ${dropin_path}"
    return 0
  fi

  local password="${_SUDO_INITIAL_PASSWORD:-}"
  _SUDO_INITIAL_PASSWORD=""

  if [[ -z "${password}" ]]; then
    die "密码不能为空。"
  fi

  # Confirm password
  if ! ui_read_secret "确认 sudo 密码" "请再次输入相同的密码："; then
    password=""
    die "无法读取密码输入，请在交互式终端中执行。"
  fi
  local password_confirm="${UI_LAST_SECRET}"
  UI_LAST_SECRET=""

  if [[ "${password}" != "${password_confirm}" ]]; then
    password=""
    password_confirm=""
    die "两次输入的密码不一致。"
  fi
  password_confirm=""

  # Set local password via chpasswd — password never appears in ps or logs
  printf '%s:%s\n' "${ADMIN_USER}" "${password}" | chpasswd
  password=""
  log info "Local password set for ${ADMIN_USER}."

  # Remove NOPASSWD drop-in if it exists
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

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    local current_shell
    current_shell="$(getent passwd "${ADMIN_USER}" | cut -d: -f7)"
    if [[ "${current_shell}" != "${ADMIN_USER_SHELL}" ]]; then
      run_cmd "Updating shell for ${ADMIN_USER}" usermod -s "${ADMIN_USER_SHELL}" "${ADMIN_USER}"
    fi

    run_cmd "Ensuring sudo groups for ${ADMIN_USER}" usermod -aG "${ADMIN_USER_GROUPS}" "${ADMIN_USER}"

    local home_dir
    home_dir="$(home_dir_for_user "${ADMIN_USER}")"
    ensure_directory "${home_dir}" "0750" "${ADMIN_USER}" "${ADMIN_USER}"

    # Sudo mode selection and application
    local sudo_mode=""
    sudo_mode="$(prompt_sudo_mode)"
    apply_sudo_mode "${sudo_mode}"
  else
    log info "Plan/Dry-run note: user ${ADMIN_USER} not yet present locally, so post-create checks are skipped."
  fi

  set_state "ADMIN_USER_EXISTS" "yes"
  set_state "ADMIN_USER" "${ADMIN_USER}"
}

main "$@"
