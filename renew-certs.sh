#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-shamaut}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

docker_cmd() {
  "${SUDO[@]}" docker "$@"
}

compose() {
  if docker_cmd compose version >/dev/null 2>&1; then
    docker_cmd compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    "${SUDO[@]}" docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
  else
    echo "Docker Compose is not installed." >&2
    exit 1
  fi
}

echo "Checking for certificate renewal..."
if compose exec -T certbot certbot renew --quiet; then
  echo "Reloading nginx..."
  compose exec -T nginx nginx -s reload
  echo "Done!"
else
  echo "Certificate renewal failed!" >&2
  exit 1
fi
