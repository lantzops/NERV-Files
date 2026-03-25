# Unit-00 + Unit-01 — NERV ISO Seeding Stack

VPN-tunneled torrent seeding for Linux ISO community distribution.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│ NERV HQ (Proxmox VM or LXC with Docker)             │
│                                                      │
│  ┌──────────────┐    ┌──────────────┐               │
│  │  Unit-00      │    │  Unit-01      │               │
│  │  Gluetun VPN  │◄───│  qBittorrent  │               │
│  │  WireGuard    │    │  (nox)        │               │
│  │  ProtonVPN    │    │  network_mode │               │
│  │  kill switch  │    │  =unit-00     │               │
│  │  port forward │    │               │               │
│  └──────┬───────┘    └──────────────┘               │
│         │                                            │
│         │ WireGuard tunnel                           │
│         ▼                                            │
│  ┌──────────────┐                                   │
│  │  ProtonVPN    │                                   │
│  │  P2P server   │                                   │
│  │  NAT-PMP port │                                   │
│  └──────────────┘                                   │
│                                                      │
│  ┌──────────────┐                                   │
│  │  port-sync    │  Polls Gluetun API every 60s     │
│  │  agent        │  Updates qBit listening port      │
│  └──────────────┘                                   │
│                                                      │
│  Storage: /data/raid6/torrents/                      │
│    ├── downloads/    ← completed ISOs (seeding)     │
│    ├── incomplete/   ← partial downloads            │
│    ├── watch/        ← drop .torrent files here     │
│    └── config/       ← persistent container config  │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

1. **ProtonVPN Plus** (or higher) subscription — free tier blocks P2P
2. **Docker + Docker Compose** installed on the VM/LXC
3. **Storage mounted** — RAID6 array at `/data/raid6/`

## Deployment

### Step 1: Get your WireGuard key

Go to https://account.proton.me/u/0/vpn/WireGuard

When generating the config:
- Platform: **GNU/Linux**
- Protocol: **WireGuard**
- NAT Type: **NAT-PMP** (NOT Moderate NAT — you need this for port forwarding)
- VPN Accelerator: **ON**
- Pick a server with the **P2P icon** (e.g., US-FREE#10 won't work — pick US#42 etc.)

Download the `.conf` file. Open it and find the `PrivateKey` line — that's
what goes in your `.env`.

**Important**: If the config shows an IPv6 address in the `Address` line
(contains `:`), you only need the IPv4 part (the one with dots).
Example: `Address = 10.2.0.2/32` — ignore the `/128` IPv6 portion.

**Key expiry**: ProtonVPN WireGuard keys expire after 12 months.
Set a reminder to regenerate.

### Step 2: Configure

```bash
cp .env.example .env
chmod 600 .env
nvim .env    # fill in your WIREGUARD_PRIVATE_KEY and QBIT_PASS
```

### Step 3: Create directories

```bash
mkdir -p /data/raid6/torrents/{downloads,watch,incomplete}
mkdir -p /data/raid6/torrents/config/{qbittorrent,gluetun}
```

### Step 4: Launch

```bash
docker compose up -d
```

### Step 5: Verify the VPN

```bash
# Check Gluetun logs — should show successful WireGuard connection
docker compose logs unit-00-vpn

# Verify your public IP is NOT your real IP
docker exec unit-01-seeder curl -s ifconfig.io

# Check the forwarded port
curl -s http://localhost:8000/v1/openvpn/portforwarded | jq
```

### Step 6: Access qBittorrent web UI

Open `http://<nerv-hq-ip>:8080` in your browser.
Login with the credentials from your `.env`.

Recommended first-time settings:
- **Downloads > Default Save Path**: `/downloads`
- **Downloads > Keep incomplete in**: `/incomplete`
- **Downloads > Monitored Folder**: `/watch`
- **Connection > Listening Port**: leave as-is (port-sync handles this)
- **Speed > Upload limit**: set based on your Comcast upstream
  (leave ~20% headroom for family internet)
- **BitTorrent > Seeding**: set ratio to 0 (seed forever) or a high number

## Starting to seed Linux ISOs

### Quick start — manual method

1. Go to a distro's download page and grab the `.torrent` file
2. Upload it through the qBittorrent web UI, or drop it in the watch folder
3. qBittorrent downloads the ISO through the VPN tunnel
4. Once complete, it automatically seeds to other peers

### Recommended ISOs to seed

Start with distros you use and care about:

| Distro | Where to find .torrent files |
|--------|------------------------------|
| CachyOS Desktop | https://cachyos.org/download/ |
| CachyOS Handheld | https://cachyos.org/download/ (handheld tab) |
| Arch Linux | https://archlinux.org/download/ |
| Rocky Linux | https://rockylinux.org/download |
| Fedora | https://torrent.fedoraproject.org/ |
| Debian | https://www.debian.org/CD/torrent-cd/ |
| Ubuntu | https://ubuntu.com/download/alternative-downloads |
| Linux Mint | https://linuxmint.com/torrents/ |

### Automated method — LinuxTracker

For a more automated approach, check out:
https://github.com/jim3692/linuxtracker-extractor

This Docker container scrapes LinuxTracker.org for the top seeded Linux
torrents and auto-adds them to Transmission. Can be adapted for
qBittorrent with its API.

## Monitoring

```bash
# Container health
docker compose ps

# VPN status
docker compose logs unit-00-vpn --tail 20

# Current forwarded port
curl -s http://localhost:8000/v1/openvpn/portforwarded | jq

# Port sync status
docker compose logs port-sync --tail 10

# qBittorrent stats via API
curl -s -b "$(curl -sf -c - \
  --data-urlencode 'username=admin' \
  --data-urlencode 'password=yourpass' \
  http://localhost:8080/api/v2/auth/login | grep -oP 'SID\s+\K\S+')" \
  http://localhost:8080/api/v2/transfer/info | jq
```

## Troubleshooting

**qBittorrent shows "firewalled"**
- Check that VPN_PORT_FORWARDING=on in the compose
- Check port-sync logs: `docker compose logs port-sync`
- Verify Gluetun has a forwarded port: `curl localhost:8000/v1/openvpn/portforwarded`

**No peers connecting**
- Ensure your ProtonVPN server supports P2P (has the P2P icon)
- Ensure NAT-PMP was selected (not Moderate NAT) when generating the key
- Check that the forwarded port matches qBit's listening port

**VPN connection failing (i/o timeout)**
- WireGuard is a silent protocol — failures show as timeouts, not errors
- Regenerate your WireGuard config and update WIREGUARD_PRIVATE_KEY
- Try a different SERVER_COUNTRIES value
- Check if your key has expired (12 month lifetime)

**Slow speeds**
- Try a different ProtonVPN server: change SERVER_COUNTRIES or use SERVER_HOSTNAMES
- Check your Comcast upstream: `speedtest-cli` on the host
- Set appropriate upload limits so you don't saturate your connection
# NERV-Files
