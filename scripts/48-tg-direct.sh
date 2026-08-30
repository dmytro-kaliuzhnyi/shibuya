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
for f in tg-gateway.py tg-dispatch.py tg-worker.py hq_bus.py; do
  as_user test -e "${USER_HOME}/hq/scripts/${f}" \
    && ok "є hq/scripts/${f}" \
    || warn "немає hq/scripts/${f} — зроби git pull у ~/hq"
done

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

section "systemd: шлюз і диспетчер"
# Два юніти, а не один: шлюз — тупий транспорт, який не має змінюватись
# ніколи; диспетчер міститиме правила й змінюватиметься часто. Розділені,
# щоб перезапуск диспетчера не рвав довгий полінг і не губив оновлень.
write_user_file ".config/systemd/user/tg-gateway.service" 0644 <<EOF
[Unit]
Description=Шлюз Telegram: getUpdates -> шина, шина -> sendMessage
After=network-online.target

[Service]
Type=simple
Environment=PATH=${USER_HOME}/.local/bin:${USER_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${USER_HOME}/hq/scripts/tg-gateway.py
Restart=always
RestartSec=15
# Полінг довгий, тож даємо зупинці дожити цикл, а не рвемо на середині.
TimeoutStopSec=45

[Install]
WantedBy=default.target
EOF

write_user_file ".config/systemd/user/tg-dispatch.service" 0644 <<EOF
[Unit]
Description=Диспетчер шини HQ: вердикти, команди, задачі
After=tg-gateway.service

[Service]
Type=simple
Environment=PATH=${USER_HOME}/.local/bin:${USER_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${USER_HOME}/hq/scripts/tg-dispatch.py
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

write_user_file ".config/systemd/user/tg-worker.service" 0644 <<EOF
[Unit]
Description=Воркер шини HQ: розмова, запис у areas/, відповідь
After=tg-dispatch.service

[Service]
Type=simple
Environment=PATH=${USER_HOME}/.local/bin:${USER_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${USER_HOME}/hq/scripts/tg-worker.py
Restart=always
RestartSec=20
# Один прогін claude -p буває довгим; вбивати на середині — втратити відповідь.
TimeoutStopSec=650

[Install]
WantedBy=default.target
EOF

chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/systemd"
uctl() { as_user env XDG_RUNTIME_DIR="/run/user/${UID_N}" systemctl --user "$@"; }

if [ -d "/run/user/${UID_N}" ]; then
  uctl daemon-reload >/dev/null 2>&1 || true
  if [ "$HAVE_TOKEN" = 1 ]; then
    for u in tg-gateway tg-dispatch tg-worker; do
      if uctl enable --now "${u}.service" >/dev/null 2>&1; then
        # is-active віддає 3 для "activating", і під set -e це виглядає
        # як провал деплою, хоча юніт просто ще стартує.
        ok "${u}: $(uctl is-active "${u}.service" 2>/dev/null || true)"
      else
        warn "${u} не запустився — systemctl --user status ${u}.service"
      fi
    done
  else
    for u in tg-gateway tg-dispatch tg-worker; do
      uctl disable "${u}.service" >/dev/null 2>&1 || true
    done
    skip "юніти записано, але без токена не вмикаю"
  fi
else
  warn "немає /run/user/${UID_N} — увімкни вручну після логіну:"
  warn "  systemctl --user enable --now tg-gateway.service tg-dispatch.service tg-worker.service"
fi

section "перевірка"
echo "  ~/hq/scripts/tg-gateway.py --check         # бот, chat_id, стан черг"
echo "  ~/hq/scripts/tg-dispatch.py --dry-run      # які рішення, нічого не застосовуючи"
echo "  ~/hq/scripts/tg-worker.py --dry-run       # які задачі в черзі"
echo "  journalctl --user -u tg-gateway -u tg-dispatch -u tg-worker -f"
