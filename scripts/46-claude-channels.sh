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

[ -d "$HQ" ] || { echo "немає $HQ — спершу клонуй життєвий репозиторій"; exit 1; }

# Особистий профіль. CLAUDE_CONFIG_DIR не виставляти:
# у Claude Code дефолт — це відсутність змінної, а не $HOME/.claude.
unset CLAUDE_CONFIG_DIR

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "сесія '$SESSION' вже жива. Підчепитись: tmux attach -t $SESSION"
  exit 0
fi

cd "$HQ"
git pull --rebase --autostash --quiet 2>/dev/null || true

tmux new-session -d -s "$SESSION" -c "$HQ" \
  "claude --channels $CHANNEL; exec bash -l"
echo "сесію '$SESSION' піднято в $HQ з каналом $CHANNEL"

# Канальний MCP-сервер часом не піднімається на старті (research preview).
# Лікується Reconnect у /mcp, але про це треба знати — тому перевіряємо самі.
printf "чекаю на канальний сервер"
for i in $(seq 1 15); do
  if pgrep -f "telegram/.*server.ts" >/dev/null 2>&1 || pgrep -f "bun.*--silent start" >/dev/null 2>&1; then
    echo " — ✔ полить Telegram"
    echo "підчепитись: tmux attach -t $SESSION   (зсередини tmux: Ctrl-a s)"
    exit 0
  fi
  printf "."; sleep 2
done

cat <<'WARN'
 — ✘ НЕ ПІДНЯВСЯ

Канал зареєстровано, але MCP-сервер плагіна не стартував: бот мовчатиме.
Полагодити всередині сесії:

    tmux attach -t hq        (зсередини tmux: Ctrl-a s, обрати hq)
    /mcp  →  plugin:telegram:telegram  →  Reconnect

Перевірити ззовні:  pgrep -af "server.ts"
WARN
exit 1
LAUNCH
ok "~/bin/hq-assistant.sh"

# ------------------------------------------------------------- перевірка ---
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
