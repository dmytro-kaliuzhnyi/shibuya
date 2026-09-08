#!/usr/bin/env bash
# Ранковий збір годин Liven: таймер + пуш на схвалення в Telegram.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"
UID_N="$(id -u "$USER_NAME")"

# Збирач читає транскрипти ОБОХ профілів Claude Code (~/.claude і ~/.claude-work)
# та Slack. Обидва профілі на Pi заводить 45-claude-sync.sh; сам time-loop.sh
# тягне їх свіжими перед збором, бо інакше порахує вчорашній стан.
#
# Чому раз на день, а не кожні 30 хв як Slack: підтвердження годин — це один
# список за день. Пушити його частіше означає питати те саме по колу.
# Чому вранці, а не ввечері: о 09:00 учорашній день уже закритий і повністю
# синхнутий, тож нічого не випадає, і оцінюєш його на свіжу голову.

section "перевірка передумов"
for f in hq/scripts/time-loop.sh hq/scripts/time-claude.py \
         hq/scripts/time-slack.py hq/scripts/timesheet.py hq/scripts/time-approve.py; do
  if as_user test -x "${USER_HOME}/${f}"; then
    ok "є ${f}"
  else
    warn "немає або не виконуваний: ${f} — зроби git pull у ~/hq"
  fi
done
as_user test -d "${USER_HOME}/.claude-work" \
  && ok "робочий профіль ~/.claude-work на місці" \
  || warn "немає ~/.claude-work — спершу прожени 45-claude-sync.sh"

section "systemd: збір годин раз на день"
write_user_file ".config/systemd/user/timesheet-day.service" 0644 <<EOF
[Unit]
Description=Збір годин Liven за вчора і пуш на схвалення в Telegram
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=${USER_HOME}/.local/bin:${USER_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${USER_HOME}/hq/scripts/time-loop.sh
TimeoutStartSec=1200
EOF

# 09:00 — учорашній день закритий і синхнутий, оцінюєш на свіжу голову.
# Persistent=true: якщо Pi лежав, зібрати при першій нагоді (за той день,
# що на момент запуску буде «вчора»), інакше день просто зникне.
write_user_file ".config/systemd/user/timesheet-day.timer" 0644 <<'EOF'
[Unit]
Description=Збирати години Liven щоранку

[Timer]
OnCalendar=*-*-* 09:00
AccuracySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/systemd"

uctl() { as_user env XDG_RUNTIME_DIR="/run/user/${UID_N}" systemctl --user "$@"; }
if [ -d "/run/user/${UID_N}" ]; then
  uctl daemon-reload >/dev/null 2>&1 || true
  if uctl enable --now timesheet-day.timer >/dev/null 2>&1; then
    ok "таймер увімкнено: $(uctl list-timers timesheet-day.timer --no-pager 2>/dev/null | sed -n 2p | cut -c1-60)"
  else
    warn "таймер не увімкнувся — перевір: systemctl --user status timesheet-day.timer"
  fi
else
  warn "немає /run/user/${UID_N} — увімкни вручну після логіну користувача:"
  warn "  systemctl --user enable --now timesheet-day.timer"
fi

section "перевірка"
echo "  Сухий прогін без Telegram:"
echo "    ~/hq/scripts/time-loop.sh --day \$(date +%F) --dry-run"
echo "  Наступний запуск:"
echo "    systemctl --user list-timers timesheet-day.timer"
