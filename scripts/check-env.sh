#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

SNAPSHOT_MIN_DISK_GIB=800
SNAPSHOT_MIN_MEM_GIB=64

usage() {
  cat <<'EOF'
Usage:
  scripts/check-env.sh [--snapshot=<height>] [--skip-checks=memory,disk] [--yes]

Checks the deployment environment before running deploy.sh.

Options:
  --snapshot=<height>    Check resource requirements for snapshot deployment.
  --skip-checks=<list>   Downgrade selected machine requirement failures to
                         warnings. Supported values: memory,disk.
  --yes                  Confirm non-snapshot deployment warnings automatically.
EOF
}

snapshot_height=""
assume_yes=0
skip_memory_check=0
skip_disk_check=0

parse_skip_checks() {
  local value="$1"
  local item
  local -a items

  if [ -z "$value" ]; then
    usage_error "--skip-checks requires at least one value"
  fi

  IFS=',' read -r -a items <<<"$value"
  for item in "${items[@]}"; do
    case "$item" in
      memory)
        skip_memory_check=1
        ;;
      disk)
        skip_disk_check=1
        ;;
      "")
        usage_error "--skip-checks contains an empty value"
        ;;
      *)
        usage_error "unsupported --skip-checks value: $item"
        ;;
    esac
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot=*)
      snapshot_height="${1#--snapshot=}"
      ;;
    --skip-checks=*)
      parse_skip_checks "${1#--skip-checks=}"
      ;;
    --yes)
      assume_yes=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
  shift
done

if [ -n "$snapshot_height" ] && ! is_numeric "$snapshot_height"; then
  usage_error "snapshot height must be numeric"
fi

mem_total_gib() {
  awk '/MemTotal:/ { printf "%.0f", $2 / 1024 / 1024 }' /proc/meminfo
}

disk_available_gib() {
  df -PB1 "$REPO_ROOT" | awk 'NR == 2 { printf "%.0f", $4 / 1024 / 1024 / 1024 }'
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt-get'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum'
  else
    printf 'unknown'
  fi
}

check_command_status() {
  local name="$1"
  local command_name="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    log "${name}: found ($(command -v "$command_name"))"
  else
    warn "${name}: missing"
  fi
}

log "Checking system environment"
log "Repository root: ${REPO_ROOT}"
log "Kernel: $(uname -srm)"
log "Package manager: $(detect_package_manager)"

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  log "Privilege: running as root"
elif command -v sudo >/dev/null 2>&1; then
  log "Privilege: sudo is available"
else
  die "sudo is required when deploy.sh is not run as root"
fi

check_command_status "Docker" docker
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  log "Docker Compose: found (docker compose plugin)"
else
  warn "Docker Compose plugin: missing"
fi
check_command_status "jq" jq
check_command_status "kopia" kopia
check_command_status "rsync" rsync

if command -v lsof >/dev/null 2>&1 || command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
  log "Port checker: available"
else
  warn "Port checker: lsof, ss, and netstat are missing"
fi

mem_gib="$(mem_total_gib)"
disk_gib="$(disk_available_gib)"
log "Memory: ${mem_gib} GiB"
log "Available disk under ${REPO_ROOT}: ${disk_gib} GiB"

log "Checking runtime data directory status"
for path in \
  "${REPO_ROOT}/fractald/data" \
  "${REPO_ROOT}/fractal-indexer/data"; do
  if [ -e "$path" ] && [ "$(find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
    warn "${path}: exists and is not empty"
  else
    log "${path}: empty or missing"
  fi
done

log "Checking service ports"
check_ports_free 10333 8000

check_port_publication_security

if [ -n "$snapshot_height" ]; then
  snapshot_resource_warnings=0
  log "Snapshot resource requirement for single-host, same-disk deployment: disk ${SNAPSHOT_MIN_DISK_GIB} GiB+, memory ${SNAPSHOT_MIN_MEM_GIB} GiB+"
  if [ "$disk_gib" -lt "$SNAPSHOT_MIN_DISK_GIB" ]; then
    if [ "$skip_disk_check" -eq 1 ]; then
      warn "snapshot deployment requires at least ${SNAPSHOT_MIN_DISK_GIB} GiB available disk; current: ${disk_gib} GiB; continuing because disk is listed in --skip-checks"
      snapshot_resource_warnings=1
    else
      die "snapshot deployment requires at least ${SNAPSHOT_MIN_DISK_GIB} GiB available disk; current: ${disk_gib} GiB"
    fi
  fi
  if [ "$mem_gib" -lt "$SNAPSHOT_MIN_MEM_GIB" ]; then
    if [ "$skip_memory_check" -eq 1 ]; then
      warn "snapshot deployment requires at least ${SNAPSHOT_MIN_MEM_GIB} GiB memory; current: ${mem_gib} GiB; continuing because memory is listed in --skip-checks"
      snapshot_resource_warnings=1
    else
      die "snapshot deployment requires at least ${SNAPSHOT_MIN_MEM_GIB} GiB memory; current: ${mem_gib} GiB"
    fi
  fi
  if [ "$snapshot_resource_warnings" -eq 1 ]; then
    warn "Snapshot resource requirement warnings were allowed for height ${snapshot_height}"
  else
    log "Snapshot resource check passed for height ${snapshot_height}"
  fi
else
  cat >&2 <<'EOF'

WARNING: deploying without --snapshot starts syncing and indexing from genesis.
This can take several days. A full node plus full index data requires more than
3 TB of disk space, and a full index rebuild is recommended on a host with
128 GB+ memory.
EOF

  if [ "$assume_yes" -eq 0 ]; then
    if [ ! -t 0 ]; then
      die "non-snapshot deployment requires confirmation; rerun with --yes for non-interactive deployment"
    fi

    printf 'Continue without snapshots? Type "yes" to continue: '
    read -r answer
    if [ "$answer" != "yes" ]; then
      die "deployment cancelled"
    fi
  fi
fi

log "Environment check completed"
