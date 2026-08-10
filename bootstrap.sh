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
ADMIN_PORT=8081

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
  local __prompt="$1" __default="${2:-n}" __reply=''
  local __hint='s/N'
  [ "$__default" = 's' ] && __hint='S/n'
  tty_read __reply "$__prompt ($__hint)" "$__default"
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
    die "já existe um container '$GATEWAY_CONTAINER' — este script é só pra primeiro boot. Para operar uma instância existente, use 'docker exec $GATEWAY_CONTAINER pabip-gatewayctl ...'; pra recriar, remova o container antigo você mesmo primeiro."
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

gather_network() {
  GATEWAY_PUBLIC_PORT=8080
  tty_read GATEWAY_PUBLIC_PORT 'Porta pública (webhook + /peers/*)' "$GATEWAY_PUBLIC_PORT"
  case "$GATEWAY_PUBLIC_PORT" in
  '' | *[!0-9]*) die "porta inválida: '$GATEWAY_PUBLIC_PORT' — precisa ser um número." ;;
  esac

  GATEWAY_TRUSTED_PROXY_CIDRS=''
  if tty_confirm 'Existe mais de um reverse proxy na frente do gateway (além do que você já vai colocar depois)?'; then
    tty_read_required GATEWAY_TRUSTED_PROXY_CIDRS 'CIDR/IP dos proxies confiáveis, separados por vírgula'
  fi
  # Vazio (padrão) mantém o trust de 1 hop — correto pra topologia de
  # reverse-proxy único, que é o que docker-compose.prod.yml.example do
  # pabip-gateway assume.
}

gather_output() {
  echo 'Para onde o gateway entrega os eventos recebidos?'
  echo '  1) callback — webhook HTTP (padrão)'
  echo '  2) queue    — RabbitMQ/Kafka/SQS/Redis Streams'
  echo '  3) db       — grava direto numa tabela de destino'
  echo '  4) decidir depois (toda entrega fica rejeitada até configurar)'
  OUTPUT_CALLBACK_HEADERS=''
  OUTPUT_QUEUE_ROUTING_KEY_TEMPLATE=''
  local choice=''
  while true; do
    tty_read choice 'Escolha' '1'
    case "$choice" in
    1)
      tty_read_required OUTPUT_CALLBACK_URL 'URL do callback (sistema legado)'
      if tty_confirm 'Enviar algum header extra em toda chamada de callback (ex.: um segredo compartilhado que o receptor espera)?'; then
        tty_read_required OUTPUT_CALLBACK_HEADERS 'Headers como JSON, ex.: {"X-Shared-Secret":"..."}'
      fi
      OUTPUT_TYPE='callback'
      break
      ;;
    2)
      tty_read_required OUTPUT_QUEUE_BROKER_URL 'URL do broker de fila'
      tty_read OUTPUT_QUEUE_ROUTING_KEY_TEMPLATE 'Routing key template' 'pabip.events.{peerId}.{batchType}'
      OUTPUT_TYPE='queue'
      break
      ;;
    3)
      tty_read_required OUTPUT_DB_CONNECTION_STRING 'Connection string do banco de destino'
      OUTPUT_TYPE='db'
      break
      ;;
    4)
      warn 'sem destino configurado — toda entrega será rejeitada até você rodar `pabip-gatewayctl config set`.'
      OUTPUT_TYPE='callback'
      OUTPUT_CALLBACK_URL=''
      break
      ;;
    *) warn 'escolha inválida.' ;;
    esac
  done
}

gather_audit() {
  AUDIT_SINK='stdout'
  if tty_confirm 'Gravar a trilha de auditoria também no Postgres desta instância (além do stdout)?'; then
    AUDIT_SINK='db'
  fi
  # stdout (padrão) é suficiente se o coletor de log do operador já retém por
  # pelo menos 180 dias (o piso normativo, AUDIT_RETENTION_DAYS) — "db" só
  # vale a pena se você quer consultar a trilha via SQL sem depender do
  # coletor de log pra isso.
}

gather_logging() {
  LOG_LEVEL='info'
  tty_read LOG_LEVEL 'Nível de log (trace/debug/info/warn/error/fatal/silent)' "$LOG_LEVEL"
  case "$LOG_LEVEL" in
  trace | debug | info | warn | error | fatal | silent) ;;
  *) die "nível de log inválido: '$LOG_LEVEL'." ;;
  esac
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
    printf 'GATEWAY_PUBLIC_PORT=%s\n' "$GATEWAY_PUBLIC_PORT"
    [ -n "$GATEWAY_TRUSTED_PROXY_CIDRS" ] && printf 'GATEWAY_TRUSTED_PROXY_CIDRS=%s\n' "$GATEWAY_TRUSTED_PROXY_CIDRS"
    printf 'OUTPUT_TYPE=%s\n' "$OUTPUT_TYPE"
    case "$OUTPUT_TYPE" in
    callback)
      printf 'OUTPUT_CALLBACK_URL=%s\n' "$OUTPUT_CALLBACK_URL"
      [ -n "$OUTPUT_CALLBACK_HEADERS" ] && printf 'OUTPUT_CALLBACK_HEADERS=%s\n' "$OUTPUT_CALLBACK_HEADERS"
      ;;
    queue)
      printf 'OUTPUT_QUEUE_BROKER_URL=%s\n' "$OUTPUT_QUEUE_BROKER_URL"
      printf 'OUTPUT_QUEUE_ROUTING_KEY_TEMPLATE=%s\n' "$OUTPUT_QUEUE_ROUTING_KEY_TEMPLATE"
      ;;
    db) printf 'OUTPUT_DB_CONNECTION_STRING=%s\n' "$OUTPUT_DB_CONNECTION_STRING" ;;
    esac
    printf 'AUDIT_SINK=%s\n' "$AUDIT_SINK"
    printf 'NODE_ENV=production\n'
    printf 'LOG_LEVEL=%s\n' "$LOG_LEVEL"
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
  # A porta admin (8081) nunca é publicada pro host — de propósito, é assim
  # que a autenticação administrativa foi desenhada pra funcionar com
  # segurança (ver `docker exec` nos passos abaixo pra alcançá-la).
  docker run -d \
    --name "$GATEWAY_CONTAINER" \
    --env-file "$ENV_FILE" \
    --add-host=host.docker.internal:host-gateway \
    -p "${GATEWAY_PUBLIC_PORT}:${GATEWAY_PUBLIC_PORT}" \
    --restart unless-stopped \
    "${IMAGE_REPO}:${GATEWAY_IMAGE_TAG}" >/dev/null
}

wait_for_health() {
  log 'Verificando healthz/readyz…'
  local attempt=0
  until docker exec "$GATEWAY_CONTAINER" pabip-gatewayctl \
    --admin-url "http://127.0.0.1:${ADMIN_PORT}" \
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
Container do gateway:     $GATEWAY_CONTAINER (porta $GATEWAY_PUBLIC_PORT publicada; $ADMIN_PORT fica só interna, de propósito)

O admin-api (porta $ADMIN_PORT) só é alcançável de dentro do container —
todo comando abaixo passa por 'docker exec'. Substitua \$TOKEN pelo token
acima.

Próximos passos:
  1. Cadastrar o primeiro Ente Privado:
     docker exec $GATEWAY_CONTAINER pabip-gatewayctl --token "\$TOKEN" peers create --name ... --base-url ... --their-api-key ... --scope plate:write
  2. Emitir um client token, se houver frontend consumindo /peers/*:
     docker exec $GATEWAY_CONTAINER pabip-gatewayctl --token "\$TOKEN" client-tokens issue --label ...
  3. Apontar seu coletor de logs pro stdout do container.
  4. Configurar backup do Postgres que esta instância usa.
  5. Ligar métricas (GET /metrics, porta admin, via docker exec ou um túnel) a um painel/alerta.
  6. Ver a configuração completa (o que foi gerado + o que ainda está no
     valor padrão) e ajustar o que quiser sem reiniciar:
     docker exec $GATEWAY_CONTAINER pabip-gatewayctl --token "\$TOKEN" config get
  7. Agendar a primeira rotação do admin token.

Cada comando aceita --help pra ver todas as opções.
EOF
}

main() {
  precheck
  gather_ente_publico
  gather_database
  gather_network
  gather_output
  gather_audit
  gather_logging
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
