#!/bin/sh
#
# check-vps.sh — verificacao pos-instalacao do Supabase na VPS, pela rede `web` (o mesmo caminho
# que o Caddy usa). Roda num conteiner descartavel `docker:27-cli` com /srv/supabase/.env montado
# em /env (somente leitura). Nao imprime segredos: so codigos HTTP e trechos de resposta.
#
# Uso pelo Docker Manager da Hostinger: ver ops-check.compose.yml. Na VPS:
#   docker run --rm --network web -v /srv/supabase/.env:/env:ro docker:27-cli sh -c \
#     "wget -qO- $BASE_URL/check-vps.sh | sh"

set -u
ENV_FILE="${ENV_FILE:-/env}"
GW="${GW:-http://supabase-api:8000}"
HOST="${SUPABASE_HOST:-supabase.doctorbusiness.net.br}"

val() { grep "^$1=" "$ENV_FILE" | cut -d= -f2-; }
ANON=$(val ANON_KEY)
PUB=$(val SUPABASE_PUBLISHABLE_KEY)

# req <rotulo> <chave> <caminho>: imprime o codigo HTTP e os primeiros bytes do corpo
req() {
    out=$(wget -q -S -O - --header "apikey: $2" "$GW/$3" 2>&1)
    code=$(printf '%s' "$out" | awk 'match($0, /HTTP\/[0-9.]+ [0-9][0-9][0-9]/) {c = substr($0, RSTART + RLENGTH - 3, 3)} END {print c}')
    body=$(printf '%s' "$out" | sed -n '/^$/,$p' | tr -d '\r' | tr '\n' ' ' | cut -c1-160)
    printf '%-6s %-28s HTTP %s  %s\n' "[$1]" "/$3" "${code:-???}" "$body"
}

echo "== APIs pelo gateway ($GW)"
for k in anon pub; do
    if [ "$k" = anon ]; then K=$ANON; else K=$PUB; fi
    for p in rest/v1/ auth/v1/settings auth/v1/health storage/v1/version storage/v1/bucket functions/v1/hello realtime/v1/api/tenants/realtime-dev/health; do
        req "$k" "$K" "$p"
    done
done

echo "== Studio sem credencial (esperado 401)"
wget -q -S -O /dev/null "$GW/" 2>&1 | awk 'match($0, /HTTP\/[0-9.]+ [0-9][0-9][0-9]/) {print "  " $0}' | tail -1

echo "== Studio com credencial do painel (esperado 200)"
wget -q -S -O /dev/null --http-user="$(val DASHBOARD_USERNAME)" --http-password="$(val DASHBOARD_PASSWORD)" "$GW/" 2>&1 \
    | awk 'match($0, /HTTP\/[0-9.]+ [0-9][0-9][0-9]/) {print "  " $0}' | tail -1

echo "== DNS de $HOST (precisa apontar para o IP da VPS)"
getent hosts "$HOST" || echo "  (sem resolucao)"
echo "== IP publico da VPS"
wget -qO- https://api.ipify.org 2>/dev/null || echo "  (nao foi possivel consultar)"
echo
echo "DONE"
