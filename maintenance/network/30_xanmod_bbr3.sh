#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

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

main() {
  load_config
  init_runtime
  module_banner "30_xanmod_bbr3" "安装/更新 XanMod 内核 + BBR v3"
  require_root
  require_debian12

  local current_kernel=""
  local xanmod_state="no"
  local bbr_state="no"
  local bbr3_state="no"
  local package_name=""
  local installed_kernel=""
  local reboot_required="no"

  current_kernel="$(network_tuning_current_kernel)"
  network_tuning_kernel_is_xanmod && xanmod_state="yes"
  network_tuning_kernel_supports_bbr && bbr_state="yes"
  network_tuning_kernel_supports_bbr3 && bbr3_state="yes"

  package_name="$(network_tuning_xanmod_package_name)" || die "当前架构不支持自动安装 XanMod MAIN 仓库内核。"

  log info "当前运行内核: ${current_kernel}"
  log info "当前是否为 XanMod: ${xanmod_state}"
  log info "当前是否支持 bbr: ${bbr_state}"
  log info "当前是否支持 bbr3(推断): ${bbr3_state}"
  log info "目标 XanMod 包: ${package_name}"

  apt_install_packages ca-certificates wget gpg lsb-release
  install_xanmod_repo_key
  apply_managed_file "$(network_tuning_xanmod_repo_list_path)" "0644" "$(network_tuning_xanmod_repo_line)" "true"
  refresh_xanmod_apt_index
  apt_install_packages "${package_name}"

  installed_kernel="$(network_tuning_highest_installed_xanmod_kernel || true)"
  if network_tuning_reboot_required_for_xanmod; then
    reboot_required="yes"
  fi

  log info "已安装的 XanMod 内核: ${installed_kernel:-not found}"
  log info "是否需要重启: ${reboot_required}"
  log info "不会自动重启。"

  set_state "NETWORK_XANMOD_PACKAGE" "${package_name}"
  set_state "NETWORK_XANMOD_KERNEL_DONE" "yes"
  set_state "NETWORK_XANMOD_REBOOT_REQUIRED" "${reboot_required}"
}

main "$@"
