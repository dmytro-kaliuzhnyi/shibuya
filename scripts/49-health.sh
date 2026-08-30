#!/usr/bin/env bash
# Сторож шини: єдиний heartbeat після того, як прибрали hq-assistant-health.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs
USER_NAME="$(target_user)"; USER_HOME="$(target_home)"; UID_N="$(id -u "$USER_NAME")"

section "передумови"
as_user test -x "${USER_HOME}/hq/scripts/hq-health.sh" \
  && ok "є hq/scripts/hq-health.sh" || warn "немає — зроби git pull у ~/hq"

section "systemd: сторож"
# Кожні 30 хв. Частіше немає сенсу: сторож нічого не лікує, він лише каже,
# що зламалось, а сигнал раз на пів години достатньо швидкий, щоб устигнути
# до вечірнього пуша.
write_user_file ".config/systemd/user/hq-health.service" 0644 <<EOF
[Unit]
Description=Сторож шини HQ: юніти, heartbeat, застряглі черги
After=tg-gateway.service

[Service]
Type=oneshot
Environment=PATH=${USER_HOME}/.local/bin:${USER_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${USER_HOME}/hq/scripts/hq-health.sh --quiet
# Скрипт виходить з 1, коли знайшов проблему — це не збій самого сторожа.
SuccessExitStatus=0 1
EOF

write_user_file ".config/systemd/user/hq-health.timer" 0644 <<'EOF'
[Unit]
Description=Перевіряти шину кожні 30 хвилин

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
AccuracySec=2min
Persistent=false

[Install]
WantedBy=timers.target
EOF

chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/systemd"
uctl() { as_user env XDG_RUNTIME_DIR="/run/user/${UID_N}" systemctl --user "$@"; }
if [ -d "/run/user/${UID_N}" ]; then
  uctl daemon-reload >/dev/null 2>&1 || true
  if uctl enable --now hq-health.timer >/dev/null 2>&1; then
    ok "сторож увімкнено: $(uctl list-timers hq-health.timer --no-pager 2>/dev/null | sed -n 2p | cut -c1-58 || true)"
  else
    warn "не увімкнувся — systemctl --user status hq-health.timer"
  fi
else
  warn "немає /run/user/${UID_N} — увімкни вручну: systemctl --user enable --now hq-health.timer"
fi

section "перевірка"
echo "  ~/hq/scripts/hq-health.sh          # разова перевірка з виводом"
echo "  ~/hq/scripts/hq-health.sh --force  # надіслати звіт у Telegram навіть коли все добре"
