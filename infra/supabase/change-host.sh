#!/bin/sh
#
# change-host.sh — troca o host publico do Supabase instalado em /srv/supabase.
#
# Roda num conteiner descartavel `docker:27-cli` (ops-change-host.compose.yml) com /srv e o
# socket do Docker montados, na rede `web`. Passos:
#   1. ajusta SUPABASE_PUBLIC_URL, API_EXTERNAL_URL, PROXY_DOMAIN, SITE_URL (e, se pedido, o nome
#      da organizacao/projeto do Studio) no .env;
#   2. substitui o bloco do Supabase no /srv/caddy/Caddyfile (com backup), valida e recarrega o
#      Caddy por SIGUSR1 — sem reiniciar, sem derrubar os outros sites;
#   3. `docker compose up -d --wait`: recria so os servicos cuja configuracao mudou
#      (gateway, studio, auth, storage, functions); dados e banco intactos;
#   4. verifica o gateway pela rede `web` e mostra para onde o DNS do novo host aponta.
#
# Variaveis:
#   BASE_URL       raw do GitHub da pasta infra/supabase (para o Caddyfile.supabase)
#   SUPABASE_HOST  novo host publico             ex.: supabase.pharmaco.com.br
#   SITE_URL       URL do app (redirect do Auth)  ex.: https://pharmaco.com.br
#   STUDIO_ORG     (opcional) nome da organizacao/projeto no Studio

set -eu

BASE_URL="${BASE_URL:?defina BASE_URL}"
NEW="${SUPABASE_HOST:?defina SUPABASE_HOST}"
SITE="${SITE_URL:?defina SITE_URL}"
ORG="${STUDIO_ORG:-}"

DIR=/srv/supabase
CADDYFILE=/srv/caddy/Caddyfile

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

[ -S /var/run/docker.sock ] || die "socket do Docker nao montado"
[ -f "$DIR/.env" ] || die "$DIR/.env nao existe: o Supabase nao esta instalado"
[ -f "$CADDYFILE" ] || die "Caddyfile nao encontrado"
cd "$DIR"

OLD=$(grep '^SUPABASE_PUBLIC_URL=' .env | cut -d= -f2- | sed -e 's|^https\{0,1\}://||' -e 's|/.*||')
[ -n "$OLD" ] || die "SUPABASE_PUBLIC_URL vazio no .env"
log "Host atual: $OLD  ->  novo: $NEW"

tmp=$(mktemp -d)
wget -q -O "$tmp/Caddyfile.supabase" "$BASE_URL/Caddyfile.supabase" || die "falha ao baixar Caddyfile.supabase"

log "Ajustando o .env"
sed -i \
    -e "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=https://$NEW|" \
    -e "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=https://$NEW/auth/v1|" \
    -e "s|^PROXY_DOMAIN=.*|PROXY_DOMAIN=$NEW|" \
    -e "s|^SITE_URL=.*|SITE_URL=$SITE|" \
    .env
if [ -n "$ORG" ]; then
    sed -i \
        -e "s|^STUDIO_DEFAULT_ORGANIZATION=.*|STUDIO_DEFAULT_ORGANIZATION=$ORG|" \
        -e "s|^STUDIO_DEFAULT_PROJECT=.*|STUDIO_DEFAULT_PROJECT=$ORG|" \
        .env
fi
grep -E '^(SUPABASE_PUBLIC_URL|API_EXTERNAL_URL|SITE_URL|PROXY_DOMAIN|STUDIO_DEFAULT_ORGANIZATION)=' .env

log "Caddy: trocando o bloco do Supabase ($OLD -> $NEW)"
bak="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
cp "$CADDYFILE" "$bak"
# O candidato fica ao lado do Caddyfile (caminho do host): o `docker run` de validacao monta
# caminhos do HOST, nao deste conteiner — um arquivo em /tmp daqui viraria diretorio vazio la.
cand="$CADDYFILE.novo"
# remove o bloco antigo: do comentario "# Supabase (self-hosted)" ate a primeira linha que e so "}"
# e tira as linhas em branco sobrando no fim
awk 'BEGIN {skip = 0}
     /^# Supabase \(self-hosted\)/ {skip = 1}
     skip && $0 == "}" {skip = 0; next}
     !skip {lines[++n] = $0}
     END {while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i]}' "$bak" > "$cand"
{ echo; sed "s|__SUPABASE_HOST__|$NEW|g" "$tmp/Caddyfile.supabase"; } >> "$cand"
grep -q "^$NEW {" "$cand" || { rm -f "$cand"; die "bloco novo nao entrou no Caddyfile"; }
# (se o .env ja tinha o host novo, por uma execucao anterior interrompida, OLD == NEW e o teste nao se aplica)
if [ "$OLD" != "$NEW" ] && grep -q "^$OLD {" "$cand"; then rm -f "$cand"; die "bloco antigo ainda presente no Caddyfile; nada aplicado"; fi

if out=$(docker run --rm -v "$cand:/cf/Caddyfile:ro" caddy:2-alpine \
        caddy validate --config /cf/Caddyfile --adapter caddyfile 2>&1); then
    mv "$cand" "$CADDYFILE"
    docker kill -s USR1 caddy >/dev/null
    sleep 3
    echo "Caddy recarregado por SIGUSR1 (backup: $bak)"
    docker logs --since 20s caddy 2>&1 | grep -i -m3 'reload\|error' || true
else
    printf '%s\n' "$out" | tail -5
    rm -f "$cand"
    die "Caddyfile novo invalido; o atual nao foi alterado (backup em $bak)"
fi

log "Recriando os servicos afetados (docker compose up -d --wait)"
docker compose up -d --wait --wait-timeout 600
docker compose ps

log "Verificacao pela rede web"
ANON=$(grep '^ANON_KEY=' .env | cut -d= -f2-)
for p in auth/v1/health auth/v1/settings storage/v1/version; do
    code=$(wget -q -S -O /dev/null --header "apikey: $ANON" "http://supabase-api:8000/$p" 2>&1 \
        | awk 'match($0, /HTTP\/[0-9.]+ [0-9][0-9][0-9]/) {c = substr($0, RSTART + RLENGTH - 3, 3)} END {print c}')
    echo "GET /$p -> HTTP ${code:-sem resposta}"
done
echo "Issuer do Auth: $(docker exec supabase-auth sh -c 'echo $GOTRUE_JWT_ISSUER' 2>/dev/null || echo '?')"

log "DNS de $NEW (precisa apontar para o IP publico da VPS)"
getent hosts "$NEW" || echo "  (sem resolucao ainda)"
echo "IP publico da VPS: $(wget -qO- https://api.ipify.org 2>/dev/null || echo '?')"

rm -rf "$tmp"
log "TROCA DE HOST CONCLUIDA: https://$NEW"
