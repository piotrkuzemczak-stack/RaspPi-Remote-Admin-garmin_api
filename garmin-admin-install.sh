#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}   RaspPi-Remote Admin (Garmin IQ) - Server Setup Script${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Please run this script with sudo.${NC}"
    echo -e "Try: ${YELLOW}curl -sSL <url> | sudo bash${NC}"
    exit 1
fi

echo -e "${YELLOW}Checking internet connection...${NC}"
if ! ping -c 1 -W 3 8.8.8.8 &> /dev/null && ! ping -c 1 -W 3 1.1.1.1 &> /dev/null; then
    echo -e "${RED}[ERROR] No internet connection detected. Please check your network.${NC}"
    exit 1
fi
echo -e "${GREEN}[+] Internet connection is OK.${NC}\n"

# Step 1: Install Dependencies
echo -e "${YELLOW}[Step 1/4] Installing system dependencies...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq sudo python3 python3-flask python3-waitress curl jq procps iproute2 iw util-linux coreutils i2c-tools gpiod > /dev/null 2>&1
echo -e "${GREEN}[+] Dependencies installed successfully.${NC}\n"

# Stop service if already running to free up its port before checking
systemctl stop rasppi-remote.service 2>/dev/null || true

SAVED_DOMAIN=""
SECRET_TOKEN=""
SAVED_PORT=""
if [ -f /etc/default/rasppi-remote ]; then
    SECRET_TOKEN=$(grep "^SECURITY_TOKEN=" /etc/default/rasppi-remote 2>/dev/null | tr -d '\r' | cut -d'=' -f2- | head -n1 | tr -d '[:space:]' || true)
    SAVED_DOMAIN=$(grep "^TS_DOMAIN=" /etc/default/rasppi-remote 2>/dev/null | tr -d '\r' | cut -d'=' -f2- | head -n1 | tr -d '[:space:]' || true)
    SAVED_PORT=$(grep "^API_PORT=" /etc/default/rasppi-remote 2>/dev/null | tr -d '\r' | cut -d'=' -f2- | head -n1 | tr -d '[:space:]' || true)
fi

API_PORT=${API_PORT:-${SAVED_PORT:-8081}}

# Verify if port is free; if occupied by another service, find the next available port
while ss -tulpn 2>/dev/null | grep -q ":${API_PORT} "; do
    API_PORT=$((API_PORT + 1))
done

case "$SECRET_TOKEN" in
    ""|"UNSET")
        SECRET_TOKEN="_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14 || true)"
        TOKEN_MSG="Secure Token generated automatically."
        ;;
    *)
        TOKEN_MSG="Existing Secure Token preserved."
        ;;
esac

echo -e "${GREEN}[+] Automated configuration:${NC}"
echo -e "    - Internal Port: ${YELLOW}$API_PORT${NC}"
echo -e "    - ${TOKEN_MSG}\n"

# Step 2: Tailscale & Funnel Authorization
echo -e "${YELLOW}[Step 2/4] Setting up Tailscale & Funnel...${NC}"
if ! command -v tailscale &> /dev/null; then
    echo -e "Tailscale not found. Installing..."
    curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1
fi

systemctl enable --now tailscaled > /dev/null 2>&1 || true

if ! tailscale status &> /dev/null; then
    echo -e "${YELLOW}Tailscale is not logged in. Starting authentication...${NC}"
    if [ -r /dev/tty ]; then
        tailscale up < /dev/tty
    else
        tailscale up
    fi
fi

echo "Configuring Tailscale Funnel..."
# Reset existing serve/funnel config to prevent 'listener already exists' errors
tailscale serve reset > /dev/null 2>&1 || true

# timeout 6 prevents tailscale CLI from hanging forever if Funnel awaits browser authorization
FUNNEL_OUT=$(timeout 6 tailscale funnel --bg "$API_PORT" </dev/null 2>&1 || true)

if echo "$FUNNEL_OUT" | grep -q "login.tailscale.com" || echo "$FUNNEL_OUT" | grep -q "allow"; then
    ACL_LINK=$(echo "$FUNNEL_OUT" | grep -o 'https://login.tailscale.com[^ ]*' | head -n1 | tr -d '[:space:]')
    
    echo -e "\n${YELLOW}============================================================${NC}"
    echo -e "${CYAN} [i]  INSTALLATION PAUSED - WAITING FOR YOUR ACTION  [i] ${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "To make your Raspberry Pi securely accessible to your watch,"
    echo -e "you must allow 'Funnel' in your Tailscale account."
    echo -e "\n${CYAN}1. Open this link in your web browser:${NC}"
    echo -e "${GREEN}${ACL_LINK}${NC}"
    echo -e "\n${CYAN}2. Enable/Allow the Funnel setting for this device.${NC}"
    echo -e "${YELLOW}============================================================${NC}\n"
    
    if [ -r /dev/tty ]; then
        read -r -p "-> Press the [ENTER] key on your keyboard after enabling Funnel... " < /dev/tty
    else
        echo "Waiting 15 seconds for Funnel authorization..."
        sleep 15
    fi
    
    tailscale serve reset > /dev/null 2>&1 || true
    timeout 10 tailscale funnel --bg "$API_PORT" </dev/null > /dev/null 2>&1 || true
fi

TS_DOMAIN=""
case "$SAVED_DOMAIN" in
    ""|"null") TS_DOMAIN="" ;;
    *) TS_DOMAIN="$SAVED_DOMAIN" ;;
esac

case "$TS_DOMAIN" in
    ""|"null")
        TS_DOMAIN=$(tailscale status --json 2>/dev/null | jq -r .Self.DNSName 2>/dev/null | tr -d '\r' | sed 's/\.$//' | head -n1 | tr -d '[:space:]' || true)
        ;;
esac

case "$TS_DOMAIN" in
    ""|"null")
        TS_DOMAIN=$(hostname -f 2>/dev/null | tr -d '\r' | head -n1 | tr -d '[:space:]' || hostname | tr -d '\r' | head -n1 | tr -d '[:space:]' || true)
        ;;
esac

echo -e "${GREEN}[+] Tailscale Funnel active on: https://${TS_DOMAIN} (proxy -> 127.0.0.1:${API_PORT})${NC}\n"

# Step 3: Application Structure & API Code
echo -e "${YELLOW}[Step 3/4] Creating secure API application and helper scripts...${NC}"
APP_DIR="/opt/rasppi-remote"
mkdir -p "$APP_DIR"

REAL_USER="${SUDO_USER:-}"
case "$REAL_USER" in
    "")
        REAL_USER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd 2>/dev/null || echo "root")
        ;;
esac
REAL_USER=$(echo "$REAL_USER" | tr -d '[:space:]' | head -n1)
case "$REAL_USER" in
    "") REAL_USER="root" ;;
esac

USER_HOME=""
RAW_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 | head -n1 || true)
USER_HOME=$(echo "$RAW_HOME" | tr -d '\r' | tr -d '[:space:]' | head -n1)

case "$USER_HOME" in
    ""|/)
        USER_HOME="/root"
        ;;
    *)
        if [ ! -d "$USER_HOME" ]; then
            USER_HOME="/root"
        fi
        ;;
esac

ALIASES_FILE="$USER_HOME/.bash_aliases"
if [ ! -f "$ALIASES_FILE" ]; then
    cat << 'EOF_ALIASES' > "$ALIASES_FILE"
# ============================================================
# RaspPi-Remote (Garmin IQ) Custom Commands & Slots
# Define your custom watch commands below using standard aliases:
# alias custom_slot1='echo "Hello from Raspberry Pi!"'
# ============================================================
EOF_ALIASES
    if [ "$USER_HOME" != "/root" ]; then
        chown "$REAL_USER":"$REAL_USER" "$ALIASES_FILE" 2>/dev/null || true
    fi
fi

# 1. Generate User Services script
cat << 'EOF_SERVICES' > "$APP_DIR/user_services.sh"
#!/bin/bash
export LC_ALL=C
echo "=== USER SERVICES ==="
for f in /etc/systemd/system/*.service; do
    [ -e "$f" ] || continue
    fname=$(basename "$f" .service)
    case "$fname" in
        systemd-*|dbus*|ssh|sshd|cron|rsyslog|syslog|networking|NetworkManager*|wpa_supplicant*|avahi-daemon*|bluetooth*|triggerhappy*|ModemManager*|polkit*|udisks2*|tailscaled|rasppi-remote|docker*|containerd*|lightdm*|alsa-*|cups*|nfs-*|rpc-*|smartmontools*|e2scrub*|fstrim*|apt-*|dpkg-*|man-db*|logrotate*|getty*|serial-getty*|user@*|console-setup*|keyboard-setup*|fake-hwclock*|raspi-config*|rpi-eeprom-update*|dphys-swapfile*)
            continue
            ;;
        *)
            echo "$fname"
            ;;
    esac
done | sort > /tmp/user_services_list.txt

if [ ! -s /tmp/user_services_list.txt ]; then
    echo "No custom user services found."
    rm -f /tmp/user_services_list.txt
    exit 0
fi

COUNT_ON=0; COUNT_OFF=0; COUNT_FAIL=0
while read -r s; do
    [ -z "$s" ] && continue
    if systemctl is-failed --quiet "${s}.service" 2>/dev/null; then
        echo "🚨 $s"
        COUNT_FAIL=$((COUNT_FAIL + 1))
    elif systemctl is-active --quiet "${s}.service" 2>/dev/null; then
        echo "🟢 $s"
        COUNT_ON=$((COUNT_ON + 1))
    elif [ -f "/etc/systemd/system/${s}.timer" ] && systemctl is-active --quiet "${s}.timer" 2>/dev/null; then
        echo "🟢 $s"
        COUNT_ON=$((COUNT_ON + 1))
    else
        echo "🔴 $s"
        COUNT_OFF=$((COUNT_OFF + 1))
    fi
done < /tmp/user_services_list.txt
rm -f /tmp/user_services_list.txt
echo "-------------------"
echo "ON: $COUNT_ON | OFF: $COUNT_OFF | ERR: $COUNT_FAIL"
EOF_SERVICES
chmod 755 "$APP_DIR/user_services.sh"

# 2. Generate Top Hogs script
cat << 'EOF_HOGS' > "$APP_DIR/top_hogs.sh"
#!/bin/bash
export LC_ALL=C
echo "🔥 TOP CPU:"
ps -eo comm,%cpu --sort=-%cpu | awk '$1 != "COMMAND" && $1 != "ps" { if(c<3) { printf "▪️ %-10s %s%%\n", substr($1,1,10), $2; c++ } }'
echo "💻 TOP RAM:"
ps -eo comm,%mem --sort=-%mem | awk 'NR>1 && NR<=4 {printf "▪️ %-10s %s%%\n", substr($1,1,10), $2}'
EOF_HOGS
chmod 755 "$APP_DIR/top_hogs.sh"

# 3. Generate GPIO Scan script
cat << 'EOF_GPIOSCAN' > "$APP_DIR/gpio_scan.sh"
#!/bin/bash
echo "=== 🔍 GPIO & I2C ==="
echo "[I2C BUS]"
if command -v i2cdetect > /dev/null 2>&1; then
    i2cdetect -y 1 2> /dev/null | awk '
    NR>1 {
        row = substr($1, 1, 1);
        for(i=2; i<=NF; i++) {
            if ($i ~ /^[0-9a-f]{2}$/) {
                printf "_GRN_ 0x%s (Active)\n", row sprintf("%x", i-2);
            } else if ($i == "UU") {
                printf "_LCK_ 0x%s (Kernel)\n", row sprintf("%x", i-2);
            }
        }
    }' | sed -e 's/_GRN_/🟢/' -e 's/_LCK_/🔒/' | grep . || echo "⚪ No I2C devices"
else
    echo "⚪ i2c-tools missing"
fi
echo "[PARKED PINS]"
if command -v gpioinfo > /dev/null 2>&1; then
    gpioinfo 2> /dev/null | awk '
    /line/ && (/used/ || /consumer=/) && $0 ~ /GPIO[0-9]+/ {
        match($0, /GPIO[0-9]+/); pin = substr($0, RSTART+4, RLENGTH-4);
        dir = ($0 ~ /output/) ? "O" : "I";
        consumer = "";
        if (match($0, /consumer="[^"]+"/)) { consumer = substr($0, RSTART+10, RLENGTH-11); }
        else if (match($0, /: "[^"]+"/)) { consumer = substr($0, RSTART+3, RLENGTH-4); }

        if (consumer != "" && consumer !~ /^(unused|shutdown|pwr_led|act_led|eth_|pcie|spi0 CS|cam|vc4|scl|sda)/) {
            printf "_PIN_ G%-2s[%s] %s\n", pin, dir, substr(consumer, 1, 11)
        }
    }' | sed 's/_PIN_/📌/' | grep . || echo "⚪ All user pins free"
else
    echo "⚪ gpiod missing"
fi
EOF_GPIOSCAN
chmod 755 "$APP_DIR/gpio_scan.sh"

# 4. Generate System Updates & Upgrade scripts
cat << 'EOF_SYSUPDATES' > "$APP_DIR/system_updates.sh"
#!/bin/bash
export LC_ALL=C
echo "📦 SYSTEM UPDATES"
if fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; then
    echo "⏳ Apt is busy..."
    echo "System is updating"
    exit 0
fi
COUNT=$(apt-get -s upgrade 2> /dev/null | awk '/^[0-9]+ upgraded,/ {print $1}')
if [ -z "$COUNT" ] || [ "$COUNT" -eq 0 ]; then
    echo "✅ All up to date!"
    echo "🛡️ System secure"
else
    echo "⚠️ $COUNT pkgs ready"
    SEC=$(apt-get -s upgrade 2> /dev/null | grep -i "security" | grep -i "Inst" | wc -l || echo 0)
    if [ "$SEC" -gt 0 ]; then
        echo "🚨 $SEC sec patches!"
    fi
    echo "💻 Use sys_upgrade"
fi
EOF_SYSUPDATES
chmod 755 "$APP_DIR/system_updates.sh"

cat << 'EOF_SYSUPGRADE' > "$APP_DIR/system_upgrade.sh"
#!/bin/bash
export LC_ALL=C
echo "🚀 Upgrade started..."
echo "Working in background."
(
    while fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; do sleep 5; done
    LOG="/tmp/sys_upgrade.log"
    sudo apt-get update -qq > /dev/null 2>&1
    sudo apt-get upgrade -y > "$LOG" 2>&1
) &
EOF_SYSUPGRADE
chmod 755 "$APP_DIR/system_upgrade.sh"


# Link helper scripts & aliases to user profiles
for d in /home/*; do
    if [ -d "$d" ]; then
        ln -sf "$APP_DIR/user_services.sh" "$d/user_services.sh"
        chown -h "$(basename "$d")":"$(basename "$d")" "$d/user_services.sh" 2>/dev/null || true
        
        U_ALIAS="$d/.bash_aliases"
        if [ ! -f "$U_ALIAS" ]; then
            touch "$U_ALIAS"
            chown "$(basename "$d")":"$(basename "$d")" "$U_ALIAS" 2>/dev/null || true
        fi
        
        sed -i '/gpio_reset/d' "$U_ALIAS" 2>/dev/null || true
        
        if ! grep -q "alias userservices=" "$U_ALIAS" 2>/dev/null; then
            echo -e "\nalias userservices='/opt/rasppi-remote/user_services.sh'" >> "$U_ALIAS"
        fi
        if ! grep -q "alias gpio_scan=" "$U_ALIAS" 2>/dev/null; then
            echo "alias gpio_scan='/opt/rasppi-remote/gpio_scan.sh'" >> "$U_ALIAS"
        fi
        if ! grep -q "alias system_updates=" "$U_ALIAS" 2>/dev/null; then
            echo "alias system_updates='/opt/rasppi-remote/system_updates.sh'" >> "$U_ALIAS"
        fi
        if ! grep -q "alias system_upgrade=" "$U_ALIAS" 2>/dev/null; then
            echo "alias system_upgrade='/opt/rasppi-remote/system_upgrade.sh'" >> "$U_ALIAS"
            echo "alias sys_upgrade='/opt/rasppi-remote/system_upgrade.sh'" >> "$U_ALIAS"
        fi
    fi
done

sed -i '/gpio_reset/d' "$ALIASES_FILE" 2>/dev/null || true
if ! grep -q "alias userservices=" "$ALIASES_FILE" 2>/dev/null; then
    echo -e "\nalias userservices='/opt/rasppi-remote/user_services.sh'" >> "$ALIASES_FILE"
fi
if ! grep -q "alias gpio_scan=" "$ALIASES_FILE" 2>/dev/null; then
    echo "alias gpio_scan='/opt/rasppi-remote/gpio_scan.sh'" >> "$ALIASES_FILE"
fi
if ! grep -q "alias system_updates=" "$ALIASES_FILE" 2>/dev/null; then
    echo "alias system_updates='/opt/rasppi-remote/system_updates.sh'" >> "$ALIASES_FILE"
fi
if ! grep -q "alias system_upgrade=" "$ALIASES_FILE" 2>/dev/null; then
    echo "alias system_upgrade='/opt/rasppi-remote/system_upgrade.sh'" >> "$ALIASES_FILE"
    echo "alias sys_upgrade='/opt/rasppi-remote/system_upgrade.sh'" >> "$ALIASES_FILE"
fi

if [ "$USER_HOME" != "/root" ]; then
    chown "$REAL_USER":"$REAL_USER" "$ALIASES_FILE" 2>/dev/null || true
fi

# 5. Prepare auth log file
touch /var/log/rasppi-remote-auth.log
chmod 600 /var/log/rasppi-remote-auth.log
chown root:root /var/log/rasppi-remote-auth.log

# 6. Generate main Python API server
cat << 'EOF_PYTHON' > "$APP_DIR/garmin_api.py"
from flask import Flask, jsonify, request
import subprocess, os, logging, hmac, time, ipaddress, re, threading, pwd, shlex
from datetime import datetime
from waitress import serve

app = Flask(__name__)
log = logging.getLogger('werkzeug')
log.setLevel(logging.ERROR)

SECURITY_TOKEN = os.environ.get('SECURITY_TOKEN', 'UNSET')
AUTH_LOG_FILE = '/var/log/rasppi-remote-auth.log'

ALLOWED_DIRECT_NETWORKS = [
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("100.64.0.0/10"),
]

MAX_FAILED_ATTEMPTS = 5
BLOCK_TIME_SECONDS = 900
failed_attempts = {}
rate_limit_lock = threading.Lock()

COMMANDS = {
    "pi_status": """
        CPU_USAGE=$(LC_ALL=C top -bn1 | grep 'Cpu(s)' | awk '{print $2+$4}')
        CPU_FREQ=$(awk '{printf "%.2f", $1/1000000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A")
        TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || vcgencmd measure_temp 2>/dev/null | grep -o '[0-9.]*' || echo "N/A")
        echo "🍓 CPU: ${CPU_USAGE}% @${CPU_FREQ} GHz"
        echo "🌡️ Temp: ${TEMP}°C"
        echo "💻 RAM: $(free -m | awk 'NR==2 {print $3}') /$(free -m | awk 'NR==2 {print $2}') MB"
        echo "⚙️ Load: $(awk '{print $1, $2, $3}' /proc/loadavg)"
        echo "⏱️ Up: $(uptime -p | sed 's/up //; s/ days/d/; s/ day/d/; s/ hours/hrs/; s/ hour/hr/; s/ minutes/min/; s/ minute/min/')"
        echo "🔥 Top: $(ps -eo comm,%cpu --sort=-%cpu | awk 'NR==2 {print $1, $2"%"}')"
        echo "👤 SSH: $(ss -tn state established '( sport = :22 )' | tail -n +2 | wc -l) online"
    """.strip(),
    "disk_space": r"""df -h | grep "^/dev/" | grep -Ev "/boot|/efi" | while read -r fs size used avail pcent mount; do rdev=$(findmnt -n -o SOURCE "$mount" 2>/dev/null || echo "$fs"); rtype=$(lsblk -no FSTYPE "$rdev" 2>/dev/null | grep -v "^$" | head -n1); [ -z "$rtype" ] && rtype=$(findmnt -n -o FSTYPE "$mount" 2>/dev/null); printf "💾 %s (%s):\n🔴 Used: %s (%s/%s)\n🟢 Free: %s\n📁 System: %s\n" "$mount" "${rdev#/dev/}" "$pcent" "$used" "$size" "$avail" "${rtype:-unknown}"; done""",
    "system_shield": """
        SSH_F=$(journalctl -u ssh -u sshd --since today --no-pager 2>/dev/null | grep -i 'failed' | wc -l)
        TODAY=$(date +%Y-%m-%d)
        API_F=$(grep "^$TODAY" /var/log/rasppi-remote-auth.log 2>/dev/null | wc -l)
        SYS_F=$(systemctl --failed --type=service --no-legend | wc -l)
        
        echo "🔐 SSH Shield:"
        if [ "$SSH_F" -eq 0 ]; then 
            echo '✅ No attacks today'
        else 
            echo "❌ $SSH_F failed logins"
        fi

        echo "🌐 API Shield:"
        if [ "$API_F" -eq 0 ]; then 
            echo '✅ No unauthorized hits'
        else 
            echo "🚨 $API_F blocked attempts"
        fi
        
        echo "🛡️ Services:"
        if [ "$SYS_F" -eq 0 ]; then 
            echo '✅ All running'
        else 
            echo "🚨 Failed ($SYS_F):"
            systemctl --failed --type=service --no-legend | awk '{print "▪️ "$1}' | sed 's/.service//' | head -n 3
        fi
    """.strip(),
    "userservices": "/opt/rasppi-remote/user_services.sh",
    "gpio_scan": "/opt/rasppi-remote/gpio_scan.sh",
    "system_updates": "/opt/rasppi-remote/system_updates.sh",
    "system_upgrade": "/opt/rasppi-remote/system_upgrade.sh &",
    "docker_status": """
        if ! command -v docker &> /dev/null; then
            echo "🐳 Docker not installed"
            echo "on this server."
            exit 0
        fi
        RUN=$(docker ps -q 2>/dev/null | wc -l)
        ALL=$(docker ps -aq 2>/dev/null | wc -l)
        if [ "$ALL" -eq 0 ]; then
            echo "🐳 No Docker containers"
            echo "found on this server."
            exit 0
        fi
        STOP=$((ALL - RUN))
        echo "🐳 ON: $RUN | OFF: $STOP"
        echo "-------------------"
        [ "$RUN" -gt 0 ] && docker ps --format "🟢 {{.Names}}" | head -n 6
        [ "$STOP" -gt 0 ] && docker ps -f "status=exited" --format "🔴 {{.Names}}" | head -n 4
        exit 0
    """.strip(),
    "top_hogs": "/opt/rasppi-remote/top_hogs.sh",
    "net_info": """
        net_info() {
            local LAN_IP TS_IP PING_MS WIFI_SIG NM_SIG DBM RX_GB;
            LAN_IP=$(hostname -I | awk '{print $1}');
            TS_IP=$(tailscale ip -4 2> /dev/null | head -n1);
            PING_MS=$(ping -c 1 -W 2 1.1.1.1 2> /dev/null | awk -F'/' 'END{print $5}');
            WIFI_SIG=$(awk 'NR==3 {print int($3 * 100 / 70)"%"}' /proc/net/wireless 2> /dev/null);
            if [ -z "$WIFI_SIG" ] && command -v nmcli &> /dev/null; then
                NM_SIG=$(nmcli -t -f IN-USE,SIGNAL dev wifi 2>/dev/null | grep '^\\*' | cut -d: -f2 | head -n1);
                [ -n "$NM_SIG" ] && WIFI_SIG="${NM_SIG}%";
            fi;
            if [ -z "$WIFI_SIG" ] && command -v iw &> /dev/null; then
                DBM=$(iw dev wlan0 link 2>/dev/null | awk '/signal:/ {print $2}');
                if [ -n "$DBM" ]; then
                    WIFI_SIG=$(awk -v dbm="$DBM" 'BEGIN { sig = 2 * (dbm + 100); if (sig > 100) sig = 100; if (sig < 0) sig = 0; printf "%d%%", sig }');
                fi;
            fi;
            echo "🏠 LAN: ${LAN_IP:-Disconnected}";
            echo "🔒 VPN: ${TS_IP:-Offline}";
            if [ -n "$WIFI_SIG" ]; then
                echo "📶 WiFi Signal: $WIFI_SIG";
            else
                echo "🔌 Net: Ethernet";
            fi;
            if [ -n "$PING_MS" ]; then
                echo "⚡ Ping: ${PING_MS} ms";
            else
                echo "❌ Ping: Offline";
            fi;
            RX_GB=$(awk 'NR>2 && $1 !~ /^(lo|docker|veth|br-|tailscale)/ {rx+=$2} END {printf "%.1f GB", rx/1024/1024/1024}' /proc/net/dev);
            echo "📥 RX Total: $RX_GB";
        }
        net_info
    """.strip(),
    "reboot_pi": "( sleep 3 && sudo reboot ) >/dev/null 2>&1 &"
}

for i in range(1, 31):
    COMMANDS[f"custom_slot{i}"] = f"printf 'ℹ️ Custom Slot {i}\\nConfigure in ~/.bash_aliases'"

def is_direct_ip_allowed(ip_str):
    try:
        ip = ipaddress.ip_address(ip_str)
        return any(ip in net for net in ALLOWED_DIRECT_NETWORKS)
    except ValueError:
        return False

def get_real_client_ip():
    remote_ip = request.remote_addr or "0.0.0.0"
    if remote_ip == "127.0.0.1":
        forwarded = request.headers.get("X-Forwarded-For", "")
        if forwarded:
            return forwarded.split(",")[0].strip()
    return remote_ip

def log_and_alert(ip_addr, reason):
    try:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(AUTH_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{timestamp} | IP: {ip_addr} | {reason}\n")
    except Exception:
        pass

def check_rate_limit(ip_str):
    now = time.time()
    with rate_limit_lock:
        for k in list(failed_attempts.keys()):
            valid = [t for t in failed_attempts[k] if now - t < BLOCK_TIME_SECONDS]
            if valid:
                failed_attempts[k] = valid
            else:
                del failed_attempts[k]
        return len(failed_attempts.get(ip_str, [])) < MAX_FAILED_ATTEMPTS

def record_failed_attempt(ip_str):
    now = time.time()
    with rate_limit_lock:
        attempts = failed_attempts.setdefault(ip_str, [])
        attempts.append(now)
        count = len(attempts)
    log_and_alert(ip_str, f"Invalid token attempt ({count}/{MAX_FAILED_ATTEMPTS})")

def verify_token_safe(action_with_token):
    if SECURITY_TOKEN == 'UNSET' or len(action_with_token) <= len(SECURITY_TOKEN):
        return None
    provided_token = action_with_token[-len(SECURITY_TOKEN):]
    if hmac.compare_digest(provided_token, SECURITY_TOKEN):
        return action_with_token[:-len(SECURITY_TOKEN)]
    return None

def get_system_aliases():
    aliases = {}
    home_dirs = ['/root']
    if os.path.exists('/home'):
        home_dirs.extend([os.path.join('/home', d) for d in os.listdir('/home') if os.path.isdir(os.path.join('/home', d))])
    
    files_to_check = []
    for d in home_dirs:
        files_to_check.append(os.path.join(d, '.bash_aliases'))
        files_to_check.append(os.path.join(d, '.bashrc'))

    for filepath in files_to_check:
        if os.path.exists(filepath):
            try:
                file_owner = pwd.getpwuid(os.stat(filepath).st_uid).pw_name
            except Exception:
                file_owner = 'root'

            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("alias "):
                            try:
                                declaration = line[6:].strip()
                                if '=' in declaration:
                                    name, cmd = declaration.split('=', 1)
                                    name = name.strip()
                                    cmd = cmd.strip()
                                    if len(cmd) >= 2 and cmd[0] in ("'", '"') and cmd[-1] == cmd[0]:
                                        quote_char = cmd[0]
                                        cmd = cmd[1:-1]
                                        if quote_char == '"':
                                            cmd = cmd.replace('\\$', '$').replace('\\"', '"').replace('\\`', '`').replace('\\\\', '\\')
                                        aliases[name] = {"cmd": cmd, "owner": file_owner}
                            except Exception:
                                pass
                        elif not line.startswith("#"):
                            m = re.match(r'^(?:function\s+)?([a-zA-Z0-9_-]+)\s*\(\s*\)', line)
                            if m:
                                func_name = m.group(1)
                                aliases[func_name] = {
                                    "cmd": f"eval \"$(sed '/^case \\$- in/,/esac/d' {filepath})\" >/dev/null 2>&1 && {func_name}",
                                    "owner": file_owner
                                }
            except Exception:
                pass
    return aliases

@app.before_request
def security_gate():
    if not is_direct_ip_allowed(request.remote_addr):
        return jsonify({"status": "error", "wykonano": None, "output": "ERROR:\nForbidden Direct IP"}), 403
    client_ip = get_real_client_ip()
    if not check_rate_limit(client_ip):
        return jsonify({"status": "error", "wykonano": None, "output": "ERROR:\nToo Many Attempts"}), 429

@app.route('/api/status', methods=['GET'])
def status():
    return jsonify({"status": "success", "wykonano": "status"}), 200

@app.route('/api/run/<path:action_with_token>', methods=['GET'])
def run_command(action_with_token):
    client_ip = get_real_client_ip()
    action = verify_token_safe(action_with_token)

    if not action:
        record_failed_attempt(client_ip)
        return jsonify({"status": "error", "wykonano": None, "output": "ERROR:\nUnauthorized Access"}), 401

    system_aliases = get_system_aliases()

    cmd = None
    run_as_user = "root"

    if action in system_aliases:
        cmd = system_aliases[action]["cmd"]
        run_as_user = system_aliases[action]["owner"]
        if "journalctl" in cmd or "tail " in cmd:
            cmd = re.sub(r'\s+-f(\s+|$)', ' --no-pager ', cmd)
    elif action in COMMANDS:
        cmd = COMMANDS[action]
        run_as_user = "root"
    else:
        return jsonify({"status": "error", "wykonano": None, "output": f"ERROR:\nUnknown action: {action}"}), 404

    if not cmd:
        return jsonify({"status": "error", "wykonano": None, "output": f"ERROR:\nEmpty cmd for '{action}'"}), 404

    try:
        is_async = (
            any(w in cmd for w in ["reboot", "poweroff", "sysbackup", "nohup"]) or 
            action in ["reboot_pi", "reboot"] or 
            cmd.strip().endswith("&")
        )

        clean_cmd = cmd.strip()
        if clean_cmd.endswith("&"):
            clean_cmd = clean_cmd[:-1].strip()

        if run_as_user != "root" and not clean_cmd.startswith("su "):
            clean_cmd = f"sudo -u {shlex.quote(run_as_user)} bash -c {shlex.quote(clean_cmd)}"

        if is_async:
            subprocess.Popen(
                clean_cmd,
                shell=True,
                executable='/bin/bash',
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True
            )
            return jsonify({
                "status": "success", 
                "wykonano": action, 
                "output": f"Action '{action}'\nstarted in background."
            }), 200
        else:
            result = subprocess.run(
                clean_cmd,
                shell=True,
                executable='/bin/bash',
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=10
            )
            output = result.stdout.strip()
            error_output = result.stderr.strip()
            
            if result.returncode != 0 and error_output:
                return jsonify({"status": "error", "wykonano": action, "output": f"ERROR:\n{error_output}"}), 400
            
            if not output:
                output = "Action executed\nsuccessfully."
            
            return jsonify({"status": "success", "wykonano": action, "output": output}), 200

    except subprocess.TimeoutExpired:
        return jsonify({"status": "error", "wykonano": None, "output": "ERROR:\nCommand Timeout"}), 504
    except Exception as e:
        return jsonify({"status": "error", "wykonano": None, "output": f"ERROR:\n{str(e)}"}), 500

if __name__ == '__main__':
    port = int(os.environ.get('API_PORT', 8081))
    serve(app, host='0.0.0.0', port=port)
EOF_PYTHON

chown -R root:root "$APP_DIR"
chmod 755 "$APP_DIR" "$APP_DIR/user_services.sh" "$APP_DIR/top_hogs.sh" "$APP_DIR/gpio_scan.sh" "$APP_DIR/system_updates.sh" "$APP_DIR/system_upgrade.sh"
chmod 600 "$APP_DIR/garmin_api.py"

# 7. Create CLI helper tool 'rasppi-remote'
cat << 'EOF_CLI' > /usr/local/bin/rasppi-remote
#!/bin/bash
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo rasppi-remote"
    exit 1
fi
. /etc/default/rasppi-remote 2>/dev/null || true
echo "============================================================"
echo "   RaspPi-Remote Admin (Garmin IQ) - Connection Details     "
echo "============================================================"
echo "1. Server URL:  https://${TS_DOMAIN}/api/run/"
echo "2. Token:       ${SECURITY_TOKEN}"
echo "3. Internal:    http://127.0.0.1:${API_PORT}"
echo "4. Service:     $(systemctl is-active rasppi-remote.service)"
echo "5. Aliases:     ${USER_HOME}/.bash_aliases"
echo "============================================================"
EOF_CLI
chmod 755 /usr/local/bin/rasppi-remote

cat << EOF_ENV > /etc/default/rasppi-remote
SECURITY_TOKEN=$SECRET_TOKEN
API_PORT=$API_PORT
USER_HOME=$USER_HOME
TS_DOMAIN=$TS_DOMAIN
EOF_ENV
chmod 600 /etc/default/rasppi-remote
chown root:root /etc/default/rasppi-remote

cat << 'EOF_SERVICE' > /etc/systemd/system/rasppi-remote.service
[Unit]
Description=RaspPi Remote Garmin API
Wants=network-online.target tailscaled.service
After=network-online.target tailscaled.service

[Service]
Environment="LANG=C.UTF-8"
EnvironmentFile=/etc/default/rasppi-remote
ExecStart=/usr/bin/python3 /opt/rasppi-remote/garmin_api.py
WorkingDirectory=/opt/rasppi-remote
Restart=always
RestartSec=3
User=root
MemoryMax=128M

[Install]
WantedBy=multi-user.target
EOF_SERVICE

chmod 644 /etc/systemd/system/rasppi-remote.service
systemctl daemon-reload
systemctl enable rasppi-remote.service > /dev/null 2>&1
systemctl restart rasppi-remote.service

echo -e "\n============================================================"
echo -e "            [+] INSTALLATION COMPLETE! [+]                  "
echo -e "============================================================"
echo -e "Server URL: https://${TS_DOMAIN}/api/run/"
echo -e "Token:      ${SECRET_TOKEN}"
echo -e ""
echo -e "Tip: Run 'sudo rasppi-remote' anytime to view credentials."
echo -e "============================================================"
