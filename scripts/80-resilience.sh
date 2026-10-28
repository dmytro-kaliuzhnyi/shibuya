#!/usr/bin/env bash
# PHASE B — preparing for the move: parents' WiFi, network self-healing, notifications.
#
# NOT part of the default run: execute it deliberately, once the details are known.
# Settings come from /etc/shibuya/move.env (created from a template on the first
# run) so that passwords never end up in git.
#
#   sudo ~/shibuya/bootstrap.sh --only 80
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

ENVF="${SHIBUYA_ETC}/move.env"

if [[ ! -f "$ENVF" ]]; then
  write_file "$ENVF" 0600 <<'EOF'
# shibuya: move parameters. This file is NOT in git — passwords stay on the machine.
# Fill it in and run:  sudo ~/shibuya/bootstrap.sh --only 80

# My parents' WiFi. Critical: netplan currently only knows the home SSID, and
# without these details the machine will come up at their place WITH NO NETWORK AT ALL.
PARENTS_WIFI_SSID=""
PARENTS_WIFI_PSK=""

# The home WiFi stays, so the Pi works in both locations.
HOME_WIFI_SSID="autostrada"
HOME_WIFI_PSK=""

# Telegram notifications: boot, public IP changes, daily heartbeat.
# The bot is created with @BotFather, the chat_id comes from @userinfobot.
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
EOF
  warn "template ${ENVF} created — fill it in and run the script again"
  exit 0
fi

# shellcheck disable=SC1090
source "$ENVF"

# ------------------------------------------------------------ netplan -----
# The most dangerous point of the whole move: if no known network exists at my
# parents' place, the machine comes up offline and can only be fixed physically.
section "network: two SSIDs + ethernet"
if [[ -z "${PARENTS_WIFI_SSID:-}" || -z "${PARENTS_WIFI_PSK:-}" ]]; then
  warn "PARENTS_WIFI_SSID/PSK are empty in ${ENVF} — leaving netplan alone"
  warn "DO NOT MOVE THE MACHINE LIKE THIS: it will have no network at their place"
else
  # Wired takes priority (lower metric): a stable link and predictable NAT for
  # port forwarding. WiFi is the automatic fallback.
  NP=/etc/netplan/60-shibuya.yaml
  write_file "$NP" 0600 <<EOF
# shibuya: networking for two locations. Ethernet takes priority over WiFi.
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: false
      optional: true
      dhcp4-overrides:
        route-metric: 100
  wifis:
    wlan0:
      dhcp4: true
      dhcp6: false
      optional: true
      regulatory-domain: "UA"
      dhcp4-overrides:
        route-metric: 600
      access-points:
        "${HOME_WIFI_SSID}":
          auth:
            key-management: "psk"
            password: "${HOME_WIFI_PSK}"
        "${PARENTS_WIFI_SSID}":
          auth:
            key-management: "psk"
            password: "${PARENTS_WIFI_PSK}"
EOF
  if changed; then
    # netplan try rolls itself back after 120 seconds if the config kills connectivity.
    # netplan apply offers no such safety net — on a remote machine that is the
    # difference between "wait two minutes" and "drive to my parents".
    if timeout 150 netplan try --timeout 120 </dev/null >/dev/null 2>&1; then
      ok "netplan accepted (both SSIDs + ethernet)"
    else
      warn "netplan try was not confirmed — config rolled back, check it by hand"
    fi
  fi
fi

echo
log "MAC addresses for the DHCP reservation on my parents' router:"
for i in eth0 wlan0; do
  m="$(cat "/sys/class/net/${i}/address" 2>/dev/null || echo '—')"
  printf '    %-6s %s\n' "$i" "$m"
done

# ------------------------------------------------------- notifications ----
# The point: learn about a reboot or a public IP change BEFORE access is
# actually needed. Otherwise the first sign of trouble is "I cannot get in
# right now, exactly when I need to".
section "Telegram notifications"
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  warn "TELEGRAM_BOT_TOKEN/CHAT_ID are empty — skipping notification setup"
else
  write_file /usr/local/bin/shibuya-notify 0755 <<'EOF'
#!/usr/bin/env bash
# Sends the machine's state to Telegram. Called at boot and once a day.
set -uo pipefail
source /etc/shibuya/move.env

REASON="${1:-manual}"
PUB_IP="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || echo '?')"
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || echo '—')"
LAN_IP="$(hostname -I | awk '{print $1}')"
IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')"
UP="$(uptime -p)"
TEMP="$(awk '{printf "%.1f°C", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
DISK="$(df -h / | awk 'NR==2{print $4" free ("$5" used)"}')"

# The public IP is remembered: a change at my parents' place means the port
# forward no longer points at our machine.
PREV_FILE=/etc/shibuya/state/last-public-ip
PREV="$(cat "$PREV_FILE" 2>/dev/null || echo '')"
CHANGED=""
[[ -n "$PREV" && "$PREV" != "$PUB_IP" ]] && CHANGED="

*PUBLIC IP CHANGED:* \`${PREV}\` -> \`${PUB_IP}\`
The port forward on the router may now point somewhere else."
printf '%s' "$PUB_IP" > "$PREV_FILE"

TEXT="*shibuya* (${REASON})
Public IP: \`${PUB_IP}\`
Tailscale: \`${TS_IP}\`
LAN: \`${LAN_IP}\` via ${IFACE}
Uptime: ${UP}
Temperature: ${TEMP}
Disk: ${DISK}${CHANGED}"

curl -fsS --max-time 15 \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=Markdown" \
  --data-urlencode "text=${TEXT}" \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null
EOF

  write_file /etc/systemd/system/shibuya-notify.service 0644 <<'EOF'
[Unit]
Description=Tell Telegram that shibuya has booted
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
# Give the network and tailscale time to settle, or the message ships empty addresses.
ExecStartPre=/bin/sleep 20
ExecStart=/usr/local/bin/shibuya-notify boot

[Install]
WantedBy=multi-user.target
EOF

  write_file /etc/systemd/system/shibuya-heartbeat.service 0644 <<'EOF'
[Unit]
Description=Daily shibuya heartbeat

[Service]
Type=oneshot
ExecStart=/usr/local/bin/shibuya-notify heartbeat
EOF

  write_file /etc/systemd/system/shibuya-heartbeat.timer 0644 <<'EOF'
[Unit]
Description=Report once a day that the machine is alive

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  enable_now shibuya-notify.service
  enable_now shibuya-heartbeat.timer

  if /usr/local/bin/shibuya-notify test; then
    ok "test message sent — check Telegram"
  else
    warn "sending failed: check the token and chat_id in ${ENVF}"
  fi
fi

# Network self-healing moved to 81-netcheck.sh (2026-10-28): it is the only
# part worth redeploying on a remote Pi, and redeploying THIS script reruns
# netplan try, which can cut the machine off.

ok "80-resilience done"
echo
echo "  Left to do before the move:"
echo "    1. Image the SD card onto the Mac (a rollback point)"
echo "    2. Log out of tty1:  sudo pkill -t tty1"
echo "    3. Print the note for my parents from ~/shibuya/RUNBOOK.md"
