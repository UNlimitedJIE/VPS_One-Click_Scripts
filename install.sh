#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/opt/VPS_One-Click_Scripts"
REPO_URL="https://github.com/UNlimitedJIE/VPS_One-Click_Scripts"
REF_MODE="branch"
REF_VALUE="main"
NO_LAUNCH="false"

usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [options]

Options:
  --branch NAME     Install or update from a branch. Default: main
  --version TAG     Install or update from a tag/release.
  --commit SHA      Install or update to a specific commit.
  --no-launch       Install shortcut but do not enter the menu.
  -h, --help        Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

validate_ref_name() {
  local value="$1"
  [[ -n "${value}" ]] || die "Reference value cannot be empty."
  [[ "${value}" != -* ]] || die "Reference value cannot start with '-'."
  [[ "${value}" =~ ^[A-Za-z0-9._/@+-]+$ ]] || die "Reference contains unsupported characters: ${value}"
  [[ "${value}" != *".."* ]] || die "Reference cannot contain '..': ${value}"
  [[ "${value}" != *".lock" ]] || die "Reference cannot end with .lock: ${value}"
}

validate_commit_sha() {
  local value="$1"
  [[ "${value}" =~ ^[A-Fa-f0-9]{7,40}$ ]] || die "Commit must be a 7-40 character hex SHA."
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --branch)
        shift
        (($# > 0)) || die "--branch requires a value."
        validate_ref_name "$1"
        REF_MODE="branch"
        REF_VALUE="$1"
        ;;
      --version)
        shift
        (($# > 0)) || die "--version requires a tag value."
        validate_ref_name "$1"
        REF_MODE="version"
        REF_VALUE="$1"
        ;;
      --commit)
        shift
        (($# > 0)) || die "--commit requires a SHA value."
        validate_commit_sha "$1"
        REF_MODE="commit"
        REF_VALUE="$1"
        ;;
      --no-launch)
        NO_LAUNCH="true"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf '%s\n' "Please run as root. Recommended: git clone https://github.com/UNlimitedJIE/VPS_One-Click_Scripts.git && cd VPS_One-Click_Scripts && bash bootstrap.sh show init && bash bootstrap.sh plan init && sudo bash bootstrap.sh preflight && sudo bash bootstrap.sh init" >&2
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

fetch_all_refs() {
  git -C "${PROJECT_ROOT}" fetch --tags origin '+refs/heads/*:refs/remotes/origin/*'
}

checkout_requested_ref() {
  case "${REF_MODE}" in
    branch)
      fetch_all_refs
      git -C "${PROJECT_ROOT}" checkout -B "${REF_VALUE}" "origin/${REF_VALUE}"
      git -C "${PROJECT_ROOT}" pull --ff-only origin "${REF_VALUE}"
      ;;
    version)
      fetch_all_refs
      git -C "${PROJECT_ROOT}" rev-parse -q --verify "refs/tags/${REF_VALUE}^{commit}" >/dev/null || die "Tag not found: ${REF_VALUE}"
      git -C "${PROJECT_ROOT}" checkout --detach "refs/tags/${REF_VALUE}"
      ;;
    commit)
      fetch_all_refs
      git -C "${PROJECT_ROOT}" rev-parse -q --verify "${REF_VALUE}^{commit}" >/dev/null || die "Commit not found after fetch: ${REF_VALUE}"
      git -C "${PROJECT_ROOT}" checkout --detach "${REF_VALUE}"
      ;;
    *)
      die "Unsupported reference mode: ${REF_MODE}"
      ;;
  esac
}

ensure_project_root() {
  mkdir -p /opt

  if [[ -d "${PROJECT_ROOT}/.git" ]]; then
    checkout_requested_ref
    return 0
  fi

  if [[ -e "${PROJECT_ROOT}" ]]; then
    printf '%s\n' "${PROJECT_ROOT} already exists but is not a git repository. Please move or remove it, then rerun this installer." >&2
    exit 1
  fi

  git clone "${REPO_URL}" "${PROJECT_ROOT}"
  checkout_requested_ref
}

install_shortcut_and_launch() {
  cd "${PROJECT_ROOT}"
  SHORTCUT_FORCE_OVERWRITE=true bash bootstrap.sh install-shortcut
  if [[ "${NO_LAUNCH}" == "true" ]]; then
    printf '%s\n' "Installed. Run 'j' to open the menu."
    return 0
  fi
  exec j
}

main() {
  parse_args "$@"
  require_root
  ensure_git
  ensure_project_root
  install_shortcut_and_launch
}

main "$@"
