# RaspPi-Remote Admin (Garmin IQ)

A script for the secure installation of an API to control and monitor your Raspberry Pi directly from a Garmin watch (via Tailscale Funnel) – 30-Slot Admin Edition.

## Built-in Ready-to-Use Commands (Slots 1–8)
1. **`pi_status`** – CPU usage/freq, temperature, RAM, load, uptime, top process, active SSH sessions
2. **`disk_space`** – Partition usage, free space, and filesystem types
3. **`system_shield`** – SSH failed logins, blocked API hits, and failed systemd services
4. **`userservices`** – Status summary of custom systemd services (`ON` / `OFF` / `ERR`)
5. **`docker_status`** – Running and stopped Docker containers overview
6. **`top_hogs`** – Top 3 CPU and Top 3 RAM consuming processes
7. **`net_info`** – LAN IP, Tailscale VPN IP, Wi-Fi signal %, Ping latency, total RX traffic
8. **`reboot_pi`** – Safe background reboot

*Slots up to 30 (`custom_slot1` – `custom_slot30`) are pre-configured and can be easily overridden by adding your own aliases in `~/.bash_aliases`.*

## Installation
Run the following command in your Raspberry Pi terminal:

```bash
curl -sSL [https://raw.githubusercontent.com/piotrkuzemczak-stack/RaspPi-Remote-Admin-API/main/garmin-admin-install.sh](https://raw.githubusercontent.com/piotrkuzemczak-stack/RaspPi-Remote-Admin-API/main/garmin-admin-install.sh) | sudo bash
