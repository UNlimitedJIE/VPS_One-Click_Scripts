#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

cutover_warning_body() {
  local effective_port=""
  effective_port="$(effective_ssh_port_for_changes)"

  cat <<EOF
此步骤将关闭 root 远程 SSH 登录。

继续前请再次确认：
- 管理用户：${ADMIN_USER:-<未设置>}
- 后续登录方式：管理用户 + SSH 公钥
- 当前 SSH 端口：${effective_port}
- 如果管理用户连接尚未验证成功，不要继续
- 如已修改 SSH 端口，还必须确认厂商安全组/云防火墙已同步放行该端口

只有在你已经准备好用管理用户和 SSH 私钥登录时，才应继续执行。
EOF
}

confirm_cutover_execution() {
  local answer=""

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "[plan] 第 5 步将要求确认后关闭 root 远程 SSH 登录。"
    return 0
  fi

  ui_require_interactive || die "关闭 root 远程登录前需要交互确认，请在交互式终端中执行。"

  while true; do
    if ! ui_prompt_input "确认关闭 root 远程登录" "$(cutover_warning_body)\n\n请输入 CUTOVER 继续，输入 0 取消当前步骤：" ""; then
      return 130
    fi

    answer="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${answer}" in
      CUTOVER)
        return 0
        ;;
      0|"")
        return 130
        ;;
      *)
        ui_warn_message "输入无效" "请输入固定短语 CUTOVER 继续，或输入 0 取消当前步骤。"
        ;;
    esac
  done
}

ensure_cutover_prerequisites() {
  local effective_port=""
  local auth_file=""
  local auth_key_count="0"
  local safe_gate_state=""

  [[ -n "${ADMIN_USER:-}" ]] || die "管理用户名未设置，无法关闭 root 远程登录。"
  id -u "${ADMIN_USER}" >/dev/null 2>&1 || die "管理用户不存在：${ADMIN_USER}"
  auth_file="$(admin_authorized_keys_file_for_user "${ADMIN_USER}" || true)"
  [[ -n "${auth_file}" ]] || die "无法定位管理用户 ${ADMIN_USER} 的 authorized_keys 路径。"
  [[ -f "${auth_file}" ]] || die "管理用户 ${ADMIN_USER} 的 authorized_keys 不存在：${auth_file}"
  auth_key_count="$(count_valid_ssh_keys_in_file "${auth_file}")"
  [[ "${auth_key_count}" -gt 0 ]] || die "管理用户 ${ADMIN_USER} 的 authorized_keys 中没有有效公钥，不能继续关闭 root 远程登录。"
  command_exists sshd || die "sshd 命令不存在，无法继续。"
  validate_sshd_config
  safe_gate_state="$(get_state "SSH_SAFE_GATE_PASSED" || true)"
  [[ "${safe_gate_state}" == "yes" ]] || die "SSH_SAFE_GATE_PASSED 不是 yes，当前未满足最终收口条件。请先重新完成第 4 步并确认目标账户公钥已有效安装。"

  effective_port="$(effective_ssh_port_for_changes)"
  [[ "${effective_port}" =~ ^[0-9]+$ ]] || die "当前 SSH 端口无法识别，不能继续关闭 root 远程登录。"
}

cutover_summary_body() {
  local effective_port=""
  effective_port="$(effective_ssh_port_for_changes)"

  cat <<EOF
root 远程登录已关闭。

下一次请使用以下方式连接：
- 用户名：${ADMIN_USER}
- 端口：${effective_port}
- 认证方式：SSH 私钥

请立刻在新窗口测试：
ssh -p ${effective_port} ${ADMIN_USER}@你的服务器IP

确认成功后，再关闭当前 root 会话。
EOF
}

main() {
  load_config
  init_runtime
  module_banner "07_switch_admin_login" "切换为管理用户登录并关闭 root 远程登录"
  require_root
  require_debian12

  ensure_cutover_prerequisites
  confirm_cutover_execution || return $?

  local target_file=""
  local content=""
  local ssh_service=""

  target_file="/etc/ssh/sshd_config.d/999-vps-root-login-cutover.conf"
  content="$(cat <<EOF
# Managed by VPS bootstrap project.
# Purpose: final SSH login cutover to admin-user-based access.

PermitRootLogin no
PubkeyAuthentication yes
EOF
)"

  apply_managed_file "${target_file}" "0644" "${content}" "true"
  validate_sshd_config

  ssh_service="$(ssh_service_name)"
  reload_service_if_exists "${ssh_service}"

  set_state "ROOT_SSH_MODE" "no"
  set_state "ADMIN_LOGIN_CUTOVER" "yes"
  log info "$(cutover_summary_body)"
}

main "$@"
