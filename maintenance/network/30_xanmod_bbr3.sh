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

  log warn "Installing XanMod meta package ${meta_package} failed."
  log warn "This often means the repository metadata is briefly ahead of the tiny meta package file."

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
  module_banner "30_xanmod_bbr3" "安装/更新 XanMod 内核 + BBR v3"
  require_root
  require_debian12

  local current_kernel=""
  local xanmod_state="no"
  local bbr_state="no"
  local bbr3_state="no"
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
    "kernel=${current_kernel}; xanmod_running=${xanmod_state}; bbr=${bbr_state}; bbr3=${bbr3_state}; selected_package=${package_name}; install_mode=${install_mode}; reboot_required=${reboot_required}" \
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
