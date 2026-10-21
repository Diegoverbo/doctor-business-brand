#!/bin/sh
#
# caddy-safe-restart.sh — reinicia o Caddy da VPS com rede de seguranca, para ele reler o
# /srv/caddy/Caddyfile quando o arquivo visto dentro do conteiner ficou diferente do arquivo
# do host (bind mount de arquivo unico preso ao inode antigo depois de um `mv`/`sed -i`).
#
#   1. compara o Caddyfile do host com o que o conteiner enxerga; se forem iguais, nao reinicia;
#   2. valida o Caddyfile do host com um caddy descartavel;
#   3. mede todos os sites (codigo HTTP via 127.0.0.1) antes do restart;
#   4. `docker restart caddy` (interrupcao de 1 a 3 s); se o Caddy nao voltar em 30 s, restaura
#      $ROLLBACK e reinicia de novo;
#   5. mede os sites de novo e espera ate 3 min pelo certificado de $SUPABASE_HOST.
#
# Roda num conteiner `docker:27-cli` com network_mode: host, o socket do Docker e /srv/caddy.

set -u
CF=/srv/caddy/Caddyfile
HOST="${SUPABASE_HOST:?defina SUPABASE_HOST}"
ROLLBACK="${ROLLBACK:?defina ROLLBACK (backup valido do Caddyfile)}"
CERTDIR=/srv/caddy/data/caddy/certificates

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

apk add --no-cache curl >/dev/null 2>&1 || die "nao consegui instalar curl"
[ -f "$ROLLBACK" ] || die "backup $ROLLBACK nao existe"

sites() {
    grep -E '^[a-z0-9][a-z0-9.,: -]*\{$' "$CF" | grep -v '^http://' \
        | sed -e 's/[ {].*//' -e 's/,$//'
}
probe() {
    for h in $(sites); do
        printf '  %-36s %s\n' "$h" \
            "$(curl -s -o /dev/null -m 8 -w '%{http_code}' --resolve "$h:443:127.0.0.1" "https://$h/" 2>/dev/null)"
    done
    printf '  %-36s %s\n' "http://179.199.136.203 (VitaMan)" \
        "$(curl -s -o /dev/null -m 8 -w '%{http_code}' -H 'Host: 179.199.136.203' http://127.0.0.1/ 2>/dev/null)"
}

log "Caddyfile: host x dentro do conteiner"
h_sum=$(md5sum < "$CF" | cut -c1-32)
c_sum=$(docker exec caddy cat /etc/caddy/Caddyfile | md5sum | cut -c1-32)
echo "  host:      $h_sum ($(grep -c '' "$CF") linhas)"
echo "  conteiner: $c_sum ($(docker exec caddy cat /etc/caddy/Caddyfile | grep -c '') linhas)"
echo "  sites no conteiner: $(docker exec caddy cat /etc/caddy/Caddyfile | grep -E '^[a-z0-9].*\{$' | sed 's/ {$//' | tr '\n' ';')"
echo "  sites no host:      $(grep -E '^[a-z0-9].*\{$' "$CF" | sed 's/ {$//' | tr '\n' ';')"

log "Validando o Caddyfile do host"
docker run --rm -v "$CF:/cf/Caddyfile:ro" caddy:2-alpine \
    caddy validate --config /cf/Caddyfile --adapter caddyfile >/tmp/val 2>&1 \
    || { tail -5 /tmp/val; die "Caddyfile do host invalido: nada foi reiniciado"; }
echo "  valido"

if [ "$h_sum" = "$c_sum" ]; then
    echo "  conteiner ja enxerga o arquivo atual: restart desnecessario"
else
    log "Sites ANTES do restart"
    probe
    log "Reiniciando o Caddy"
    docker restart caddy >/dev/null
    i=0
    while [ $i -lt 30 ] && [ "$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" != true ]; do
        i=$((i + 1)); sleep 1
    done
    sleep 4
    if [ "$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" != true ]; then
        docker logs --tail 20 caddy 2>&1
        log "Caddy nao voltou: restaurando $ROLLBACK"
        cat "$ROLLBACK" > "$CF"
        docker restart caddy >/dev/null
        sleep 5
        docker inspect -f 'Running={{.State.Running}}' caddy
        die "restart falhou; backup restaurado"
    fi
    echo "  Caddy de volta ($(docker inspect -f '{{.State.StartedAt}}' caddy))"
    echo "  conteiner agora: $(docker exec caddy cat /etc/caddy/Caddyfile | md5sum | cut -c1-32)"
    log "Sites DEPOIS do restart"
    probe
fi

log "Certificado de $HOST"
i=0
while [ $i -lt 36 ] && ! ls "$CERTDIR"/*/"$HOST"/"$HOST".crt >/dev/null 2>&1; do i=$((i + 1)); sleep 5; done
ls "$CERTDIR"/*/"$HOST"/ 2>/dev/null || echo "  ainda sem certificado"
docker logs --since 4m caddy 2>&1 | grep -F "$HOST" | cut -c1-300 | tail -6
echo
curl -sS -m 10 -o /dev/null -w "  https://$HOST/auth/v1/health (DNS publico) -> %{http_code}\n" "https://$HOST/auth/v1/health" 2>&1
echo
echo "DONE"
