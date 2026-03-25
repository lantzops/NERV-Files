# NERV HQ deployment guide — Proxmox VE on Dell R730xd

Rebuild of baator from RHEL 9 bare metal to Proxmox VE with Evangelion naming.

---

## Hardware reference

| Component | Details |
|-----------|---------|
| Server | Dell PowerEdge R730xd |
| CPUs | 2x Intel Xeon E5-2697v4 (18C/36T each, 72 threads total) |
| RAM | 192GB DDR4-2133 (24x 8GB Samsung RDIMMs) |
| NIC | 2x 10GbE SFP+ (eno1, eno2) + 2x 1GbE |
| RAID controller | Dell H330 in HBA mode (passthrough, no hardware RAID) |
| iDRAC | Enterprise, dedicated NIC |
| Rack | StarTech 18U open frame |

## Drive inventory

| Slot | Drives | Purpose (RHEL era) | New purpose |
|------|--------|-------------------|-------------|
| Rear flex bay | 2x SATA SSD | OS boot (mdadm RAID1) | Proxmox boot (mdadm RAID1 + LVM + ext4) |
| Quad M.2 adapter | 2x NVMe (nvme0n1, nvme2n1) | VM images (RAID0) | ZFS mirror — VM/CT storage |
| Front 3.5" bays | 4x SATA HDD | Data (RAID10 + cache) | ZFS 2x mirror vdev — primary data |
| Front 3.5" bays | 8x SATA HDD | Bulk (RAID6) | ZFS RAIDZ2 — ISOs, seeds, backups |
| M.2 adapter | 1x 256GB NVMe (nvme1n1) | LVM cache for RAID10 | ZFS L2ARC or SLOG (see notes) |

---

## Phase 0 — Pre-install prep

### 0.1 — iDRAC

iDRAC should still be configured from the RHEL build. Verify you can
reach the web console and remote KVM works. If you're doing this from
the rack, a crash cart (monitor + keyboard) works too.

Update iDRAC firmware if you haven't recently:
https://www.dell.com/support (enter service tag)

### 0.2 — BIOS / H330 verification

Boot into BIOS (F2) and confirm:

- Virtualization: VT-x ON, VT-d ON
- Boot mode: UEFI (not Legacy)
- Memory mode: Optimizer (not Mirror or Spare)
- H330: still in HBA mode (Controller Management > Switch to HBA Mode)
  If it shows "Switch to RAID mode" then it's already in HBA. Good.

### 0.3 — Download Proxmox VE ISO

From entreri or another machine:

```bash
# Download Proxmox VE 8.x ISO (check proxmox.com/en/downloads for latest)
wget https://enterprise.proxmox.com/iso/proxmox-ve_8.4-1.iso

# Write to USB with dd or use Ventoy
# dd example:
sudo dd if=proxmox-ve_8.4-1.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Or if you still have Ventoy on a USB, just drop the ISO on it.

### 0.4 — Wipe existing RHEL data

If you want a truly clean slate, boot the Proxmox installer and it will
offer to format the target drives. But if you want to pre-wipe the RHEL
mdadm arrays so nothing confuses the installer:

Boot a live ISO and run:
```bash
# Stop and zero mdadm superblocks from the RHEL build
mdadm --stop /dev/md0 /dev/md1 /dev/md126 /dev/md127 2>/dev/null
mdadm --zero-superblock /dev/sda /dev/sdb    # rear SSDs
mdadm --zero-superblock /dev/sd{c,d,e,f}     # RAID10 drives
mdadm --zero-superblock /dev/sd{g,h,i,j,k,l,m,n}  # RAID6 drives

# Wipe LVM metadata from the NVMe cache drive
wipefs -a /dev/nvme1n1

# Wipe the NVMe VM drives
wipefs -a /dev/nvme0n1 /dev/nvme2n1
```

Adjust device names as needed — `lsblk` is your friend.

---

## Phase 1 — Proxmox VE installation

### 1.1 — Boot the installer

USB boot, select "Install Proxmox VE (Graphical)".

### 1.2 — Target disk selection

When the installer asks for the target disk:

- Click **Options** (bottom of the disk selection screen)
- Select: **ext4 (with LVM)**
- Target disk: pick ONE of the rear flex bay SSDs
  (the smaller ones — they'll show as /dev/sda or similar)
- Filesystem: ext4
- hdsize: leave default (use full disk)
- swapsize: 8 (GB — with 192GB RAM you don't need much)

The Proxmox installer puts the boot partition, root filesystem, and a
data LV all on this single disk. We will mirror the boot drive manually
after install (see Phase 2).

### 1.3 — Network configuration

| Field | Value |
|-------|-------|
| Management Interface | pick a 1GbE port (not 10GbE — save those for VM traffic) |
| Hostname (FQDN) | nerv-hq.tokyo3.lan |
| IP Address | 10.0.1.10/24 (or wherever you want it on VLAN 10 mgmt) |
| Gateway | your router IP |
| DNS Server | your current DNS (will point to Rei/AdGuard later) |

If you're still on the flat vecna network pre-VLAN-cutover, use whatever
IP scheme works now. You can change it after VLANs are configured.

### 1.4 — Set root password and email

Pick a strong root password. Email can be anything — it's for Proxmox
alert notifications.

### 1.5 — Complete installation

Let it rip. Reboot when prompted. Remove USB.

### 1.6 — First boot verification

SSH in or use the console:

```bash
ssh root@10.0.1.10
```

Verify:
```bash
# Proxmox version
pveversion -v

# All drives visible
lsblk

# CPU and RAM
lscpu | grep "CPU(s):"
free -h

# Network
ip a
```

---

## Phase 2 — Post-install hardening

### 2.1 — Disable enterprise repo, enable no-subscription

```bash
# Comment out the paid enterprise repo
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list

# Disable Ceph enterprise repo if present
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list 2>/dev/null

# Add the free no-subscription repo
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list

# Update and upgrade
apt update && apt full-upgrade -y
```

### 2.2 — Remove subscription nag in web UI (optional)

```bash
# This patches the JavaScript that shows the "No valid subscription" popup
sed -Ezi.bak \
  "s/(Ext\.Msg\.show\(\{.*?title: gettext\('No valid sub)/void\(\{ \/\/ \1/g" \
  /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
systemctl restart pveproxy
```

### 2.3 — Install essential tools

```bash
apt install -y \
  vim htop tmux iotop \
  lm-sensors smartmontools \
  ethtool bridge-utils vlan \
  docker.io docker-compose-plugin
```

Docker is for the Unit-00/Unit-01 torrent stack and any future
containerized services.

### 2.4 — Enable IOMMU for future passthrough

Edit the bootloader config for IOMMU support (useful if you ever want
GPU passthrough or direct NIC assignment to VMs):

```bash
# Edit GRUB command line
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/' \
  /etc/default/grub
update-grub
```

### 2.5 — Mirror the boot drive

Proxmox installs to a single disk. Let's set up mdadm RAID1 on the
second rear SSD so you can survive a boot drive failure.

This is a more involved process — we need to:
1. Partition the second SSD identically to the first
2. Create a degraded RAID1 from the second SSD
3. Copy data, install GRUB, and add the first SSD to the array

This is a "nice to have" that can wait until after the ZFS pools and
VMs are running. I'll write the detailed steps in a follow-up if you
want to tackle it — it's fiddly but worth it for boot redundancy.

### 2.6 — Configure sensors

```bash
sensors-detect --auto
sensors   # verify CPU temps, fan speeds
```

---

## Phase 3 — ZFS pool creation

### 3.1 — Identify drives

Map your physical drives to device paths:

```bash
# List all drives with serial numbers for positive identification
lsblk -o NAME,SIZE,MODEL,SERIAL,ROTA,TRAN

# Or use by-id paths (preferred for ZFS — stable across reboots)
ls -la /dev/disk/by-id/ | grep -v part
```

Write down which by-id paths map to which physical slots. ZFS should
always reference drives by /dev/disk/by-id/ paths, never /dev/sdX
(those can change on reboot).

### 3.2 — Pool: Central Dogma (NVMe mirror — VM storage)

Named after the heart of NERV HQ where the core systems live.
This pool holds all VM disk images and container rootfs.

ZFS mirror (RAID1 equivalent) — not RAID0 like the RHEL build.
You lost redundancy for speed before, but for a Proxmox host where
VMs are the crown jewels, a mirror is the right call. Still extremely
fast on NVMe.

```bash
zpool create \
  -o ashift=12 \
  -o autotrim=on \
  -O compression=zstd-1 \
  -O atime=off \
  -O relatime=on \
  -O xattr=sa \
  -O dnodesize=auto \
  -O normalization=formD \
  -O acltype=posixacl \
  central-dogma \
  mirror \
  /dev/disk/by-id/nvme-XXXXX_nvme0n1 \
  /dev/disk/by-id/nvme-XXXXX_nvme2n1
```

Create datasets:

```bash
# VM disk images
zfs create -o recordsize=64K central-dogma/vm-disks

# Container rootfs
zfs create -o recordsize=16K central-dogma/ct-rootfs

# ISO storage (temporary — ISOs for installing VMs)
zfs create -o recordsize=1M central-dogma/iso
```

Add to Proxmox storage config:

```bash
# VM disks (ZFS native — zvols)
pvesm add zfspool central-dogma-vms \
  -pool central-dogma/vm-disks \
  -content images,rootdir \
  -sparse 1

# ISO images
pvesm add dir central-dogma-iso \
  -path /central-dogma/iso \
  -content iso,vztmpl
```

Options explained:
- `ashift=12` — 4K sector alignment, correct for all modern drives
- `autotrim=on` — issues TRIM/discard to NVMe for performance
- `compression=zstd-1` — lightweight compression, saves space with
  minimal CPU cost on your dual 18-core Xeons
- `atime=off` — don't update access timestamps on every read (huge
  performance win for VM workloads)
- `recordsize=64K` for VM disks — matches typical VM I/O block size
- `sparse=1` — thin provisioning, don't pre-allocate full disk size

### 3.3 — Pool: GeoFront (SATA RAID10 — primary data)

Named after the massive underground cavity beneath Tokyo-3.
4x SATA HDDs as 2 mirror vdevs (RAID10 equivalent).

This is your primary working data store — Home Assistant databases,
Grafana/Prometheus TSDB, Ansible playbooks, config repos, anything
that benefits from random I/O performance.

```bash
zpool create \
  -o ashift=12 \
  -o autotrim=off \
  -O compression=zstd-3 \
  -O atime=off \
  -O relatime=on \
  -O xattr=sa \
  -O dnodesize=auto \
  -O normalization=formD \
  -O acltype=posixacl \
  geofront \
  mirror \
  /dev/disk/by-id/ata-XXXXX_sdc \
  /dev/disk/by-id/ata-XXXXX_sdd \
  mirror \
  /dev/disk/by-id/ata-XXXXX_sde \
  /dev/disk/by-id/ata-XXXXX_sdf
```

Create datasets:

```bash
# General data
zfs create geofront/data

# Application configs and databases
zfs create -o recordsize=16K geofront/databases

# Docker volumes
zfs create geofront/docker
```

### 3.4 — Pool: Terminal Dogma (SATA RAIDZ2 — bulk storage)

Named after the deepest level of NERV, where the secrets are kept.
8x SATA HDDs in RAIDZ2 (RAID6 equivalent — any 2 drives can fail).

This holds ISOs for seeding, PBS backup targets, media, and anything
bulk/archival. Sequential throughput is fine; random I/O is slow.

```bash
zpool create \
  -o ashift=12 \
  -o autotrim=off \
  -O compression=zstd-3 \
  -O atime=off \
  -O relatime=on \
  -O xattr=sa \
  -O dnodesize=auto \
  -O normalization=formD \
  -O acltype=posixacl \
  terminal-dogma \
  raidz2 \
  /dev/disk/by-id/ata-XXXXX_sdg \
  /dev/disk/by-id/ata-XXXXX_sdh \
  /dev/disk/by-id/ata-XXXXX_sdi \
  /dev/disk/by-id/ata-XXXXX_sdj \
  /dev/disk/by-id/ata-XXXXX_sdk \
  /dev/disk/by-id/ata-XXXXX_sdl \
  /dev/disk/by-id/ata-XXXXX_sdm \
  /dev/disk/by-id/ata-XXXXX_sdn
```

Create datasets:

```bash
# ISO torrent seeding (Unit-01 target)
zfs create -o recordsize=1M terminal-dogma/torrents

# Proxmox Backup Server target (Melchior-1 stores backups here)
zfs create -o recordsize=1M terminal-dogma/backups

# Media (Pen Pen's domain)
zfs create -o recordsize=1M terminal-dogma/media

# ISO mirror files (Balthasar-2 syncs from here or to here)
zfs create -o recordsize=1M terminal-dogma/mirror
```

Add to Proxmox:

```bash
# Backup target (for PBS or local vzdump)
pvesm add dir terminal-dogma-backup \
  -path /terminal-dogma/backups \
  -content backup

# ISO storage (installable ISOs for VM creation)
pvesm add dir terminal-dogma-iso \
  -path /terminal-dogma/torrents \
  -content iso
```

### 3.5 — The 256GB NVMe cache drive (nvme1n1)

You have options:

**Option A: ZFS L2ARC on the GeoFront pool**
Adds a read cache in front of the SATA mirror vdevs. Helps if you're
reading a lot of random data from spinning disks.

```bash
zpool add geofront cache /dev/disk/by-id/nvme-XXXXX_nvme1n1
```

**Option B: ZFS SLOG on the GeoFront pool**
Write-intent log for synchronous writes. Helps databases and NFS.

```bash
zpool add geofront log /dev/disk/by-id/nvme-XXXXX_nvme1n1
```

**Option C: Skip it for now**
L2ARC eats RAM for its index (~5GB per 256GB of cache), and SLOG
only helps sync writes. You might not need either depending on
workload. You can always add it later.

Recommendation: start with Option C. Add L2ARC later if you notice
the GeoFront pool's read latency is a bottleneck. With 192GB of RAM,
ZFS ARC (the in-memory cache) will handle most reads.

### 3.6 — Verify pools

```bash
# Pool status
zpool status

# Pool usage
zpool list

# Dataset listing
zfs list

# Verify compression ratios
zfs get compressratio
```

---

## Phase 4 — Network configuration

### 4.1 — Bridge setup for VMs

Create bridges in /etc/network/interfaces (or via the Proxmox web UI
under Datacenter > nerv-hq > System > Network):

```
# Management bridge (1GbE — Proxmox web UI, SSH)
auto vmbr0
iface vmbr0 inet static
    address 10.0.1.10/24
    gateway 10.0.1.1
    bridge-ports eno3
    bridge-stp off
    bridge-fd 0

# VM traffic bridge (10GbE SFP+ port 1)
auto vmbr1
iface vmbr1 inet manual
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0

# Storage bridge (10GbE SFP+ port 2) — optional, for iSCSI/NFS
auto vmbr2
iface vmbr2 inet manual
    bridge-ports eno2
    bridge-stp off
    bridge-fd 0
```

VLAN tagging will be configured per-VM in Proxmox when you assign
network interfaces. The MikroTik (Asmodeus) handles the trunk.

### 4.2 — Install Tailscale (Kaworu)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh
```

This gives you remote access immediately. Critical before you touch
any network config that might lock you out.

---

## Phase 5 — Docker setup for Unit-00 + Unit-01

### 5.1 — Create the torrent directory structure

```bash
mkdir -p /terminal-dogma/torrents/{downloads,watch,incomplete}
mkdir -p /terminal-dogma/torrents/config/{qbittorrent,gluetun}
```

### 5.2 — Deploy the compose stack

Copy the unit-01-seeder/ directory to NERV HQ:

```bash
# From entreri:
scp -r unit-01-seeder/ root@nerv-hq:/root/unit-01-seeder/
```

On NERV HQ:

```bash
cd /root/unit-01-seeder
cp .env.example .env
chmod 600 .env
nvim .env   # fill in WIREGUARD_PRIVATE_KEY and QBIT_PASS

# Launch
docker compose up -d

# Verify
docker compose ps
docker compose logs unit-00-vpn --tail 30
```

### 5.3 — Adjust storage paths in .env

Update the paths to match the ZFS dataset mount points:

```
TORRENT_DATA=/terminal-dogma/torrents/downloads
TORRENT_WATCH=/terminal-dogma/torrents/watch
TORRENT_INCOMPLETE=/terminal-dogma/torrents/incomplete
QBIT_CONFIG=/terminal-dogma/torrents/config/qbittorrent
GLUETUN_DATA=/terminal-dogma/torrents/config/gluetun
```

---

## Phase 6 — VM scaffolding

Create the Eva units and bridge crew as empty VMs. Don't install OSes
yet — just reserve the resources and IDs so the architecture is mapped.

### VM ID scheme

| VMID | Name | Role | vCPU | RAM | Disk | Notes |
|------|------|------|------|-----|------|-------|
| 100 | rei | AdGuard Home DNS | 2 | 2GB | 16GB | LXC container |
| 101 | misato | Grafana + Prometheus | 4 | 8GB | 64GB | VM |
| 102 | unit-02 | Home Assistant | 2 | 4GB | 32GB | VM (HAOS image) |
| 103 | kaji | Reverse proxy (nginx) | 2 | 2GB | 16GB | LXC container |
| 104 | kaworu | Tailscale coordinator | 1 | 1GB | 8GB | LXC container |
| 105 | pen-pen | Jellyfin | 4 | 8GB | 32GB | VM |
| — | unit-00 + unit-01 | VPN + seeder | — | — | — | Docker on host |

Unit-00 and Unit-01 run as Docker containers directly on the Proxmox
host (not inside a VM) for maximum network performance and direct
access to the ZFS datasets. The rest are proper VMs or LXC containers.

### Quick-create script

```bash
# Rei — LXC container for AdGuard Home
pct create 100 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname rei \
  --cores 2 --memory 2048 \
  --rootfs central-dogma-vms:16 \
  --net0 name=eth0,bridge=vmbr1,firewall=1 \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --description "DNS - AdGuard Home. Quiet. Essential."

# Kaji — LXC container for reverse proxy
pct create 103 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname kaji \
  --cores 2 --memory 2048 \
  --rootfs central-dogma-vms:16 \
  --net0 name=eth0,bridge=vmbr1,firewall=1 \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --description "Reverse proxy - nginx. Double agent."

# Kaworu — LXC container for Tailscale exit node
pct create 104 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname kaworu \
  --cores 1 --memory 1024 \
  --rootfs central-dogma-vms:8 \
  --net0 name=eth0,bridge=vmbr1,firewall=1 \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --description "Tailscale mesh. Arrives from outside."
```

VMs (misato, unit-02, pen-pen) need ISOs to install from, so those
get created once you've downloaded the relevant OS images to the ISO
storage.

---

## Phase 7 — Post-deploy checklist

- [ ] Proxmox installed and updated
- [ ] Enterprise repo disabled, no-subscription repo added
- [ ] Subscription nag removed
- [ ] Docker installed
- [ ] IOMMU enabled in GRUB
- [ ] ZFS pool: central-dogma (NVMe mirror) — VM storage
- [ ] ZFS pool: geofront (SATA mirrors) — primary data
- [ ] ZFS pool: terminal-dogma (SATA RAIDZ2) — bulk/ISOs
- [ ] Datasets created on all pools
- [ ] Storage added to Proxmox (pvesm)
- [ ] Network bridges configured (vmbr0 mgmt, vmbr1 VMs)
- [ ] Tailscale installed and connected
- [ ] Unit-00 + Unit-01 Docker stack deployed
- [ ] VPN verified (curl ifconfig.io from Unit-01)
- [ ] Port forwarding confirmed
- [ ] First ISO torrent added and seeding
- [ ] Rei (AdGuard) container created
- [ ] smartd configured for drive health monitoring
- [ ] ZFS scrub scheduled (monthly cron)

---

## ZFS maintenance cron

Add to root's crontab:

```bash
crontab -e
```

```
# ZFS scrub — first Sunday of every month at 2 AM
0 2 1-7 * 0 /sbin/zpool scrub central-dogma
0 3 1-7 * 0 /sbin/zpool scrub geofront
0 4 1-7 * 0 /sbin/zpool scrub terminal-dogma

# ZFS snapshot — daily at midnight (keep 30 days)
0 0 * * * /sbin/zfs snapshot -r central-dogma@auto-$(date +\%Y\%m\%d)
0 0 * * * /sbin/zfs snapshot -r geofront@auto-$(date +\%Y\%m\%d)

# Prune snapshots older than 30 days
15 0 * * * /sbin/zfs list -H -t snapshot -o name | grep '@auto-' | head -n -30 | xargs -r -n1 /sbin/zfs destroy
```

---

## Pool name reference

| Evangelion location | ZFS pool | Purpose |
|----|----------|---------|
| Central Dogma | central-dogma | NVMe mirror — VM/CT storage (the brain) |
| GeoFront | geofront | SATA RAID10 — working data (the underground city) |
| Terminal Dogma | terminal-dogma | SATA RAIDZ2 — bulk storage, ISOs, backups (the deepest level) |
