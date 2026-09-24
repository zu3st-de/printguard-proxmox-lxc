# PrintGuard Proxmox LXC

Community script for deploying [PrintGuard](https://oliverbravery.github.io/PrintGuard/) in a Debian 12 LXC container on Proxmox VE.

PrintGuard is a self-hosted 3D-print failure detector. It runs the dashboard and inference locally, connects to supported printer services and can send alerts through ntfy, Pushover, Telegram or Discord.

## What the script does

- Creates a Debian 12 LXC container on the selected Proxmox node.
- Enables the LXC features required by Docker (`nesting` and `keyctl`).
- Installs Docker Engine and the Docker Compose plugin inside the container.
- Starts the official `ghcr.io/oliverbravery/printguard:latest` image.
- Persists PrintGuard data in `/var/lib/printguard` inside the LXC root disk.
- Publishes the dashboard on port `8000` and live video on port `8554`.

The script is intended to run on a Proxmox VE host as `root`.

## Requirements

- Proxmox VE 7 or newer with outbound internet access.
- A Debian 12 LXC template available on the node.
- At least 2 CPU cores, 4 GiB RAM and 16 GiB disk recommended for a small setup. Actual requirements depend on the number of cameras and the selected inference workload.
- A static IP or DHCP reservation is recommended.
- Docker inside an LXC is convenient but has more kernel and device constraints than a VM. For production workloads, evaluate a VM if you need GPU acceleration or encounter device access limitations.

## Installation

Run the community installer on the Proxmox host as `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/zu3st-de/printguard-proxmox-lxc/main/printguard.sh)"
```

The script asks for the CT ID, hostname, storage, network bridge, IP configuration and resource limits. It prints the PrintGuard URL when the installation completes.

To inspect the script before running it:

```bash
curl -fsSL https://raw.githubusercontent.com/zu3st-de/printguard-proxmox-lxc/main/printguard.sh -o printguard.sh
less printguard.sh
chmod +x printguard.sh
./printguard.sh
```

For a non-interactive run, set the variables before invoking the script:

```bash
CT_ID=220 CT_HOSTNAME=printguard CT_STORAGE=local-lvm CT_DISK_GB=32 CT_MEMORY_MB=4096 CT_CORES=2 CT_IP=dhcp ./printguard.sh
```

## Access

Open `http://<container-ip>:8000` after the container starts. Complete the PrintGuard setup in the dashboard, then connect your printer service and cameras.

The live video service is exposed on port `8554`. Do not expose either port directly to the public internet; use a VPN or a properly configured reverse proxy with authentication.

## Updating

The container includes an update helper:

```bash
pct exec <CT_ID> -- /usr/local/sbin/update-printguard
```

This pulls the configured image and recreates the container while keeping the persistent data.

## Removing the deployment

The script does not provide an automatic removal command because deleting an LXC also deletes its application data. Review and back up `/var/lib/printguard` in the container first, then remove it from the Proxmox UI or with:

```bash
pct shutdown <CT_ID>
pct destroy <CT_ID>
```

## GPU acceleration

CPU inference is the default. GPU/NPU passthrough is hardware-specific and is not enabled automatically. See PrintGuard's [hardware documentation](https://github.com/oliverbravery/PrintGuard/blob/main/docs/hardware.md) and add the required Proxmox device mapping only after testing it with your host kernel and LXC security profile.

## Community project status

This repository is independent of the PrintGuard project. It contains deployment automation only and is provided as-is. Please report PrintGuard application issues upstream at [oliverbravery/PrintGuard](https://github.com/oliverbravery/PrintGuard).

## License

The deployment script in this repository is released under the MIT License. PrintGuard remains licensed separately under GPL-2.0.
