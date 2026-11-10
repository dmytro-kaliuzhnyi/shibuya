#!/usr/bin/env bash
# Network self-healing: restart networking, and reboot as a last resort — with
# a growing pause between reboots.
#
# Split out of 80-resilience.sh on 2026-10-28, so it can be redeployed alone
# (80 reruns netplan try). Same day's lesson: during a power cut the router is
# dead while the Pi still runs, and the old rule "6 failures -> reboot, at most
# once an hour" rebooted every hour, all evening. A reboot does not bring back
# the internet; over a three-day outage that would be ~70 pointless reboots.
#
# Now: the 1st reboot after 30 min offline, then each next one only after
# 1h, 2h, 4h, 8h, then every 12h. Any successful check resets the ladder.
#
#   sudo ~/shibuya/bootstrap.sh --only 81
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

section "network self-healing"
write_file /usr/local/bin/shibuya-netcheck 0755 <<'EOF'
#!/usr/bin/env bash
# Checks connectivity. Three failures in a row -> restart networking. Six ->
# reboot, then reboots with a doubling pause (1h, 2h, 4h, 8h, cap 12h).
set -uo pipefail

STATE=/etc/shibuya/state
FAILS="${STATE}/netcheck-fails"
LAST_REBOOT="${STATE}/netcheck-last-reboot"
REBOOTS="${STATE}/netcheck-reboots"      # reboots since connectivity was last seen
mkdir -p "$STATE"

alive() {
  ping -c1 -W5 1.1.1.1  >/dev/null 2>&1 && return 0
  ping -c1 -W5 8.8.8.8  >/dev/null 2>&1 && return 0
  # DNS separately: packets sometimes flow while resolution is broken.
  getent hosts one.one.one.one >/dev/null 2>&1 && return 0
  return 1
}

if alive; then
  echo 0 > "$FAILS"
  echo 0 > "$REBOOTS"
  exit 0
fi

n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAILS"
logger -t shibuya-netcheck "no connectivity, failure #${n}"

if [[ $n -eq 3 ]]; then
  logger -t shibuya-netcheck "restarting systemd-networkd and the Wi-Fi supplicant"
  systemctl restart systemd-networkd
  systemctl restart 'netplan-wpa-*.service' 2>/dev/null || true
  systemctl restart tailscaled 2>/dev/null || true
fi

# The brcmfmac firmware can wedge (dmesg: "bcdc_msg failed w/status -110"). A
# driver reload is cheaper than a reboot and is skipped when ethernet carries us.
if [[ $n -eq 4 ]] && ! grep -q 1 /sys/class/net/eth0/carrier 2>/dev/null; then
  logger -t shibuya-netcheck "reloading the brcmfmac Wi-Fi driver"
  modprobe -r brcmfmac_wcc 2>/dev/null
  modprobe -r brcmfmac && sleep 2 && modprobe brcmfmac
  sleep 5
  systemctl restart 'netplan-wpa-*.service' 2>/dev/null || true
fi

if [[ $n -ge 6 ]]; then
  k=$(cat "$REBOOTS" 2>/dev/null || echo 0)
  e=$(( k > 0 ? k - 1 : 0 )); (( e > 4 )) && e=4
  pause=$(( 3600 << e ))                 # k=1 -> 1h, 2 -> 2h, 3 -> 4h, 4 -> 8h
  (( pause > 43200 )) && pause=43200     # after that, every 12h
  now=$(date +%s)
  last=$(cat "$LAST_REBOOT" 2>/dev/null || echo 0)
  if (( k == 0 || now - last > pause )); then
    echo "$now" > "$LAST_REBOOT"
    echo $(( k + 1 )) > "$REBOOTS"
    echo 0 > "$FAILS"
    logger -t shibuya-netcheck "still no connectivity after restarting networking — reboot #$((k + 1))"
    systemctl reboot
  else
    logger -t shibuya-netcheck "reboot skipped: next one no sooner than $(( (pause - (now - last)) / 60 )) min (reboot #$((k + 1)) of this outage)"
  fi
fi
EOF

write_file /etc/systemd/system/shibuya-netcheck.service 0644 <<'EOF'
[Unit]
Description=Connectivity check with self-recovery

[Service]
Type=oneshot
ExecStart=/usr/local/bin/shibuya-netcheck
EOF

write_file /etc/systemd/system/shibuya-netcheck.timer 0644 <<'EOF'
[Unit]
Description=Check connectivity every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

section "Wi-Fi power save off"
# brcmfmac turns power save on by default ("power save enabled" in dmesg). On a
# server with no cable that means dropped packets and missed beacons. The unit is
# tied to the wlan0 device, so it runs again after a driver reload.
apt_install iw
write_file /etc/systemd/system/shibuya-wifi-powersave-off.service 0644 <<'EOF'
[Unit]
Description=Disable Wi-Fi power saving on wlan0
BindsTo=sys-subsystem-net-devices-wlan0.device
After=sys-subsystem-net-devices-wlan0.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iw dev wlan0 set power_save off

[Install]
WantedBy=sys-subsystem-net-devices-wlan0.device
EOF

systemctl daemon-reload
enable_now shibuya-wifi-powersave-off.service
enable_now shibuya-netcheck.timer

ok "81-netcheck done"
