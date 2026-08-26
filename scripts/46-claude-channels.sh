#!/usr/bin/env bash
# Claude Code Channels: Bun + постійна сесія для життєвого асистента (~/hq).
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"

# Channels — це MCP-сервери, які пушать події у ВЖЕ ЗАПУЩЕНУ сесію Claude Code.
# Звідси два наслідки:
#   1) події приходять лише поки сесія жива → потрібен постійний tmux
#   2) плагіни каналів — це Bun-скрипти, тож Bun обов'язковий
#
# Асистент запускається під ОСОБИСТИМ профілем (~/.claude, Pro).
# Робочий (Team) для каналів не годиться: там вони заблоковані, поки власник
# організації не увімкне channelsEnabled.

# ----------------------------------------------------------------- bun ----
section "Bun"
if as_user test -x "${USER_HOME}/.local/bin/bun" || as_user test -x "${USER_HOME}/.bun/bin/bun"; then
  skip "bun вже стоїть: $(as_user bash -lc 'bun --version' 2>/dev/null || echo '?')"
else
  if as_user npm install -g bun >/dev/null 2>&1; then
    ok "bun встановлено через npm: $(as_user bash -lc 'bun --version' 2>/dev/null || echo '?')"
  else
    warn "npm не впорався, пробую офіційний інсталятор"
    as_user bash -lc 'curl -fsSL https://bun.sh/install | bash' >/dev/null 2>&1 \
      && ok "bun встановлено в ~/.bun" \
      || die "bun не встановився — без нього канали не запустяться"
  fi
fi

# PATH для ~/.bun/bin, якщо ставили офіційним інсталятором
if as_user test -d "${USER_HOME}/.bun/bin"; then
  as_user touch "${USER_HOME}/.profile"
  ensure_line "${USER_HOME}/.profile" 'export PATH="$HOME/.bun/bin:$PATH"'
fi

# ------------------------------------------------------- каталог каналів ---
section "каталог каналів"
as_user mkdir -p "${USER_HOME}/.claude/channels/telegram"
as_user chmod 700 "${USER_HOME}/.claude/channels"
ok "${USER_HOME}/.claude/channels/ готовий (сюди /telegram:configure покладе .env з токеном)"

# ------------------------------------------------------------ запускач ----
# Окремий скрипт, щоб сесію можна було перезапустити однією командою
# і щоб systemd-юніт не тягнув довгий рядок аргументів.
section "запускач асистента"
write_user_file "bin/hq-assistant.sh" 0755 <<'LAUNCH'
#!/usr/bin/env bash
# Постійна сесія життєвого асистента з увімкненим Telegram-каналом.
# Запуск:   ~/bin/hq-assistant.sh
# Підчепитись: tmux attach -t hq
set -euo pipefail

HQ="${HQ_DIR:-$HOME/hq}"
SESSION="hq"
CHANNEL="plugin:telegram@claude-plugins-official"

# Під systemd оточення мінімальне: ні ~/.local/bin, ні ~/.bun/bin у PATH.
# Через інтерактивний shell це не видно — там PATH повний, і скрипт
# «працює». Тому задаємо явно, а не покладаємось на того, хто нас запустив.
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
[ -x "$CLAUDE" ] || { echo "не знайшов claude (шукав у $HOME/.local/bin)"; exit 1; }

[ -d "$HQ" ] || { echo "немає $HQ — спершу клонуй життєвий репозиторій"; exit 1; }

# Особистий профіль. CLAUDE_CONFIG_DIR не виставляти:
# у Claude Code дефолт — це відсутність змінної, а не $HOME/.claude.
unset CLAUDE_CONFIG_DIR

channel_up() { pgrep -f "telegram/.*server.ts" >/dev/null 2>&1 \
                || pgrep -f "bun.*--silent start" >/dev/null 2>&1; }

if tmux has-session -t "$SESSION" 2>/dev/null; then
  if channel_up; then
    echo "сесія '$SESSION' жива, канал полить Telegram"
    exit 0
  fi
  # Сесія є, каналу немає — це зламаний стан: бот мовчатиме, а зовні
  # все виглядає працюючим. Краще перезапустити, ніж лишити німим.
  echo "сесія '$SESSION' жива, але канал не працює — перезапускаю"
  tmux kill-session -t "$SESSION" 2>/dev/null
  sleep 2
fi

cd "$HQ"
git pull --rebase --autostash --quiet 2>/dev/null || true

# Абсолютний шлях і явний PATH усередині сесії: tmux запускає команду
# через `zsh -c`, а той PATH з ~/.local/bin не успадковує.
tmux new-session -d -s "$SESSION" -c "$HQ" \
  "export PATH='$PATH'; '$CLAUDE' --channels $CHANNEL; exec bash -l"
echo "сесію '$SESSION' піднято в $HQ з каналом $CHANNEL"

printf "чекаю на канальний сервер"
for i in $(seq 1 15); do
  if channel_up; then
    echo " — ✔ полить Telegram"
    exit 0
  fi
  printf "."; sleep 2
done

echo " — ✘ НЕ ПІДНЯВСЯ"
echo "Канал зареєстровано, але MCP-сервер плагіна не стартував: бот мовчатиме."
echo "Полагодити зсередини сесії:  /mcp → plugin:telegram:telegram → Reconnect"
echo "Перемкнутись у сесію:        tmux switch-client -t $SESSION"
exit 1
LAUNCH
ok "~/bin/hq-assistant.sh"

# ------------------------------------------------------------- перевірка ---
section "systemd: тримати сесію живою"
# Сесія вмирає, якщо зайняти її вікно чимось іншим (реальний випадок: nano
# у тому ж вікні). Таймер щоп'ять хвилин запускає ідемпотентний запускач:
# жива й здорова — нічого не робить, впала або без каналу — піднімає.
write_user_file ".config/systemd/user/hq-assistant.service" 0644 <<EOF
[Unit]
Description=Життєвий асистент: сесія Claude Code з Telegram-каналом
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=${USER_HOME}/.local/bin:${USER_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${USER_HOME}/bin/hq-assistant.sh
# exit 1 = канал не піднявся. Не тягнемо це в "failed" юніта:
# наступний тік таймера спробує знову.
SuccessExitStatus=0 1
EOF

write_user_file ".config/systemd/user/hq-assistant.timer" 0644 <<'EOF'
[Unit]
Description=Перевіряти сесію асистента кожні 5 хвилин

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

# write_file створює батьківські каталоги через install -D від root,
# тому ~/.config/systemd/ лишається root:root і systemd не може покласти
# туди symlink у timers.target.wants. Повертаємо власника.
chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/systemd"

# Без linger user-юніти вмирають разом із SSH-сесією — тобто рівно тоді,
# коли вони найпотрібніші.
if loginctl show-user "$USER_NAME" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
  skip "linger уже увімкнено"
else
  loginctl enable-linger "$USER_NAME" && ok "linger увімкнено для $USER_NAME"
fi

# systemctl --user через sudo -u не працює без шини користувача:
# потрібен XDG_RUNTIME_DIR, інакше "Failed to connect to bus".
UID_N="$(id -u "$USER_NAME")"
uctl() { as_user env XDG_RUNTIME_DIR="/run/user/${UID_N}" systemctl --user "$@"; }

if [ ! -d "/run/user/${UID_N}" ]; then
  warn "немає /run/user/${UID_N} — увімкни linger і перезапусти цей крок"
else
  uctl daemon-reload || warn "daemon-reload не пройшов"
  if uctl enable --now hq-assistant.timer >/dev/null 2>&1; then
    ok "таймер увімкнено: $(uctl list-timers hq-assistant.timer --no-pager 2>/dev/null | sed -n 2p | cut -c1-60)"
  else
    warn "таймер не увімкнувся — перевір: systemctl --user status hq-assistant.timer"
  fi
fi

section "підсумок"
as_user bash -lc 'command -v bun >/dev/null' \
  && ok "bun у PATH" \
  || warn "bun не в PATH — перелогінься або додай ~/.bun/bin вручну"

cat <<'NEXT'

  Далі — кроки, які скрипт зробити не може, бо вони інтерактивні
  і потребують твого акаунта:

    1. Клонувати життєвий репозиторій:
         git clone <remote> ~/hq

    2. У Telegram: @BotFather → /newbot → скопіювати токен

    3. На Pi, у сесії Claude Code (особистий профіль):
         /plugin marketplace add anthropics/claude-plugins-official
         /plugin install telegram@claude-plugins-official     (обрати user scope)
         /reload-plugins                                      (якщо попросить)
         /telegram:configure <токен>

    4. Підняти постійну сесію:
         ~/bin/hq-assistant.sh

    5. Написати боту будь-що → він відповість кодом → у сесії:
         /telegram:access pair <код>
         /telegram:access policy allowlist

  Останній крок обов'язковий: без allowlist боту зможе писати будь-хто,
  хто знає його ім'я.

NEXT
