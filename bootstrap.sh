#!/usr/bin/env bash
# First-boot wizard for a pabip-gateway instance — sobe uma instância nova
# sem clonar repositório: pergunta as escolhas de configuração e roda os
# comandos (docker pull, migrate-only, docker run) por conta do operador.
# Não cobre TLS/reverse-proxy nem múltiplas réplicas — isso é um segundo
# passo, depois que a primeira instância já está no ar (ver README).
#
# Uso recomendado (preserva o stdin real do terminal pros prompts abaixo,
# já que o corpo inteiro do script é baixado antes de começar a rodar):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/protocolo-aberto-brasileiro-integracao/pabip-gateway-installer/main/bootstrap.sh)"
# `curl -fsSL <url> | bash` também funciona — cada prompt abaixo lê de
# /dev/tty explicitamente pra esse caso, já que o stdin do script seria o
# próprio pipe do curl.
set -euo pipefail

IMAGE_REPO='public.ecr.aws/x8o6o1x8/pabip-gateway'
GATEWAY_CONTAINER='pabip-gateway'
POSTGRES_CONTAINER='pabip-postgres'
POSTGRES_VOLUME='pabip-gateway-postgres-data'
ENV_FILE='pabip-gateway.env'

log() { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1" >&2; }
die() {
  printf '\033[1;31mx\033[0m %s\n' "$1" >&2
  exit 1
}

# Reads one line from the real terminal even when this script's own stdin is
# curl's pipe (curl | bash) rather than an interactive shell.
tty_read() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  if [ -n "$__default" ]; then
    __prompt="$__prompt [$__default]: "
  else
    __prompt="$__prompt: "
  fi
  if [ -r /dev/tty ]; then
    read -r -p "$__prompt" __reply </dev/tty
  else
    read -r -p "$__prompt" __reply
  fi
  [ -z "$__reply" ] && __reply="$__default"
  printf -v "$__var" '%s' "$__reply"
}

tty_read_required() {
  local __var="$1" __prompt="$2" __reply=''
  while [ -z "$__reply" ]; do
    tty_read __reply "$__prompt"
    [ -z "$__reply" ] && warn 'obrigatório, não pode ficar em branco.'
  done
  printf -v "$1" '%s' "$__reply"
}

tty_confirm() {
  local __prompt="$1" __reply=''
  tty_read __reply "$__prompt (s/N)" 'n'
  case "$__reply" in
  s | S | sim | y | Y | yes) return 0 ;;
  *) return 1 ;;
  esac
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$1"
}

precheck() {
  command -v docker >/dev/null 2>&1 || die 'docker não encontrado no PATH. Instale o Docker Engine antes de continuar.'
  docker info >/dev/null 2>&1 || die 'não foi possível falar com o daemon do Docker — ele está rodando e acessível pro seu usuário?'
  command -v openssl >/dev/null 2>&1 || die 'openssl não encontrado no PATH (necessário pra gerar o admin token/senha).'

  if container_exists "$GATEWAY_CONTAINER"; then
    die "já existe um container '$GATEWAY_CONTAINER' — este script é só pra primeiro boot. Para operar uma instância existente, use pabip-gatewayctl (ver OPERATIONS.md); pra recriar, remova o container antigo você mesmo primeiro."
  fi
}

gather_ente_publico() {
  tty_read_required GATEWAY_ENTE_PUBLICO_NAME 'Nome do Ente Público (identidade fixa desta instância, não muda fácil depois)'
}

gather_database() {
  if tty_confirm 'Você já tem uma instância Postgres para usar?'; then
    tty_read_required DATABASE_URL 'Connection string completa (DATABASE_URL)'
    USE_LOCAL_POSTGRES=0
  else
    USE_LOCAL_POSTGRES=1
    if container_exists "$POSTGRES_CONTAINER"; then
      die "já existe um container '$POSTGRES_CONTAINER' de uma execução anterior — aponte pra ele como Postgres existente (responda 'sim' na pergunta acima) ou remova-o antes de tentar subir um novo."
    fi
    PG_PASSWORD="$(openssl rand -hex 16)"
    DATABASE_URL="postgresql://gateway:${PG_PASSWORD}@host.docker.internal:5432/gateway?schema=public"
  fi
}

gather_output() {
  echo 'Para onde o gateway entrega os eventos recebidos?'
  echo '  1) callback — webhook HTTP (padrão)'
  echo '  2) queue    — RabbitMQ/Kafka/SQS/Redis Streams'
  echo '  3) db       — grava direto numa tabela de destino'
  echo '  4) decidir depois (toda entrega fica rejeitada até configurar)'
  local choice=''
  while true; do
    tty_read choice 'Escolha' '1'
    case "$choice" in
    1)
      tty_read_required OUTPUT_CALLBACK_URL 'URL do callback (sistema legado)'
      OUTPUT_TYPE='callback'
      break
      ;;
    2)
      tty_read_required OUTPUT_QUEUE_BROKER_URL 'URL do broker de fila'
      OUTPUT_TYPE='queue'
      break
      ;;
    3)
      tty_read_required OUTPUT_DB_CONNECTION_STRING 'Connection string do banco de destino'
      OUTPUT_TYPE='db'
      break
      ;;
    4)
      warn 'sem destino configurado — toda entrega será rejeitada até você rodar `pabip-gatewayctl config set` (ver OPERATIONS.md).'
      OUTPUT_TYPE='callback'
      OUTPUT_CALLBACK_URL=''
      break
      ;;
    *) warn 'escolha inválida.' ;;
    esac
  done
}

gather_image_tag() {
  tty_read GATEWAY_IMAGE_TAG 'Tag da imagem' 'latest'
}

write_env_file() {
  ADMIN_TOKEN="$(openssl rand -hex 32)"

  {
    printf 'DATABASE_URL=%s\n' "$DATABASE_URL"
    printf 'GATEWAY_ENTE_PUBLICO_NAME=%s\n' "$GATEWAY_ENTE_PUBLICO_NAME"
    printf 'GATEWAY_ADMIN_TOKENS=%s\n' "$ADMIN_TOKEN"
    printf 'OUTPUT_TYPE=%s\n' "$OUTPUT_TYPE"
    case "$OUTPUT_TYPE" in
    callback) printf 'OUTPUT_CALLBACK_URL=%s\n' "$OUTPUT_CALLBACK_URL" ;;
    queue) printf 'OUTPUT_QUEUE_BROKER_URL=%s\n' "$OUTPUT_QUEUE_BROKER_URL" ;;
    db) printf 'OUTPUT_DB_CONNECTION_STRING=%s\n' "$OUTPUT_DB_CONNECTION_STRING" ;;
    esac
    printf 'NODE_ENV=production\n'
    printf 'LOG_LEVEL=info\n'
  } >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

start_local_postgres() {
  [ "$USE_LOCAL_POSTGRES" -eq 1 ] || return 0
  log "Subindo Postgres local ($POSTGRES_CONTAINER)…"
  docker run -d \
    --name "$POSTGRES_CONTAINER" \
    -p 5432:5432 \
    -e POSTGRES_USER=gateway \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -e POSTGRES_DB=gateway \
    -v "${POSTGRES_VOLUME}:/var/lib/postgresql/data" \
    --restart unless-stopped \
    postgres:16-alpine >/dev/null

  log 'Aguardando o Postgres aceitar conexões…'
  local attempt=0
  until docker exec "$POSTGRES_CONTAINER" pg_isready -U gateway -d gateway >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -ge 15 ] && die "Postgres não ficou pronto a tempo — veja 'docker logs $POSTGRES_CONTAINER'."
    sleep 2
  done
}

pull_image() {
  log "Baixando ${IMAGE_REPO}:${GATEWAY_IMAGE_TAG}…"
  docker pull "${IMAGE_REPO}:${GATEWAY_IMAGE_TAG}"
}

run_migration() {
  log 'Aplicando o schema no banco (migrate-only)…'
  docker run --rm \
    --env-file "$ENV_FILE" \
    --add-host=host.docker.internal:host-gateway \
    "${IMAGE_REPO}:${GATEWAY_IMAGE_TAG}" \
    migrate-only
}

start_gateway() {
  log "Subindo o gateway ($GATEWAY_CONTAINER)…"
  docker run -d \
    --name "$GATEWAY_CONTAINER" \
    --env-file "$ENV_FILE" \
    --add-host=host.docker.internal:host-gateway \
    -p 8080:8080 \
    --restart unless-stopped \
    "${IMAGE_REPO}:${GATEWAY_IMAGE_TAG}" >/dev/null
}

wait_for_health() {
  log 'Verificando healthz/readyz…'
  local attempt=0
  until docker exec "$GATEWAY_CONTAINER" pabip-gatewayctl \
    --admin-url http://127.0.0.1:8081 \
    --token "$ADMIN_TOKEN" \
    health check >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 15 ]; then
      warn 'a instância não respondeu saudável a tempo. Últimas linhas de log:'
      docker logs --tail 50 "$GATEWAY_CONTAINER" >&2 || true
      die 'health check falhou — investigue o log acima antes de considerar a instância no ar.'
    fi
    sleep 2
  done
}

print_summary() {
  log 'Instância no ar.'
  cat <<EOF

Admin token (única vez que aparece — guarde no gerenciador de segredos AGORA):
  $ADMIN_TOKEN

Arquivo de config gerado: $ENV_FILE
Container do gateway:     $GATEWAY_CONTAINER (porta 8080 publicada; 8081 fica só interna, de propósito)

Próximos passos (GUIA-ENTE-PUBLICO.md, Parte 3):
  1. Cadastrar o primeiro Ente Privado:
     pabip-gatewayctl --admin-url http://127.0.0.1:8081 --token "\$TOKEN" peers create ...
  2. Emitir client token, se houver frontend consumindo /peers/*.
  3. Apontar seu coletor de logs pro stdout do container.
  4. Configurar backup do Postgres (ver OPERATIONS.md).
  5. Ligar métricas (GET /metrics, porta admin) a um painel/alerta.
  6. Rodar o checklist de primeiro boot em OPERATIONS.md item a item.
  7. Agendar a primeira rotação do admin token.
EOF
}

main() {
  precheck
  gather_ente_publico
  gather_database
  gather_output
  gather_image_tag
  write_env_file
  start_local_postgres
  pull_image
  run_migration
  start_gateway
  wait_for_health
  print_summary
}

main "$@"
