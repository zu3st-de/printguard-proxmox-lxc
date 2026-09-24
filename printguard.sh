#!/usr/bin/env bash
set -Eeuo pipefail

readonly PRINTGUARD_IMAGE="${PRINTGUARD_IMAGE:-ghcr.io/oliverbravery/printguard:latest}"

CT_ID="${CT_ID:-}"
CT_HOSTNAME="${CT_HOSTNAME:-printguard}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-local}"
CT_DISK_GB="${CT_DISK_GB:-12}"
CT_MEMORY_MB="${CT_MEMORY_MB:-4096}"
CT_CORES="${CT_CORES:-4}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-}"
CT_GATEWAY="${CT_GATEWAY:-}"
CT_DNS="${CT_DNS:-1.1.1.1}"

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

run_step() {
  local label="$1"
  shift
  local log_file
  log_file="$(mktemp)"
  printf '[*] %s... ' "$label"
  if "$@" >"$log_file" 2>&1; then
    printf 'done\n'
    rm -f "$log_file"
    return 0
  fi
  printf 'failed\n' >&2
  cat "$log_file" >&2
  rm -f "$log_file"
  return 1
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

next_free_ct_id() {
  pvesh get /cluster/nextid
}

collect_values() {
  if [[ -z "$CT_ID" ]]; then
    CT_ID="$(prompt_default 'Container ID' "$(next_free_ct_id)")"
    CT_HOSTNAME="$(prompt_default 'Hostname' "$CT_HOSTNAME")"
    CT_STORAGE="$(prompt_default 'Root disk storage' "$CT_STORAGE")"
    CT_TEMPLATE_STORAGE="$(prompt_default 'Template storage' "$CT_TEMPLATE_STORAGE")"
    CT_DISK_GB="$(prompt_default 'Root disk size in GiB' "$CT_DISK_GB")"
    CT_MEMORY_MB="$(prompt_default 'Memory in MiB' "$CT_MEMORY_MB")"
    CT_CORES="$(prompt_default 'CPU cores' "$CT_CORES")"
    CT_BRIDGE="$(prompt_default 'Network bridge' "$CT_BRIDGE")"
    CT_IP="$(prompt_default 'IPv4 address' "${CT_IP:-dhcp}")"
    if [[ "$CT_IP" != "dhcp" ]]; then
      CT_GATEWAY="$(prompt_default 'IPv4 gateway' "$CT_GATEWAY")"
    fi
    CT_DNS="$(prompt_default 'DNS server' "$CT_DNS")"
  fi
}

validate_values() {
  validate_number 'CT_ID' "$CT_ID"
  validate_number 'CT_DISK_GB' "$CT_DISK_GB"
  validate_number 'CT_MEMORY_MB' "$CT_MEMORY_MB"
  validate_number 'CT_CORES' "$CT_CORES"
  validate_ip_config
  (( CT_ID >= 100 && CT_ID <= 999999999 )) || die 'CT_ID must be between 100 and 999999999'
  (( CT_DISK_GB >= 8 )) || die 'CT_DISK_GB must be at least 8'
  (( CT_MEMORY_MB >= 1024 )) || die 'CT_MEMORY_MB must be at least 1024'
  (( CT_CORES >= 1 )) || die 'CT_CORES must be at least 1'
}

download_template() {
  local template_name
  run_step 'Updating Proxmox template catalog' pveam update >&2
  template_name="$(pveam available --section system | awk '$1 == "system" && $2 ~ /^debian-12-standard_.*_amd64\.tar\.zst$/ { print $2 }' | sort -V | tail -n 1)"
  [[ -n "$template_name" ]] || die 'No Debian 12 amd64 LXC template is available from Proxmox'
  if ! pvesm path "${CT_TEMPLATE_STORAGE}:vztmpl/${template_name}" >/dev/null 2>&1; then
    run_step "Downloading Debian template $template_name" pveam download "$CT_TEMPLATE_STORAGE" "$template_name" >&2
  fi
  printf '%s:vztmpl/%s' "$CT_TEMPLATE_STORAGE" "$template_name"
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
  pvesm status --storage "$CT_TEMPLATE_STORAGE" >/dev/null 2>&1 || die "Template storage is not available: $CT_TEMPLATE_STORAGE"

  run_step 'Creating LXC container' pct create "$CT_ID" "$template_path" \
    --hostname "$CT_HOSTNAME" \
    --storage "$CT_STORAGE" \
    --rootfs "${CT_STORAGE}:${CT_DISK_GB}" \
    --memory "$CT_MEMORY_MB" \
    --swap 0 \
    --cores "$CT_CORES" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}${CT_GATEWAY:+,gw=${CT_GATEWAY}}" \
    --nameserver "$CT_DNS" \
    --features 'nesting=1,keyctl=1' \
    --unprivileged 1 \
    --onboot 1 \
    --start 0

  run_step 'Starting LXC container' pct start "$CT_ID"
  run_step 'Waiting for container' wait_for_container
}

install_printguard() {
  local log_file
  log_file="$(mktemp)"
  printf '[*] Installing Docker and PrintGuard... '
  if pct exec "$CT_ID" -- bash -s -- "$PRINTGUARD_IMAGE" >"$log_file" 2>&1 <<'CONTAINER_SCRIPT'
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
  then
    printf 'done\n'
    rm -f "$log_file"
    return 0
  fi
  printf 'failed\n' >&2
  cat "$log_file" >&2
  rm -f "$log_file"
  return 1
}

container_ip() {
  local address
  if [[ "$CT_IP" != 'dhcp' ]]; then
    printf '%s' "${CT_IP%/*}"
    return
  fi
  for _ in {1..30}; do
    address="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -n "$address" ]]; then
      printf '%s' "$address"
      return
    fi
    sleep 2
  done
  printf 'unknown'
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die 'Run this script as root on a Proxmox VE host'
  require_command pct
  require_command pvesm
  require_command pvesh
  require_command pveam
  collect_values
  validate_values
  printf '\nPrintGuard LXC %s (%s)\n\n' "$CT_ID" "$CT_HOSTNAME"
  local template_path
  template_path="$(download_template)"
  create_container "$template_path"
  install_printguard
  local address
  address="$(container_ip)"
  printf '\nPrintGuard is ready.\n'
  printf 'Container: %s\n' "$CT_ID"
  printf 'Dashboard: http://%s:8000\n' "$address"
}

main "$@"
