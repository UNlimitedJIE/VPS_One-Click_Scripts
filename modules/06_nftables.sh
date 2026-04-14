#!/usr/bin/env bash
set -euo pipefail

# Module: 06_nftables
# Purpose: 配置 Debian 12 的 nftables，默认仅放行 SSH。
# Preconditions: root；Debian 12；nftables 包可安装。
# Steps:
#   1. 安装 nftables
#   2. 生成清晰易审查的 /etc/nftables.conf
#   3. 非 22 端口必须显式确认后才真正切换到新端口规则
#   4. 启用并加载规则
# Idempotency:
#   - 采用受控主配置文件
#   - 配置未变化时不重复覆盖

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "06_nftables" "配置 nftables 防火墙"
  require_root
  require_debian12

  if is_false "${ENABLE_NFTABLES}"; then
    log info "ENABLE_NFTABLES=false, skip."
    set_state "NFTABLES_ENABLED" "no"
    return 0
  fi

  apt_install_packages nftables

  local firewall_ssh_port
  firewall_ssh_port="$(effective_ssh_port_for_changes)"

  if ssh_port_change_pending_confirmation; then
    warn_ssh_port_change_not_confirmed
  fi

  local nft_conf
  nft_conf="$(cat <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif "lo" accept
    ct state established,related accept
    ct state invalid drop

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    tcp dport ${firewall_ssh_port} accept comment "SSH"
    # BEGIN VPS EXTRA TCP PORTS
    # END VPS EXTRA TCP PORTS
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
EOF
)"

  apply_managed_file "/etc/nftables.conf" "0644" "${nft_conf}" "true"

  run_cmd "Checking nftables syntax" nft -c -f /etc/nftables.conf
  enable_and_start_service "nftables"
  run_cmd "Loading nftables rules" nft -f /etc/nftables.conf

  set_state "NFTABLES_ENABLED" "yes"
  set_state "NFTABLES_SSH_PORT_EFFECTIVE" "${firewall_ssh_port}"

  if [[ "${SSH_PORT}" != "${firewall_ssh_port}" ]]; then
    log warn "Requested SSH port ${SSH_PORT} is not yet confirmed. nftables still only allows port ${firewall_ssh_port}."
  else
    log warn "Only SSH port ${firewall_ssh_port} is allowed by default. HTTP/HTTPS remain closed unless future modules open them."
  fi
  log warn "Reminder: nftables only controls this server itself. If your cloud provider also has security-group/cloud-firewall rules, update them in the provider console as well."
}

main "$@"
