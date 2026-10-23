#!/usr/bin/env bash
# Sobe o Portainer CE neste computador via Docker, sem Go/pnpm no host.
# Uso: ./dev/local.sh [up|down|rebuild|rebuild-server|rebuild-client|logs|status|reset]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT/dev/docker-compose.yml"
DIST_DIR="$ROOT/dist"

GO_IMAGE="${PORTAINER_GO_IMAGE:-golang:1.26-bookworm}"
NODE_IMAGE="${PORTAINER_NODE_IMAGE:-node:22-bookworm}"
PNPM_VERSION="${PORTAINER_PNPM_VERSION:-10.26.2}"
BASE_IMAGE="${PORTAINER_BASE_IMAGE:-portainer/base}"

GO_MOD_VOLUME="portainer-local-go-mod"
GO_CACHE_VOLUME="portainer-local-go-cache"
PNPM_STORE_VOLUME="portainer-local-pnpm-store"
NODE_MODULES_VOLUME="portainer-local-node-modules"

HTTP_PORT="${PORTAINER_HTTP_PORT:-9000}"
HTTPS_PORT="${PORTAINER_HTTPS_PORT:-9443}"
EDGE_PORT="${PORTAINER_EDGE_PORT:-8000}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log() { printf "${CYAN}==>${NC} %s\n" "$*"; }
ok() { printf "${GREEN}OK${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}AVISO${NC} %s\n" "$*"; }
die() { printf "${RED}ERRO${NC} %s\n" "$*" >&2; exit 1; }

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker não encontrado no PATH."
  docker info >/dev/null 2>&1 || die "O daemon do Docker não está acessível. Verifique se o serviço está rodando e se o usuário pertence ao grupo docker."
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin não encontrado."
}

ensure_dist() {
  mkdir -p "$DIST_DIR"
}

copy_templates() {
  ensure_dist
  rm -rf "$DIST_DIR/mustache-templates"
  cp -a "$ROOT/mustache-templates" "$DIST_DIR/mustache-templates"
}

host_uid() { id -u; }
host_gid() { id -g; }

ensure_images() {
  local image
  for image in "$GO_IMAGE" "$NODE_IMAGE" "$BASE_IMAGE"; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      log "Baixando imagem $image"
      docker pull "$image"
    fi
  done
}

build_server() {
  need_docker
  ensure_images
  ensure_dist
  log "Compilando backend Go em $GO_IMAGE"
  docker run --rm \
    --user "0:0" \
    -e CGO_ENABLED=0 \
    -e GOOS=linux \
    -e GOFLAGS="-buildvcs=false" \
    -e GOPATH=/go \
    -e GOCACHE=/go-cache \
    -e GOMODCACHE=/go/pkg/mod \
    -v "$ROOT:/src" \
    -v "$GO_MOD_VOLUME:/go/pkg/mod" \
    -v "$GO_CACHE_VOLUME:/go-cache" \
    -w /src/api \
    "$GO_IMAGE" \
    bash -c "go build -trimpath -o /src/dist/portainer ./cmd/portainer/ && chown $(host_uid):$(host_gid) /src/dist/portainer"

  copy_templates
  [[ -x "$DIST_DIR/portainer" ]] || die "O binário dist/portainer não foi gerado."
  ok "Backend compilado em dist/portainer"
}

build_client() {
  need_docker
  ensure_images
  ensure_dist
  log "Compilando frontend (Node $NODE_IMAGE, pnpm $PNPM_VERSION)"
  docker run --rm \
    --user "0:0" \
    -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    -e NODE_ENV=development \
    -e NODE_OPTIONS="--max-old-space-size=4096" \
    -e PNPM_HOME=/pnpm \
    -e npm_config_store_dir=/pnpm/store \
    -v "$ROOT:/src" \
    -v "$PNPM_STORE_VOLUME:/pnpm/store" \
    -v "$NODE_MODULES_VOLUME:/src/node_modules" \
    -w /src \
    "$NODE_IMAGE" \
    bash -c "corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate && cp pnpm-lock.yaml /tmp/pnpm-lock.yaml.bak && pnpm install --no-frozen-lockfile && cp /tmp/pnpm-lock.yaml.bak pnpm-lock.yaml && pnpm run build --config webpack/webpack.development.js && chown -R $(host_uid):$(host_gid) /src/dist/public"

  [[ -f "$DIST_DIR/public/index.html" ]] || die "O frontend não gerou dist/public/index.html."
  ok "Frontend compilado em dist/public"
}

need_artifacts() {
  local missing=0
  if [[ ! -x "$DIST_DIR/portainer" ]]; then
    warn "Binário do servidor ausente."
    missing=1
  fi
  if [[ ! -f "$DIST_DIR/public/index.html" ]]; then
    warn "Assets do frontend ausentes."
    missing=1
  fi
  return "$missing"
}

build_if_needed() {
  ensure_images
  if [[ ! -x "$DIST_DIR/portainer" ]]; then
    build_server
  else
    copy_templates
    ok "Reusando binário existente em dist/portainer"
  fi
  if [[ ! -f "$DIST_DIR/public/index.html" ]]; then
    build_client
  else
    ok "Reusando frontend existente em dist/public"
  fi
}

wait_ready() {
  local url="http://127.0.0.1:${HTTP_PORT}/api/system/status"
  local i
  log "Aguardando o Portainer responder em $url"
  for i in $(seq 1 45); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      ok "Portainer pronto"
      return 0
    fi
    sleep 2
  done
  warn "O container subiu, mas /api/system/status ainda não respondeu. Veja: $0 logs"
}

print_urls() {
  cat <<EOF

${GREEN}Portainer local está no ar${NC}

  HTTP:   http://localhost:${HTTP_PORT}
  HTTPS:  https://localhost:${HTTPS_PORT}
  Edge:   ${EDGE_PORT} (túnel de agentes)

No primeiro acesso, crie o usuário administrador na UI.

Comandos úteis:
  $0 logs              # acompanhar logs
  $0 rebuild-server    # após alterar Go
  $0 rebuild-client    # após alterar React/Angular
  $0 rebuild           # rebuild completo + restart
  $0 down              # parar
  $0 reset             # parar e apagar o volume de dados

EOF
}

cmd_up() {
  need_docker
  build_if_needed
  log "Subindo container portainer-local"
  compose up -d --remove-orphans
  wait_ready
  print_urls
}

cmd_down() {
  need_docker
  log "Parando Portainer local"
  compose down --remove-orphans
  ok "Container parado (os dados em volume foram mantidos)"
}

cmd_rebuild() {
  need_docker
  build_server
  build_client
  log "Reiniciando container"
  compose up -d --force-recreate --remove-orphans
  wait_ready
  print_urls
}

cmd_rebuild_server() {
  need_docker
  build_server
  log "Reiniciando container para carregar o novo binário"
  compose up -d --force-recreate --remove-orphans
  wait_ready
  ok "Servidor atualizado"
}

cmd_rebuild_client() {
  need_docker
  build_client
  log "Recarregando o frontend no container"
  compose up -d --remove-orphans
  wait_ready
  ok "Frontend atualizado"
}

cmd_logs() {
  need_docker
  compose logs -f --tail=200 portainer
}

cmd_status() {
  need_docker
  echo
  compose ps
  echo
  if [[ -x "$DIST_DIR/portainer" ]]; then
    ok "dist/portainer presente"
  else
    warn "dist/portainer ausente — rode: $0 rebuild-server"
  fi
  if [[ -f "$DIST_DIR/public/index.html" ]]; then
    ok "dist/public presente"
  else
    warn "dist/public ausente — rode: $0 rebuild-client"
  fi
  echo
}

cmd_reset() {
  need_docker
  log "Parando e removendo o volume de dados do Portainer local"
  compose down --remove-orphans --volumes
  ok "Ambiente zerado. Suba de novo com: $0 up"
}

usage() {
  cat <<EOF
Uso: $0 <comando>

Sobe o Portainer CE neste computador usando só Docker.
O backend e o frontend são compilados dentro de containers
(golang:1.26 e node:22), então não é necessário instalar Go ou pnpm no host.

Comandos:
  up                 Compila o que faltar e sobe o container (padrão)
  down               Para o container (mantém os dados)
  rebuild            Recompila backend + frontend e reinicia
  rebuild-server     Recompila só o Go e reinicia
  rebuild-client     Recompila só o frontend e reinicia
  logs               Acompanha os logs
  status             Mostra container e artefatos
  reset              Para e apaga o volume de dados (/data)

Variáveis opcionais:
  PORTAINER_HTTP_PORT    porta HTTP (padrão 9000)
  PORTAINER_HTTPS_PORT   porta HTTPS (padrão 9443)
  PORTAINER_EDGE_PORT    porta do túnel Edge (padrão 8000)
  PORTAINER_GO_IMAGE     imagem para o build Go
  PORTAINER_NODE_IMAGE   imagem para o build do frontend

EOF
}

main() {
  local cmd="${1:-up}"
  case "$cmd" in
    up|start) cmd_up ;;
    down|stop) cmd_down ;;
    rebuild) cmd_rebuild ;;
    rebuild-server) cmd_rebuild_server ;;
    rebuild-client) cmd_rebuild_client ;;
    logs) cmd_logs ;;
    status) cmd_status ;;
    reset) cmd_reset ;;
    -h|--help|help) usage ;;
    *) die "Comando desconhecido: $cmd. Use --help." ;;
  esac
}

main "$@"
