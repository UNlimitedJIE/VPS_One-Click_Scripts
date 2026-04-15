#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/ui.sh
source "${SCRIPT_DIR}/../../lib/ui.sh"

prompt_dns_mode() {
  local choice=""

  while true; do
    if ! ui_prompt_input "3. DNS 净化" $'请选择 DNS 模式：\n1. 国外模式（Google + Cloudflare，强制 DoT）\n2. 国内模式（阿里云 + DNSPod，不启用 DoT）\n0. 返回'; then
      return 1
    fi

    choice="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${choice}" in
      0)
        return 1
        ;;
      1)
        printf '%s\n' "global"
        return 0
        ;;
      2)
        printf '%s\n' "cn"
        return 0
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2 或 0。"
        ;;
    esac
  done
}

render_dns_dropin() {
  local mode="$1"
  local dns_servers=""
  local fallback_servers=""
  local dot_value=""

  case "${mode}" in
    global)
      dns_servers="8.8.8.8#dns.google 1.1.1.1#cloudflare-dns.com"
      fallback_servers="8.8.4.4#dns.google 1.0.0.1#cloudflare-dns.com"
      dot_value="yes"
      ;;
    cn)
      dns_servers="223.5.5.5 119.29.29.29"
      fallback_servers="223.6.6.6 182.254.116.116"
      dot_value="no"
      ;;
    *)
      die "Unsupported DNS mode: ${mode}"
      ;;
  esac

  cat <<EOF
[Resolve]
DNS=${dns_servers}
FallbackDNS=${fallback_servers}
Domains=~.
DNSOverTLS=${dot_value}
EOF
}

rollback_dns_change() {
  local snapshot_dir="$1"
  local service_active_before="${2:-no}"
  local resolv_target_before="${3:-}"

  log warn "DNS 净化执行失败，正在自动回滚。"
  network_tuning_restore_file_snapshot "$(network_tuning_dns_dropin_path)" "${snapshot_dir}"
  network_tuning_restore_file_snapshot "/etc/resolv.conf" "${snapshot_dir}"

  if [[ "${service_active_before}" == "yes" ]]; then
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
  fi

  if [[ -n "${resolv_target_before}" && -L /etc/resolv.conf ]]; then
    ln -sfn "${resolv_target_before}" /etc/resolv.conf >/dev/null 2>&1 || true
  fi
}

apply_dns_mode() {
  local mode="$1"
  local snapshot_dir="$2"
  local stack=""
  local service_active_before="no"
  local resolv_target_before=""

  stack="$(network_tuning_resolved_stack_type)"
  if [[ "${stack}" == "external-manager" ]]; then
    die "检测到 DNS 栈由 NetworkManager/resolvconf 等外部管理，当前步骤不会粗暴改写。"
  fi

  if service_exists "systemd-resolved" && service_active "systemd-resolved"; then
    service_active_before="yes"
  fi

  if [[ -L /etc/resolv.conf ]]; then
    resolv_target_before="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
  fi

  network_tuning_snapshot_file "$(network_tuning_dns_dropin_path)" "${snapshot_dir}"
  network_tuning_snapshot_file "/etc/resolv.conf" "${snapshot_dir}"

  trap 'rollback_dns_change "'"${snapshot_dir}"'" "'"${service_active_before}"'" "'"${resolv_target_before}"'"' ERR

  apt_install_packages systemd-resolved
  apply_managed_file "$(network_tuning_dns_dropin_path)" "0644" "$(render_dns_dropin "${mode}")" "true"
  run_cmd "Enabling systemd-resolved" systemctl enable systemd-resolved
  run_cmd "Restarting systemd-resolved" systemctl restart systemd-resolved

  if [[ ! -L /etc/resolv.conf || "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" != "/run/systemd/resolve/stub-resolv.conf" ]]; then
    if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
      rm -f /etc/resolv.conf
      ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    else
      log info "[plan] ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf"
    fi
  fi

  if command_exists resolvectl; then
    run_cmd "Flushing systemd-resolved caches" resolvectl flush-caches
  fi

  if [[ "$(network_tuning_service_state systemd-resolved)" != "active" ]]; then
    die "systemd-resolved 未成功变为 active。"
  fi

  case "${mode}" in
    global)
      [[ "$(network_tuning_dns_dot_state)" == "yes" ]] || die "DoT 未成功启用。"
      printf '%s\n' "$(network_tuning_dns_current_servers)" | grep -Eq '8\.8\.8\.8|1\.1\.1\.1' || die "当前上游 DNS 与国外模式不一致。"
      ;;
    cn)
      [[ "$(network_tuning_dns_dot_state)" == "no" ]] || die "国内模式不应启用 DoT。"
      printf '%s\n' "$(network_tuning_dns_current_servers)" | grep -Eq '223\.5\.5\.5|119\.29\.29\.29' || die "当前上游 DNS 与国内模式不一致。"
      ;;
  esac

  trap - ERR
}

main() {
  load_config
  init_runtime
  module_banner "32_dns_purification" "DNS 净化"
  require_root
  require_debian12

  local mode=""
  local snapshot_dir=""

  mode="$(prompt_dns_mode)" || return 0
  snapshot_dir="$(network_tuning_state_root)/dns-snapshots/${RUN_ID}"
  apply_dns_mode "${mode}" "${snapshot_dir}"

  log info "当前 DNS 模式: $(network_tuning_dns_mode_label)"
  log info "当前上游 DNS: $(network_tuning_dns_current_servers)"
  log info "当前 DoT 状态: $(network_tuning_dns_dot_state)"

  set_state "NETWORK_DNS_PURIFIED" "yes"
  set_state "NETWORK_DNS_MODE" "${mode}"
}

main "$@"
