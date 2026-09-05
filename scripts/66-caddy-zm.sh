#!/usr/bin/env bash
# Caddy: TLS on :443 for zm.ko1.me -> the ZenMoney MCP container on localhost.
#
# Run it deliberately:
#   sudo ~/shibuya/bootstrap.sh --only 66
#
# This is the alternative to the Cloudflare Tunnel in 65: the router forwards
# 443 -> this machine's 443, so the connector is reachable directly.
#
# The record is PROXIED (orange cloud), so Cloudflare terminates TLS for the
# visitor and holds the public certificate. Caddy is no longer a public HTTPS
# endpoint — it is Cloudflare's origin. Two consequences:
#
#   * No Let's Encrypt here. An ACME challenge can never reach this machine:
#     Cloudflare answers the handshake, not us. Asking for one just loops
#     every five minutes against the rate limits.
#   * Something still has to speak TLS on 443, because Cloudflare must reach
#     the origin over HTTPS (SSL/TLS mode Full). A self-signed certificate is
#     enough for Full; Full (strict) wants a Cloudflare Origin Certificate,
#     which this script picks up automatically if the files are in place.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

# The tunnel and this proxy are alternatives, not layers. When 65 has a tunnel
# token, cloudflared reaches the container on localhost by itself: nothing has
# to listen on 443, and leaving Caddy there would only hold the port and give
# the impression that the port forward still matters.
CF_ENV_FILE="${SHIBUYA_ETC}/cloudflared-zenmoney.env"
if [[ -s "$CF_ENV_FILE" ]] && grep -qE '^TUNNEL_TOKEN=.+' "$CF_ENV_FILE"; then
  section "not needed"
  log "a Cloudflare Tunnel is configured — Caddy is the alternative to it"
  if systemctl is-enabled --quiet caddy.service 2>/dev/null || systemctl is-active --quiet caddy.service 2>/dev/null; then
    systemctl disable --now caddy.service >/dev/null 2>&1 || true
    ok "caddy stopped and disabled; 443 is free again"
  else
    skip "caddy is already stopped"
  fi
  warn "the 443 port-forwarding rule on the router can be removed too"
  ok "66-caddy-zm done (skipped: tunnel in use)"
  exit 0
fi

DOMAIN="zm.ko1.me"
UPSTREAM="127.0.0.1:8080"
# Cloudflare Origin Certificate, if it was installed. Dashboard:
# SSL/TLS -> Origin Server -> Create Certificate. Valid for 15 years, and it
# is trusted by Cloudflare only — useless to anyone who reaches the box directly.
ORIGIN_CERT="${SHIBUYA_ETC}/origin-zm.pem"
ORIGIN_KEY="${SHIBUYA_ETC}/origin-zm.key"

section "caddy"
if have caddy; then
  skip "caddy already installed: $(caddy version 2>/dev/null | head -1)"
else
  add_apt_repo caddy \
    "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
    "https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main"
  apt_install caddy
fi

section "tls mode"
if [[ -s "$ORIGIN_CERT" && -s "$ORIGIN_KEY" ]]; then
  TLS_LINE="tls ${ORIGIN_CERT} ${ORIGIN_KEY}"
  ok "Cloudflare Origin Certificate found — set the zone to Full (strict)"
else
  # Caddy's own local CA. Cloudflare does not verify the origin certificate
  # in Full mode, so this is enough to get the connection encrypted.
  TLS_LINE="tls internal"
  warn "no Origin Certificate — falling back to a self-signed one"
  warn "    the zone MUST be set to Full (not Full strict, not Flexible)"
  warn "    to upgrade: put the cert into ${ORIGIN_CERT} and the key into ${ORIGIN_KEY}"
fi

section "configuration"
write_file /etc/caddy/Caddyfile 0644 <<EOF
# Managed by shibuya/scripts/66-caddy-zm.sh — edit there, not here.
{
	# Nothing else is served from this machine; an unknown Host gets no answer
	# rather than a default certificate that says what runs here.
	servers {
		strict_sni_host
	}
}

${DOMAIN} {
	${TLS_LINE}

	# The MCP server runs its own OAuth 2.1 provider, so authorization is its
	# job, not the proxy's. Caddy only terminates TLS and forwards.
	#
	# flush_interval -1 disables response buffering: MCP streamable HTTP keeps
	# the response open and sends events as they happen. Buffered, a long call
	# looks like a hang and then arrives all at once.
	reverse_proxy ${UPSTREAM} {
		flush_interval -1
	}
}
EOF
NEED_RESTART=0
if changed; then NEED_RESTART=1; fi

section "validation"
if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  ok "Caddyfile is valid"
else
  caddy validate --config /etc/caddy/Caddyfile 2>&1 | tail -5
  die "invalid Caddyfile"
fi

section "service"
enable_now caddy.service
if [[ $NEED_RESTART -eq 1 ]]; then
  if systemctl restart caddy.service; then
    ok "caddy restarted"
  else
    warn "caddy did not start — journalctl -u caddy -n 30"
  fi
fi

# ------------------------------------------------------------- checks ------
section "checks"

# Without the DNS record there is nothing for ACME to validate, and Caddy will
# keep retrying quietly. Better to say so here than to leave it in the journal.
RESOLVED="$( { getent ahostsv4 "$DOMAIN" || true; } 2>/dev/null | awk 'NR==1{print $1}')"
if [[ -z "$RESOLVED" ]]; then
  warn "${DOMAIN} does not resolve — no A record"
elif [[ "$RESOLVED" == 104.* || "$RESOLVED" == 172.6[4-9].* || "$RESOLVED" == 188.114.* || "$RESOLVED" == 162.159.* ]]; then
  ok "${DOMAIN} -> ${RESOLVED} (proxied through Cloudflare, as expected)"
else
  warn "${DOMAIN} -> ${RESOLVED} — that is not a Cloudflare address;"
  warn "    this config assumes the orange cloud is on"
fi

# The local answer proves Caddy and the container; it says nothing about
# whether Cloudflare can get in. That needs the port forward to work.
if curl -fsSk --max-time 5 -o /dev/null "https://${DOMAIN}/healthz" --resolve "${DOMAIN}:443:127.0.0.1" 2>/dev/null; then
  ok "locally: https://${DOMAIN}/healthz answers through Caddy"
else
  warn "locally https://${DOMAIN}/healthz does not answer — journalctl -u caddy -n 30"
fi

if { ss -ltn || true; } | grep -q ':443 '; then
  ok "something is listening on :443"
else
  warn "nothing is listening on :443 — journalctl -u caddy -n 50"
fi

if curl -fsS --max-time 5 -o /dev/null "http://${UPSTREAM}/healthz" 2>/dev/null; then
  ok "upstream ${UPSTREAM} answers"
else
  warn "upstream ${UPSTREAM} is silent — is zenmoney-mcp running? (--only 65)"
fi

echo
log "Cloudflare zone: SSL/TLS -> Overview -> Full  (Full strict with an Origin Certificate)"
log "from the outside:    curl -sSI https://${DOMAIN}/healthz"
log "a 403 with 'Server: Web server' means Cloudflare reached the ROUTER, not us"

ok "66-caddy-zm done"
