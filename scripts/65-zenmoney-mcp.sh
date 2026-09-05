#!/usr/bin/env bash
# ZenMoney MCP as a Claude custom connector: container on localhost + Cloudflare Tunnel.
#
# Not part of phase A — run it deliberately:
#   sudo ~/shibuya/bootstrap.sh --only 65
#
# The container listens on 127.0.0.1 ONLY. The single way in is the tunnel,
# so the port is never exposed to the LAN or to the tailnet.
# Claude reaches https://zm.ko1.me/mcp; the server runs its own OAuth 2.1
# provider (DCR + PKCE + a password consent gate), so a stray URL is not enough.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

# Pinned by digest, not by :latest — otherwise a redeploy silently swaps the
# code that holds a ZenMoney token. Update deliberately: read the diff, then
# change the digest here.
IMAGE_REPO="ghcr.io/abrekhov/zenmoney-mcp"
IMAGE_DIGEST="sha256:4749b8b145028184b042451580ea2fe2d1851a58e258211ab45317ccbdbca18d"
IMAGE="${IMAGE_REPO}@${IMAGE_DIGEST}"

BASE_URL="https://zm.ko1.me"
# The .ru API host does not answer from Ukraine — TCP 443 to 95.213.236.52 just
# times out, from the Pi and from the laptop alike. api.zenmoney.app is the same
# API (same /v8/diff/, same auth) on a reachable host. Without this the server
# starts, passes /healthz, and fails on the first real call.
API_BASE="https://api.zenmoney.app"
PORT=8080
ENV_FILE="${SHIBUYA_ETC}/zenmoney-mcp.env"
CF_ENV_FILE="${SHIBUYA_ETC}/cloudflared-zenmoney.env"

have docker || die "docker is missing — run --only 60 first"

# ------------------------------------------------------------- secrets -----
# Secrets never live in the repo (deploy.sh excludes secrets/ from the rsync),
# so the template is created here and filled in by hand, once.
section "secrets"
if [[ -s "$ENV_FILE" ]]; then
  skip "already there: ${ENV_FILE}"
else
  # The signing key is machine-generated, not human — no reason to ask for it.
  SIGNING_KEY="$(openssl rand -hex 32)"
  OAUTH_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  write_file "$ENV_FILE" 0600 <<EOF
# ZenMoney MCP. Fill in ZENMONEY_TOKEN, then: systemctl restart zenmoney-mcp
# Token: https://zerro.app/token
ZENMONEY_TOKEN=
# api.zenmoney.ru is unreachable from here (see the migration block below).
ZENMONEY_API_BASE_URL=${API_BASE}
MCP_TRANSPORT=http
HTTP_ADDR=:${PORT}
MCP_BASE_URL=${BASE_URL}
MCP_OAUTH_PASSWORD=${OAUTH_PASSWORD}
MCP_SIGNING_KEY=${SIGNING_KEY}
EOF
  warn "consent password generated — it is asked once per authorization:"
  warn "    ${OAUTH_PASSWORD}"
fi

# An env file written before the .ru block was discovered has no API base.
if grep -qE '^ZENMONEY_API_BASE_URL=' "$ENV_FILE"; then
  skip "ZENMONEY_API_BASE_URL is set"
else
  printf 'ZENMONEY_API_BASE_URL=%s\n' "$API_BASE" >> "$ENV_FILE"
  ok "added ZENMONEY_API_BASE_URL=${API_BASE}"
fi

if grep -qE '^ZENMONEY_TOKEN=.+' "$ENV_FILE"; then
  HAVE_TOKEN=1
  ok "ZENMONEY_TOKEN is set"
else
  HAVE_TOKEN=0
  warn "ZENMONEY_TOKEN is empty — the service will not start"
  warn "    1. take a token at https://zerro.app/token"
  warn "    2. put it into ${ENV_FILE}"
  warn "    3. systemctl restart zenmoney-mcp"
fi

if [[ -s "$CF_ENV_FILE" ]]; then
  skip "already there: ${CF_ENV_FILE}"
else
  write_file "$CF_ENV_FILE" 0600 <<'EOF'
# Cloudflare Tunnel, remotely-managed. Token from the Zero Trust dashboard:
# Networks -> Tunnels -> Create a tunnel -> Cloudflared -> copy the token.
# Public hostname: zm.ko1.me -> HTTP -> localhost:8080
TUNNEL_TOKEN=
EOF
  warn "put the tunnel token into ${CF_ENV_FILE}"
fi
grep -qE '^TUNNEL_TOKEN=.+' "$CF_ENV_FILE" && HAVE_CF=1 || HAVE_CF=0

# --------------------------------------------------------------- image -----
section "image"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  skip "image already pulled: ${IMAGE_DIGEST:0:19}…"
else
  log "docker pull ${IMAGE_REPO} (${IMAGE_DIGEST:0:19}…)"
  docker pull "$IMAGE"
  ok "image pulled"
fi

# ------------------------------------------------------------- service -----
section "systemd: zenmoney-mcp"
# --rm plus ExecStartPre stop/rm: the container is disposable, all the state
# that matters is the env file and the OAuth tokens inside the process.
# Restarting means re-authorizing in Claude, which is the intended trade —
# there is nothing on disk to steal.
write_file /etc/systemd/system/zenmoney-mcp.service 0644 <<EOF
[Unit]
Description=ZenMoney MCP server (Claude custom connector)
After=docker.service network-online.target
Requires=docker.service

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker stop zenmoney-mcp
ExecStartPre=-/usr/bin/docker rm zenmoney-mcp
ExecStart=/usr/bin/docker run --rm --name zenmoney-mcp \\
  --env-file ${ENV_FILE} \\
  -p 127.0.0.1:${PORT}:${PORT} \\
  --memory 256m --pids-limit 128 \\
  --read-only --tmpfs /tmp \\
  --cap-drop ALL --security-opt no-new-privileges \\
  ${IMAGE}
ExecStop=/usr/bin/docker stop zenmoney-mcp

[Install]
WantedBy=multi-user.target
EOF
NEED_RELOAD=0
if changed; then NEED_RELOAD=1; fi

section "systemd: cloudflared"
if have cloudflared; then
  skip "cloudflared already installed: $(cloudflared --version 2>/dev/null | head -1)"
else
  add_apt_repo cloudflare \
    "https://pkg.cloudflare.com/cloudflare-main.gpg" \
    "https://pkg.cloudflare.com/cloudflared $(. /etc/os-release && echo "$VERSION_CODENAME") main"
  apt_install cloudflared
fi

# Our own unit rather than `cloudflared service install`: that command writes
# the token into a config on disk outside the repo, and then the deploy is no
# longer the source of truth for what runs here.
write_file /etc/systemd/system/cloudflared-zenmoney.service 0644 <<EOF
[Unit]
Description=Cloudflare Tunnel for zm.ko1.me
After=network-online.target zenmoney-mcp.service
Wants=network-online.target

[Service]
Restart=always
RestartSec=10
EnvironmentFile=${CF_ENV_FILE}
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token \${TUNNEL_TOKEN}
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
if changed; then NEED_RELOAD=1; fi

if [[ $NEED_RELOAD -eq 1 ]]; then
  systemd_reload_if_needed
fi

# --------------------------------------------------------------- start -----
section "start"
if [[ $HAVE_TOKEN -eq 1 ]]; then
  systemctl enable zenmoney-mcp.service >/dev/null 2>&1 || true
  systemctl restart zenmoney-mcp.service
  # The container needs a moment before /healthz answers; three tries is plenty.
  for i in 1 2 3; do
    sleep 2
    if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
      ok "zenmoney-mcp answers on /healthz"
      break
    fi
    if [[ $i -eq 3 ]]; then
      warn "no answer on /healthz — journalctl -u zenmoney-mcp -n 50"
    fi
  done
else
  systemctl disable zenmoney-mcp.service >/dev/null 2>&1 || true
  skip "zenmoney-mcp not started: no token"
fi

if [[ $HAVE_CF -eq 1 ]]; then
  systemctl enable cloudflared-zenmoney.service >/dev/null 2>&1 || true
  systemctl restart cloudflared-zenmoney.service
  ok "cloudflared-zenmoney started"
else
  systemctl disable cloudflared-zenmoney.service >/dev/null 2>&1 || true
  skip "cloudflared not started: no tunnel token"
fi

echo
if [[ $HAVE_TOKEN -eq 1 && $HAVE_CF -eq 1 ]]; then
  log "Claude: Settings -> Connectors -> Add custom connector -> ${BASE_URL}/mcp"
  log "The consent page will ask for MCP_OAUTH_PASSWORD from ${ENV_FILE}"
else
  warn "fill in the secrets and re-run: sudo ~/shibuya/bootstrap.sh --only 65"
fi

ok "65-zenmoney-mcp done"
