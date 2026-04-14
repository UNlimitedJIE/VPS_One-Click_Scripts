#!/usr/bin/env bash
set -euo pipefail

apt_log_conservative_policy_once() {
  if [[ "$(get_state APT_POLICY_LOGGED 2>/dev/null || true)" == "true" ]]; then
    return 0
  fi

  log info "APT policy: noninteractive conservative mode is enabled."
  log info "APT policy: keep existing local config files when package updates ship new defaults."
  log info "APT policy: using apt-get -y with dpkg --force-confdef --force-confold."
  log info "APT policy: packages kept back by apt-get upgrade will be logged as info by default, and only promoted to warnings when critical prerequisites remain unsatisfied."
  set_state "APT_POLICY_LOGGED" "true"
}

apt_critical_kept_back_package_names() {
  printf '%s\n' \
    ca-certificates \
    curl \
    sudo \
    rsync \
    git \
    procps \
    openssh-server \
    nftables
}

apt_kept_back_package_is_critical() {
  local package_name="${1:-}"
  local critical_package=""

  while IFS= read -r critical_package; do
    [[ -n "${critical_package}" ]] || continue
    [[ "${package_name}" == "${critical_package}" ]] && return 0
  done < <(apt_critical_kept_back_package_names)

  return 1
}

apt_critical_prerequisites_look_satisfied() {
  local package_name=""

  while IFS= read -r package_name; do
    [[ -n "${package_name}" ]] || continue
    package_installed "${package_name}" || return 1
  done < <(printf '%s\n' ca-certificates curl sudo rsync git procps)

  command_exists apt-get || return 1
  command_exists dpkg || return 1
  command_exists sudo || return 1
  command_exists rsync || return 1
  command_exists git || return 1
  command_exists sshd || return 1

  return 0
}

apt_kept_back_requires_warning() {
  local package_name=""
  local found_critical="false"

  for package_name in "$@"; do
    apt_kept_back_package_is_critical "${package_name}" || continue
    found_critical="true"
    break
  done

  if [[ "${found_critical}" != "true" ]]; then
    return 1
  fi

  if apt_critical_prerequisites_look_satisfied; then
    return 1
  fi

  return 0
}

apt_log_kept_back_packages() {
  local phase_label="${1:-upgrade}"
  shift || true
  local -a kept_back_packages=("$@")

  ((${#kept_back_packages[@]} > 0)) || return 0

  if apt_kept_back_requires_warning "${kept_back_packages[@]}"; then
    log warn "Conservative ${phase_label} kept back critical packages that may affect later steps: ${kept_back_packages[*]}"
  else
    log info "Conservative ${phase_label} kept these packages back for later review: ${kept_back_packages[*]}"
  fi
}

apt_run_noninteractive() {
  local description="$1"
  shift

  apt_log_conservative_policy_once

  local -a cmd=(
    env
    DEBIAN_FRONTEND=noninteractive
    APT_LISTCHANGES_FRONTEND=none
    UCF_FORCE_CONFFOLD=1
    LC_ALL=C
    LANG=C
    apt-get
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    "$@"
  )

  run_cmd "${description}" "${cmd[@]}"
}

apt_update_once() {
  if [[ "$(get_state APT_UPDATED 2>/dev/null || true)" == "true" ]]; then
    log info "apt-get update already completed in this run."
    return 0
  fi

  run_cmd \
    "Refreshing apt package index" \
    env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1 LC_ALL=C LANG=C apt-get update
  set_state "APT_UPDATED" "true"
}

apt_list_kept_back_packages() {
  local output=""
  local status=0
  local -a cmd=(
    env
    DEBIAN_FRONTEND=noninteractive
    APT_LISTCHANGES_FRONTEND=none
    UCF_FORCE_CONFFOLD=1
    LC_ALL=C
    LANG=C
    apt-get
    -s
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    upgrade
  )

  output="$("${cmd[@]}" 2>&1)" || status=$?
  if (( status != 0 )); then
    log warn "Unable to pre-detect kept-back packages before upgrade."
    log warn "apt-get -s upgrade exited with status ${status}."
    return "${status}"
  fi

  printf '%s\n' "${output}" | awk '
    /^The following packages have been kept back:/ {
      keep = 1
      next
    }
    keep && NF == 0 {
      keep = 0
      next
    }
    keep {
      for (i = 1; i <= NF; i++) {
        print $i
      }
    }
  ' | awk '!seen[$0]++'
}

apt_conservative_upgrade() {
  apt_update_once

  local -a kept_back_packages=()
  if is_true "${PLAN_ONLY}" || is_true "${DRY_RUN}"; then
    log info "Plan/Dry-run note: conservative upgrade may keep dependency-changing packages back."
  else
    mapfile -t kept_back_packages < <(apt_list_kept_back_packages || true)
    if ((${#kept_back_packages[@]} > 0)); then
      apt_log_kept_back_packages "upgrade preview" "${kept_back_packages[@]}"
    else
      log info "No kept-back packages detected for conservative upgrade."
    fi
  fi

  apt_run_noninteractive \
    "Applying conservative system upgrades (noninteractive, keep local configs)" \
    upgrade

  if ((${#kept_back_packages[@]} > 0)); then
    apt_log_kept_back_packages "upgrade result" "${kept_back_packages[@]}"
  fi
}

apt_install_packages() {
  local missing=()
  local pkg=""
  for pkg in "$@"; do
    if ! package_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if ((${#missing[@]} == 0)); then
    log info "All requested packages are already installed."
    return 0
  fi

  apt_update_once
  apt_run_noninteractive \
    "Installing packages (noninteractive, keep local configs): ${missing[*]}" \
    install --no-install-recommends "${missing[@]}"
}

apt_autoremove_unused() {
  apt_run_noninteractive \
    "Removing unused packages (noninteractive, keep local configs)" \
    autoremove
}
