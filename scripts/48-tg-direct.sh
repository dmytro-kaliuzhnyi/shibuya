#!/usr/bin/env bash
# Прямий канал HQ ⇄ Telegram: демон полінгу без MCP і без живої сесії.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"
UID_N="$(id -u "$USER_NAME")"
TOKEN="${USER_HOME}/.config/hq-telegram/token"

# Навіщо окремо від плагіна каналу: схвалення чернеток і підтвердження годин —
# це детерміновані вердикти, для них модель не потрібна взагалі. Прив'язувати
# їх до постійної сесії Claude Code означає, що падіння сесії зупиняє облік.
# Демон робить їх сам; сесія лишається тільки для вільної розмови.
#
# Telegram віддає getUpdates ОДНОМУ споживачу. Плагін полінгує сам, тому демону
# потрібен ВЛАСНИЙ бот — інакше вони крадуть повідомлення один в одного.

section "передумови"
as_user test -x "${USER_HOME}/hq/scripts/tg-poll.py" \
  && ok "є hq/scripts/tg-poll.py" \
  || { warn "немає hq/scripts/tg-poll.py — зроби git pull у ~/hq"; }

HAVE_TOKEN=0
if as_user test -s "$TOKEN"; then
  HAVE_TOKEN=1
  as_user chmod 600 "$TOKEN" 2>/dev/null || true
  ok "токен другого бота на місці"
else
  warn "немає ${TOKEN}"
  warn "  1. @BotFather → /newbot → отримати токен"
  warn "  2. mkdir -p ~/.config/hq-telegram && chmod 700 ~/.config/hq-telegram"
  warn "  3. покласти токен у ~/.config/hq-telegram/token && chmod 600"
  warn "  4. написати новому боту будь-що з того ж чату, потім прожени цей крок ще раз"
  warn "  Юніт поставлю, але вмикати не буду."
fi

section "systemd: демон полінгу"
write_user_file ".config/systemd/user/tg-direct.service" 0644 <<EOF
[Unit]
Description=Прямий канал HQ - Telegram (полінг, без MCP)
After=network-online.target

[Service]
Type=simple
Environment=PATH=${USER_HOME}/.local/bin:${USER_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${USER_HOME}/hq/scripts/tg-poll.py
Restart=always
RestartSec=15
# Полінг довгий (50 с), тому зупинку даємо пережити спокійно.
TimeoutStopSec=70

[Install]
WantedBy=default.target
EOF

chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/systemd"
uctl() { as_user env XDG_RUNTIME_DIR="/run/user/${UID_N}" systemctl --user "$@"; }

if [ -d "/run/user/${UID_N}" ]; then
  uctl daemon-reload >/dev/null 2>&1 || true
  if [ "$HAVE_TOKEN" = 1 ]; then
    if uctl enable --now tg-direct.service >/dev/null 2>&1; then
      ok "демон запущено: $(uctl is-active tg-direct.service)"
    else
      warn "не запустився — systemctl --user status tg-direct.service"
    fi
  else
    uctl disable tg-direct.service >/dev/null 2>&1 || true
    skip "юніт записано, але без токена не вмикаю"
  fi
else
  warn "немає /run/user/${UID_N} — увімкни вручну після логіну:"
  warn "  systemctl --user enable --now tg-direct.service"
fi

section "перевірка"
echo "  ~/hq/scripts/tg-poll.py --check      # бот, chat_id, чи живий плагін"
echo "  ~/hq/scripts/tg-poll.py --once       # один цикл вручну"
echo "  journalctl --user -u tg-direct -f    # що приходить"
