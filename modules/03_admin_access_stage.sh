#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

confirm_stage_checkpoint() {
  local title="$1"
  local body="$2"
  local answer=""

  if is_true "${PLAN_ONLY:-false}"; then
    log info "[plan] ${title}"
    log info "${body}"
    return 0
  fi

  ui_require_interactive || die "${title} 需要交互确认，请在交互式终端中执行。"

  while true; do
    if ! ui_prompt_input "${title}" "${body}\n\n输入 yes 继续；输入 0 取消本次执行：" "yes"; then
      return 1
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
        ui_warn_message "输入无效" "请输入 yes 继续，或输入 0 取消本次执行。"
        ;;
    esac
  done
}

stage_intro_body() {
  cat <<EOF
这一步会按顺序完成以下动作：
1. 创建管理用户
   - 创建时会询问 sudo 模式：
     直接回车 = 免密 sudo
     输入密码 = sudo 需要该密码
   - 会先出现一个可见的 sudo 模式选择提示；若选择 password，随后才会进入隐藏密码输入
   - 这里设置的是本地 sudo 行为，不会自动启用 SSH 密码登录
2. 配置 SSH 公钥
3. 执行 SSH 接入准备

这一阶段不会最终关闭 root 远程登录，而是为后续切换做准备。
如果公钥没有成功安装到目标账户，后续仍不满足最终收口条件。
EOF
}

stage_before_hardening_body() {
  local requested_port=""
  local effective_port=""
  local port_note=""

  requested_port="${SSH_PORT:-22}"
  effective_port="$(effective_ssh_port_for_changes)"

  if [[ "${requested_port}" == "${effective_port}" ]]; then
    port_note="当前 SSH 端口将按 ${effective_port} 生效。"
  else
    port_note="你请求的 SSH 端口是 ${requested_port}，但当前真正会生效的仍是 ${effective_port}。"
  fi

  cat <<EOF
在真正执行 SSH 加固前，请再次确认：
- AUTHORIZED_KEYS_FILE：${AUTHORIZED_KEYS_FILE:-<未设置>}
- 管理用户名：${ADMIN_USER:-<未设置>}
- SSH_PORT：${requested_port}

${port_note}

这一阶段只做 SSH 接入准备，root 远程登录暂时不会关闭。
如果你修改了 SSH 端口，还必须确认云厂商安全组/云防火墙已经同步放行对应端口。
否则即使本机 sshd 已改好，公网访问结果也可能仍然不正确。
EOF
}

stage_connection_summary() {
  local effective_port=""
  local auth_ready="no"
  local safe_gate_state=""
  effective_port="$(effective_ssh_port_for_changes)"
  safe_gate_state="$(get_state "SSH_SAFE_GATE_PASSED" || true)"

  if [[ -n "${ADMIN_USER:-}" ]] && admin_authorized_keys_ready_for_user "${ADMIN_USER}"; then
    auth_ready="yes"
  fi

  if [[ "${auth_ready}" == "yes" && "${safe_gate_state}" == "yes" ]]; then
    cat <<EOF
管理用户接入阶段已完成。

请按下面方式准备下一次连接：
- 用户名：${ADMIN_USER}
- SSH 端口：${effective_port}
- 登录方式：管理用户 + SSH 公钥
- 建议保持当前 root 会话不断开，先在新窗口测试管理用户新连接
- 连接示例：ssh -p ${effective_port} ${ADMIN_USER}@你的服务器IP
- 第 5 步会进一步关闭 root 远程登录，必须在新连接验证成功后再执行

如果你配置的目标端口不是 ${effective_port}，说明端口切换还在等待确认；
请先确认云厂商安全组/云防火墙已经同步放行，再继续验证和收口。
EOF
    return 0
  fi

  cat <<EOF
管理用户接入阶段已完成，但当前还不能按“最终收口”继续推进。

当前状态：
- 用户名：${ADMIN_USER:-<未设置>}
- SSH 端口：${effective_port}
- 目标账户公钥已安装：${auth_ready}
- SSH safe gate：${safe_gate_state:-no}

结论：
- 管理用户已创建，但公钥尚未安装到目标账户 / 当前未满足最终收口条件
- 请先修复目标账户 ${ADMIN_USER:-<未设置>} 的 authorized_keys，再重新执行第 4 步验证
- 在确认新连接可用前，不要继续执行关闭 root 远程登录的收口步骤
EOF
}

main() {
  load_config
  init_runtime
  module_banner "03_admin_access_stage" "创建并配置管理用户接入"
  require_root
  require_debian12

  log info "ACTIVE_CONFIG_CHAIN=${ACTIVE_CONFIG_CHAIN:-<unset>}"
  log info "ADMIN_USER=${ADMIN_USER:-<unset>}"
  log info "AUTHORIZED_KEYS_FILE=${AUTHORIZED_KEYS_FILE:-<empty>}"
  log info "SSH_PORT=${SSH_PORT:-<unset>}"

  confirm_stage_checkpoint "管理用户与 SSH 接入阶段" "$(stage_intro_body)" || die "管理用户与 SSH 接入阶段已取消。"

  bash "${SCRIPT_DIR}/03_admin_user.sh"
  bash "${SCRIPT_DIR}/04_ssh_keys.sh"

  confirm_stage_checkpoint "执行 SSH 加固前确认" "$(stage_before_hardening_body)" || die "SSH 加固已取消。"

  bash "${SCRIPT_DIR}/05_ssh_hardening.sh"

  log info "$(stage_connection_summary)"
}

main "$@"
