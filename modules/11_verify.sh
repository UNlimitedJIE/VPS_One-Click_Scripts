#!/usr/bin/env bash
set -euo pipefail

# Module: 11_verify
# Purpose: 验收初始化第 2 到第 11 步的实际系统状态。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

failures=0
warnings=0
pending=0
VERIFY_REPORT=""

append_report_block() {
  local block="${1:-}"
  VERIFY_REPORT+="${block}"$'\n'
}

emit_section() {
  local title="${1:-}"
  local block=""

  block=$'\n'"${title}"$'\n'
  printf '%s' "${block}"
  append_report_block "${block}"
}

record_status_count() {
  case "${1:-}" in
    ERROR)
      failures=$((failures + 1))
      ;;
    WARN)
      warnings=$((warnings + 1))
      ;;
    PENDING)
      pending=$((pending + 1))
      ;;
  esac
}

emit_check() {
  local level="$1"
  local title="$2"
  local current="$3"
  local expected="$4"
  local evidence="$5"
  local conclusion="$6"
  local block=""

  record_status_count "${level}"
  block="$(cat <<EOF
[${level}] ${title}
Current: ${current}
Expected: ${expected}
Evidence: ${evidence}
Conclusion: ${conclusion}
EOF
)"
  printf '%s\n' "${block}"
  append_report_block "${block}"
}

service_state_summary() {
  local unit="${1:-}"

  if ! service_exists "${unit}"; then
    printf '%s\n' "not installed"
    return 0
  fi

  if service_enabled "${unit}" && service_active "${unit}"; then
    printf '%s\n' "enabled and active"
    return 0
  fi

  if service_enabled "${unit}"; then
    printf '%s\n' "enabled"
    return 0
  fi

  if service_active "${unit}"; then
    printf '%s\n' "active"
    return 0
  fi

  printf '%s\n' "inactive"
}

package_version_or_missing() {
  local package_name="${1:-}"
  dpkg-query -W -f='${Version}' "${package_name}" 2>/dev/null || printf '%s\n' "missing"
}

openssl_version_or_missing() {
  if command_exists openssl; then
    openssl version 2>/dev/null || printf '%s\n' "unknown"
    return 0
  fi
  printf '%s\n' "missing"
}

apt_upgradable_packages() {
  apt list --upgradable 2>/dev/null | awk -F/ 'NR > 1 && $1 != "Listing..." { print $1 }'
}

timedatectl_value() {
  local key="${1:-}"
  timedatectl show --property="${key}" --value 2>/dev/null || true
}

nftables_ssh_port_allowed_in_file() {
  local port="${1:-}"
  [[ -n "${port}" ]] || return 1
  [[ -r /etc/nftables.conf ]] || return 1
  grep -Eq "tcp dport ${port} accept" /etc/nftables.conf
}

swap_status_summary() {
  local swap_show=""
  local fstab_state="no"
  local state_hint=""

  if swap_fstab_present; then
    fstab_state="yes"
  fi

  swap_show="$(swapon --show --noheadings --output NAME,SIZE,USED,PRIO 2>/dev/null || true)"
  [[ -n "${swap_show}" ]] || swap_show="(none)"
  state_hint="$(get_state "SWAP_STATUS" || true)"

  printf '/swapfile=%s; swapon=%s; fstab=%s; state=%s\n' \
    "$(if [[ -f /swapfile ]]; then printf present; else printf absent; fi)" \
    "${swap_show}" \
    "${fstab_state}" \
    "${state_hint:-unknown}"
}

detect_admin_sudo_mode() {
  local dropin_path=""
  local sudo_group_enabled="no"
  local user_in_sudo_group="no"

  if [[ -z "${ADMIN_USER:-}" ]] || ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    printf '%s\n' "unknown"
    return 0
  fi

  dropin_path="/etc/sudoers.d/90-${ADMIN_USER}"
  if [[ -f "${dropin_path}" && "$(grep -Fxc "${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL" "${dropin_path}" 2>/dev/null || true)" -gt 0 ]]; then
    printf '%s\n' "nopasswd"
    return 0
  fi

  if id -nG "${ADMIN_USER}" 2>/dev/null | tr ' ' '\n' | grep -Fxq "sudo"; then
    user_in_sudo_group="yes"
  fi
  if grep -RqsE '^[[:space:]]*%sudo[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
    sudo_group_enabled="yes"
  fi

  if [[ "${user_in_sudo_group}" == "yes" && "${sudo_group_enabled}" == "yes" ]]; then
    printf '%s\n' "password"
    return 0
  fi

  if grep -RqsE "^[[:space:]]*${ADMIN_USER}[[:space:]]+ALL=\\(ALL(:ALL)?\\)[[:space:]]+ALL" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
    printf '%s\n' "password"
    return 0
  fi

  printf '%s\n' "no-sudo"
}

detect_admin_sudo_password_implementation() {
  local sudo_mode=""
  local implementation=""

  sudo_mode="$(detect_admin_sudo_mode)"
  case "${sudo_mode}" in
    nopasswd)
      printf '%s\n' "n/a"
      ;;
    password)
      implementation="$(get_state "ADMIN_SUDO_PASSWORD_IMPLEMENTATION" || true)"
      printf '%s\n' "${implementation:-account-password}"
      ;;
    no-sudo)
      printf '%s\n' "n/a"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

run_admin_sudo_runtime_probe() {
  local sudo_output=""
  local sudo_status=0
  local current_user=""

  current_user="$(id -un 2>/dev/null || true)"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    sudo_output="$(env LC_ALL=C LANG=C sudo -u "${ADMIN_USER}" sudo -n true 2>&1)" || sudo_status=$?
    printf '%s\t%s\n' "${sudo_status}" "${sudo_output:-<no output>}"
    return 0
  fi

  if [[ -n "${current_user}" && "${current_user}" == "${ADMIN_USER}" ]]; then
    sudo_output="$(env LC_ALL=C LANG=C sudo -n true 2>&1)" || sudo_status=$?
    printf '%s\t%s\n' "${sudo_status}" "${sudo_output:-<no output>}"
    return 0
  fi

  printf '%s\t%s\n' "125" "runtime probe skipped: run verify as root or as ${ADMIN_USER} to execute sudo -n true"
}

check_step_2_base_update() {
  local openssh_version=""
  local openssl_version=""
  local missing_packages=()
  local package_name=""
  local kept_back=()
  local upgradable=()
  local current=""
  local evidence=""
  local conclusion=""
  local level="OK"

  openssh_version="$(package_version_or_missing "openssh-server")"
  openssl_version="$(openssl_version_or_missing)"

  for package_name in sudo openssh-server rsync git procps; do
    package_installed "${package_name}" || missing_packages+=("${package_name}")
  done

  mapfile -t kept_back < <(apt_list_kept_back_packages 2>/dev/null || true)
  mapfile -t upgradable < <(apt_upgradable_packages 2>/dev/null || true)

  current="openssh-server=${openssh_version}; openssl=${openssl_version}; upgradable=${#upgradable[@]}; kept-back=$(if ((${#kept_back[@]} > 0)); then printf '%s' "${kept_back[*]}"; else printf none; fi)"
  evidence="dpkg-query/openssl version, apt list --upgradable, apt-get -s upgrade"

  if ((${#missing_packages[@]} > 0)); then
    level="ERROR"
    conclusion="关键基础包缺失：${missing_packages[*]}；第 2 步结果不通过。"
  elif apt_kept_back_requires_warning "${kept_back[@]:-}"; then
    level="WARN"
    conclusion="存在关键 kept-back 包，需要人工复核；当前属于保守升级后的待确认状态。"
  elif ((${#upgradable[@]} > 0 || ${#kept_back[@]} > 0)); then
    level="PENDING"
    conclusion="基础更新执行过，但仍有可升级或 kept-back 包；这更像后续维护项，而不是当前阻塞。"
  else
    conclusion="关键基础包已安装，当前未发现 kept-back 或待升级阻塞项。"
  fi

  emit_check \
    "${level}" \
    "第 2 步 系统基础更新状态" \
    "${current}" \
    "关键基础包已安装；无关键 kept-back 包阻塞后续步骤" \
    "${evidence}" \
    "${conclusion}"
}

check_step_3_admin_account() {
  local current=""
  local evidence=""

  if [[ -z "${ADMIN_USER:-}" ]]; then
    emit_check \
      "ERROR" \
      "第 5 步 管理用户账户" \
      "ADMIN_USER 为空" \
      "必须存在明确的管理用户" \
      "配置来源：${ACTIVE_CONFIG_CHAIN:-unknown}" \
      "管理用户还没有被明确配置。"
    return 0
  fi

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    current="用户 ${ADMIN_USER} 已存在，home=$(home_dir_for_user "${ADMIN_USER}")"
    evidence="getent passwd ${ADMIN_USER}"
    emit_check \
      "OK" \
      "第 5 步 管理用户账户" \
      "${current}" \
      "管理用户存在，且 home 目录可解析" \
      "${evidence}" \
      "管理用户账户已经就绪。"
    return 0
  fi

  emit_check \
    "ERROR" \
    "第 5 步 管理用户账户" \
    "用户 ${ADMIN_USER} 不存在" \
    "管理用户必须已经创建" \
    "getent passwd ${ADMIN_USER} 无结果" \
    "第 5 步未通过，后续 SSH 接入也不会成立。"
}

check_step_3_sudo_mode() {
  local sudo_mode=""
  local sudo_impl=""
  local sudo_probe=""
  local sudo_output=""
  local sudo_status=0
  local current=""
  local evidence=""
  local conclusion=""
  local level="OK"

  if [[ -z "${ADMIN_USER:-}" ]] || ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    emit_check \
      "PENDING" \
      "第 5 步 sudo 行为" \
      "无法检查，管理用户不存在" \
      "应明确为 nopasswd 或 password" \
      "ADMIN_USER 不可用" \
      "必须先让管理用户存在，才能验收 sudo 行为。"
    return 0
  fi

  sudo_mode="$(detect_admin_sudo_mode)"
  sudo_impl="$(detect_admin_sudo_password_implementation)"
  sudo_probe="$(run_admin_sudo_runtime_probe)"
  sudo_status="$(printf '%s\n' "${sudo_probe}" | cut -f1)"
  sudo_output="$(printf '%s\n' "${sudo_probe}" | cut -f2-)"

  current="mode=${sudo_mode}; implementation=${sudo_impl}; sudo -n status=${sudo_status}"
  evidence="/etc/sudoers.d/90-${ADMIN_USER}; id -nG ${ADMIN_USER}; sudo runtime probe => ${sudo_output:-<no output>}"

  case "${sudo_mode}" in
    nopasswd)
      if [[ "${sudo_status}" -eq 0 ]]; then
        conclusion="当前是免密 sudo，且运行时验证通过。"
      elif [[ "${sudo_status}" -eq 125 ]]; then
        level="PENDING"
        conclusion="sudoers 配置显示当前应为 nopasswd，但这次 verify 不是以 root 或 ${ADMIN_USER} 身份运行，未执行运行时探测。"
      else
        level="ERROR"
        conclusion="配置看起来是 nopasswd，但运行时 sudo -n 失败，说明 sudo 配置没有真正生效。"
      fi
      ;;
    password)
      if [[ "${sudo_status}" -eq 0 ]]; then
        level="ERROR"
        conclusion="当前看起来应为 password 模式，但 sudo -n 直接成功，和目标不一致。"
      elif [[ "${sudo_status}" -eq 125 ]]; then
        conclusion="当前 sudo 需要密码；这次 verify 未执行运行时探测，但当前实现仍依赖账户密码，而不是独立 sudo 密码。"
      else
        conclusion="当前 sudo 需要密码；实现方式仍是账户密码，而不是独立 sudo 密码。"
      fi
      ;;
    no-sudo)
      level="ERROR"
      conclusion="当前没有检测到该管理用户的有效 sudo 权限；这与第 5 步目标不一致。"
      ;;
    *)
      level="ERROR"
      conclusion="无法确定 sudo 模式。"
      ;;
  esac

  emit_check \
    "${level}" \
    "第 5 步 sudo 行为" \
    "${current}" \
    "应明确为 nopasswd 或 password；若为 password，当前实现仍依赖账户密码" \
    "${evidence}" \
    "${conclusion}"
}

check_step_3_account_password() {
  local state_label=""
  local state_value=""
  local sudo_mode=""
  local level="OK"
  local conclusion=""

  if [[ -z "${ADMIN_USER:-}" ]] || ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    emit_check \
      "PENDING" \
      "第 5 步 本地账户密码状态" \
      "无法检查，管理用户不存在" \
      "应与当前 sudo 模式兼容" \
      "ADMIN_USER 不可用" \
      "必须先让管理用户存在，才能验收账户密码状态。"
    return 0
  fi

  state_value="$(user_account_password_state "${ADMIN_USER}")"
  state_label="$(user_account_password_state_label "${ADMIN_USER}")"
  sudo_mode="$(detect_admin_sudo_mode)"

  if [[ "${state_value}" == "unknown" ]]; then
    level="PENDING"
    conclusion="当前会话无法可靠读取该用户的 shadow 密码状态；请用 root 重新运行 verify，或把这项只当作辅助信息。"
  elif [[ "${state_value}" == "locked_or_unset" && "${sudo_mode}" == "password" ]]; then
    level="ERROR"
    conclusion="当前 sudo 需要密码，但账户密码又处于未设置或已锁定状态，这两者互相冲突。"
  else
    conclusion="账户密码状态与 SSH 公钥登录是两条独立线；这里只反映本地/密码类认证现状。"
  fi

  emit_check \
    "${level}" \
    "第 5 步 本地账户密码状态" \
    "${state_label}" \
    "应与 sudo 模式兼容" \
    "getent shadow / user_account_password_state" \
    "${conclusion}"
}

check_step_4_ssh_port() {
  local target_port=""
  local actual_port=""
  local port_source=""
  local consistency="no"
  local current=""
  local evidence=""
  local conclusion=""
  local level="OK"

  target_port="${SSH_PORT:-unknown}"
  actual_port="$(current_ssh_port 2>/dev/null || true)"
  port_source="$(sshd_last_directive_source_line "Port" || true)"

  if [[ -n "${target_port}" && "${target_port}" == "${actual_port}" ]]; then
    consistency="yes"
  fi

  current="target=${target_port:-unknown}; actual=${actual_port:-unknown}; consistent=${consistency}"
  evidence="配置来源=${ACTIVE_CONFIG_CHAIN:-unknown}; Port source=${port_source:-not found}; sshd -T"

  if [[ ! "${target_port}" =~ ^[0-9]+$ ]]; then
    level="ERROR"
    conclusion="当前 SSH_PORT 配置非法，无法作为后续步骤的目标端口。"
  elif [[ ! "${actual_port}" =~ ^[0-9]+$ ]]; then
    level="ERROR"
    conclusion="当前无法从 sshd -T 读取实际生效端口。"
  elif [[ "${target_port}" != "${actual_port}" ]]; then
    level="ERROR"
    conclusion="项目目标 SSH 端口与 sshd 实际生效端口不一致。"
  else
    conclusion="项目目标 SSH 端口与 sshd 实际生效端口一致。"
  fi

  emit_check \
    "${level}" \
    "第 4 步 SSH 端口状态" \
    "${current}" \
    "当前目标 SSH 端口与 sshd 实际生效端口一致" \
    "${evidence}" \
    "${conclusion}"
}

check_step_4_authorized_keys() {
  local source_file=""
  local source_key_count="0"
  local auth_file=""
  local ssh_dir=""
  local auth_meta=""
  local ssh_meta=""
  local target_key_count="0"
  local current=""
  local evidence=""
  local conclusion=""
  local level="OK"

  if [[ -z "${ADMIN_USER:-}" ]] || ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    emit_check \
      "ERROR" \
      "第 5 步 目标账户 authorized_keys" \
      "无法检查，管理用户不存在" \
      "目标用户 .ssh/authorized_keys 必须真实存在且权限正确" \
      "ADMIN_USER 不可用" \
      "第 5 步未通过。"
    return 0
  fi

  source_file="$(preferred_authorized_keys_source_path)"
  source_key_count="$(count_valid_ssh_keys_in_file "${source_file}")"
  auth_file="$(admin_authorized_keys_file_for_user "${ADMIN_USER}")"
  ssh_dir="$(admin_ssh_dir_for_user "${ADMIN_USER}")"

  if [[ -d "${ssh_dir}" ]]; then
    ssh_meta="$(stat -c '%U:%G %a' "${ssh_dir}" 2>/dev/null || true)"
  else
    ssh_meta="missing"
  fi

  if [[ -f "${auth_file}" ]]; then
    auth_meta="$(stat -c '%U:%G %a' "${auth_file}" 2>/dev/null || true)"
    target_key_count="$(count_valid_ssh_keys_in_file "${auth_file}")"
  else
    auth_meta="missing"
  fi

  current="source=${source_file} (${source_key_count} key); target=${auth_file}; ssh_dir=${ssh_meta}; auth_file=${auth_meta}; target_keys=${target_key_count}"
  evidence="stat ${ssh_dir} ${auth_file}; count_valid_ssh_keys_in_file"

  if admin_authorized_keys_install_valid_for_user "${ADMIN_USER}"; then
    conclusion="目标账户 authorized_keys 已真实安装成功，safe gate 的前置条件成立。"
  elif [[ "${source_key_count}" -gt 0 ]]; then
    level="ERROR"
    conclusion="源文件已有有效公钥，但目标账户 authorized_keys 仍未安装成功；这正是第 5 步需要修复的状态。"
  else
    level="ERROR"
    conclusion="固定源文件和目标账户 authorized_keys 都还没有就绪。"
  fi

  emit_check \
    "${level}" \
    "第 5 步 目标账户 authorized_keys" \
    "${current}" \
    "目标文件存在、属主属组正确、权限正确、至少 1 条有效 key" \
    "${evidence}" \
    "${conclusion}"
}

check_step_4_5_ssh_policy() {
  local password_auth=""
  local pubkey_auth=""
  local kbd_auth=""
  local permit_root_login=""
  local port=""
  local auth_ready="no"
  local expected_password_auth="no"
  local password_source=""
  local pubkey_source=""
  local root_source=""
  local current=""
  local expected=""
  local evidence=""
  local conclusion=""
  local level="OK"

  password_auth="$(current_password_authentication_mode || true)"
  pubkey_auth="$(current_pubkey_authentication_mode || true)"
  kbd_auth="$(current_kbdinteractive_authentication_mode || true)"
  permit_root_login="$(current_permit_root_login_mode || true)"
  port="$(current_ssh_port)"

  if ssh_publickey_login_ready_for_user "${ADMIN_USER:-}"; then
    auth_ready="yes"
  else
    auth_ready="no"
    expected_password_auth="yes"
  fi

  if is_false "${DISABLE_PASSWORD_LOGIN:-true}"; then
    expected_password_auth="yes"
  fi

  password_source="$(sshd_last_directive_source_line "PasswordAuthentication" || true)"
  pubkey_source="$(sshd_last_directive_source_line "PubkeyAuthentication" || true)"
  root_source="$(sshd_last_directive_source_line "PermitRootLogin" || true)"

  current="pubkey=${pubkey_auth:-unknown}; password=${password_auth:-unknown}; kbd=${kbd_auth:-unknown}; permitrootlogin=${permit_root_login:-unknown}; port=${port}; safe_gate=$(if [[ "${auth_ready}" == "yes" ]]; then printf yes; else printf no; fi)"
  expected="pubkey=yes; password=${expected_password_auth}; kbd=no; permitrootlogin=no after step 6 cutover; port=${SSH_PORT:-unknown}"
  evidence="sshd -T; PubkeyAuthentication source=${pubkey_source:-not found}; PasswordAuthentication source=${password_source:-not found}; PermitRootLogin source=${root_source:-not found}"

  if [[ "${pubkey_auth}" != "yes" ]]; then
    level="ERROR"
    conclusion="当前 PubkeyAuthentication 不是 yes；来源已经在 Evidence 中列出，这与第 5 步目标策略直接冲突。"
  elif [[ "${password_auth}" != "${expected_password_auth}" ]]; then
    level="ERROR"
    conclusion="当前 PasswordAuthentication 与 safe gate 应有的状态不一致；Evidence 已指出显式配置来源。"
  elif [[ "${kbd_auth}" != "no" ]]; then
    level="ERROR"
    conclusion="当前 KbdInteractiveAuthentication 仍未关闭，不符合脚本的基线目标。"
  elif [[ "${permit_root_login}" != "no" ]]; then
    level="ERROR"
    conclusion="第 6 步切换尚未真正完成；当前 root 远程登录仍然开放。"
  else
    conclusion="SSH 实际生效值与脚本目标一致；safe gate 和最终 cutover 都已达成。"
  fi

  emit_check \
    "${level}" \
    "第 5/6 步 SSH 接入与收紧状态" \
    "${current}" \
    "${expected}" \
    "${evidence}" \
    "${conclusion}"
}

check_step_4_5_ssh_auth_method() {
  local auth_method=""
  local auth_label=""
  local auth_line=""
  local level="OK"
  local conclusion=""

  auth_method="$(last_successful_ssh_auth_method_for_user "${ADMIN_USER}")"
  auth_label="$(ssh_last_successful_auth_method_label "${auth_method}")"
  auth_line="$(last_successful_ssh_auth_line_for_user "${ADMIN_USER}" || true)"

  case "${auth_method}" in
    publickey)
      conclusion="最近一次成功 SSH 认证已经是 publickey，符合最终目标。"
      ;;
    password)
      level="WARN"
      conclusion="最近一次成功 SSH 认证仍是 password，说明你至少还观测到密码登录成功过；需要继续做 password-only 失败测试。"
      ;;
    *)
      level="PENDING"
      conclusion="当前日志还不足以判断最近一次成功认证方式；需要补做手工 SSH 验证。"
      ;;
  esac

  emit_check \
    "${level}" \
    "第 5/6 步 最近一次成功 SSH 登录方式" \
    "${auth_label}" \
    "最终应观察到 publickey；password-only 测试应失败" \
    "${auth_line:-journalctl/auth.log 中暂无可判定行}" \
    "${conclusion}"
}

check_step_6_nftables() {
  local service_state=""
  local port=""
  local file_state="missing"
  local file_rule_state="missing"
  local current=""
  local conclusion=""
  local level="OK"

  service_state="$(service_state_summary "nftables")"
  port="$(effective_ssh_port_for_changes)"
  [[ -f /etc/nftables.conf ]] && file_state="present"
  if nftables_ssh_port_allowed_in_file "${port}"; then
    file_rule_state="ssh-port-allowed"
  fi

  current="service=${service_state}; config=/etc/nftables.conf(${file_state}); effective_ssh_port=${port}; rule_state=${file_rule_state}"

  if [[ "${service_state}" != "enabled and active" || "${file_state}" != "present" || "${file_rule_state}" != "ssh-port-allowed" ]]; then
    level="ERROR"
    conclusion="nftables 当前没有完整达到“已启用且已放行当前 SSH 端口”的目标。"
  else
    conclusion="nftables 已启用，且当前 SSH 端口规则已在配置文件中明确放行。"
  fi

  emit_check \
    "${level}" \
    "第 7 步 nftables 状态" \
    "${current}" \
    "nftables enabled and active；/etc/nftables.conf 存在；当前 SSH 端口已放行" \
    "systemctl is-enabled/is-active nftables；/etc/nftables.conf" \
    "${conclusion}"
}

check_step_7_time_sync() {
  local service_state=""
  local ntp_enabled=""
  local ntp_synced=""
  local timezone_value=""
  local current=""
  local level="OK"
  local conclusion=""

  service_state="$(service_state_summary "systemd-timesyncd")"
  ntp_enabled="$(timedatectl_value "NTP")"
  ntp_synced="$(timedatectl_value "NTPSynchronized")"
  timezone_value="$(timedatectl_value "Timezone")"
  current="service=${service_state}; timezone=${timezone_value:-unknown}; NTP=${ntp_enabled:-unknown}; NTPSynchronized=${ntp_synced:-unknown}"

  if [[ "${service_state}" != "enabled and active" ]]; then
    level="ERROR"
    conclusion="timesyncd 当前未正常启用。"
  elif [[ "${ntp_enabled}" != "yes" || "${ntp_synced}" != "yes" ]]; then
    level="PENDING"
    conclusion="时间同步服务已启用，但当前还没看到明确同步成功。"
  else
    conclusion="时间同步服务已启用，且当前已经同步。"
  fi

  emit_check \
    "${level}" \
    "第 8 步 时间同步状态" \
    "${current}" \
    "systemd-timesyncd enabled and active；NTP=yes；NTPSynchronized=yes" \
    "timedatectl show；systemctl is-enabled/is-active systemd-timesyncd" \
    "${conclusion}"
}

check_step_8_auto_updates() {
  local service_state=""
  local config_file="/etc/apt/apt.conf.d/20auto-upgrades"
  local config_state="missing"
  local current=""
  local level="OK"
  local conclusion=""

  service_state="$(service_state_summary "unattended-upgrades")"
  if [[ -f "${config_file}" ]]; then
    config_state="$(tr '\n' ';' <"${config_file}" 2>/dev/null)"
  fi

  current="service=${service_state}; config=${config_state}"

  if [[ ! -f "${config_file}" ]]; then
    level="ERROR"
    conclusion="自动更新配置文件缺失。"
  elif ! grep -Fq 'APT::Periodic::Update-Package-Lists "1";' "${config_file}" || ! grep -Fq 'APT::Periodic::Unattended-Upgrade "1";' "${config_file}"; then
    level="ERROR"
    conclusion="20auto-upgrades 存在，但关键项没有设为 1。"
  elif [[ "${service_state}" != "enabled and active" && "${service_state}" != "enabled" ]]; then
    level="WARN"
    conclusion="配置文件已写入，但 unattended-upgrades 服务没有处于启用状态。"
  else
    conclusion="自动安全更新配置已落地，服务也处于可用状态。"
  fi

  emit_check \
    "${level}" \
    "第 9 步 自动安全更新状态" \
    "${current}" \
    "20auto-upgrades 存在且关键项为 1；unattended-upgrades 已启用" \
    "${config_file}; systemctl is-enabled/is-active unattended-upgrades" \
    "${conclusion}"
}

check_step_9_fail2ban() {
  local service_state=""
  local jail_output=""
  local current=""
  local level="OK"
  local conclusion=""

  service_state="$(service_state_summary "fail2ban")"
  if command_exists fail2ban-client; then
    jail_output="$(fail2ban-client status sshd 2>/dev/null | tr '\n' ';' || true)"
  fi
  [[ -n "${jail_output}" ]] || jail_output="unavailable"

  current="service=${service_state}; jail=${jail_output}"

  if [[ "${service_state}" != "enabled and active" ]]; then
    level="ERROR"
    conclusion="Fail2Ban 服务当前没有正常启用。"
  elif [[ "${jail_output}" == "unavailable" ]]; then
    level="WARN"
    conclusion="Fail2Ban 服务可用，但当前拿不到 sshd jail 状态。"
  else
    conclusion="Fail2Ban 已启用，且当前能读取 sshd jail 状态。"
  fi

  emit_check \
    "${level}" \
    "第 10 步 Fail2Ban 状态" \
    "${current}" \
    "fail2ban enabled and active；sshd jail 可读" \
    "/etc/fail2ban/jail.d/sshd.local；systemctl is-enabled/is-active fail2ban；fail2ban-client status sshd" \
    "${conclusion}"
}

check_step_10_swap() {
  local swap_summary=""
  local swap_state=""
  local level="OK"
  local conclusion=""

  swap_summary="$(swap_status_summary)"
  swap_state="$(get_state "SWAP_STATUS" || true)"

  if has_active_swap && swap_fstab_present; then
    conclusion="swap 已启用，并且 /etc/fstab 已写入。"
  elif has_active_swap && ! swap_fstab_present; then
    level="WARN"
    conclusion="swap 当前已启用，但 /etc/fstab 没有对应项，重启后可能丢失。"
  elif [[ "${swap_state}" == "skipped" ]]; then
    conclusion="当前无 swap，但历史选择是 skip；这可以视为一次明确决策。"
  elif [[ -f /swapfile ]]; then
    level="WARN"
    conclusion="/swapfile 已存在，但当前并未启用 swap。"
  else
    level="PENDING"
    conclusion="当前没有 active swap，也没有看到明确的 skip 痕迹。"
  fi

  emit_check \
    "${level}" \
    "第 11 步 swap 状态" \
    "${swap_summary}" \
    "若启用则应有 active swap 和 fstab 项；若跳过则应是明确 skip 决策" \
    "swapon --show；/etc/fstab；/swapfile；runtime state 仅作辅助" \
    "${conclusion}"
}

print_final_summary() {
  local overall_status="PASS"
  local manual_next_step=""
  local summary_block=""

  if (( failures > 0 )); then
    overall_status="FAIL"
  elif (( warnings > 0 || pending > 0 )); then
    overall_status="CHECK"
  fi

  manual_next_step="继续使用下面两条命令做人类验收：$(ssh_force_publickey_test_command "${ADMIN_USER:-<ADMIN_USER>}" "$(effective_ssh_port_for_changes)") ; $(ssh_force_password_test_command "${ADMIN_USER:-<ADMIN_USER>}" "$(effective_ssh_port_for_changes)")"

  summary_block="$(cat <<EOF

=== Acceptance Summary ===
Overall: ${overall_status}
Errors: ${failures}
Warnings: ${warnings}
Pending: ${pending}
Last observed successful SSH auth method: $(ssh_last_successful_auth_method_label "$(last_successful_ssh_auth_method_for_user "${ADMIN_USER}")")
Current target SSH port: ${SSH_PORT:-unknown}
Current sshd runtime port: $(current_ssh_port 2>/dev/null || printf unknown)
Target/runtime consistent: $(if [[ "${SSH_PORT:-}" == "$(current_ssh_port 2>/dev/null || true)" ]]; then printf yes; else printf no; fi)
Current SSH password auth policy: $(ssh_policy_enabled_disabled_label "$(current_password_authentication_mode || true)")
Current SSH public key policy: $(ssh_policy_enabled_disabled_label "$(current_pubkey_authentication_mode || true)")
Current root remote login policy: $(ssh_root_remote_login_enabled_disabled_label "$(current_permit_root_login_mode || true)")
Next step: ${manual_next_step}
Reminder: ${SNAPSHOT_REMINDER}
EOF
)"

  printf '%s\n' "${summary_block}"
  append_report_block "${summary_block}"

  set_state "VERIFY_WARNINGS" "${warnings}"
  set_state "VERIFY_FAILURES" "${failures}"
  set_state "VERIFY_PENDING" "${pending}"
  set_state "VERIFY_OVERALL" "${overall_status}"

  if [[ -n "${STATE_DIR:-}" ]]; then
    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    printf '%s\n' "${VERIFY_REPORT}" >"${STATE_DIR}/acceptance-summary.txt" 2>/dev/null || true
  fi
}

main() {
  load_config
  init_runtime
  module_banner "11_verify" "初始化第 2-11 步验收"

  emit_section "=== Initialization Acceptance: Steps 2-11 ==="

  check_step_2_base_update

  emit_section "-- Step 4 SSH 端口 --"
  check_step_4_ssh_port

  emit_section "-- Step 5 管理用户接入 --"
  check_step_3_admin_account
  check_step_3_sudo_mode
  check_step_3_account_password
  check_step_4_authorized_keys

  emit_section "-- Step 5 / 6 SSH 接入与收紧 --"
  check_step_4_5_ssh_policy
  check_step_4_5_ssh_auth_method

  emit_section "-- Step 7-11 关键服务与系统状态 --"
  check_step_6_nftables
  check_step_7_time_sync
  check_step_8_auto_updates
  check_step_9_fail2ban
  check_step_10_swap

  print_final_summary
}

main "$@"
