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
#
# Cores/spinner são desligados automaticamente se a saída não for um
# terminal (ex.: redirecionada pra arquivo/CI) ou se NO_COLOR estiver
# definido — nesse caso o script cai pra texto liso, sem animação.
set -euo pipefail

IMAGE_REPO='public.ecr.aws/x8o6o1x8/pabip-gateway'
GATEWAY_CONTAINER='pabip-gateway'
POSTGRES_CONTAINER='pabip-postgres'
POSTGRES_VOLUME='pabip-gateway-postgres-data'
ENV_FILE='pabip-gateway.env'
ADMIN_PORT=8081

# ---------- estilo ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  USE_COLOR=1
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_MAGENTA=$'\033[35m'
else
  USE_COLOR=0
  C_RESET='' C_DIM='' C_BOLD='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_MAGENTA=''
fi

ICON_OK='✅'
ICON_ERR='❌'
ICON_WARN='⚠️'
ICON_ARROW='❯'

STEP_TOTAL=7
STEP_CURRENT=0

SPIN_LOG="$(mktemp)"
cleanup() { rm -f "$SPIN_LOG"; }
trap cleanup EXIT

log() { printf '\n%s%s%s %s\n' "${C_CYAN}${C_BOLD}" "$ICON_ARROW" "$C_RESET" "$1"; }
ok() { printf '%s%s%s %s\n' "$C_GREEN" "$ICON_OK" "$C_RESET" "$1"; }
warn() { printf '%s%s%s %s\n' "$C_YELLOW" "$ICON_WARN" "$C_RESET" "$1" >&2; }
die() {
  printf '%s%s%s %s\n' "$C_RED" "$ICON_ERR" "$C_RESET" "$1" >&2
  exit 1
}

# Repete um caractere (possivelmente multibyte, ex. box-drawing) N vezes —
# `tr` corrompe caracteres UTF-8 de múltiplos bytes, por isso não usamos ele
# aqui pra desenhar bordas.
repeat_char() {
  local ch="$1" count="$2" out='' i=0
  while [ "$i" -lt "$count" ]; do
    out+="$ch"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

banner() {
  local -a art=(
    ' _____        ____ _____ _____  '
    '|  __ \ /\   |  _ \_   _|  __ \ '
    '| |__) /  \  | |_) || | | |__) |'
    '|  ___/ /\ \ |  _ < | | |  ___/ '
    '| |  / ____ \| |_) || |_| |     '
    '|_| /_/    \_\____/_____|_|     '
  )
  local line
  printf '\n'
  for line in "${art[@]}"; do
    printf '%s%s%s\n' "$C_MAGENTA$C_BOLD" "$line" "$C_RESET"
  done
  printf '%s        G A T E W A Y%s\n' "$C_CYAN$C_BOLD" "$C_RESET"
  printf '\n🚀 %sinstalador de primeiro boot — protocolo PABIP%s\n' "$C_DIM" "$C_RESET"
}

# Cabeçalho de cada pergunta do wizard, numerado — dá pra saber quanto falta.
step() {
  STEP_CURRENT=$((STEP_CURRENT + 1))
  printf '\n%s┄┄┄ Passo %d/%d ┄┄┄%s %s%s%s\n' "$C_DIM" "$STEP_CURRENT" "$STEP_TOTAL" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
}

# Cabeçalho de seção fora do wizard (fase de aplicar, resumo final).
section() {
  printf '\n%s── %s ──%s\n' "${C_DIM}${C_BOLD}" "$1" "$C_RESET"
}

# Reads one line from the real terminal even when this script's own stdin is
# curl's pipe (curl | bash) rather than an interactive shell.
tty_read() {
  local __var="$1" __label="$2" __default="${3:-}" __tty_read_value __prompt
  if [ -n "$__default" ]; then
    __prompt="${C_GREEN}${C_BOLD}${ICON_ARROW}${C_RESET} ${__label} ${C_DIM}(${__default})${C_RESET}: "
  else
    __prompt="${C_GREEN}${C_BOLD}${ICON_ARROW}${C_RESET} ${__label}: "
  fi
  if [ -r /dev/tty ]; then
    read -r -p "$__prompt" __tty_read_value </dev/tty
  else
    read -r -p "$__prompt" __tty_read_value
  fi
  [ -z "$__tty_read_value" ] && __tty_read_value="$__default"
  printf -v "$__var" '%s' "$__tty_read_value"
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
  tty_read __reply "$__prompt ${C_DIM}($__hint)${C_RESET}" "$__default"
  case "$__reply" in
  s | S | sim | y | Y | yes) return 0 ;;
  *) return 1 ;;
  esac
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$1"
}

# Roda um comando em background com um spinner animado na frente da
# mensagem; sem tty/cor, cai pra "mensagem... ok/falhou" sem animação.
spin() {
  local msg="$1"
  shift
  if [ "$USE_COLOR" -ne 1 ]; then
    printf '%s ' "$msg"
    if "$@" >"$SPIN_LOG" 2>&1; then
      printf 'ok\n'
      return 0
    else
      printf 'falhou\n'
      cat "$SPIN_LOG" >&2
      return 1
    fi
  fi

  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local n=${#frames[@]} i=0 rc=0

  "$@" >"$SPIN_LOG" 2>&1 &
  local pid=$!
  printf '%s%s%s %s' "$C_CYAN" "${frames[0]}" "$C_RESET" "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$(((i + 1) % n))
    printf '\r\033[K%s%s%s %s' "$C_CYAN" "${frames[$i]}" "$C_RESET" "$msg"
  done
  wait "$pid" || rc=$?

  if [ "$rc" -eq 0 ]; then
    printf '\r\033[K%s%s%s %s\n' "$C_GREEN" "$ICON_OK" "$C_RESET" "$msg"
  else
    printf '\r\033[K%s%s%s %s\n' "$C_RED" "$ICON_ERR" "$C_RESET" "$msg"
    cat "$SPIN_LOG" >&2
  fi
  return "$rc"
}

# Igual ao spin(), mas pra polling: repete a checagem $fn até ela passar,
# até $max tentativas, dormindo $interval segundos entre elas.
spin_until() {
  local msg="$1" fn="$2" max="$3" interval="${4:-2}" attempt=0

  if [ "$USE_COLOR" -ne 1 ]; then
    printf '%s ' "$msg"
    while ! "$fn"; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge "$max" ]; then
        printf 'falhou\n'
        return 1
      fi
      sleep "$interval"
    done
    printf 'ok\n'
    return 0
  fi

  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local n=${#frames[@]} i=0
  printf '%s%s%s %s' "$C_CYAN" "${frames[0]}" "$C_RESET" "$msg"
  while ! "$fn"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max" ]; then
      printf '\r\033[K%s%s%s %s\n' "$C_RED" "$ICON_ERR" "$C_RESET" "$msg"
      return 1
    fi
    i=$(((i + 1) % n))
    printf '\r\033[K%s%s%s %s' "$C_CYAN" "${frames[$i]}" "$C_RESET" "$msg"
    sleep "$interval"
  done
  printf '\r\033[K%s%s%s %s\n' "$C_GREEN" "$ICON_OK" "$C_RESET" "$msg"
  return 0
}

precheck() {
  command -v docker >/dev/null 2>&1 || die 'docker não encontrado no PATH. Instale o Docker Engine antes de continuar.'
  docker info >/dev/null 2>&1 || die 'não foi possível falar com o daemon do Docker — ele está rodando e acessível pro seu usuário?'
  command -v openssl >/dev/null 2>&1 || die 'openssl não encontrado no PATH (necessário pra gerar o admin token/senha).'

  if container_exists "$GATEWAY_CONTAINER"; then
    die "já existe um container '$GATEWAY_CONTAINER' — este script é só pra primeiro boot. Para operar uma instância existente, use 'docker exec $GATEWAY_CONTAINER pabip-gatewayctl ...'; pra recriar, remova o container antigo você mesmo primeiro."
  fi

  ok '🐳 Docker e openssl disponíveis — pronto pra começar.'
}

gather_ente_publico() {
  step '🏛️  Nome do Ente Público'
  tty_read_required GATEWAY_ENTE_PUBLICO_NAME 'Nome do Ente Público (identidade fixa desta instância, não muda fácil depois)'
}

gather_database() {
  step '🗄️  Banco de dados'
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
  step '🌐 Rede'
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
  step '📬 Entrega dos eventos'
  printf '%sPara onde o gateway entrega os eventos recebidos?%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s1)%s 🔗 callback — webhook HTTP %s(padrão)%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '  %s2)%s 📨 queue    — RabbitMQ/Kafka/SQS/Redis Streams\n' "$C_CYAN" "$C_RESET"
  printf '  %s3)%s 🗃️  db       — grava direto numa tabela de destino\n' "$C_CYAN" "$C_RESET"
  printf '  %s4)%s ⏭️  decidir depois %s(toda entrega fica rejeitada até configurar)%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
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
  step '📝 Auditoria'
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
  step '📋 Log'
  LOG_LEVEL='info'
  tty_read LOG_LEVEL 'Nível de log (trace/debug/info/warn/error/fatal/silent)' "$LOG_LEVEL"
  case "$LOG_LEVEL" in
  trace | debug | info | warn | error | fatal | silent) ;;
  *) die "nível de log inválido: '$LOG_LEVEL'." ;;
  esac
}

gather_image_tag() {
  step '🏷️  Imagem'
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
  ok "🧾 Configuração gravada em $ENV_FILE"
}

pg_ready() {
  docker exec "$POSTGRES_CONTAINER" pg_isready -U gateway -d gateway >/dev/null 2>&1
}

start_local_postgres() {
  [ "$USE_LOCAL_POSTGRES" -eq 1 ] || return 0
  spin "🐘 Subindo Postgres local…" docker run -d \
    --name "$POSTGRES_CONTAINER" \
    -p 5432:5432 \
    -e POSTGRES_USER=gateway \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -e POSTGRES_DB=gateway \
    -v "${POSTGRES_VOLUME}:/var/lib/postgresql/data" \
    --restart unless-stopped \
    postgres:16-alpine || die 'não foi possível subir o Postgres local — veja o log acima.'

  spin_until '⏳ Aguardando o Postgres aceitar conexões…' pg_ready 15 2 \
    || die "Postgres não ficou pronto a tempo — veja 'docker logs $POSTGRES_CONTAINER'."
}

pull_image() {
  spin "📦 Baixando a imagem…" docker pull "${IMAGE_REPO}:${GATEWAY_IMAGE_TAG}" \
    || die 'falha ao baixar a imagem — veja o log acima.'
}

run_migration() {
  spin '🗄️  Rodando migrações…' docker run --rm \
    --env-file "$ENV_FILE" \
    --add-host=host.docker.internal:host-gateway \
    "${IMAGE_REPO}:${GATEWAY_IMAGE_TAG}" \
    migrate-only \
    || die 'falha ao migrar o banco — veja o log acima.'
}

start_gateway() {
  # A porta admin (8081) nunca é publicada pro host — de propósito, é assim
  # que a autenticação administrativa foi desenhada pra funcionar com
  # segurança (ver `docker exec` nos passos abaixo pra alcançá-la).
  spin "🚀 Subindo o gateway…" docker run -d \
    --name "$GATEWAY_CONTAINER" \
    --env-file "$ENV_FILE" \
    --add-host=host.docker.internal:host-gateway \
    -p "${GATEWAY_PUBLIC_PORT}:${GATEWAY_PUBLIC_PORT}" \
    --restart unless-stopped \
    "${IMAGE_REPO}:${GATEWAY_IMAGE_TAG}" \
    || die 'falha ao subir o container do gateway — veja o log acima.'
}

gateway_healthy() {
  docker exec "$GATEWAY_CONTAINER" pabip-gatewayctl \
    --admin-url "http://127.0.0.1:${ADMIN_PORT}" \
    health check >/dev/null 2>&1
}

wait_for_health() {
  if ! spin_until '🩺 Verificando saúde da instância…' gateway_healthy 15 2; then
    warn 'a instância não respondeu saudável a tempo. Últimas linhas de log:'
    docker logs --tail 50 "$GATEWAY_CONTAINER" >&2 || true
    die 'health check falhou — investigue o log acima antes de considerar a instância no ar.'
  fi
}

gather_first_peer() {
  tty_read_required PEER_NAME 'Nome do Ente Privado'
  tty_read_required PEER_BASE_URL "URL base do Ente Privado (a URL dele, não a do admin-api)"
  tty_read_required PEER_THEIR_API_KEY 'API key que o Ente Privado te passou por fora de banda'

  printf '%sQuais escopos esse peer vai usar?%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s1)%s 🚗 plate:write %s(padrão)%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '  %s2)%s 👤 face:write\n' "$C_CYAN" "$C_RESET"
  printf '  %s3)%s 🚗👤 plate:write e face:write\n' "$C_CYAN" "$C_RESET"
  local choice=''
  while true; do
    tty_read choice 'Escolha' '1'
    case "$choice" in
    1) PEER_SCOPE_ARGS=(plate:write) && break ;;
    2) PEER_SCOPE_ARGS=(face:write) && break ;;
    3) PEER_SCOPE_ARGS=(plate:write face:write) && break ;;
    *) warn 'escolha inválida.' ;;
    esac
  done

  PEER_IP_ALLOWLIST_ARGS=()
  if tty_confirm 'Restringir esse peer a IPs/CIDRs específicos?'; then
    local raw=''
    tty_read_required raw 'IPs/CIDRs separados por vírgula'
    IFS=', ' read -ra PEER_IP_ALLOWLIST_ARGS <<<"$raw"
  fi
}

create_first_peer() {
  local -a cmd=(
    docker exec "$GATEWAY_CONTAINER" pabip-gatewayctl --token "$ADMIN_TOKEN" peers create
    --name "$PEER_NAME" --base-url "$PEER_BASE_URL" --their-api-key "$PEER_THEIR_API_KEY"
    --scope "${PEER_SCOPE_ARGS[@]}"
  )
  [ "${#PEER_IP_ALLOWLIST_ARGS[@]}" -gt 0 ] && cmd+=(--ip-allowlist "${PEER_IP_ALLOWLIST_ARGS[@]}")

  # peers create chama de volta o /sensor-nodes do próprio peer pra validar a
  # theirApiKey antes de confirmar o cadastro — pode levar alguns segundos.
  if ! spin "📇 Cadastrando \"$PEER_NAME\" (valida o manifesto dele antes de confirmar)…" "${cmd[@]}"; then
    return 1
  fi

  PEER_ISSUED_API_KEY="$(sed -n 's/^ *"issuedApiKey": *"\(.*\)"$/\1/p' "$SPIN_LOG")"
  if [ -z "$PEER_ISSUED_API_KEY" ]; then
    warn 'peer cadastrado, mas não consegui extrair a API key emitida da resposta — confira manualmente:'
    cat "$SPIN_LOG"
  fi
}

print_peer_key_box() {
  [ -n "$PEER_ISSUED_API_KEY" ] || return 0
  local key_line="  ${PEER_ISSUED_API_KEY}  "
  local border
  border=$(repeat_char '─' "${#key_line}")
  printf '\n🔑 %sAPI key emitida pro peer "%s" — única vez que aparece, guarde no gerenciador de segredos AGORA:%s\n' \
    "$C_YELLOW$C_BOLD" "$PEER_NAME" "$C_RESET"
  printf '%s┌%s┐%s\n' "$C_YELLOW" "$border" "$C_RESET"
  printf '%s│%s%s%s%s│%s\n' "$C_YELLOW" "$C_RESET$C_BOLD" "$key_line" "$C_RESET" "$C_YELLOW" "$C_RESET"
  printf '%s└%s┘%s\n' "$C_YELLOW" "$border" "$C_RESET"
}

offer_first_peer() {
  PEER_CREATED=0
  section '🤝 Primeiro peer'
  tty_confirm 'Quer cadastrar o primeiro Ente Privado (peer) agora?' 's' || return 0

  while true; do
    gather_first_peer
    if create_first_peer; then
      PEER_CREATED=1
      ok "Peer \"$PEER_NAME\" cadastrado."
      print_peer_key_box
      break
    fi
    tty_confirm 'Tentar de novo com outros dados?' 's' || {
      warn 'seguindo sem cadastrar o peer agora — dá pra fazer isso depois (ver "Próximos passos" no resumo).'
      break
    }
  done
}

print_summary() {
  printf '\n%s%s Instância no ar.%s\n' "$C_GREEN$C_BOLD" "$ICON_OK" "$C_RESET"

  local token_line="  ${ADMIN_TOKEN}  "
  local border
  border=$(repeat_char '─' "${#token_line}")
  printf '\n🔑 %sAdmin token — única vez que aparece, guarde no gerenciador de segredos AGORA:%s\n' "$C_YELLOW$C_BOLD" "$C_RESET"
  printf '%s┌%s┐%s\n' "$C_YELLOW" "$border" "$C_RESET"
  printf '%s│%s%s%s%s│%s\n' "$C_YELLOW" "$C_RESET$C_BOLD" "$token_line" "$C_RESET" "$C_YELLOW" "$C_RESET"
  printf '%s└%s┘%s\n' "$C_YELLOW" "$border" "$C_RESET"

  section '🗂️  Arquivos e containers'
  printf '  Config:   %s\n' "$ENV_FILE"
  printf '  Gateway:  %s %s(porta pública %s; admin %s só interna, de propósito)%s\n' \
    "$GATEWAY_CONTAINER" "$C_DIM" "$GATEWAY_PUBLIC_PORT" "$ADMIN_PORT" "$C_RESET"

  printf '\n%sO admin-api (porta %s) só é alcançável de dentro do container — todo comando abaixo passa por %sdocker exec%s. Substitua %s$TOKEN%s pelo token acima.%s\n' \
    "$C_DIM" "$ADMIN_PORT" "$C_BOLD" "$C_RESET$C_DIM" "$C_BOLD" "$C_RESET$C_DIM" "$C_RESET"

  section '👉 Próximos passos'
  local peer_step
  if [ "$PEER_CREATED" -eq 1 ]; then
    peer_step='Ente Privado "'"$PEER_NAME"'" já cadastrado ✅. Pra adicionar outro:\n     docker exec '"$GATEWAY_CONTAINER"' pabip-gatewayctl --token "$TOKEN" peers create --name ... --base-url ... --their-api-key ... --scope plate:write'
  else
    peer_step='Cadastrar o primeiro Ente Privado:\n     docker exec '"$GATEWAY_CONTAINER"' pabip-gatewayctl --token "$TOKEN" peers create --name ... --base-url ... --their-api-key ... --scope plate:write'
  fi
  local -a steps=(
    "$peer_step"
    'Emitir um client token, se houver frontend consumindo /peers/*:\n     docker exec '"$GATEWAY_CONTAINER"' pabip-gatewayctl --token "$TOKEN" client-tokens issue --label ...'
    'Apontar seu coletor de logs pro stdout do container.'
    'Configurar backup do Postgres que esta instância usa.'
    'Ligar métricas (GET /metrics, porta admin, via docker exec ou um túnel) a um painel/alerta.'
    'Ver a configuração completa (o que foi gerado + o que ainda está no valor padrão) e ajustar o que quiser sem reiniciar:\n     docker exec '"$GATEWAY_CONTAINER"' pabip-gatewayctl --token "$TOKEN" config get'
    'Agendar a primeira rotação do admin token.'
  )
  local n=1 s
  for s in "${steps[@]}"; do
    printf "  %s%d.%s %b\n" "$C_CYAN$C_BOLD" "$n" "$C_RESET" "$s"
    n=$((n + 1))
  done

  printf '\n%sCada comando aceita --help pra ver todas as opções.%s\n' "$C_DIM" "$C_RESET"
}

main() {
  banner
  precheck
  gather_ente_publico
  gather_database
  gather_network
  gather_output
  gather_audit
  gather_logging
  gather_image_tag
  write_env_file
  section '⚙️  Aplicando'
  start_local_postgres
  pull_image
  run_migration
  start_gateway
  wait_for_health
  offer_first_peer
  print_summary
}

main "$@"
