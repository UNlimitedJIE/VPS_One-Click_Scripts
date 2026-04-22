#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/VPS_One-Click_Scripts"
REPO_URL="https://github.com/UNlimitedJIE/VPS_One-Click_Scripts"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf '%s\n' "Please run as root. Example: sudo bash <(curl -fsSL https://raw.githubusercontent.com/UNlimitedJIE/VPS_One-Click_Scripts/main/install.sh)" >&2
    exit 1
  fi
}

ensure_git() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git
}

ensure_project_root() {
  mkdir -p /opt

  if [[ -d "${PROJECT_ROOT}/.git" ]]; then
    git -C "${PROJECT_ROOT}" pull --ff-only
    return 0
  fi

  if [[ -e "${PROJECT_ROOT}" ]]; then
    printf '%s\n' "${PROJECT_ROOT} already exists but is not a git repository. Please move or remove it, then rerun this installer." >&2
    exit 1
  fi

  git clone "${REPO_URL}" "${PROJECT_ROOT}"
}

install_shortcut_and_launch() {
  cd "${PROJECT_ROOT}"
  SHORTCUT_FORCE_OVERWRITE=true bash bootstrap.sh install-shortcut
  exec j
}

main() {
  require_root
  ensure_git
  ensure_project_root
  install_shortcut_and_launch
}

main "$@"
