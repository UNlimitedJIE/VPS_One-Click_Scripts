#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

realm_toml_managed_begin() {
  printf '# BEGIN VPS NETWORK TUNING REALM\n'
}

realm_toml_managed_end() {
  printf '# END VPS NETWORK TUNING REALM\n'
}

realm_toml_managed_block() {
  cat <<'EOF'
tcp_timeout = 30
tcp_keepalive = 15
tcp_keepalive_probe = 3
EOF
}

realm_update_toml_config() {
  local file="$1"
  local tmp_file=""
  local block_file=""

  tmp_file="$(mktemp)"
  block_file="$(mktemp)"

  {
    printf '%s\n' "$(realm_toml_managed_begin)"
    printf '%s\n' "$(realm_toml_managed_block)"
    printf '%s\n' "$(realm_toml_managed_end)"
  } >"${block_file}"

  awk -v begin_marker="$(realm_toml_managed_begin)" \
      -v end_marker="$(realm_toml_managed_end)" \
      -v block_file="${block_file}" '
    function emit_block(   line) {
      while ((getline line < block_file) > 0) {
        print line
      }
      close(block_file)
      inserted = 1
    }
    {
      if ($0 == begin_marker) {
        emit_block()
        in_managed_block = 1
        next
      }
      if (in_managed_block) {
        if ($0 == end_marker) {
          in_managed_block = 0
        }
        next
      }
      if ($0 ~ /^\[network\][[:space:]]*$/) {
        in_network = 1
        print
        emit_block()
        next
      }
      if (in_network && $0 ~ /^\[/) {
        if (!inserted) {
          emit_block()
        }
        in_network = 0
      }
      if (in_network && $1 ~ /^(tcp_timeout|tcp_keepalive|tcp_keepalive_probe)$/) {
        next
      }
      print
    }
    END {
      if (!inserted) {
        if (NR > 0) {
          print ""
        }
        print "[network]"
        emit_block()
      }
    }
  ' "${file}" >"${tmp_file}"

  rm -f "${block_file}"
  replace_file_with_tmp_if_changed "${file}" "${tmp_file}" "true"
}

realm_update_json_config() {
  local file="$1"
  local tmp_file=""

  tmp_file="$(mktemp)"
  jq '
    .network = (.network // {}) |
    .network.tcp_timeout = 30 |
    .network.tcp_keepalive = 15 |
    .network.tcp_keepalive_probe = 3
  ' "${file}" >"${tmp_file}" || {
    rm -f "${tmp_file}"
    die "Unable to update Realm JSON config: ${file}"
  }

  replace_file_with_tmp_if_changed "${file}" "${tmp_file}" "true"
}

realm_current_fix_values() {
  local file="${1:-}"
  local format="${2:-}"

  case "${format}" in
    toml)
      awk '
        /^\[network\]/ { in_network = 1; next }
        in_network && /^\[/ { in_network = 0 }
        in_network && $1 ~ /^(tcp_timeout|tcp_keepalive|tcp_keepalive_probe)$/ { print $1 "=" $3 }
      ' "${file}" 2>/dev/null
      ;;
    json)
      jq -r '.network | "tcp_timeout=\(.tcp_timeout // "unset")\ntcp_keepalive=\(.tcp_keepalive // "unset")\ntcp_keepalive_probe=\(.tcp_keepalive_probe // "unset")"' "${file}" 2>/dev/null || true
      ;;
  esac
}

realm_rollback() {
  local config_path="$1"
  local snapshot_dir="$2"
  local service_name="$3"

  log warn "Realm timeout 修复失败，正在回滚。"
  network_tuning_restore_file_snapshot "${config_path}" "${snapshot_dir}"
  [[ -n "${service_name}" ]] && systemctl restart "${service_name}" >/dev/null 2>&1 || true
}

main() {
  load_config
  init_runtime
  module_banner "33_realm_timeout_fix" "Realm 转发 timeout 修复"
  require_root
  require_debian12

  local service_name=""
  local config_path=""
  local config_format=""
  local snapshot_dir=""

  service_name="$(network_tuning_realm_service_name || true)"
  config_path="$(network_tuning_realm_config_path || true)"

  [[ -n "${service_name}" || -n "${config_path}" || "$(command -v realm 2>/dev/null || true)" != "" ]] || die "未检测到 Realm。"
  [[ -n "${config_path}" && -f "${config_path}" ]] || die "已检测到 Realm，但未找到可修改的配置文件。"

  config_format="$(network_tuning_realm_config_format "${config_path}")"
  [[ "${config_format}" == "toml" || "${config_format}" == "json" ]] || die "当前只支持修复 TOML/JSON 格式的 Realm 配置：${config_path}"

  snapshot_dir="$(network_tuning_state_root)/realm-snapshots/${RUN_ID}"
  network_tuning_snapshot_file "${config_path}" "${snapshot_dir}"
  trap 'realm_rollback "'"${config_path}"'" "'"${snapshot_dir}"'" "'"${service_name}"'"' ERR

  case "${config_format}" in
    toml)
      realm_update_toml_config "${config_path}"
      ;;
    json)
      realm_update_json_config "${config_path}"
      ;;
  esac

  if [[ -n "${service_name}" ]]; then
    run_cmd "Restarting Realm service" systemctl restart "${service_name}"
    [[ "$(network_tuning_service_state "${service_name}")" == "active" ]] || die "Realm 服务重启后未处于 active。"
  fi

  trap - ERR

  log info "Realm service: ${service_name:-not detected}"
  log info "Realm config: ${config_path}"
  log info "Realm timeout fix values: $(realm_current_fix_values "${config_path}" "${config_format}" | tr '\n' ';' | sed 's/;$/ /')"

  set_state "NETWORK_REALM_TIMEOUT_FIXED" "yes"
}

main "$@"
