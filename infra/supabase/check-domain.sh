#!/bin/sh
#
# check-domain.sh — verifica o Supabase pelo dominio publico, de dentro da VPS (a internet real):
# DNS em resolvers publicos, certificado TLS, rotas da API por HTTPS, websocket do Realtime,
# basic-auth do Studio e se a Cloudflare esta na frente (proxy laranja) ou nao (DNS only).
#
# Roda num conteiner descartavel `docker:27-cli` com /srv/supabase/.env montado em /env (ro) e o
# socket do Docker (ro, so para ler os logs do Caddy). Nao imprime segredos: so codigos HTTP,
# cabecalhos relevantes e trechos de resposta. Uso: ops-check-domain.compose.yml.

set -u
HOST="${SUPABASE_HOST:?defina SUPABASE_HOST}"
VPS_IP="${VPS_IP:-179.199.136.203}"
ENV_FILE="${ENV_FILE:-/env}"
ZONE=$(printf '%s' "$HOST" | awk -F. '{n = NF; if ($(n-1) == "com" || $(n-1) == "net" || $(n-1) == "org") print $(n-2)"."$(n-1)"."$n; else print $(n-1)"."$n}')

val() { grep "^$1=" "$ENV_FILE" | cut -d= -f2-; }
PUB=$(val SUPABASE_PUBLISHABLE_KEY)
ANON=$(val ANON_KEY)

apk add --no-cache curl bind-tools >/dev/null 2>&1 || echo "(aviso: nao consegui instalar curl/bind-tools)"

echo "== DNS ($HOST) em resolvers publicos"
for r in 1.1.1.1 8.8.8.8; do
    printf '  @%-8s A: %s | AAAA: %s\n' "$r" \
        "$(dig +short A "$HOST" @"$r" | tr '\n' ' ')" \
        "$(dig +short AAAA "$HOST" @"$r" | tr '\n' ' ')"
done
echo "  NS da zona $ZONE: $(dig +short NS "$ZONE" @1.1.1.1 | tr '\n' ' ')"
echo "  A da raiz $ZONE: $(dig +short A "$ZONE" @1.1.1.1 | tr '\n' ' ')"
echo "  CAA da zona: $(dig +short CAA "$ZONE" @1.1.1.1 | tr '\n' ' ')"
echo "  IP da VPS: $VPS_IP"

echo
echo "== Caddy: eventos de certificado de $HOST (ultimas 3h)"
docker logs --since 3h caddy 2>&1 | grep -F "$HOST" \
    | sed -e 's/.*"msg":"\([^"]*\)".*"identifier":"\([^"]*\)".*"detail":"\([^"]*\)".*/  \1 [\2] \3/' \
          -e 's/.*"msg":"\([^"]*\)".*/  \1/' | tail -8
ls /srv/caddy/data/caddy/certificates/*/"$HOST"/ 2>/dev/null | sed 's/^/  arquivo: /' || true

# hit <rotulo> <url> [args curl...]: codigo HTTP + trecho
hit() {
    label=$1; url=$2; shift 2
    : > /tmp/body
    code=$(curl -sS -m 15 -o /tmp/body -w '%{http_code}' "$@" "$url" 2>/tmp/err) || true
    body=$(tr -d '\r\n' < /tmp/body | cut -c1-110)
    [ -s /tmp/err ] && body="$(tr -d '\r\n' < /tmp/err | cut -c1-110)"
    printf '  %-34s %s  %s\n' "$label" "$code" "$body"
}

for mode in dns direto; do
    echo
    if [ "$mode" = dns ]; then
        echo "== HTTPS pelo DNS publico (o caminho de qualquer usuario)"
        R=""
    else
        echo "== HTTPS direto no IP da VPS ($VPS_IP), ignorando o DNS"
        R="--resolve $HOST:443:$VPS_IP"
    fi
    # shellcheck disable=SC2086
    curl -sS -m 15 -v -o /dev/null $R "https://$HOST/auth/v1/health" -H "apikey: $PUB" 2>&1 \
        | grep -E 'subject:|issuer:|expire date:|SSL certificate|server: |cf-ray|HTTP/[0-9.]+ [0-9]+|Could not|failed|error' \
        | sed 's/^[*<>] */  /' | head -10
    # shellcheck disable=SC2086
    hit "auth/v1/health" "https://$HOST/auth/v1/health" $R -H "apikey: $PUB"
    # shellcheck disable=SC2086
    hit "auth/v1/settings" "https://$HOST/auth/v1/settings" $R -H "apikey: $PUB"
    # shellcheck disable=SC2086
    hit "rest/v1/ (raiz; 403 esperado)" "https://$HOST/rest/v1/" $R -H "apikey: $PUB"
    # shellcheck disable=SC2086
    hit "storage/v1/version" "https://$HOST/storage/v1/version" $R -H "apikey: $PUB"
    # shellcheck disable=SC2086
    hit "storage/v1/bucket" "https://$HOST/storage/v1/bucket" $R -H "apikey: $PUB" -H "Authorization: Bearer $ANON"
    # shellcheck disable=SC2086
    hit "functions/v1/hello" "https://$HOST/functions/v1/hello" $R -H "apikey: $PUB"
    # shellcheck disable=SC2086
    hit "studio / sem senha (401)" "https://$HOST/" $R
    # shellcheck disable=SC2086
    hit "studio / com senha (200/307)" "https://$HOST/" $R -u "$(val DASHBOARD_USERNAME):$(val DASHBOARD_PASSWORD)"
    # shellcheck disable=SC2086
    ws=$(curl -sS -m 6 -i --http1.1 $R \
        -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        "https://$HOST/realtime/v1/websocket?apikey=$PUB&vsn=1.0.0" 2>&1 | grep -m1 -E '^HTTP/' | tr -d '\r')
    printf '  %-34s %s\n' "realtime websocket (101)" "${ws:-sem resposta}"
    printf '  %-34s %s\n' "http:// -> https:// (308)" \
        "$(curl -sS -m 10 -o /dev/null -w '%{http_code} -> %{redirect_url}' $(echo "$R" | sed 's/:443:/:80:/') "http://$HOST/" 2>&1)"
done

echo
echo "DONE"
