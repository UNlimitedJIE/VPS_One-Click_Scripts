#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/ui.sh
source "${SCRIPT_DIR}/../../lib/ui.sh"

prompt_debian13_bbr3_mode() {
  local current_kernel="$1"
  local choice=""

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    printf '%s\n' "keep-builtin"
    return 0
  fi

  if ! ui_require_interactive; then
    printf '%s\n' "keep-builtin"
    return 0
  fi

  while true; do
    if ! ui_prompt_input "Debian 13 BBRv3 开关" "$(cat <<EOF
检测到当前系统是 Debian 13，且当前内核已支持 bbr。

Debian 13 默认内核已内置 BBRv3 能力，通常不需要为了 BBRv3 再安装 XanMod 内核。

当前内核：${current_kernel}

1. 启用 Debian 13 内置 BBRv3（推荐，不安装 XanMod）
2. 仍然安装 / 更新 XanMod 内核
0. 返回上一级菜单
99. 退出脚本
EOF
)"; then
      return 1
    fi

    choice="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${choice}" in
      ""|1)
        printf '%s\n' "keep-builtin"
        return 0
        ;;
      0)
        return 1
        ;;
      2)
        printf '%s\n' "install-xanmod"
        return 0
        ;;
      99)
        ui_exit_script
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、0 或 99。"
        ;;
    esac
  done
}

record_debian13_builtin_bbr3() {
  local current_kernel="$1"
  local report=""

  network_tuning_apply_builtin_bbr_profile

  report="$(readonly_status_block \
    "Debian 13 内置 BBRv3" \
    "kernel=${current_kernel}; bbr=yes; bbr3_source=debian13-builtin; active=$(network_tuning_tcp_congestion_control); default_qdisc=$(network_tuning_default_qdisc); xanmod_install=skipped" \
    "Debian 13 + tcp_available_congestion_control 包含 bbr；已写入 $(network_tuning_bbr_sysctl_file) 并执行 sysctl --system；未改写 XanMod APT 源，未安装内核，未要求重启" \
    "yes")"
  log info "${report}"

  set_state "NETWORK_XANMOD_PACKAGE" "debian13-builtin"
  set_state "NETWORK_XANMOD_INSTALL_MODE" "skipped-debian13-builtin"
  set_state "NETWORK_XANMOD_INSTALL_TARGETS" "none"
  set_state "NETWORK_XANMOD_KERNEL_DONE" "debian13-builtin"
  set_state "NETWORK_XANMOD_REBOOT_REQUIRED" "no"
  set_state "NETWORK_BBR_TUNED" "yes"
}

install_xanmod_repo_key() {
  local keyring=""
  local tmp_key=""

  keyring="$(network_tuning_xanmod_repo_keyring_path)"
  tmp_key="${keyring}.tmp"

  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "[plan] refresh XanMod archive key at ${keyring}"
    return 0
  fi

  install -d -m 0755 "$(dirname "${keyring}")"
  wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o "${tmp_key}"
  install -m 0644 "${tmp_key}" "${keyring}"
  rm -f "${tmp_key}"
  log info "XanMod archive key ready: ${keyring}"
}

refresh_xanmod_apt_index() {
  run_cmd \
    "Refreshing apt package index for XanMod repository" \
    env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1 LC_ALL=C LANG=C apt-get update
}

xanmod_direct_kernel_packages_from_meta() {
  local meta_package="${1:-}"

  [[ -n "${meta_package}" ]] || return 1
  command_exists apt-cache || return 1

  apt-cache depends "${meta_package}" 2>/dev/null \
    | awk '/^[[:space:]]*Depends:/ {print $2}' \
    | grep -E '^linux-(image|headers)-.*xanmod' \
    | awk 'NF && !seen[$0]++'
}

install_selected_xanmod_package() {
  local meta_package="${1:-}"
  local -a direct_packages=()

  [[ -n "${meta_package}" ]] || return 1

  XANMOD_INSTALL_MODE="meta"
  XANMOD_INSTALL_TARGETS="${meta_package}"

  if apt_install_packages "${meta_package}"; then
    return 0
  fi

  log info "XanMod 元包 ${meta_package} 当前不可下载，准备自动切换为直接安装内核与 headers 包。"
  log info "这通常是仓库索引已更新、元包文件尚未同步；若直接包可用，则不会影响本次安装。"

  refresh_xanmod_apt_index || true
  mapfile -t direct_packages < <(xanmod_direct_kernel_packages_from_meta "${meta_package}" || true)
  ((${#direct_packages[@]} > 0)) || die "无法从 ${meta_package} 解析出可直接安装的 XanMod image/headers 包。请稍后重试。"

  XANMOD_INSTALL_MODE="direct-fallback"
  XANMOD_INSTALL_TARGETS="$(printf '%s\n' "${direct_packages[@]}" | paste -sd ',' - | sed 's/,/, /g')"
  log info "Retrying XanMod install with direct packages: ${direct_packages[*]}"
  apt_install_packages "${direct_packages[@]}"
}

main() {
  load_config
  init_runtime
  module_banner "30_xanmod_bbr3" "XanMod 内核 / Debian 13 BBRv3 开关"
  require_root
  require_debian12

  local current_kernel=""
  local xanmod_state="no"
  local bbr_state="no"
  local bbr3_state="no"
  local bbr3_source="none"
  local debian13_mode=""
  local package_name=""
  local candidate_packages=""
  local available_packages=""
  local installed_kernel=""
  local reboot_required="no"
  local report=""
  local install_mode=""
  local install_targets=""

  current_kernel="$(network_tuning_current_kernel)"
  network_tuning_kernel_is_xanmod && xanmod_state="yes"
  network_tuning_kernel_supports_bbr && bbr_state="yes"
  network_tuning_kernel_supports_bbr3 && bbr3_state="yes"
  bbr3_source="$(network_tuning_bbr3_source_label)"

  if network_tuning_debian13_bbr3_builtin_available; then
    debian13_mode="$(prompt_debian13_bbr3_mode "${current_kernel}" || true)"
    [[ -n "${debian13_mode}" ]] || return 0
    if [[ "${debian13_mode}" == "keep-builtin" ]]; then
      record_debian13_builtin_bbr3 "${current_kernel}"
      return 0
    fi
  fi

  if ! network_tuning_xanmod_preferred_packages >/dev/null 2>&1; then
    die "当前架构不支持自动安装 XanMod MAIN 仓库内核。"
  fi

  apt_install_packages ca-certificates wget gpg lsb-release
  install_xanmod_repo_key
  apply_managed_file "$(network_tuning_xanmod_repo_list_path)" "0644" "$(network_tuning_xanmod_repo_line)" "true"
  refresh_xanmod_apt_index

  candidate_packages="$(network_tuning_xanmod_preferred_packages 2>/dev/null | tr '\n' ',' | sed 's/,$//; s/,/, /g' || true)"
  available_packages="$(network_tuning_xanmod_available_packages 2>/dev/null | tr '\n' ',' | sed 's/,$//; s/,/, /g' || true)"
  package_name="$(network_tuning_select_xanmod_package_from_repo || true)"

  if [[ -z "${package_name}" ]]; then
    report="$(readonly_status_block \
      "XanMod 内核与 BBR 能力" \
      "当前仓库未提供适合该机器的 XanMod 包" \
      "candidates=${candidate_packages:-none}; available=${available_packages:-none}" \
      "no")"
    log info "${report}"
    die "当前仓库未提供适合该机器的 XanMod 包。"
  fi

  XANMOD_INSTALL_MODE=""
  XANMOD_INSTALL_TARGETS=""
  install_selected_xanmod_package "${package_name}"
  install_mode="${XANMOD_INSTALL_MODE:-meta}"
  install_targets="${XANMOD_INSTALL_TARGETS:-${package_name}}"

  installed_kernel="$(network_tuning_highest_installed_xanmod_kernel || true)"
  if network_tuning_reboot_required_for_xanmod; then
    reboot_required="yes"
  fi

  report="$(readonly_status_block \
    "XanMod 内核与 BBR 能力" \
    "kernel=${current_kernel}; xanmod_running=${xanmod_state}; bbr=${bbr_state}; bbr3=${bbr3_state}; bbr3_source=${bbr3_source}; selected_package=${package_name}; install_mode=${install_mode}; reboot_required=${reboot_required}" \
    "candidates=${candidate_packages:-none}; available=${available_packages:-none}; install_targets=${install_targets}; installed=${installed_kernel:-not found}" \
    "yes")"
  log info "${report}"

  set_state "NETWORK_XANMOD_PACKAGE" "${package_name}"
  set_state "NETWORK_XANMOD_INSTALL_MODE" "${install_mode}"
  set_state "NETWORK_XANMOD_INSTALL_TARGETS" "${install_targets}"
  set_state "NETWORK_XANMOD_KERNEL_DONE" "yes"
  set_state "NETWORK_XANMOD_REBOOT_REQUIRED" "${reboot_required}"
}

main "$@"
