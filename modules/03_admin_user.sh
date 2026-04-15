#!/usr/bin/env bash
set -euo pipefail

# Module: 03_admin_user
# Purpose: 创建管理用户，并分别配置 sudo 认证和本地账户密码策略。
# Preconditions: root；Debian 12；ADMIN_USER 不得为 root。
# Steps:
#   1. 确认目标用户与组
#   2. 不存在则创建用户
#   3. 交互选择 sudo 行为
#   4. 交互选择账户密码行为
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

capture_admin_sudo_mode() {
  local default_mode="${ADMIN_SUDO_MODE_DEFAULT:-nopasswd}"
  local answer=""

  _ADMIN_SUDO_MODE_SELECTED=""
  _ADMIN_SUDO_PASSWORD_SOURCE="n/a"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    _ADMIN_SUDO_MODE_SELECTED="${default_mode}"
    if [[ "${_ADMIN_SUDO_MODE_SELECTED}" == "password" ]]; then
      _ADMIN_SUDO_PASSWORD_SOURCE="shared-account-password"
      log info "[plan] sudo password mode will still use the admin account password; independent sudo password is not supported."
    fi
    log info "Selected sudo mode: ${_ADMIN_SUDO_MODE_SELECTED}"
    return 0
  fi

  ui_require_interactive || die "当前不是交互式终端，无法安全选择 sudo 行为。"

  while true; do
    if ! ui_prompt_input \
      "第 4.2 段 配置 sudo 行为" \
      "当前正在设置：sudo 是否需要密码\n- nopasswd = sudo 不需要密码\n- password = sudo 需要密码\n这里只影响 sudo，不影响 SSH 登录方式。" \
      "${default_mode}"; then
      die "无法读取 sudo 模式选择，请在交互式终端中执行。"
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      nopasswd|password)
        _ADMIN_SUDO_MODE_SELECTED="${answer}"
        log info "Selected sudo mode: ${_ADMIN_SUDO_MODE_SELECTED}"
        if [[ "${_ADMIN_SUDO_MODE_SELECTED}" == "password" ]]; then
          capture_admin_sudo_password_source
        fi
        return 0
        ;;
      *)
        ui_warn_message "输入无效" "请输入 nopasswd 或 password。"
        ;;
    esac
  done
}

confirm_admin_sudo_separate_password_fallback() {
  local answer=""

  while true; do
    if ! ui_prompt_input \
      "第 4.2 段 sudo 密码限制说明" \
      "当前实现不支持独立 sudo 密码。\n如果继续，sudo 仍使用 ${ADMIN_USER} 的账户密码。\n输入 yes 继续，输入 0 返回。" \
      "yes"; then
      die "无法读取 sudo 密码限制确认，请在交互式终端中执行。"
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      yes|YES|y|Y)
        return 0
        ;;
      0)
        return 1
        ;;
      *)
        ui_warn_message "输入无效" "请输入 yes 继续，或输入 0 返回重新选择 sudo 密码方案。"
        ;;
    esac
  done
}

capture_admin_sudo_password_source() {
  local answer=""
  local default_value="shared"

  while true; do
    if ! ui_prompt_input \
      "第 4.2 段 sudo 密码来源" \
      "当前正在设置：sudo 用哪个密码\n- shared = sudo 使用 ${ADMIN_USER} 的账户密码\n- separate = 想单独设置 sudo 密码\n- 0 = 返回\n当前实现不支持独立 sudo 密码；若选 separate，后面仍会回到使用账户密码。" \
      "${default_value}"; then
      die "无法读取 sudo 密码来源，请在交互式终端中执行。"
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      0)
        die "sudo 行为配置已取消。"
        ;;
      shared)
        _ADMIN_SUDO_PASSWORD_SOURCE="shared-account-password"
        log info "sudo password source request: use the admin account password"
        return 0
        ;;
      separate)
        if confirm_admin_sudo_separate_password_fallback; then
          _ADMIN_SUDO_PASSWORD_SOURCE="separate-requested-fallback-to-account-password"
          log info "sudo password source request: separate password requested, but implementation will still use the admin account password"
          return 0
        fi
        ;;
      *)
        ui_warn_message "输入无效" "请输入 shared、separate 或 0。"
        ;;
    esac
  done
}

capture_account_password_value() {
  local password=""
  local password_confirm=""

  while true; do
    if ! ui_read_secret "第 4.3 段 设置账户密码" "请输入 ${ADMIN_USER} 的本地账户密码："; then
      die "无法安全读取账户密码输入，请在交互式终端中执行。"
    fi
    password="${UI_LAST_SECRET}"
    UI_LAST_SECRET=""

    if [[ -z "${password}" ]]; then
      ui_warn_message "密码为空" "账户密码不能为空，请重新输入。"
      continue
    fi

    if ! ui_read_secret "第 4.3 段 确认账户密码" "请再次输入 ${ADMIN_USER} 的本地账户密码："; then
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
      "第 4.3 段 锁定账户密码风险确认" \
      "当前 authorized_keys 还没安装成功。\n如果现在锁账户密码，这个账户之后就不能再用密码认证。\n输入 yes 继续锁定，输入 0 返回。" \
      "0"; then
      return 1
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      yes|YES|y|Y)
        return 0
        ;;
      0|"")
        return 1
        ;;
      *)
        ui_warn_message "输入无效" "请输入 yes 继续锁定，或输入 0 返回。"
        ;;
    esac
  done
}

capture_admin_account_password_behavior() {
  local current_state_label=""
  local answer=""
  local default_value="keep"
  local password_is_available="no"

  _ADMIN_ACCOUNT_PASSWORD_ACTION="keep"
  _ADMIN_ACCOUNT_PASSWORD_VALUE=""

  current_state_label="$(user_account_password_state_label "${ADMIN_USER}")"
  if user_account_password_available "${ADMIN_USER}"; then
    password_is_available="yes"
  fi

  if [[ "${_ADMIN_SUDO_MODE_SELECTED}" == "password" && "${password_is_available}" != "yes" ]]; then
    default_value="set"
  fi

  if [[ "${_ADMIN_SUDO_PASSWORD_SOURCE}" == "separate-requested-fallback-to-account-password" ]]; then
    default_value="set"
  fi

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    if [[ "${_ADMIN_SUDO_MODE_SELECTED}" == "password" && "${password_is_available}" != "yes" ]]; then
      _ADMIN_ACCOUNT_PASSWORD_ACTION="set"
      log info "[plan] sudo password mode requires an available account password."
    elif [[ "${_ADMIN_SUDO_PASSWORD_SOURCE}" == "separate-requested-fallback-to-account-password" ]]; then
      _ADMIN_ACCOUNT_PASSWORD_ACTION="set"
      log info "[plan] user requested a separate sudo password, but current implementation still requires using the account password."
    else
      _ADMIN_ACCOUNT_PASSWORD_ACTION="keep"
    fi
    log info "[plan] account password action: ${_ADMIN_ACCOUNT_PASSWORD_ACTION} (current state: ${current_state_label})"
    return 0
  fi

  while true; do
    if ! ui_prompt_input \
      "第 4.3 段 配置账户密码" \
      "当前正在设置：管理用户 ${ADMIN_USER} 的账户密码状态\n当前状态：${current_state_label}\n- keep = 保持当前账户密码状态不变\n- set = 现在设置/更新账户密码\n- lock = 锁定账户密码，之后不能再用密码认证该账户\n- 0 = 返回\n若上一步选择了 sudo=password，则 sudo 也会使用这个账户密码。" \
      "${default_value}"; then
      die "无法读取账户密码行为，请在交互式终端中执行。"
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      0)
        die "账户密码配置已取消。"
        ;;
      keep)
        if [[ "${_ADMIN_SUDO_MODE_SELECTED}" == "password" ]] && ! user_account_password_available "${ADMIN_USER}"; then
          ui_warn_message "当前账户密码不可用" "sudo 需要密码时，该用户必须有可用的账户密码。请选择 set。"
          continue
        fi
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
        if [[ "${_ADMIN_SUDO_MODE_SELECTED}" == "password" ]]; then
          ui_warn_message "当前组合无效" "当前 sudo 需要密码，所以这个账户必须保留可用密码，不能选择 lock。"
          continue
        fi
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
      set_state "ADMIN_SUDO_PASSWORD_REQUEST" "${_ADMIN_SUDO_PASSWORD_SOURCE}"
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

  capture_admin_sudo_mode
  capture_admin_account_password_behavior

  apply_account_password_behavior
  apply_sudo_mode

  set_state "ADMIN_USER_EXISTS" "yes"
  set_state "ADMIN_USER" "${ADMIN_USER}"
}

main "$@"
