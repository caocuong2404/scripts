#!/bin/bash
# ============================================================
#  MIMO OpenClaw Proxy Quick Setup
#
#  TEMP URL (default):
#    curl -sL .../mimo-oc-setup.sh | ssh -p PORT root@HOST 'bash -s'
#
#  PERMANENT DOMAIN (ai-public.cuong.day):
#    curl -sL .../mimo-oc-setup.sh | ssh -p PORT root@HOST 'bash -s -- --mode domain'
#
#  PERMANENT + TOKEN inline (no prompt):
#    curl -sL .../mimo-oc-setup.sh | ssh -p PORT root@HOST \
#      'CF_TOKEN=eyJhI... bash -s -- --mode domain'
#
#  Get CF_TOKEN from: Cloudflare Zero Trust → Tunnels → Create Tunnel
#    → copy the token from the install command
# ============================================================
set -e

PROXY_PORT=8899
TARGET="https://api-sgp-oc.xiaomimimo.com"
MODE="temp"

# ── Parse args ─────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --mode) MODE="$2"; shift 2 ;;
    --token) CF_TOKEN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── 1. Get fresh MIMO key from live process ────────────────
PID=$(pgrep -f openclaw-gateway 2>/dev/null | head -1)
if [ -n "$PID" ]; then
  MIMO_KEY=$(cat /proc/$PID/environ 2>/dev/null | tr '\0' '\n' | grep '^MIMO_API_KEY=' | cut -d= -f2-)
fi
MIMO_KEY="${MIMO_KEY:-oc_slyc79d0ibj2mgsgumldiyoskdlzwkj2vl9oapf64i44qay7}"

# ── 2. Kill stale processes ────────────────────────────────
pkill -f mimo_proxy 2>/dev/null || true
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1

# ── 3. Setup nginx proxy (high traffic: 50k+ concurrent, SSE streaming) ────
apt-get install -y -qq nginx > /dev/null 2>&1 || true

if command -v nginx &>/dev/null; then
  cat > /etc/nginx/sites-enabled/default << EOF
server {
    listen $PROXY_PORT default_server;
    add_header Access-Control-Allow-Origin  "*" always;
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Content-Type, Authorization, api-key, x-api-key, anthropic-version" always;
    location / {
        if (\$request_method = OPTIONS) { return 204; }
        proxy_pass            https://api-sgp-oc.xiaomimimo.com;
        proxy_ssl_server_name on;
        proxy_ssl_name        api-sgp-oc.xiaomimimo.com;
        proxy_set_header      Host api-sgp-oc.xiaomimimo.com;
        proxy_buffering       off;
        proxy_cache           off;
        proxy_read_timeout    120s;
        proxy_send_timeout    120s;
        chunked_transfer_encoding on;
        proxy_pass_request_headers on;
    }
}
EOF
  rm -f /etc/nginx/sites-enabled/default.dpkg-dist 2>/dev/null || true
  nginx -t > /dev/null 2>&1 && (nginx -s reload 2>/dev/null || nginx 2>/dev/null) || true
  sleep 1
  echo "   nginx: $(curl -s -o /dev/null -w '%{http_code}' http://localhost:$PROXY_PORT/ 2>/dev/null)"
else
  # Fallback: Python proxy
  cat > /tmp/mimo_proxy.py << 'PYEOF'
import http.server, urllib.request, urllib.error, ssl, sys, os
from socketserver import ThreadingMixIn
TARGET = os.environ.get("MIMO_TARGET","https://api-sgp-oc.xiaomimimo.com")
CTX = ssl.create_default_context()
CORS = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Methods":"GET,POST,OPTIONS","Access-Control-Allow-Headers":"Content-Type,Authorization,api-key,x-api-key"}
class P(http.server.BaseHTTPRequestHandler):
    def log_message(self,f,*a): print(f"[{self.address_string()}] {f%a}",flush=True)
    def do_OPTIONS(self):
        self.send_response(204)
        [self.send_header(k,v) for k,v in CORS.items()]; self.end_headers()
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","application/json")
        [self.send_header(k,v) for k,v in CORS.items()]; self.end_headers()
        self.wfile.write(b'{"status":"ok","proxy":"mimo-oc"}')
    def do_POST(self):
        n=int(self.headers.get("Content-Length",0)); body=self.rfile.read(n)
        req=urllib.request.Request(TARGET+self.path,data=body,method="POST")
        [req.add_header(k,v) for k,v in self.headers.items() if k.lower() not in {"host","content-length","transfer-encoding"}]
        try:
            with urllib.request.urlopen(req,context=CTX,timeout=120) as r:
                self.send_response(r.status)
                [self.send_header(k,v) for k,v in r.headers.items() if k.lower() not in {"transfer-encoding","connection"}]
                [self.send_header(k,v) for k,v in CORS.items()]; self.end_headers()
                while True:
                    c=r.read(1024)
                    if not c: break
                    self.wfile.write(c); self.wfile.flush()
        except urllib.error.HTTPError as e:
            b=e.read(); self.send_response(e.code); self.end_headers(); self.wfile.write(b)
class T(ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
T(("0.0.0.0",int(sys.argv[1])),P).serve_forever()
PYEOF
  nohup python3 /tmp/mimo_proxy.py $PROXY_PORT > /tmp/mimo_proxy.log 2>&1 &
  sleep 1
  echo "   python proxy: $(curl -s http://localhost:$PROXY_PORT/ 2>/dev/null | head -c 30)"
fi

# ── 4. Install cloudflared if missing ─────────────────────
if ! command -v cloudflared &>/dev/null; then
  echo "Installing cloudflared..."
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
fi

# ── 5. Start tunnel ────────────────────────────────────────
if [ "$MODE" = "domain" ]; then

  # Get CF_API_TOKEN
  if [ -z "$CF_API_TOKEN" ]; then
    echo ""
    echo "  Cloudflare API token needed (one-time)."
    echo "  Create at: dash.cloudflare.com/profile/api-tokens"
    echo "  Permissions: Account/Cloudflare Tunnel:Edit + Zone/DNS:Edit"
    echo -n "  CF_API_TOKEN: "
    read -r CF_API_TOKEN < /dev/tty
  fi

  DOMAIN="ai-public.cuong.day"
  TUNNEL_NAME="ai-public"

  echo "  [CF] Fetching account + zone..."
  CF_ACCOUNT=$(curl -sf "https://api.cloudflare.com/client/v4/accounts" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])")

  CF_ZONE=$(curl -sf "https://api.cloudflare.com/client/v4/zones?name=cuong.day" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])")

  echo "  [CF] Account: $CF_ACCOUNT | Zone: $CF_ZONE"

  # Create or reuse tunnel
  EXISTING=$(curl -sf "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(r[0]['id'] if r else '')" 2>/dev/null)

  if [ -n "$EXISTING" ]; then
    TUNNEL_ID="$EXISTING"
    echo "  [CF] Reusing tunnel: $TUNNEL_ID"
  else
    echo "  [CF] Creating tunnel: $TUNNEL_NAME..."
    TUNNEL_ID=$(curl -sf -X POST \
      "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/cfd_tunnel" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"$TUNNEL_NAME\",\"config_src\":\"cloudflare\"}" \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['id'])")
    echo "  [CF] Created: $TUNNEL_ID"
  fi

  # Configure ingress
  echo "  [CF] Setting ingress → http://localhost:$PROXY_PORT..."
  curl -sf -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/cfd_tunnel/$TUNNEL_ID/configurations" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"config\":{\"ingress\":[{\"hostname\":\"$DOMAIN\",\"service\":\"http://localhost:$PROXY_PORT\"},{\"service\":\"http_status:404\"}]}}" > /dev/null

  # Upsert DNS CNAME
  echo "  [CF] Upserting DNS: $DOMAIN → $TUNNEL_ID.cfargotunnel.com..."
  DNS_ID=$(curl -sf "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?name=$DOMAIN" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(r[0]['id'] if r else '')" 2>/dev/null)

  DNS_PAYLOAD="{\"type\":\"CNAME\",\"name\":\"$DOMAIN\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}"
  if [ -n "$DNS_ID" ]; then
    curl -sf -X PATCH \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records/$DNS_ID" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$DNS_PAYLOAD" > /dev/null
    echo "  [CF] DNS updated ✅"
  else
    curl -sf -X POST \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$DNS_PAYLOAD" > /dev/null
    echo "  [CF] DNS created ✅"
  fi

  # Get tunnel token and run
  echo "  [CF] Starting tunnel..."
  CF_TOKEN=$(curl -sf \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/cfd_tunnel/$TUNNEL_ID/token" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['result'])")

  nohup cloudflared tunnel run --token "$CF_TOKEN" --no-autoupdate \
    > /tmp/cf_tunnel.log 2>&1 &
  sleep 5
  URL="https://$DOMAIN"

else
  # Temp: random trycloudflare.com URL
  nohup cloudflared tunnel --url http://localhost:$PROXY_PORT --no-autoupdate \
    > /tmp/cf_tunnel.log 2>&1 &
  for i in $(seq 1 15); do
    URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf_tunnel.log 2>/dev/null | head -1)
    [ -n "$URL" ] && break
    sleep 1
  done
fi

# ── 6. Output ──────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "  ✅  MIMO PROXY READY"
echo "╠══════════════════════════════════════════════════════╣"
echo "  URL  : $URL"
echo "  KEY  : $MIMO_KEY"
echo "╠══════════════════════════════════════════════════════╣"
echo "  curl -X POST $URL/v1/chat/completions \\"
echo "    -H 'api-key: $MIMO_KEY' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"mimo-v2.5-pro\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":20}'"
echo "╚══════════════════════════════════════════════════════╝"
