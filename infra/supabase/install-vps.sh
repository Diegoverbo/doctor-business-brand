#!/bin/sh
#
# install-vps.sh — instala o Supabase self-hosted (stack completa, open source) em
# /srv/supabase na VPS da Hostinger, sem mexer no que ja roda la.
#
# Roda dentro de um conteiner temporario `docker:27-cli` (ops-install.compose.yml), subido pelo
# Docker Manager da Hostinger, com /srv e o socket do Docker montados. Passos:
#   1. instala git/openssl/jq no conteiner e roda o setup.sh OFICIAL do Supabase, fixado numa
#      tag de release (self-hosted/vX.Y.Z): clona docker/, gera todos os segredos e chaves
#      (utils/generate-keys.sh + utils/add-new-auth-keys.sh) e grava .supabase-version;
#   2. ajusta o .env (URLs publicas, nome do projeto, telefone desligado, OpenAI vazio);
#   3. grava docker-compose.vps.yml e README-VPS.md (deste repositorio) e ativa os overrides
#      `logs` (Logflare + Vector) e `vps` com o run.sh oficial;
#   4. baixa as imagens e sobe a stack esperando todos os healthchecks;
#   5. acrescenta o site ao /srv/caddy/Caddyfile (com backup), valida e recarrega o Caddy por
#      sinal (SIGUSR1) — sem reiniciar o conteiner, sem derrubar os outros sites;
#   6. verifica o gateway pela rede `web` e imprime um resumo (segredos ficam no .env).
#
# E idempotente no sentido seguro: se /srv/supabase ja existe, para sem tocar em nada.
#
# Variaveis (vem do compose do instalador):
#   BASE_URL       raw do GitHub da pasta infra/supabase deste repositorio
#   SUPABASE_HOST  host publico (DNS A -> IP da VPS)           ex.: supabase.doctorbusiness.net.br
#   SITE_URL       URL do app que usa o Auth (redirect padrao)  ex.: https://doctorbusiness.net.br
#   SUPABASE_REF   tag de release do Supabase self-hosted       ex.: self-hosted/v0.8.3

set -eu

BASE_URL="${BASE_URL:?defina BASE_URL}"
SUPABASE_HOST="${SUPABASE_HOST:?defina SUPABASE_HOST}"
SITE_URL="${SITE_URL:?defina SITE_URL}"
SUPABASE_REF="${SUPABASE_REF:?defina SUPABASE_REF}"
STUDIO_ORG="${STUDIO_ORG:-Doctor Business}"
POOLER_TENANT="${POOLER_TENANT:-doctorbusiness}"

DIR=/srv/supabase
CADDYFILE=/srv/caddy/Caddyfile
UPSTREAM_RAW="https://raw.githubusercontent.com/supabase/supabase/$SUPABASE_REF/docker"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

[ -S /var/run/docker.sock ] || die "socket do Docker nao montado em /var/run/docker.sock"
[ -f "$CADDYFILE" ] || die "Caddyfile nao encontrado em $CADDYFILE"
[ -e "$DIR" ] && die "$DIR ja existe: nada foi alterado. Remova ou renomeie antes de reinstalar."
docker network inspect web >/dev/null 2>&1 || die "rede docker 'web' (do Caddy) nao existe"

log "Dependencias do instalador (no conteiner, nao na VPS)"
apk add --no-cache git openssl jq >/dev/null

log "Baixando os arquivos desta instalacao de $BASE_URL"
tmp=$(mktemp -d)
for f in docker-compose.vps.yml Caddyfile.supabase README.md; do
    wget -q -O "$tmp/$f" "$BASE_URL/$f" || die "falha ao baixar $f"
done
wget -q -O "$tmp/setup.sh" "$UPSTREAM_RAW/setup.sh" || die "falha ao baixar setup.sh ($SUPABASE_REF)"

log "setup.sh oficial do Supabase ($SUPABASE_REF) -> $DIR"
# O setup.sh imprime TODOS os segredos gerados no stdout (comportamento do upstream). Aqui a
# saida vai para um log privado dentro do projeto, e nao para os logs do conteiner, que a API
# da Hostinger expoe. So as linhas de progresso ("===>") passam para o log do conteiner.
setuplog=/srv/supabase-setup.log
cd /srv
sh "$tmp/setup.sh" --skip-deps -y --project-dir supabase --ref "$SUPABASE_REF" >"$setuplog" 2>&1 \
    || { grep -v '=' "$setuplog" | tail -20; die "setup.sh falhou (log completo em $setuplog)"; }
grep '^===>' "$setuplog" || true
cd "$DIR"
mv "$setuplog" ./setup.log && chmod 600 ./setup.log
[ -f .env ] || die "setup.sh terminou sem gerar o .env"
chmod 600 .env
grep -q '^JWT_SECRET=' .env || die "JWT_SECRET nao gerado"
grep -q '^SUPABASE_PUBLISHABLE_KEY=sb_publishable_' .env || die "chaves sb_ nao geradas"

log "Ajustando o .env"
sed -i \
    -e "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=https://$SUPABASE_HOST|" \
    -e "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=https://$SUPABASE_HOST/auth/v1|" \
    -e "s|^SITE_URL=.*|SITE_URL=$SITE_URL|" \
    -e "s|^PROXY_DOMAIN=.*|PROXY_DOMAIN=$SUPABASE_HOST|" \
    -e "s|^STUDIO_DEFAULT_ORGANIZATION=.*|STUDIO_DEFAULT_ORGANIZATION=$STUDIO_ORG|" \
    -e "s|^STUDIO_DEFAULT_PROJECT=.*|STUDIO_DEFAULT_PROJECT=$STUDIO_ORG|" \
    -e "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=|" \
    -e "s|^POOLER_TENANT_ID=.*|POOLER_TENANT_ID=$POOLER_TENANT|" \
    -e "s|^ENABLE_PHONE_SIGNUP=.*|ENABLE_PHONE_SIGNUP=false|" \
    -e "s|^ENABLE_PHONE_AUTOCONFIRM=.*|ENABLE_PHONE_AUTOCONFIRM=false|" \
    .env

cp "$tmp/docker-compose.vps.yml" docker-compose.vps.yml
cp "$tmp/README.md" README-VPS.md
sh run.sh config add logs vps

log "Baixando imagens e subindo a stack (pode levar alguns minutos)"
docker compose --progress quiet pull
docker compose up -d --wait --wait-timeout 900
docker compose ps

log "Caddy: acrescentando o site $SUPABASE_HOST"
if grep -q "^$SUPABASE_HOST" "$CADDYFILE"; then
    echo "bloco ja existe no Caddyfile; nao duplicado"
else
    bak="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$CADDYFILE" "$bak"
    { echo; sed "s|__SUPABASE_HOST__|$SUPABASE_HOST|g" "$tmp/Caddyfile.supabase"; } >> "$CADDYFILE"
    if docker run --rm -v "$CADDYFILE:/cf/Caddyfile:ro" caddy:2-alpine \
            caddy validate --config /cf/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        docker kill -s USR1 caddy >/dev/null
        sleep 3
        echo "Caddy recarregado por SIGUSR1 (backup: $bak)"
        docker logs --since 20s caddy 2>&1 | grep -i -m3 'reload\|error' || true
    else
        cp "$bak" "$CADDYFILE"
        die "Caddyfile invalido apos o acrescimo; restaurado de $bak"
    fi
fi

log "Verificacao pela rede web (o caminho que o Caddy usa)"
ANON=$(grep '^ANON_KEY=' .env | cut -d= -f2-)
for p in auth/v1/health rest/v1/ storage/v1/version; do
    code=$(wget -q -S -O /dev/null --header "apikey: $ANON" "http://supabase-api:8000/$p" 2>&1 \
        | awk 'match($0, /HTTP\/[0-9.]+ [0-9][0-9][0-9]/) {c = substr($0, RSTART + RLENGTH - 3, 3)} END {print c}')
    echo "GET /$p -> HTTP ${code:-sem resposta}"
done

docker image rm node:22-alpine >/dev/null 2>&1 || true
rm -rf "$tmp"

log "RESUMO"
cat <<EOF
Diretorio:   $DIR  (compose oficial $SUPABASE_REF + docker-compose.logs.yml + docker-compose.vps.yml)
Versao base: $(grep '^ref=' .supabase-version 2>/dev/null || echo 'sem .supabase-version')
URL publica: https://$SUPABASE_HOST   (exige DNS: A $SUPABASE_HOST -> IP da VPS)
Studio:      https://$SUPABASE_HOST/  usuario $(grep '^DASHBOARD_USERNAME=' .env | cut -d= -f2-)
Postgres:    127.0.0.1:5432 (sessao) e 127.0.0.1:6543 (transacao), so na VPS ou por tunel SSH
Segredos:    $DIR/.env (chmod 600). Na VPS: cd $DIR && sh run.sh secrets
Caddy:       site acrescentado em $CADDYFILE
Operacao:    cd $DIR && sh run.sh status|logs|restart|stop|start ; atualizar: sh update.sh

Credenciais de uso no cliente (as de servidor ficam so no .env):
DASHBOARD_PASSWORD=$(grep '^DASHBOARD_PASSWORD=' .env | cut -d= -f2-)
SUPABASE_PUBLISHABLE_KEY=$(grep '^SUPABASE_PUBLISHABLE_KEY=' .env | cut -d= -f2-)
ANON_KEY=$ANON
EOF
log "INSTALACAO CONCLUIDA"
