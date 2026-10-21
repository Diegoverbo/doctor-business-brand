# Supabase self-hosted na VPS (Hostinger)

Stack **completa e open source** do Supabase (release oficial `self-hosted/v0.8.3`) rodando em
`/srv/supabase` na VPS `srv1938448.hstgr.cloud` (KVM 4, Ubuntu, Docker). Instalada pelo
`install-vps.sh` desta pasta, por meio do Docker Manager da Hostinger, sem tocar nos outros
projetos da VPS (Caddy, Galeed, Pharmaco, VitaMan, painel-chat, Hermes).

Este `README.md` e copiado para a VPS como `/srv/supabase/README-VPS.md`.

## O que esta rodando

| Servico | Conteiner | Papel |
|---|---|---|
| Postgres 17 (supabase/postgres) | `supabase-db` | banco, extensoes, pgsodium, vault |
| Supavisor | `supabase-pooler` | pooler de conexoes (5432 sessao / 6543 transacao, so 127.0.0.1) |
| Envoy (gateway) | `supabase-envoy` | porta de entrada unica (`:8000`): roteia por `/rest`, `/auth`, `/storage`, `/realtime`, `/functions`, `/pg`, `/analytics` e o Studio em `/` |
| GoTrue | `supabase-auth` | autenticacao (e-mail/senha, magic link, OAuth, MFA, SAML) |
| PostgREST | `supabase-rest` | API REST automatica sobre o banco |
| Realtime | `realtime-dev.supabase-realtime` | websockets: mudancas no banco, broadcast, presence |
| Storage + imgproxy | `supabase-storage`, `supabase-imgproxy` | arquivos (backend em disco, `volumes/storage`) e transformacao de imagens |
| postgres-meta | `supabase-meta` | API de administracao do banco usada pelo Studio |
| Edge Runtime (Deno) | `supabase-edge-functions` | Edge Functions em `volumes/functions` |
| Studio | `supabase-studio` | painel web (tabelas, SQL, auth, storage, logs) |
| Logflare + Vector | `supabase-analytics`, `supabase-vector` | logs de todos os servicos, visiveis no Studio |

Arquivos de compose (ativados pelo `COMPOSE_FILE` do `.env`, veja `sh run.sh config`):

- `docker-compose.yml` — base oficial (nao editar; `update.sh` faz merge de 3 vias por cima);
- `docker-compose.logs.yml` — override oficial de logs (Logflare + Vector);
- `docker-compose.vps.yml` — **nosso** override: nada publicado na internet, Postgres so em
  `127.0.0.1`, gateway na rede `web` com o alias `supabase-api`.

## Acesso

| O que | Onde |
|---|---|
| Studio (painel) | `https://supabase.doctorbusiness.net.br/` — usuario e senha `DASHBOARD_*` do `.env` |
| URL do projeto (SDKs) | `https://supabase.doctorbusiness.net.br` |
| Chave publica (cliente) | `SUPABASE_PUBLISHABLE_KEY` (`sb_publishable_...`) ou `ANON_KEY` (JWT legado) |
| Chave de servidor | `SUPABASE_SECRET_KEY` (`sb_secret_...`) ou `SERVICE_ROLE_KEY` — **nunca** no cliente |
| Postgres direto | so na VPS: `psql -h 127.0.0.1 -p 5432 -U postgres.doctorbusiness` (pooler) ou tunel SSH |

Ver os segredos na VPS: `cd /srv/supabase && sh run.sh secrets` (ou `cat .env`, chmod 600).

Comportamentos esperados do gateway (verificados na instalacao com `check-vps.sh`):
`/rest/v1/` (raiz, especificacao OpenAPI) responde **403** para `anon`/`sb_publishable_` por
desenho do upstream (so `service_role`/`sb_secret_` leem a spec); tabelas e RPCs em
`/rest/v1/<tabela>` funcionam normalmente. `/auth/v1/*`, `/storage/v1/*` e
`/functions/v1/*` respondem 200 com a chave publica; o Studio em `/` responde 401 sem
usuario/senha.

**DNS obrigatorio:** o host `supabase.doctorbusiness.net.br` precisa de um registro `A`
apontando para o IP da VPS (`179.199.136.203`; opcionalmente `AAAA` para
`2a02:4780:6e:43fe::1`). Na instalacao (2026-10-21) o nome resolvia para `64.29.17.65`
(wildcard do dominio, fora da Hostinger): ate trocar o registro, o HTTPS publico nao sobe. O Caddy emite o certificado Let's Encrypt sozinho assim que o DNS
resolver; ate la ele tenta de novo em segundo plano e os outros sites nao sao afetados.

## Como a VPS expoe o Supabase

```
internet ──HTTPS──> caddy (/srv/caddy, portas 80/443)
                      └─ supabase.doctorbusiness.net.br ──rede web──> supabase-api:8000 (Envoy)
                                                                         ├─ /rest/v1      -> supabase-rest
                                                                         ├─ /auth/v1      -> supabase-auth
                                                                         ├─ /storage/v1   -> supabase-storage
                                                                         ├─ /realtime/v1  -> realtime (websocket)
                                                                         ├─ /functions/v1 -> edge-functions
                                                                         └─ /              -> supabase-studio (basic-auth)
```

Nenhum conteiner do Supabase publica porta no IP publico. As unicas portas no host sao em
`127.0.0.1`: `8010` (gateway, diagnostico), `5432` e `6543` (Supavisor). O bloco do Caddy esta
em `/srv/caddy/Caddyfile` (fonte: `Caddyfile.supabase` desta pasta) e o Caddy foi recarregado
por sinal (`docker kill -s USR1 caddy`), sem reiniciar.

## Operacao do dia a dia (na VPS, em `/srv/supabase`)

```sh
sh run.sh status            # docker compose ps
sh run.sh logs [servico]    # logs (ex.: sh run.sh logs auth)
sh run.sh restart [servico] # reinicia tudo ou um servico
sh run.sh stop / start      # para / sobe a stack (dados preservados)
sh run.sh secrets           # senhas e chaves do .env
sh run.sh config            # overrides ativos (COMPOSE_FILE)
```

Depois de editar o `.env` (SMTP, provedores OAuth etc.): `sh run.sh recreate <servico>` ou
`docker compose up -d`.

### Atualizar o Supabase

```sh
cd /srv/supabase
sh update.sh --dry-run      # mostra o que mudaria
sh update.sh                # merge de 3 vias dos arquivos oficiais (respeita .env e o override vps)
sh run.sh pull && sh run.sh recreate
```

A versao base fica em `.supabase-version`. Antes de atualizar: **backup do banco** (abaixo).

### Backup

- Banco: `docker exec supabase-db pg_dumpall -U postgres > /srv/backups/supabase-$(date +%F).sql`
  (crie `/srv/backups` fora do diretorio do projeto). Restaurar: `psql` no `supabase-db`.
- Arquivos do Storage: `/srv/supabase/volumes/storage`.
- Configuracao: `.env`, `docker-compose.vps.yml`, `volumes/functions`.
- A Hostinger ja faz backup semanal da VPS inteira (acoes `backup_create` no historico da VM);
  snapshots manuais pelo hPanel ou API `vps_snapshots_*`.

## Configuracoes que ficaram para depois (no `.env`)

- **SMTP** (`SMTP_*`, `SMTP_ADMIN_EMAIL`): sem isso o Auth nao envia e-mail de confirmacao,
  recuperacao e magic link. Qualquer SMTP serve (Resend, Gmail Workspace, Hostinger Email).
  `ENABLE_EMAIL_AUTOCONFIRM=false` por padrao: usuarios precisam confirmar o e-mail.
- **Telefone/SMS**: desligado (`ENABLE_PHONE_SIGNUP=false`) ate existir um provedor.
- **OAuth** (Google, GitHub, Azure...): descomente `GOTRUE_EXTERNAL_*` no `docker-compose.yml`
  e as variaveis no `.env` (docs: self-hosted-oauth).
- **OpenAI** (`OPENAI_API_KEY`): vazio; habilita o assistente de IA do Studio se preenchido.
- **Redirects do Auth**: `SITE_URL=https://doctorbusiness.net.br`; outros em
  `ADDITIONAL_REDIRECT_URLS`.
- **Storage em S3** (em vez de disco): override `docker-compose.rustfs.yml` (`sh run.sh config add rustfs`).

### Trocar o dominio

1. `.env`: `SUPABASE_PUBLIC_URL`, `API_EXTERNAL_URL`, `PROXY_DOMAIN` (e `SITE_URL` se for o caso);
2. `/srv/caddy/Caddyfile`: o nome do site no bloco do Supabase; depois `docker kill -s USR1 caddy`;
3. `sh run.sh recreate`.

## Seguranca

- Todos os segredos foram gerados na propria VPS pelos utilitarios oficiais
  (`utils/generate-keys.sh`, `utils/add-new-auth-keys.sh`): JWT HS256 + par ES256, chaves
  `sb_publishable_`/`sb_secret_`, senhas de Postgres, Studio, Logflare, Supavisor, S3 e Vault.
- `.env` com `chmod 600`, fora do git. Nunca commitar. O `setup.log` (saida do setup.sh
  oficial, que imprime os segredos gerados) tambem fica `chmod 600` dentro de `/srv/supabase`.
- Trocar a senha do Studio: editar `DASHBOARD_PASSWORD` no `.env` e `sh run.sh recreate api-gw`.
  Rotacionar as chaves de API: `sh utils/generate-keys.sh` e `sh utils/add-new-auth-keys.sh`
  (docs: self-hosted-auth-keys), depois `sh run.sh recreate`.
- Studio atras de basic-auth do gateway e de HTTPS (HSTS). APIs exigem `apikey`.
- Postgres sem porta publica. Para ferramentas externas: tunel SSH.
- Cabecalhos de seguranca no Caddy (`nosniff`, `Referrer-Policy`, sem `Server`).

## Como foi instalado (reproduzivel)

1. Esta pasta foi publicada no GitHub (branch com `install-vps.sh`, `docker-compose.vps.yml`,
   `Caddyfile.supabase`, `README.md`).
2. Pela API da Hostinger (`vps_docker_create`), subiu-se o projeto `supabase-install-tmp` com
   `ops-install.compose.yml`: um conteiner `docker:27-cli` com `/srv` e o socket do Docker.
3. O conteiner baixou `install-vps.sh` e executou: `setup.sh` oficial (tag fixada) ->
   ajustes do `.env` -> overrides `logs` + `vps` -> `docker compose up -d --wait` ->
   bloco no Caddyfile (com backup `Caddyfile.bak-<data>`) -> validacao -> SIGUSR1 no Caddy.
4. Logs lidos pela API (`vps_docker_logs`) e projeto temporario removido (`vps_docker_delete`).

### Desfazer tudo

```sh
cd /srv/supabase && docker compose down -v     # para e remove conteineres e volumes nomeados
rm -rf /srv/supabase                            # dados: volumes/db/data e volumes/storage
# remover o bloco "supabase.doctorbusiness.net.br { ... }" do /srv/caddy/Caddyfile
docker kill -s USR1 caddy
```
