#!/usr/bin/env bash
set -euo pipefail

# Module: 03_admin_user
# Purpose: 创建管理用户，并只配置 sudo 行为。
# Preconditions: root；Debian 12；ADMIN_USER 不得为 root。
# Steps:
#   1. 确认目标用户与组
#   2. 不存在则创建用户
#   3. 交互选择 sudo 行为
#   4. 若选择 sudo=password，则设置该用户用于 sudo 验证的本地密码
#   5. 应用 sudoers，并做运行时验证
# Idempotency:
#   - 已存在用户只做必要修正
#   - sudo 模式可重复切换

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

_ADMIN_SUDO_MODE_SELECTED="${_ADMIN_SUDO_MODE_SELECTED:-}"
_ADMIN_SUDO_PASSWORD_VALUE="${_ADMIN_SUDO_PASSWORD_VALUE:-}"

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

admin_user_effective_groups_csv() {
  local groups_csv="${ADMIN_USER_GROUPS:-sudo}"

  if printf '%s\n' "${groups_csv}" | tr ',' '\n' | grep -Fxq "sudo"; then
    printf '%s\n' "${groups_csv}"
    return 0
  fi

  if [[ -n "${groups_csv}" ]]; then
    printf '%s\n' "${groups_csv},sudo"
    return 0
  fi

  printf '%s\n' "sudo"
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

capture_admin_sudo_password_value() {
  local password=""
  local password_confirm=""

  while true; do
    if ! ui_read_secret "第 5.2 段 设置 sudo 验证密码" "请输入 ${ADMIN_USER} 用于 sudo 验证的密码："; then
      die "无法安全读取 sudo 验证密码输入，请在交互式终端中执行。"
    fi
    password="${UI_LAST_SECRET}"
    UI_LAST_SECRET=""

    if [[ -z "${password}" ]]; then
      ui_warn_message "密码为空" "sudo 验证密码不能为空，请重新输入。"
      continue
    fi

    if ! ui_read_secret "第 5.2 段 确认 sudo 验证密码" "请再次输入 ${ADMIN_USER} 用于 sudo 验证的密码："; then
      password=""
      die "无法安全读取 sudo 验证密码确认输入，请在交互式终端中执行。"
    fi
    password_confirm="${UI_LAST_SECRET}"
    UI_LAST_SECRET=""

    if [[ "${password}" != "${password_confirm}" ]]; then
      password=""
      password_confirm=""
      ui_warn_message "密码不一致" "两次输入的 sudo 验证密码不一致，请重新输入。"
      continue
    fi

    _ADMIN_SUDO_PASSWORD_VALUE="${password}"
    return 0
  done
}

capture_admin_sudo_mode() {
  local default_mode="${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}"
  local answer=""

  _ADMIN_SUDO_MODE_SELECTED=""
  _ADMIN_SUDO_PASSWORD_VALUE=""

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    _ADMIN_SUDO_MODE_SELECTED="${default_mode}"
    if [[ "${_ADMIN_SUDO_MODE_SELECTED}" == "password" ]]; then
      log info "[plan] sudo=password will prompt for a password and set it as ${ADMIN_USER}'s local password for sudo verification."
    fi
    log info "[plan] sudo mode: ${_ADMIN_SUDO_MODE_SELECTED}"
    return 0
  fi

  ui_require_interactive || die "当前不是交互式终端，无法安全选择 sudo 行为。"

  while true; do
    if ! ui_prompt_input \
      "第 5.2 段 配置 sudo 行为" \
      "当前正在设置：sudo 是否需要密码\n- nopasswd = 执行 sudo 不需要密码\n- password = 执行 sudo 需要密码\n- 如果选择 password，接下来会设置该管理用户用于 sudo 验证的密码\n- 0 = 返回" \
      "${default_mode}"; then
      die "无法读取 sudo 模式选择，请在交互式终端中执行。"
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      0)
        die "sudo 行为配置已取消。"
        ;;
      nopasswd)
        _ADMIN_SUDO_MODE_SELECTED="nopasswd"
        log info "Selected sudo mode: nopasswd"
        return 0
        ;;
      password)
        _ADMIN_SUDO_MODE_SELECTED="password"
        capture_admin_sudo_password_value
        log info "Selected sudo mode: password"
        return 0
        ;;
      *)
        ui_warn_message "输入无效" "请输入 nopasswd、password 或 0。"
        ;;
    esac
  done
}

verify_password_required_sudo_runtime() {
  local sudo_output=""
  local sudo_status=0

  sudo_output="$(
    env LC_ALL=C LANG=C sudo -u "${ADMIN_USER}" sudo -n true 2>&1
  )" || sudo_status=$?

  if [[ "${sudo_status}" -eq 0 ]]; then
    die "Expected password-required sudo for ${ADMIN_USER}, but sudo -n succeeded unexpectedly."
  fi

  if [[ "${sudo_output}" == *"password is required"* || "${sudo_output}" == *"a password is required"* ]]; then
    log info "Verified password-required sudo for ${ADMIN_USER}."
    set_state "ADMIN_SUDO_RUNTIME_VERIFIED" "yes"
    return 0
  fi

  die "Expected password-required sudo for ${ADMIN_USER}, but got: ${sudo_output:-<no output>}"
}

verify_nopasswd_sudo_runtime() {
  local sudo_output=""
  local sudo_status=0

  sudo_output="$(
    env LC_ALL=C LANG=C sudo -u "${ADMIN_USER}" sudo -n true 2>&1
  )" || sudo_status=$?

  if [[ "${sudo_status}" -eq 0 ]]; then
    log info "Verified nopasswd sudo for ${ADMIN_USER}."
    set_state "ADMIN_SUDO_RUNTIME_VERIFIED" "yes"
    return 0
  fi

  die "Configured nopasswd sudo for ${ADMIN_USER}, but runtime verification failed: ${sudo_output:-<no output>}"
}

apply_validated_sudoers_dropin() {
  local content="$1"
  local dropin_path=""

  dropin_path="$(sudoers_dropin_path)"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] write sudoers drop-in: ${dropin_path}"
    log info "[plan] content: ${content}"
    log info "[plan] visudo -c -f ${dropin_path}"
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
}

apply_nopasswd_sudo() {
  local content=""

  content="${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL"
  apply_validated_sudoers_dropin "${content}"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] verify sudo -n true for ${ADMIN_USER}"
    return 0
  fi

  verify_nopasswd_sudo_runtime
}

apply_password_required_sudo() {
  local content=""

  content="${ADMIN_USER} ALL=(ALL:ALL) ALL"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] set local password for ${ADMIN_USER} from the hidden sudo password input"
    apply_validated_sudoers_dropin "${content}"
    log info "[plan] verify sudo -n true fails for ${ADMIN_USER}"
    return 0
  fi

  [[ -n "${_ADMIN_SUDO_PASSWORD_VALUE}" ]] || die "sudo=password 已选择，但当前没有可用的 sudo 验证密码输入。"
  printf '%s:%s\n' "${ADMIN_USER}" "${_ADMIN_SUDO_PASSWORD_VALUE}" | chpasswd
  _ADMIN_SUDO_PASSWORD_VALUE=""
  log info "Updated local password for ${ADMIN_USER} for sudo verification."

  apply_validated_sudoers_dropin "${content}"
  verify_password_required_sudo_runtime
}

apply_sudo_mode() {
  case "${_ADMIN_SUDO_MODE_SELECTED}" in
    nopasswd)
      apply_nopasswd_sudo
      set_state "ADMIN_SUDO_MODE" "nopasswd"
      set_state "ADMIN_SUDO_PASSWORD_REQUEST" "n/a"
      set_state "ADMIN_SUDO_PASSWORD_IMPLEMENTATION" "n/a"
      set_state "ADMIN_SUDO_PASSWORD_SOURCE" "n/a"
      set_state "ADMIN_ACCOUNT_PASSWORD_ACTION" "not-managed"
      ;;
    password)
      apply_password_required_sudo
      set_state "ADMIN_SUDO_MODE" "password"
      set_state "ADMIN_SUDO_PASSWORD_REQUEST" "sudo-password"
      set_state "ADMIN_SUDO_PASSWORD_IMPLEMENTATION" "local-user-password"
      set_state "ADMIN_SUDO_PASSWORD_SOURCE" "local-user-password"
      set_state "ADMIN_ACCOUNT_PASSWORD_ACTION" "set-for-sudo"
      ;;
    *)
      die "Unknown sudo mode: ${_ADMIN_SUDO_MODE_SELECTED:-<empty>}"
      ;;
  esac

  set_state "ADMIN_ACCOUNT_PASSWORD_STATE" "$(user_account_password_state "${ADMIN_USER}")"
}

main() {
  load_config
  init_runtime
  module_banner "03_admin_user" "创建管理用户并配置 sudo 行为"
  require_root
  require_debian12

  local admin_groups=""
  local current_shell=""
  local home_dir=""

  ADMIN_SUDO_MODE_DEFAULT="${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}"
  validate_admin_sudo_mode_default

  if [[ -z "${ADMIN_USER}" ]]; then
    log warn "ADMIN_USER is empty. Skip admin user creation."
    set_state "ADMIN_USER_EXISTS" "no"
    return 0
  fi

  admin_groups="$(admin_user_effective_groups_csv)"
  ensure_groups "${admin_groups}"

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    log info "Admin user already exists: ${ADMIN_USER}"
  else
    run_cmd "Creating admin user ${ADMIN_USER}" \
      useradd -m -s "${ADMIN_USER_SHELL}" -G "${admin_groups}" "${ADMIN_USER}"
  fi

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

  run_cmd "Ensuring sudo groups for ${ADMIN_USER}" usermod -aG "${admin_groups}" "${ADMIN_USER}"
  ensure_directory "${home_dir}" "0750" "${ADMIN_USER}" "${ADMIN_USER}"

  capture_admin_sudo_mode
  apply_sudo_mode

  set_state "ADMIN_USER_EXISTS" "yes"
  set_state "ADMIN_USER" "${ADMIN_USER}"
}

main "$@"
