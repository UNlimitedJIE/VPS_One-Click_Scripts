#!/usr/bin/env bash
set -euo pipefail

# Module: 03_admin_user
# Purpose: 创建管理用户，并分别配置 sudo 认证和本地账户密码策略。
# Preconditions: root；Debian 12；ADMIN_USER 不得为 root。
# Steps:
#   1. 确认目标用户与组
#   2. 不存在则创建用户
#   3. 交互选择账户密码行为
#   4. 交互选择 sudo 行为
#   5. 分别应用账户密码与 sudo 配置，并做运行时验证
# Idempotency:
#   - 已存在用户只做必要修正
#   - sudo 与账户密码可重复切换

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

_ADMIN_SUDO_MODE_SELECTED="${_ADMIN_SUDO_MODE_SELECTED:-}"
_ADMIN_SUDO_PASSWORD_SOURCE="${_ADMIN_SUDO_PASSWORD_SOURCE:-}"
_ADMIN_ACCOUNT_PASSWORD_ACTION="${_ADMIN_ACCOUNT_PASSWORD_ACTION:-}"
_ADMIN_ACCOUNT_PASSWORD_VALUE="${_ADMIN_ACCOUNT_PASSWORD_VALUE:-}"

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

planned_admin_account_password_available() {
  case "${_ADMIN_ACCOUNT_PASSWORD_ACTION:-keep}" in
    set)
      return 0
      ;;
    lock)
      return 1
      ;;
    keep|"")
      user_account_password_available "${ADMIN_USER}"
      ;;
    *)
      return 1
      ;;
  esac
}

planned_admin_account_password_state_label() {
  case "${_ADMIN_ACCOUNT_PASSWORD_ACTION:-keep}" in
    set)
      printf '%s\n' "将设置/更新账户密码"
      ;;
    lock)
      printf '%s\n' "将锁定账户密码"
      ;;
    keep|"")
      printf '%s\n' "$(user_account_password_state_label "${ADMIN_USER}")"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

capture_account_password_value() {
  local password=""
  local password_confirm=""

  while true; do
    if ! ui_read_secret "第 4.2 段 设置账户密码" "请输入 ${ADMIN_USER} 的本地账户密码："; then
      die "无法安全读取账户密码输入，请在交互式终端中执行。"
    fi
    password="${UI_LAST_SECRET}"
    UI_LAST_SECRET=""

    if [[ -z "${password}" ]]; then
      ui_warn_message "密码为空" "账户密码不能为空，请重新输入。"
      continue
    fi

    if ! ui_read_secret "第 4.2 段 确认账户密码" "请再次输入 ${ADMIN_USER} 的本地账户密码："; then
      password=""
      die "无法安全读取账户密码确认输入，请在交互式终端中执行。"
    fi
    password_confirm="${UI_LAST_SECRET}"
    UI_LAST_SECRET=""

    if [[ "${password}" != "${password_confirm}" ]]; then
      password=""
      password_confirm=""
      ui_warn_message "密码不一致" "两次输入的账户密码不一致，请重新输入。"
      continue
    fi

    _ADMIN_ACCOUNT_PASSWORD_VALUE="${password}"
    return 0
  done
}

confirm_account_password_lock_risk() {
  local answer=""

  while true; do
    if ! ui_prompt_input \
      "第 4.2 段 锁定账户密码风险确认" \
      "当前 authorized_keys 还没安装成功。\n如果现在锁账户密码，这个账户之后就不能再用密码认证。\n输入 y 继续锁定（yes 也可），输入 0 返回。" \
      "0"; then
      return 1
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    if ui_input_is_affirmative "${answer}"; then
      return 0
    fi
    if [[ "${answer}" == "0" || -z "${answer}" ]]; then
      return 1
    fi
    ui_warn_message "输入无效" "请输入 y 继续锁定（yes 也可），或输入 0 返回。"
  done
}

capture_admin_account_password_behavior() {
  local current_state_label=""
  local answer=""
  local default_value="keep"

  _ADMIN_ACCOUNT_PASSWORD_ACTION="keep"
  _ADMIN_ACCOUNT_PASSWORD_VALUE=""

  current_state_label="$(user_account_password_state_label "${ADMIN_USER}")"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    _ADMIN_ACCOUNT_PASSWORD_ACTION="keep"
    log info "[plan] account password action: ${_ADMIN_ACCOUNT_PASSWORD_ACTION} (current state: ${current_state_label})"
    return 0
  fi

  while true; do
    if ! ui_prompt_input \
      "第 4.2 段 配置账户密码" \
      "当前正在设置：管理用户 ${ADMIN_USER} 的账户密码状态\n当前状态：${current_state_label}\n- keep = 保持当前账户密码状态不变\n- set = 现在设置/更新账户密码\n- lock = 锁定账户密码，之后不能再用密码认证该账户\n- 0 = 返回\n如果下一步选择 sudo=password，sudo 使用的就是这个账户密码。" \
      "${default_value}"; then
      die "无法读取账户密码行为，请在交互式终端中执行。"
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      0)
        die "账户密码配置已取消。"
        ;;
      keep)
        _ADMIN_ACCOUNT_PASSWORD_ACTION="keep"
        log info "Account password action: keep current state"
        return 0
        ;;
      set)
        _ADMIN_ACCOUNT_PASSWORD_ACTION="set"
        capture_account_password_value
        log info "Account password action: set"
        return 0
        ;;
      lock|locked|unset)
        if ! admin_authorized_keys_ready_for_user "${ADMIN_USER}"; then
          confirm_account_password_lock_risk || continue
        fi
        _ADMIN_ACCOUNT_PASSWORD_ACTION="lock"
        log info "Account password action: lock"
        return 0
        ;;
      *)
        ui_warn_message "输入无效" "请输入 keep、set、lock 或 0。"
        ;;
    esac
  done
}

apply_account_password_behavior() {
  case "${_ADMIN_ACCOUNT_PASSWORD_ACTION}" in
    keep)
      log info "Keeping current account password state for ${ADMIN_USER}: $(user_account_password_state_label "${ADMIN_USER}")"
      ;;
    set)
      if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
        log info "[plan] set account password for ${ADMIN_USER} (hidden)"
      else
        [[ -n "${_ADMIN_ACCOUNT_PASSWORD_VALUE}" ]] || die "账户密码动作为 set，但当前没有可用的密码输入。"
        printf '%s:%s\n' "${ADMIN_USER}" "${_ADMIN_ACCOUNT_PASSWORD_VALUE}" | chpasswd
        _ADMIN_ACCOUNT_PASSWORD_VALUE=""
        log info "Account password updated for ${ADMIN_USER}."
      fi
      ;;
    lock)
      if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
        log info "[plan] passwd -l ${ADMIN_USER}"
      else
        passwd -l "${ADMIN_USER}" >/dev/null
        log info "Account password locked for ${ADMIN_USER}."
      fi
      ;;
    *)
      die "Unknown account password action: ${_ADMIN_ACCOUNT_PASSWORD_ACTION:-<empty>}"
      ;;
  esac

  set_state "ADMIN_ACCOUNT_PASSWORD_ACTION" "${_ADMIN_ACCOUNT_PASSWORD_ACTION}"
  set_state "ADMIN_ACCOUNT_PASSWORD_STATE" "$(user_account_password_state "${ADMIN_USER}")"
}

capture_admin_sudo_mode() {
  local default_mode="${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}"
  local answer=""
  local password_state_label=""

  _ADMIN_SUDO_MODE_SELECTED=""
  _ADMIN_SUDO_PASSWORD_SOURCE="n/a"

  if ! planned_admin_account_password_available; then
    default_mode="nopasswd"
  fi

  password_state_label="$(planned_admin_account_password_state_label)"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    _ADMIN_SUDO_MODE_SELECTED="${default_mode}"
    if [[ "${_ADMIN_SUDO_MODE_SELECTED}" == "password" ]]; then
      _ADMIN_SUDO_PASSWORD_SOURCE="account-password"
      log info "[plan] sudo=password will use the admin account password."
    fi
    log info "[plan] sudo mode: ${_ADMIN_SUDO_MODE_SELECTED} (account password state: ${password_state_label})"
    return 0
  fi

  ui_require_interactive || die "当前不是交互式终端，无法安全选择 sudo 行为。"

  while true; do
    if ! ui_prompt_input \
      "第 4.3 段 配置 sudo 行为" \
      "当前正在设置：sudo 是否需要密码\n当前账户密码状态：${password_state_label}\n- nopasswd = sudo 不需要密码\n- password = sudo 需要密码（使用该账户密码）\n- 0 = 返回\n这里只影响 sudo，不影响 SSH 登录方式。" \
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
        _ADMIN_SUDO_PASSWORD_SOURCE="n/a"
        log info "Selected sudo mode: nopasswd"
        return 0
        ;;
      password)
        if ! planned_admin_account_password_available; then
          ui_warn_message "当前组合无效" "当前账户密码未设置或已锁定，不能选择 sudo=password。请先回到上一步选择 keep/set，并确保账户密码可用。"
          continue
        fi
        _ADMIN_SUDO_MODE_SELECTED="password"
        _ADMIN_SUDO_PASSWORD_SOURCE="account-password"
        log info "Selected sudo mode: password (uses the admin account password)"
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

apply_nopasswd_sudo() {
  local dropin_path=""
  local content=""

  dropin_path="$(sudoers_dropin_path)"
  content="${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] write sudoers drop-in: ${dropin_path}"
    log info "[plan] content: ${content}"
    log info "[plan] visudo -c -f ${dropin_path}"
    log info "[plan] verify sudo -n true for ${ADMIN_USER}"
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
  verify_nopasswd_sudo_runtime
}

apply_password_required_sudo() {
  local dropin_path=""

  dropin_path="$(sudoers_dropin_path)"
  user_account_password_available "${ADMIN_USER}" || die "sudo password 模式需要该用户已有可用的账户密码。"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] remove sudoers drop-in if exists: ${dropin_path}"
    log info "[plan] verify sudo -n true fails for ${ADMIN_USER}"
    return 0
  fi

  if [[ -f "${dropin_path}" ]]; then
    rm -f "${dropin_path}"
    log info "Removed sudoers drop-in: ${dropin_path}"
  fi

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
      ;;
    password)
      apply_password_required_sudo
      set_state "ADMIN_SUDO_MODE" "password"
      set_state "ADMIN_SUDO_PASSWORD_REQUEST" "account-password"
      set_state "ADMIN_SUDO_PASSWORD_IMPLEMENTATION" "account-password"
      set_state "ADMIN_SUDO_PASSWORD_SOURCE" "account-password"
      ;;
    *)
      die "Unknown sudo mode: ${_ADMIN_SUDO_MODE_SELECTED:-<empty>}"
      ;;
  esac
}

main() {
  load_config
  init_runtime
  module_banner "03_admin_user" "创建管理用户并分别配置 sudo 与账户密码"
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

  capture_admin_account_password_behavior
  apply_account_password_behavior
  capture_admin_sudo_mode
  apply_sudo_mode

  set_state "ADMIN_USER_EXISTS" "yes"
  set_state "ADMIN_USER" "${ADMIN_USER}"
}

main "$@"
