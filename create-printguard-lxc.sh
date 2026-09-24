#!/usr/bin/env bash
set -Eeuo pipefail

readonly PRINTGUARD_IMAGE="${PRINTGUARD_IMAGE:-ghcr.io/oliverbravery/printguard:latest}"
readonly TEMPLATE_URL="${TEMPLATE_URL:-https://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst}"

CT_ID="${CT_ID:-}"
CT_HOSTNAME="${CT_HOSTNAME:-printguard}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
CT_DISK_GB="${CT_DISK_GB:-32}"
CT_MEMORY_MB="${CT_MEMORY_MB:-4096}"
CT_SWAP_MB="${CT_SWAP_MB:-512}"
CT_CORES="${CT_CORES:-2}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-}"
CT_GATEWAY="${CT_GATEWAY:-}"
CT_DNS="${CT_DNS:-1.1.1.1}"
CT_PASSWORD="${CT_PASSWORD:-}"

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local answer
  read -r -p "$prompt [$default_value]: " answer
  printf '%s' "${answer:-$default_value}"
}

prompt_secret() {
  local answer
  while [[ -z "$CT_PASSWORD" ]]; do
    read -r -s -p 'Container root password: ' answer
    printf '\n'
    [[ -n "$answer" ]] || printf 'Password cannot be empty.\n' >&2
    CT_PASSWORD="$answer"
  done
}

validate_number() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a number"
}

validate_ip_config() {
  if [[ "$CT_IP" == "dhcp" ]]; then
    CT_GATEWAY=""
    return
  fi
  [[ "$CT_IP" =~ ^[^/]+/[0-9]+$ ]] || die 'CT_IP must be dhcp or an address with CIDR, for example 192.168.1.50/24'
  [[ -n "$CT_GATEWAY" ]] || die 'CT_GATEWAY is required for a static IP'
}

collect_values() {
  if [[ -z "$CT_ID" ]]; then
    CT_ID="$(prompt_default 'Container ID' '220')"
    CT_HOSTNAME="$(prompt_default 'Hostname' "$CT_HOSTNAME")"
    CT_STORAGE="$(prompt_default 'Root disk storage' "$CT_STORAGE")"
    CT_DISK_GB="$(prompt_default 'Root disk size in GiB' "$CT_DISK_GB")"
    CT_MEMORY_MB="$(prompt_default 'Memory in MiB' "$CT_MEMORY_MB")"
    CT_SWAP_MB="$(prompt_default 'Swap in MiB' "$CT_SWAP_MB")"
    CT_CORES="$(prompt_default 'CPU cores' "$CT_CORES")"
    CT_BRIDGE="$(prompt_default 'Network bridge' "$CT_BRIDGE")"
    CT_IP="$(prompt_default 'IPv4 address' "${CT_IP:-dhcp}")"
    if [[ "$CT_IP" != "dhcp" ]]; then
      CT_GATEWAY="$(prompt_default 'IPv4 gateway' "$CT_GATEWAY")"
    fi
    CT_DNS="$(prompt_default 'DNS server' "$CT_DNS")"
  fi
  prompt_secret
}

validate_values() {
  validate_number 'CT_ID' "$CT_ID"
  validate_number 'CT_DISK_GB' "$CT_DISK_GB"
  validate_number 'CT_MEMORY_MB' "$CT_MEMORY_MB"
  validate_number 'CT_SWAP_MB' "$CT_SWAP_MB"
  validate_number 'CT_CORES' "$CT_CORES"
  validate_ip_config
  (( CT_ID >= 100 && CT_ID <= 999999999 )) || die 'CT_ID must be between 100 and 999999999'
  (( CT_DISK_GB >= 8 )) || die 'CT_DISK_GB must be at least 8'
  (( CT_MEMORY_MB >= 1024 )) || die 'CT_MEMORY_MB must be at least 1024'
  (( CT_CORES >= 1 )) || die 'CT_CORES must be at least 1'
}

download_template() {
  local template_path="/var/lib/vz/template/cache/${TEMPLATE_URL##*/}"
  mkdir -p "$(dirname "$template_path")"
  if [[ ! -f "$template_path" ]]; then
    printf 'Downloading Debian template...\n' >&2
    curl --fail --location --progress-bar "$TEMPLATE_URL" --output "$template_path"
  fi
  printf '%s' "$template_path"
}

wait_for_container() {
  local attempt
  for attempt in {1..30}; do
    pct exec "$CT_ID" -- true >/dev/null 2>&1 && return
    sleep 2
  done
  die "Container $CT_ID did not become ready"
}

create_container() {
  local template_path="$1"
  pct status "$CT_ID" >/dev/null 2>&1 && die "Container ID $CT_ID already exists"
  pvesm status --storage "$CT_STORAGE" >/dev/null 2>&1 || die "Storage is not available: $CT_STORAGE"

  pct create "$CT_ID" "$template_path" \
    --hostname "$CT_HOSTNAME" \
    --password "$CT_PASSWORD" \
    --storage "$CT_STORAGE" \
    --rootfs "${CT_STORAGE}:${CT_DISK_GB}" \
    --memory "$CT_MEMORY_MB" \
    --swap "$CT_SWAP_MB" \
    --cores "$CT_CORES" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}${CT_GATEWAY:+,gw=${CT_GATEWAY}}" \
    --nameserver "$CT_DNS" \
    --features 'nesting=1,keyctl=1' \
    --unprivileged 1 \
    --onboot 1 \
    --start 0

  pct start "$CT_ID"
  wait_for_container
}

install_printguard() {
  pct exec "$CT_ID" -- bash -s -- "$PRINTGUARD_IMAGE" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
printguard_image="$1"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
mkdir -p /etc/printguard /var/lib/printguard
cat > /etc/printguard/compose.yaml <<EOF
services:
  printguard:
    image: ${printguard_image}
    container_name: printguard
    restart: unless-stopped
    ports:
      - "8000:8000"
      - "8554:8554"
    volumes:
      - /var/lib/printguard:/data
EOF
docker compose -f /etc/printguard/compose.yaml pull
docker compose -f /etc/printguard/compose.yaml up -d
cat > /usr/local/sbin/update-printguard <<'UPDATE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
docker compose -f /etc/printguard/compose.yaml pull
docker compose -f /etc/printguard/compose.yaml up -d
UPDATE_SCRIPT
chmod 0755 /usr/local/sbin/update-printguard
CONTAINER_SCRIPT
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die 'Run this script as root on a Proxmox VE host'
  require_command pct
  require_command pvesm
  require_command curl
  collect_values
  validate_values
  printf '\nCreating PrintGuard LXC %s (%s)...\n' "$CT_ID" "$CT_HOSTNAME"
  local template_path
  template_path="$(download_template)"
  create_container "$template_path"
  install_printguard
  printf '\nPrintGuard is ready.\n'
  printf 'Container: %s\n' "$CT_ID"
  if [[ "$CT_IP" == 'dhcp' ]]; then
    printf 'Dashboard: determine the DHCP address, then open http://<container-ip>:8000\n'
  else
    printf 'Dashboard: http://%s:8000\n' "${CT_IP%/*}"
  fi
}

main "$@"
