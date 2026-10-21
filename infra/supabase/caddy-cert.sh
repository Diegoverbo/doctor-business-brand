#!/bin/sh
#
# caddy-cert.sh — diagnostica e, se faltar, pede de novo o certificado TLS de um host no Caddy
# da VPS, sem reiniciar o conteiner e sem afetar os outros sites.
#
# 1. mostra os eventos de TLS/ACME recentes do Caddy;
# 2. se nao houver certificado para o host, faz `caddy reload --force` (recarga graciosa: os
#    outros sites seguem servindo e o Caddy reagenda a emissao imediatamente);
# 3. espera ate 3 min pelo certificado e mostra o resultado.
#
# Roda num conteiner descartavel `docker:27-cli` com o socket do Docker e /srv/caddy/data (ro).

set -u
HOST="${SUPABASE_HOST:?defina SUPABASE_HOST}"
CERTDIR=/srv/caddy/data/caddy/certificates

has_cert() { ls "$CERTDIR"/*/"$HOST"/"$HOST".crt >/dev/null 2>&1; }
tls_events() {
    docker logs --since "$1" caddy 2>&1 \
        | grep -E '"logger":"(tls|tls\.obtain|tls\.issuance\.acme|http\.acme_client|tls\.cache\.maintenance)"|obtain|certificate' \
        | grep -v -E 'evoimersaoosasco|individuale' \
        | cut -c1-400 | tail -"$2"
}

echo "== Eventos TLS/ACME do Caddy (ultimas 2h, sem os outros sites)"
tls_events 2h 25

echo
if has_cert; then
    echo "== Certificado de $HOST ja existe:"
    ls -la "$CERTDIR"/*/"$HOST"/
else
    echo "== Sem certificado para $HOST: recarga forcada do Caddy (graciosa)"
    docker exec caddy caddy reload --force --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -3
    i=0
    while [ $i -lt 36 ] && ! has_cert; do i=$((i + 1)); sleep 5; done
    echo
    echo "== Eventos TLS/ACME apos a recarga"
    tls_events 4m 20
    echo
    if has_cert; then
        echo "== CERTIFICADO EMITIDO para $HOST:"
        ls -la "$CERTDIR"/*/"$HOST"/
    else
        echo "== Ainda sem certificado para $HOST apos 3 min (ver eventos acima)"
    fi
fi
echo
echo "DONE"
