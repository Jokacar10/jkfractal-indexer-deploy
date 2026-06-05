#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/install-deps.sh

Installs deployment dependencies when they are missing:
  docker, docker compose plugin, jq, kopia, rsync, lsof

Supported package managers:
  apt-get, dnf, yum
EOF
}

original_args=("$@")

while [ "$#" -gt 0 ]; do
  case "$1" in
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

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  require_command sudo
  log "Re-running dependency installer as root via sudo"
  exec sudo -E bash "$0" "${original_args[@]}"
fi

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt\n'
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    printf 'dnf\n'
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    printf 'yum\n'
    return
  fi

  return 1
}

have_docker_compose() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

missing_items=()

command -v docker >/dev/null 2>&1 || missing_items+=(docker)
have_docker_compose || missing_items+=(docker-compose-plugin)
command -v jq >/dev/null 2>&1 || missing_items+=(jq)
command -v kopia >/dev/null 2>&1 || missing_items+=(kopia)
command -v rsync >/dev/null 2>&1 || missing_items+=(rsync)
if ! command -v lsof >/dev/null 2>&1 && ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
  missing_items+=(lsof)
fi

if [ "${#missing_items[@]}" -eq 0 ]; then
  log "All deployment dependencies are already installed"
  exit 0
fi

pm="$(detect_package_manager || true)"
if [ -z "$pm" ]; then
  die "unsupported system: missing dependencies (${missing_items[*]}) and apt-get/dnf/yum is unavailable"
fi

log "Missing deployment dependencies: ${missing_items[*]}"

install_apt() {
  local need_docker="$1"
  local need_kopia="$2"
  local packages=(ca-certificates curl gnupg jq rsync lsof)

  log "Installing packages with apt-get"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

  if [ "$need_docker" -eq 1 ]; then
    install_docker_apt
  fi

  if [ "$need_kopia" -eq 1 ]; then
    log "Configuring Kopia APT repository"
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://kopia.io/signing-key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kopia-keyring.gpg
    printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main' >/etc/apt/sources.list.d/kopia.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y kopia
  fi
}

install_yum_like() {
  local pm_cmd="$1"
  local need_docker="$2"
  local need_kopia="$3"
  local packages=(ca-certificates curl gnupg2 jq rsync lsof)

  log "Installing packages with ${pm_cmd}"
  "$pm_cmd" install -y "${packages[@]}"

  if [ "$need_docker" -eq 1 ]; then
    install_docker_yum_like "$pm_cmd"
  fi

  if [ "$need_kopia" -eq 1 ]; then
    log "Configuring Kopia RPM repository"
    rpm --import https://kopia.io/signing-key
    cat >/etc/yum.repos.d/kopia.repo <<'EOF'
[Kopia]
name=Kopia
baseurl=http://packages.kopia.io/rpm/stable/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://kopia.io/signing-key
EOF
    "$pm_cmd" install -y kopia
  fi
}

install_docker_apt() {
  local arch
  local codename

  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
  if [ -z "$codename" ]; then
    codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-}")"
  fi
  if [ -z "$codename" ]; then
    die "cannot detect Debian/Ubuntu codename for Docker repository"
  fi

  log "Configuring Docker APT repository"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  if [ -f /etc/debian_version ] && ! grep -qi ubuntu /etc/os-release; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian %s stable\n' "$arch" "$codename" >/etc/apt/sources.list.d/docker.list
  else
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "$codename" >/etc/apt/sources.list.d/docker.list
  fi

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_yum_like() {
  local pm_cmd="$1"
  local config_manager=()

  if [ "$pm_cmd" = "dnf" ]; then
    "$pm_cmd" install -y dnf-plugins-core
    config_manager=(dnf config-manager --add-repo)
  else
    "$pm_cmd" install -y yum-utils
    config_manager=(yum-config-manager --add-repo)
  fi

  log "Configuring Docker RPM repository"
  rm -f /etc/yum.repos.d/docker-ce.repo /etc/yum.repos.d/docker-ce-staging.repo
  "${config_manager[@]}" https://download.docker.com/linux/centos/docker-ce.repo

  log "Installing Docker packages with ${pm_cmd}"
  "$pm_cmd" makecache
  "$pm_cmd" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

need_docker=0
need_kopia=0
if ! command -v docker >/dev/null 2>&1 || ! have_docker_compose; then
  need_docker=1
fi
if ! command -v kopia >/dev/null 2>&1; then
  need_kopia=1
fi

case "$pm" in
  apt)
    install_apt "$need_docker" "$need_kopia"
    ;;
  dnf)
    install_yum_like dnf "$need_docker" "$need_kopia"
    ;;
  yum)
    install_yum_like yum "$need_docker" "$need_kopia"
    ;;
  *)
    die "unsupported package manager: ${pm}"
    ;;
esac

if command -v systemctl >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
  systemctl enable --now docker >/dev/null 2>&1 || warn "failed to enable/start docker via systemctl; start Docker manually if needed"
fi

log "Dependency installation finished"

if ! command -v docker >/dev/null 2>&1; then
  die "Docker is still unavailable after installation"
fi
if ! have_docker_compose; then
  die "Docker Compose is still unavailable after installation"
fi
require_command jq
require_command kopia
require_command rsync
