#!/bin/sh
# Nabu installer: writes .env (generating the secret key and the database password), pulls the
# published image, starts the stack, waits for health and prints the URL.
# Safe to re-run: an existing .env is kept and only empty secrets are filled in.
#
# Fetch it from the release assets or from a clone of this repository, read it, then run it:
#   ./install.sh
set -eu

cd "$(dirname "$0")"

say()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'xx  %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine first."
docker compose version >/dev/null 2>&1 || die "docker compose v2 not found. Install the Compose plugin."

# docker-compose.yml uses the optional env_file form, which needs Compose 2.24 or newer.
compose_version="$(docker compose version --short 2>/dev/null || true)"
compose_version="${compose_version#v}"
cv_major="${compose_version%%.*}"
cv_rest="${compose_version#*.}"
cv_minor="${cv_rest%%.*}"
case "${cv_major}${cv_minor}" in
  ''|*[!0-9]*) warn "Could not read the Docker Compose version ('${compose_version}'); continuing." ;;
  *)
    if [ "$cv_major" -lt 2 ] || { [ "$cv_major" -eq 2 ] && [ "$cv_minor" -lt 24 ]; }; then
      die "Docker Compose ${compose_version} is too old; 2.24 or newer is required."
    fi
    ;;
esac

# When the script was downloaded on its own, fetch the files it needs next to it: the compose
# file from the latest release, the example configuration from the repository.
fetch() {
  command -v curl >/dev/null 2>&1 || die "$1 is missing and curl is not installed. Download it from $2 into this directory."
  say "Downloading $1"
  curl -fsSL -o "$1" "$2" || die "could not download $2"
}
[ -f docker-compose.yml ] || fetch docker-compose.yml "https://github.com/Root-Chain-Ventures-LLC/RCV-Nabu/releases/latest/download/docker-compose.yml"
if [ ! -f .env ] && [ ! -f .env.example ]; then
  fetch .env.example "https://raw.githubusercontent.com/Root-Chain-Ventures-LLC/RCV-Nabu/main/.env.example"
fi

# Random hex of N bytes. openssl is preferred; /dev/urandom is the fallback.
rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# Value of KEY in .env: the last assignment, surrounding quotes and spaces removed.
env_get() {
  line="$(grep -E "^[[:space:]]*$1=" .env | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%%#*}"
  printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# Set KEY=VALUE in .env, replacing an existing line or appending one. VALUE is generated hex:
# it never contains '|', '&' or a backslash.
env_set() {
  if grep -qE "^$1=" .env; then
    tmp=".env.tmp.$$"
    sed "s|^$1=.*|$1=$2|" .env > "$tmp"
    cat "$tmp" > .env
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}

if [ -f .env ]; then
  say "Using the existing .env (delete it to start over)."
else
  say "Writing .env from .env.example"
  cp .env.example .env
fi
chmod 600 .env

generated_key=0
if [ -z "$(env_get NABU_SECRET_KEY)" ] && [ -z "$(env_get NABU_SECRET_KEY_FILE)" ]; then
  env_set NABU_SECRET_KEY "$(rand_hex 32)"
  generated_key=1
  say "Generated NABU_SECRET_KEY in .env"
fi
if [ -z "$(env_get NABU_DB_PASSWORD)" ]; then
  env_set NABU_DB_PASSWORD "$(rand_hex 24)"
  say "Generated NABU_DB_PASSWORD in .env"
fi

BASE_URL="$(env_get BASE_URL)"
NABU_PORT="$(env_get NABU_PORT)"
NABU_PORT="${NABU_PORT:-8080}"
NABU_BIND="$(env_get NABU_BIND)"
NABU_BIND="${NABU_BIND:-127.0.0.1}"
ALLOW_INSECURE_BASE_URL="$(env_get ALLOW_INSECURE_BASE_URL)"
NABU_VERSION="$(env_get NABU_VERSION)"
SETUP_TOKEN="$(env_get SETUP_TOKEN)"

[ -n "$BASE_URL" ] || die "BASE_URL is not set in .env"

case "$BASE_URL" in
  https://*) ;;
  *)
    if [ "$ALLOW_INSECURE_BASE_URL" != "true" ]; then
      die "BASE_URL must start with https:// (the server refuses to start otherwise). Edit .env, or set ALLOW_INSECURE_BASE_URL=true for a local trial, then re-run."
    fi
    warn "BASE_URL is not https:// and ALLOW_INSECURE_BASE_URL=true: acceptable for a local trial only."
    ;;
esac

case "$BASE_URL" in
  *example.com*)
    warn "BASE_URL still contains example.com. Sign-in links, email links and SSO redirects will point there."
    warn "Edit .env and re-run ./install.sh once you know the real hostname."
    ;;
esac

say "Pulling ghcr.io/root-chain-ventures-llc/nabu:${NABU_VERSION:-latest}"
docker compose pull

say "Starting"
docker compose up -d

say "Waiting for health"
# /api/health is answered over plain HTTP on the published port, so this probe needs no
# certificate handling even though the public URL is HTTPS. It needs the port published on
# this host (the default is loopback).
probe_host="$NABU_BIND"
case "$probe_host" in 0.0.0.0|'') probe_host=127.0.0.1 ;; esac
healthy=0
i=0
while [ "$i" -lt 60 ]; do
  i=$((i + 1))
  if curl -fsS --max-time 3 "http://${probe_host}:${NABU_PORT}/api/health" >/dev/null 2>&1; then
    say "Healthy after ${i} attempt(s)."
    healthy=1
    break
  fi
  sleep 2
done
if [ "$healthy" != 1 ]; then
  warn "Never came up. Recent logs:"
  docker compose logs --tail 40 app >&2 || true
  die "Health check failed at http://${probe_host}:${NABU_PORT}/api/health"
fi

echo
say "Nabu is running at ${BASE_URL}"
say "On this host (plain HTTP, for a quick check): http://${probe_host}:${NABU_PORT}"
echo
say "First run: open ${BASE_URL%/} and create the first administrator account."
if [ -n "$SETUP_TOKEN" ]; then
  say "SETUP_TOKEN is set in .env: enter its value in the extra field on the setup page."
else
  say "If no SETUP_TOKEN is set, Nabu prints a one-time setup token in its log until the first"
  say "administrator exists: docker compose logs app"
fi

if [ "$generated_key" = 1 ]; then
  echo
  warn "A new NABU_SECRET_KEY was written to .env. Back it up somewhere safe, separately from"
  warn "the database backups: without it every file and every credential saved in Settings is"
  warn "unrecoverable."
fi
echo
say "Nabu speaks plain HTTP. Put a reverse proxy that terminates TLS in front of it, and set"
say "TRUST_PROXY in .env (keep NABU_BIND=127.0.0.1 if the proxy runs on this host)."
