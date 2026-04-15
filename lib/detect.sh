#!/usr/bin/env bash
set -euo pipefail

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

package_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

service_exists() {
  local unit="${1%.service}"
  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "${unit}.service"
}

service_enabled() {
  local unit="${1%.service}"
  systemctl is-enabled "${unit}" >/dev/null 2>&1
}

service_active() {
  local unit="${1%.service}"
  systemctl is-active "${unit}" >/dev/null 2>&1
}

os_id() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    printf '%s\n' "${ID:-unknown}"
  else
    printf '%s\n' "unknown"
  fi
}

os_version_id() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    printf '%s\n' "${VERSION_ID:-unknown}"
  else
    printf '%s\n' "unknown"
  fi
}

pretty_os_name() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    printf '%s\n' "${PRETTY_NAME:-unknown}"
  else
    printf '%s\n' "unknown"
  fi
}

is_debian12() {
  [[ "$(os_id)" == "debian" && "$(os_version_id)" == "12" ]]
}

memory_mb() {
  awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo
}

cpu_cores() {
  nproc 2>/dev/null || echo "1"
}

has_active_swap() {
  swapon --show --noheadings 2>/dev/null | grep -q .
}

home_dir_for_user() {
  getent passwd "$1" | cut -d: -f6
}

count_valid_ssh_keys_in_file() {
  local file="$1"
  [[ -f "$file" ]] || {
    echo "0"
    return 0
  }

  awk '
    /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) / { count++ }
    END { print count+0 }
  ' "$file"
}

authorized_keys_present_for_user() {
  local user="$1"
  id -u "$user" >/dev/null 2>&1 || return 1
  local home_dir=""
  home_dir="$(home_dir_for_user "$user")"
  [[ -n "$home_dir" ]] || return 1
  [[ "$(count_valid_ssh_keys_in_file "${home_dir}/.ssh/authorized_keys")" -gt 0 ]]
}

current_ssh_port() {
  local detected_port=""
  if command_exists sshd; then
    detected_port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
    if [[ -n "${detected_port}" ]]; then
      printf '%s\n' "${detected_port}"
      return 0
    fi
  fi
  printf '%s\n' "${SSH_PORT:-22}"
}

ssh_service_name() {
  if service_exists "ssh"; then
    echo "ssh"
  else
    echo "sshd"
  fi
}

interactive_users() {
  getent passwd | awk -F: '
    $7 ~ /(bash|sh|zsh|fish)$/ && $1 != "nobody" {
      print $1
    }
  '
}

sudo_members() {
  getent group sudo | awk -F: '{print $4}'
}

listening_tcp_ports() {
  ss -lntH 2>/dev/null | awk '
    {
      split($4, parts, ":")
      print parts[length(parts)]
    }
  ' | sort -n | uniq
}

listening_socket_process_label() {
  local process_field="${1:-}"
  local process_name=""
  local process_pid=""

  if [[ -z "${process_field}" || "${process_field}" == "-" ]]; then
    printf '%s\n' "unknown"
    return 0
  fi

  process_name="$(printf '%s\n' "${process_field}" | sed -n 's/^[^"]*"\([^"]*\)".*/\1/p')"
  process_pid="$(printf '%s\n' "${process_field}" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')"

  case "${process_name}" in
    systemd-resolve)
      process_name="systemd-resolved"
      ;;
  esac

  if [[ -n "${process_name}" && -n "${process_pid}" ]]; then
    printf '%s (pid=%s)\n' "${process_name}" "${process_pid}"
    return 0
  fi

  if [[ -n "${process_name}" ]]; then
    printf '%s\n' "${process_name}"
    return 0
  fi

  if [[ -n "${process_pid}" ]]; then
    printf 'pid=%s\n' "${process_pid}"
    return 0
  fi

  printf '%s\n' "unknown"
}

listening_socket_details() {
  local line=""
  local proto=""
  local state=""
  local recv_q=""
  local send_q=""
  local local_socket=""
  local peer_socket=""
  local process_field=""
  local extra_field=""
  local process_label=""
  local port_sort_key=""

  command_exists ss || return 0

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue

    proto=""
    state=""
    recv_q=""
    send_q=""
    local_socket=""
    peer_socket=""
    process_field=""
    extra_field=""
    read -r proto state recv_q send_q local_socket peer_socket process_field extra_field <<<"${line}"

    [[ -n "${proto}" && -n "${local_socket}" ]] || continue
    process_label="$(listening_socket_process_label "${process_field:-}")"
    port_sort_key="${local_socket##*:}"
    [[ "${port_sort_key}" =~ ^[0-9]+$ ]] || port_sort_key="0"

    printf '%05d\t%s %s -> %s\n' "${port_sort_key}" "${proto}" "${local_socket}" "${process_label}"
  done < <(ss -lntupH 2>/dev/null || true) | sort -n | cut -f2-
}
