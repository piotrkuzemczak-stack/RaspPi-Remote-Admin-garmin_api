#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}   RaspPi-Remote Admin (Garmin IQ) - Server Setup Script    ${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run this script with sudo.${NC}"
  echo -e "Try: ${YELLOW}curl -sSL <url> | sudo bash${NC}"
  exit 1
fi

echo -e "${YELLOW}Checking internet connection...${NC}"
if ! ping -c 1 8.8.8.8 &> /dev/null; then
  echo -e "${RED}[ERROR] No internet connection detected. Please check your network.${NC}"
  exit 1
fi
echo -e "${GREEN}[+] Internet connection is OK.${NC}\n"

API_PORT=${API_PORT:-8080}

# Preserve existing token on reinstall/update, or generate a new one
if [ -f /etc/default/rasppi-remote ] && grep -q "^SECURITY_TOKEN=" /etc/default/rasppi-remote; then
    SECRET_TOKEN=$(grep "^SECURITY_TOKEN=" /etc/default/rasppi-remote | cut -d'=' -f2)
    TOKEN_MSG="Existing Secure Token preserved."
else
    SECRET_TOKEN="_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14 || true)"
    TOKEN_MSG="Secure Token generated automatically."
fi

echo -e "${GREEN}[+] Automated configuration:${NC}"
echo -e "    - Internal Port: ${YELLOW}$API_PORT${NC}"
echo -e "    - ${TOKEN_MSG}\n"

# Step 1: Install Dependencies
echo -e "${YELLOW}[Step 1/4] Installing system dependencies...${NC}"
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq python3 python3-flask python3-waitress curl jq > /dev/null 2>&1
echo -e "${GREEN}[+] Dependencies installed successfully.${NC}\n"

# Step 2: Tailscale & Funnel Authorization
echo -e "${YELLOW}[Step 2/4] Setting up Tailscale & Funnel...${NC}"
if ! command -v tailscale &> /dev/null; then
    echo -e "Tailscale not found. Installing..."
    curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1
fi

if ! tailscale status &> /dev/null; then
    echo -e "${RED}[ERROR] Tailscale is not logged in.${NC}"
    echo -e "Please run '${YELLOW}sudo tailscale up${NC}' manually to log in, then restart this script."
    exit 1
fi

echo "Requesting public URL via Tailscale Funnel..."
FUNNEL_OUT=$(tailscale funnel --bg $API_PORT 2>&1 || true)

if [[ "$FUNNEL_OUT" == *"login.tailscale.com"* || "$FUNNEL_OUT" == *"allow"* ]]; then
    ACL_LINK=$(echo "$FUNNEL_OUT" | grep -o 'https://login.tailscale.com[^ ]*')
    
    echo -e "\n${YELLOW}============================================================${NC}"
    echo -e "${CYAN} ℹ️  INSTALLATION PAUSED - WAITING FOR YOUR ACTION  ℹ️ ${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "To make your Raspberry Pi securely accessible to your watch,"
    echo -e "you must allow 'Funnel' in your Tailscale account."
    echo -e "\n${CYAN}1. Open this link in your web browser:${NC}"
    echo -e "${GREEN}${ACL_LINK}${NC}"
    echo -e "\n${CYAN}2. Enable/Allow the Funnel setting for this device.${NC}"
    echo -e "${YELLOW}============================================================${NC}\n"
    
    read -p "👉 Press the [ENTER] key on your keyboard to continue... " < /dev/tty
    
    tailscale funnel --bg $API_PORT > /dev/null 2>&1
fi

TS_DOMAIN=$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')
if [ -z "$TS_DOMAIN" ] || [ "$TS_DOMAIN" == "null" ]; then
    echo -e "${RED}[ERROR] Failed to get Tailscale domain. Ensure Funnel is authorized.${NC}"
    exit 1
fi
echo -e "${GREEN}[+] Tailscale Funnel is active on: https://${TS_DOMAIN}${NC}\n"

# Step 3: Application Structure & API Code
echo -e "${YELLOW}[Step 3/4] Creating secure API application and User Services...${NC}"
APP_DIR="/opt/rasppi-remote"
mkdir -p "$APP_DIR"

# Generate User Services script in the user's home directory
USER_HOME=$(eval echo ~${SUDO_USER:-root})
cat << 'EOF' > "$USER_HOME/user_services.sh"
#!/bin/bash
echo "=== USER SERVICES ==="
USER_SERVICES=$(find /etc/systemd/system -maxdepth 1 -type f -name "*.service" -printf "%f\n" | sed 's/\.service//' | sort)
if [ -z "$USER_SERVICES" ]; then
    echo "No custom user"
    echo "services found."
    exit 0
fi
COUNT_ON=0; COUNT_OFF=0; COUNT_FAIL=0
for s in $USER_SERVICES; do
    if systemctl is-failed --quiet "${s}.service"; then
        echo "🚨 $s"
        ((COUNT_FAIL++))
    elif systemctl is-active --quiet "${s}.service"; then
        echo "🟢 $s"
        ((COUNT_ON++))
    else
        echo "🔴 $s"
        ((COUNT_OFF++))
    fi
done
echo "-------------------"
echo "ON: $COUNT_ON | OFF: $COUNT_OFF | ERR: $COUNT_FAIL"
EOF
chmod +x "$USER_HOME/user_services.sh"
if [ "$USER_HOME" != "/root" ]; then
    chown $(stat -c '%U:%G' "$USER_HOME") "$USER_HOME/user_services.sh"
fi

touch /var/log/rasppi-remote-auth.log
chmod 600 /var/log/rasppi-remote-auth.log

cat << 'EOF' > "$APP_DIR/garmin_api.py"
from flask import Flask, jsonify, request
import subprocess
import os
import logging
import hmac
import time
import ipaddress
import re
import urllib.request
import urllib.parse
from datetime import datetime
from waitress import serve

app = Flask(__name__)

# Silence default Flask request logging to prevent token leaks in journald
log = logging.getLogger('werkzeug')
log.setLevel(logging.ERROR)

SECURITY_TOKEN = os.environ.get('SECURITY_TOKEN', 'UNSET')
USER_HOME = os.environ.get('USER_HOME', '/root')
PUSHOVER_TOKEN = os.environ.get('PUSHOVER_TOKEN', '')
PUSHOVER_USER = os.environ.get('PUSHOVER_USER', '')
AUTH_LOG_FILE = '/var/log/rasppi-remote-auth.log'

# Direct socket connections are allowed only from Localhost (Tailscale Funnel proxy), LAN, and Tailscale VPN
ALLOWED_DIRECT_NETWORKS = [
    ipaddress.ip_network("127.0.0.0/8"),       # Localhost / Tailscale Funnel Proxy
    ipaddress.ip_network("192.168.0.0/16"),    # Local LAN
    ipaddress.ip_network("10.0.0.0/8"),        # Private LAN / VPN
    ipaddress.ip_network("172.16.0.0/12"),     # Private LAN
    ipaddress.ip_network("100.64.0.0/10"),     # Tailscale VPN
]

MAX_FAILED_ATTEMPTS = 5
BLOCK_TIME_SECONDS = 900  # 15 minutes ban after 5 failed attempts
failed_attempts = {}      # {ip: [timestamps]}

COMMANDS = {
    "pi_status": """
        echo "🍓 CPU: $(LC_ALL=C top -bn1 | grep 'Cpu(s)' | awk '{print $2+$4}')% @ $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{print $1/1000000}' || echo 0) GHz"
        echo "🌡️ Temp: $(vcgencmd measure_temp 2>/dev/null | grep -o '[0-9.]*')°C"
        echo "💻 RAM: $(free -m | awk 'NR==2 {print $3}') / $(free -m | awk 'NR==2 {print $2}') MB"
        echo "⚙️ Load: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
        echo "⏱️ Up: $(uptime -p | sed 's/up //; s/ days/d/; s/ day/d/; s/ hours/hrs/; s/ hour/hr/; s/ minutes/min/; s/ minute/min/')"
        echo "🔥 Top: $(ps -eo comm,%cpu --sort=-%cpu | head -n 2 | tail -n 1 | awk '{print $1, $2"%"}' )"
        echo "👤 SSH: $(who | wc -l) online"
    """.strip(),
    "disk_space": r"""df -h | grep "^/dev/" | grep -v "/boot" | while read -r fs size used avail pcent mount; do rdev=$(findmnt -n -o SOURCE "$mount" 2>/dev/null || echo "$fs"); rtype=$(lsblk -no FSTYPE "$rdev" 2>/dev/null | grep -v "^$" | head -n1); [ -z "$rtype" ] && rtype=$(findmnt -n -o FSTYPE "$mount" 2>/dev/null); printf "💾 %s (%s):\n🔴 Used: %s (%s/%s)\n🟢 Free: %s\n📁 System: %s\n" "$mount" "${rdev#/dev/}" "$pcent" "$used" "$size" "$avail" "${rtype:-unknown}"; done""",
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
    "userservices": f"{USER_HOME}/user_services.sh",
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
    "top_hogs": """
        echo "🔥 TOP CPU:"
        ps -eo comm,%cpu --sort=-%cpu | awk 'NR>1 && NR<=4 {printf "▪️ %-10s %s%%\n", substr($1,1,10), $2}'
        echo "💻 TOP RAM:"
        ps -eo comm,%mem --sort=-%mem | awk 'NR>1 && NR<=4 {printf "▪️ %-10s %s%%\n", substr($1,1,10), $2}'
    """.strip(),
    "net_info": """
        LAN_IP=$(hostname -I | awk '{print $1}')
        TS_IP=$(tailscale ip -4 2>/dev/null | head -n1)
        PING_MS=$(ping -c 1 -W 2 1.1.1.1 2>/dev/null | awk -F'/' 'END{print $5}')
        WIFI_SIG=$(awk 'NR==3 {print int($3 * 100 / 70)"%"}' /proc/net/wireless 2>/dev/null)
        
        echo "🏠 LAN: ${LAN_IP:-Disconnected}"
        echo "🔒 VPN: ${TS_IP:-Offline}"
        if [ -n "$WIFI_SIG" ]; then
            echo "📶 WiFi Signal: $WIFI_SIG"
        else
            echo "🔌 Net: Ethernet"
        fi
        if [ -n "$PING_MS" ]; then
            echo "⚡ Ping: ${PING_MS} ms"
        else
            echo "❌ Ping: Offline"
        fi
        RX_GB=$(awk '/eth0|wlan0|end0/ {rx+=$2} END {printf "%.1f GB", rx/1024/1024/1024}' /proc/net/dev)
        echo "📥 RX Total: $RX_GB"
    """.strip(),
    "reboot_pi": "( sleep 3 && sudo reboot ) >/dev/null 2>&1 &"
}

# Dynamically populate custom_slot1 through custom_slot30
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
    # If request comes through local Tailscale Funnel proxy (127.0.0.1), inspect X-Forwarded-For
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

    if PUSHOVER_TOKEN and PUSHOVER_USER:
        try:
            data = urllib.parse.urlencode({
                "token": PUSHOVER_TOKEN,
                "user": PUSHOVER_USER,
                "message": f"🚨 RaspPi-Remote Security Alert!\nIP: {ip_addr}\n{reason}",
                "priority": 1
            }).encode("utf-8")
            req = urllib.request.Request("https://api.pushover.net/1/messages.json", data=data)
            urllib.request.urlopen(req, timeout=5)
        except Exception:
            pass


def check_rate_limit(ip_str):
    now = time.time()
    attempts = [t for t in failed_attempts.get(ip_str, []) if now - t < BLOCK_TIME_SECONDS]
    failed_attempts[ip_str] = attempts
    return len(attempts) < MAX_FAILED_ATTEMPTS


def record_failed_attempt(ip_str):
    now = time.time()
    attempts = failed_attempts.setdefault(ip_str, [])
    attempts.append(now)
    log_and_alert(ip_str, f"Invalid token attempt ({len(attempts)}/{MAX_FAILED_ATTEMPTS})")


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
                                        cmd = cmd[1:-1]
                                    aliases[name] = cmd
                            except Exception:
                                pass
            except Exception:
                pass
    return aliases


@app.before_request
def security_gate():
    # 1. Block direct non-private connections bypassing Tailscale Funnel
    if not is_direct_ip_allowed(request.remote_addr):
        return jsonify({"status": "error", "wykonano": None, "output": "ERROR:\nForbidden Direct IP"}), 403
    # 2. Check brute-force rate limit for the real client IP
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
    if action in system_aliases:
        cmd = system_aliases[action]
        # Prevent continuous log streams (-f) from hanging the API thread
        if "journalctl" in cmd or "tail " in cmd:
            cmd = re.sub(r'\s+-f(\s+|$)', ' --no-pager ', cmd)
    elif action in COMMANDS:
        cmd = COMMANDS[action]
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

        if is_async:
            clean_cmd = cmd.strip()
            if clean_cmd.endswith("&"):
                clean_cmd = clean_cmd[:-1].strip()
                
            subprocess.Popen(clean_cmd, shell=True, executable='/bin/bash', start_new_session=True)
            return jsonify({
                "status": "success", 
                "wykonano": action, 
                "output": f"Action '{action}'\nstarted in background."
            }), 200
        else:
            result = subprocess.run(cmd, shell=True, executable='/bin/bash', capture_output=True, text=True, timeout=10)
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
    port = int(os.environ.get('API_PORT', 8080))
    serve(app, host='0.0.0.0', port=port)
EOF

chmod 700 "$APP_DIR"
chmod 600 "$APP_DIR/garmin_api.py"
chown -R root:root "$APP_DIR"
echo -e "${GREEN}[+] API files generated securely.${NC}\n"

# Step 4: System Services
echo -e "${YELLOW}[Step 4/4] Configuring background services...${NC}"

if systemctl is-active --quiet rasppi-cf-tunnel.service 2>/dev/null; then
    systemctl stop rasppi-cf-tunnel.service 2>/dev/null
    systemctl disable rasppi-cf-tunnel.service 2>/dev/null
    rm -f /etc/systemd/system/rasppi-cf-tunnel.service
fi

cat << EOF > /etc/default/rasppi-remote
SECURITY_TOKEN=$SECRET_TOKEN
API_PORT=$API_PORT
USER_HOME=$USER_HOME
EOF
chmod 600 /etc/default/rasppi-remote

cat << 'EOF' > /etc/systemd/system/rasppi-remote.service
[Unit]
Description=RaspPi Remote Garmin API
Wants=network-online.target tailscaled.service
After=network-online.target tailscaled.service

[Service]
EnvironmentFile=/etc/default/rasppi-remote
ExecStart=/usr/bin/python3 /opt/rasppi-remote/garmin_api.py
WorkingDirectory=/opt/rasppi-remote
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rasppi-remote.service > /dev/null 2>&1
systemctl restart rasppi-remote.service

if ! systemctl is-active --quiet rasppi-remote.service; then
    echo -e "${RED}[ERROR] Service failed to start. Check 'systemctl status rasppi-remote.service'${NC}"
    exit 1
fi
echo -e "${GREEN}[+] Service configured and running.${NC}\n"

# Step 5: Finalization and Credentials
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}                  ✅ INSTALLATION COMPLETE! ✅                  ${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e "Your secure server is now active and protected by Tailscale."
echo -e ""
echo -e "1. Server URL:  ${YELLOW}https://${TS_DOMAIN}/api/run/${NC}"
echo -e "2. Token:       ${YELLOW}${SECRET_TOKEN}${NC}"
echo -e ""
echo -e "${CYAN}>> COPY BOTH OF THESE VALUES TO YOUR GARMIN CONNECT APP <<${NC}"
echo -e "The 8 default commands (pi_status, disk_space, system_shield, userservices,"
echo -e "docker_status, top_hogs, net_info, reboot_pi) + custom slots (1-30)"
echo -e "are already configured and ready to use out of the box!"
echo -e "${CYAN}============================================================${NC}"
