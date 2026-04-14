#!/usr/bin/env bash
set -euo pipefail

apt_log_conservative_policy_once() {
  if [[ "$(get_state APT_POLICY_LOGGED 2>/dev/null || true)" == "true" ]]; then
    return 0
  fi

  log info "APT policy: noninteractive conservative mode is enabled."
  log info "APT policy: keep existing local config files when package updates ship new defaults."
  log info "APT policy: using apt-get -y with dpkg --force-confdef --force-confold."
  log info "APT policy: packages kept back by apt-get upgrade will be logged as warnings and will not fail the run."
  set_state "APT_POLICY_LOGGED" "true"
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
      log warn "Conservative upgrade will keep these packages back: ${kept_back_packages[*]}"
    else
      log info "No kept-back packages detected for conservative upgrade."
    fi
  fi

  apt_run_noninteractive \
    "Applying conservative system upgrades (noninteractive, keep local configs)" \
    upgrade

  if ((${#kept_back_packages[@]} > 0)); then
    log warn "Conservative upgrade finished. These packages remain kept back: ${kept_back_packages[*]}"
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
