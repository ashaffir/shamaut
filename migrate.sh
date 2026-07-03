#!/usr/bin/env bash
set -euo pipefail

# First-time Ubuntu deployment for the shamaut.com WordPress stack.
# Optional environment variables:
#   DOMAIN=shamaut.com
#   CERTBOT_DOMAINS=shamaut.com,www.shamaut.com
#   LETSENCRYPT_EMAIL=alfreds@actappon.com
#   ISSUE_CERT=1              # set to 0 to keep the temporary certificate
#   CERTBOT_STAGING=0         # set to 1 to use Let's Encrypt staging
#   INSTALL_DOCKER=1          # set to 0 to require Docker to already exist
#   PROJECT_NAME=shamaut

DOMAIN="${DOMAIN:-shamaut.com}"
CERTBOT_DOMAINS="${CERTBOT_DOMAINS:-shamaut.com,www.shamaut.com}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-alfreds@actappon.com}"
ISSUE_CERT="${ISSUE_CERT:-1}"
CERTBOT_STAGING="${CERTBOT_STAGING:-0}"
INSTALL_DOCKER="${INSTALL_DOCKER:-1}"
PROJECT_NAME="${PROJECT_NAME:-shamaut}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
CERTBOT_DIR="$SCRIPT_DIR/certbot"
CERT_LIVE_DIR="$CERTBOT_DIR/conf/live/$DOMAIN"
TEMP_CERT_MARKER="$CERT_LIVE_DIR/.temporary-self-signed"
RENEWAL_CRON="/etc/cron.d/shamaut-cert-renewal"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || {
    echo "ERROR: sudo is required when not running as root." >&2
    exit 1
  }
  SUDO=(sudo)
fi

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

as_root() {
  "${SUDO[@]}" "$@"
}

docker_cmd() {
  as_root docker "$@"
}

compose() {
  if docker_cmd compose version >/dev/null 2>&1; then
    docker_cmd compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    as_root docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
  else
    die "Docker Compose is not installed."
  fi
}

require_project_files() {
  [[ -f "$COMPOSE_FILE" ]] || die "Cannot find $COMPOSE_FILE"
  [[ -f "$SCRIPT_DIR/nginx/default.conf" ]] || die "Cannot find nginx/default.conf"
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
    if docker_cmd compose version >/dev/null 2>&1; then
      log "Docker and Docker Compose are already available."
      return
    fi
  fi

  [[ "$INSTALL_DOCKER" == "1" ]] || die "Docker Compose is missing and INSTALL_DOCKER=0."
  [[ -f /etc/os-release ]] || die "Cannot detect Linux distribution."

  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script is intended for Ubuntu. Detected: ${PRETTY_NAME:-unknown}"

  log "Installing Docker Engine and Compose plugin."
  as_root apt-get update
  as_root apt-get install -y ca-certificates curl gnupg lsb-release openssl cron
  as_root install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | as_root gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi

  as_root chmod a+r /etc/apt/keyrings/docker.gpg

  local codename arch
  codename="${VERSION_CODENAME:-$(lsb_release -cs)}"
  arch="$(dpkg --print-architecture)"

  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "$codename" \
    | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null

  as_root apt-get update
  as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  as_root systemctl enable --now docker

  docker_cmd compose version >/dev/null 2>&1 || die "Docker Compose plugin installation failed."
}

prepare_directories() {
  log "Preparing project directories."
  mkdir -p "$CERTBOT_DIR/conf" "$CERTBOT_DIR/www" "$SCRIPT_DIR/nginx/logs"
  chmod 755 "$CERTBOT_DIR" "$CERTBOT_DIR/conf" "$CERTBOT_DIR/www" "$SCRIPT_DIR/nginx/logs"
}

create_temporary_certificate_if_needed() {
  if [[ -s "$CERT_LIVE_DIR/fullchain.pem" && -s "$CERT_LIVE_DIR/privkey.pem" ]]; then
    log "Certificate files already exist for $DOMAIN."
    return
  fi

  log "Creating a temporary self-signed certificate so Nginx can start."
  mkdir -p "$CERT_LIVE_DIR"
  openssl req -x509 -nodes -days 7 -newkey rsa:2048 \
    -keyout "$CERT_LIVE_DIR/privkey.pem" \
    -out "$CERT_LIVE_DIR/fullchain.pem" \
    -subj "/CN=$DOMAIN" >/dev/null 2>&1
  touch "$TEMP_CERT_MARKER"
}

open_firewall_if_needed() {
  if command -v ufw >/dev/null 2>&1 && as_root ufw status | grep -q "Status: active"; then
    log "Opening HTTP and HTTPS in ufw."
    as_root ufw allow 80/tcp
    as_root ufw allow 443/tcp
  fi
}

certbot_domain_args() {
  local domain
  IFS=',' read -r -a domains <<< "$CERTBOT_DOMAINS"
  for domain in "${domains[@]}"; do
    domain="${domain//[[:space:]]/}"
    [[ -n "$domain" ]] && printf '%s\n%s\n' "-d" "$domain"
  done
}

issue_or_renew_certificate() {
  [[ "$ISSUE_CERT" == "1" ]] || {
    log "Skipping Let's Encrypt issuance because ISSUE_CERT=0."
    return
  }

  mapfile -t domain_args < <(certbot_domain_args)
  [[ "${#domain_args[@]}" -gt 0 ]] || die "CERTBOT_DOMAINS must contain at least one domain."

  local staging_args=()
  if [[ "$CERTBOT_STAGING" == "1" ]]; then
    staging_args=(--staging)
  fi

  if [[ -f "$TEMP_CERT_MARKER" ]]; then
    local backup_dir
    backup_dir="$CERTBOT_DIR/conf/live/${DOMAIN}.temporary.$(date +%s)"

    log "Requesting a real Let's Encrypt certificate for $CERTBOT_DOMAINS."
    mv "$CERT_LIVE_DIR" "$backup_dir"

    if compose exec -T certbot certbot certonly \
      --webroot \
      --webroot-path=/var/www/certbot \
      --email "$LETSENCRYPT_EMAIL" \
      --agree-tos \
      --no-eff-email \
      --non-interactive \
      --cert-name "$DOMAIN" \
      "${domain_args[@]}" \
      "${staging_args[@]}"; then
      rm -rf "$backup_dir"
      compose exec -T nginx nginx -s reload
      log "Let's Encrypt certificate installed and Nginx reloaded."
    else
      log "Let's Encrypt issuance failed. Restoring the temporary certificate."
      rm -rf "$CERT_LIVE_DIR"
      mv "$backup_dir" "$CERT_LIVE_DIR"
      compose exec -T nginx nginx -s reload >/dev/null 2>&1 || true
      die "Certificate issuance failed. Check DNS for $CERTBOT_DOMAINS and make sure ports 80/443 reach this server."
    fi
  else
    log "Renewing existing Let's Encrypt certificates if needed."
    compose exec -T certbot certbot renew --quiet
    compose exec -T nginx nginx -s reload
  fi
}

install_renewal_cron() {
  local quoted_dir
  quoted_dir="$(printf '%q' "$SCRIPT_DIR")"

  log "Installing certificate renewal cron job."
  chmod +x "$SCRIPT_DIR/renew-certs.sh"
  {
    echo "SHELL=/bin/bash"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "0 3,15 * * * root cd $quoted_dir && ./renew-certs.sh >> /var/log/cert-renewal.log 2>&1"
  } | as_root tee "$RENEWAL_CRON" >/dev/null
  as_root chmod 644 "$RENEWAL_CRON"
  as_root systemctl enable --now cron >/dev/null 2>&1 || true
}

main() {
  cd "$SCRIPT_DIR"
  require_project_files
  install_docker_if_needed
  prepare_directories
  create_temporary_certificate_if_needed
  open_firewall_if_needed

  log "Pulling container images."
  compose pull

  log "Starting the WordPress, MySQL, Nginx, and Certbot containers."
  compose up -d

  issue_or_renew_certificate
  install_renewal_cron

  log "Deployment status:"
  compose ps

  log "Done. Once DNS points here, the site should be available at https://$DOMAIN"
}

main "$@"
