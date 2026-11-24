#!/usr/bin/env bash

SECRETS_FILE="/etc/riskybit-secrets.gpg"
HOST_KEY_FILE="/etc/riskybit-host.key"
ENV_FILE="/etc/docker-app.env"

set -e
set -o pipefail
step="starting up"
on_err() { echo "Error: update failed while ${step} (exit $1) at line $2: $3" >&2; }
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

die() { echo "Error: $1" >&2; exit "${2:-1}"; }

# Helper to parse key=value lines into an associative array
parse_env() {
    local -n _arr=$1
    shift
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        # Trim leading/trailing whitespace or quotes if needed
        key=$(echo "$key" | xargs)
        val=$(echo "$val" | xargs)
        for target in "$@"; do
            if [[ "$key" == "$target" ]]; then
                _arr[$key]="$val"
            fi
        done
    done
}

dev=0
gpu=2
for a in "$@"; do
  case $a in
    --dev)  dev=1 ;;
    amd)    gpu=0 ;;
    nvidia) gpu=1 ;;
    null)   gpu=2 ;;
    *) die "unknown option: $a (supported: --dev, amd, nvidia, null)" 2 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
    die "this script must be run as root. Run it via the main script or with sudo."
fi

step="running pre-flight checks"
for cmd in docker git find sed grep gpg; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done
docker compose version >/dev/null 2>&1 \
    || die "the 'docker compose' plugin is not available. Install Docker Compose v2."
docker info >/dev/null 2>&1 \
    || die "cannot connect to the Docker daemon. Is it running, and do you have permission to use it?"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "'$(pwd)' is not inside a git repository. Run update from the project directory."
[ -d config ] || die "config directory not found in '$(pwd)'. Run this from the project directory."

step="checking setup configuration"
for f in "$SECRETS_FILE" "$HOST_KEY_FILE" "$ENV_FILE"; do
    [ -f "$f" ] || die "$f is missing. Please run the setup command first."
done

compose_files="-f ./docker-compose.yaml"
if [[ $gpu -eq 0 ]]; then
    compose_files="$compose_files -f ./compose.amd.yaml"
elif [[ $gpu -eq 1 ]]; then
    compose_files="$compose_files -f ./compose.nvidia.yaml"
fi

step="pulling Github commits"
echo "Pulling last Github commits..."
git fetch >/dev/null
git pull --ff-only >/dev/null \
    || die "git pull failed (local changes or diverged branch?). Resolve it manually and re-run update."

if [ $dev -eq 1 ]; then
    step="updating git submodules"
    echo "Updating git submodules..."
    git submodule sync --recursive >/dev/null
    git submodule update --init --recursive --remote >/dev/null
    git submodule foreach --recursive 'git switch main >/dev/null && git pull --ff-only >/dev/null'
fi

step="preparing config files"
echo "Preparing files for docker..."
trap - ERR; set +e
find config -type f -exec sh -c '
    for f; do
        grep -qI . "$f" && sed -i "s/\r$//" "$f"
    done
' sh {} +
set -e; trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

step="reading $ENV_FILE"
declare -A APP_ENV=()
parse_env APP_ENV ADMIN_EMAIL DOMAIN < "$ENV_FILE"
[ -n "${APP_ENV[ADMIN_EMAIL]:-}" ] || die "ADMIN_EMAIL is missing in $ENV_FILE. Re-run the setup command."
[ -n "${APP_ENV[DOMAIN]:-}" ]      || die "DOMAIN is missing in $ENV_FILE. Re-run the setup command."
ADMIN_EMAIL="${APP_ENV[ADMIN_EMAIL]}"
DOMAIN="${APP_ENV[DOMAIN]}"
export ADMIN_EMAIL DOMAIN

step="decrypting secrets"
if ! secrets_plain=$(gpg --batch --decrypt --passphrase-file "$HOST_KEY_FILE" "$SECRETS_FILE" 2>/dev/null); then
    die "could not decrypt $SECRETS_FILE (wrong or damaged $HOST_KEY_FILE?). Re-run the setup command."
fi

secret_keys=(ADMIN_PASSWORD DB_PASS JWT_SECRET CSRF_SECRET INTERNAL_SECRET)
declare -A SECRETS=()
parse_env SECRETS "${secret_keys[@]}" <<<"$secrets_plain"
unset secrets_plain
for k in "${secret_keys[@]}"; do
    [ -n "${SECRETS[$k]:-}" ] || die "$k is missing or empty in the decrypted secrets. Re-run the setup command."
done

ADMIN_PASSWORD="${SECRETS[ADMIN_PASSWORD]}"
DB_PASS="${SECRETS[DB_PASS]}"
JWT_SECRET="${SECRETS[JWT_SECRET]}"
CSRF_SECRET="${SECRETS[CSRF_SECRET]}"
INTERNAL_SECRET="${SECRETS[INTERNAL_SECRET]}"
export ADMIN_PASSWORD DB_PASS JWT_SECRET CSRF_SECRET INTERNAL_SECRET

step="updating docker images"
echo "Updating docker images..."
if [ $dev -eq 1 ]; then
    docker compose $compose_files build
    docker compose $compose_files pull traefik db ollama
else
    docker compose $compose_files pull
fi

# Clean up sensitive vars from memory environment
unset ADMIN_PASSWORD DB_PASS JWT_SECRET CSRF_SECRET INTERNAL_SECRET

step="checking running containers"
if [ -n "$(docker compose ps -q 2>/dev/null)" ]; then
    echo ""
    echo "Update finished. Containers are still running the old images."
    echo "Run './riskybit.sh run' to recreate them with the updated images."
else
    echo ""
    echo "Update finished. Run './riskybit.sh run' to start the project."
fi

exit 0
