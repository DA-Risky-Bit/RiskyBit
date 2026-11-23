#!/usr/bin/env bash

set -e
step="starting up"
on_err() { echo "Error: down failed while ${step} (exit $1) at line $2: $3" >&2; }
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

die() { echo "Error: $1" >&2; exit "${2:-1}"; }

ENV_FILE="/etc/docker-app.env"
SECRETS_FILE="/etc/riskybit-secrets.gpg"
HOST_KEY_FILE="/etc/riskybit-host.key"

gpu=2
service_name=""
for a in "$@"; do
  case $a in
    --dev) ;;
    amd)   gpu=0 ;;
    nvidia)gpu=1 ;;
    null)  gpu=2 ;;
    -*)    die "unknown option: $a (supported: --dev, amd, nvidia, null)" 2 ;;
    *)     service_name="$a" ;;
  esac
done

parse_env() {
    local -n _out=$1
    shift
    local allowed=" $* " line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        [[ -z $line || $line == \#* || $line != *=* ]] && continue
        key=${line%%=*}
        val=${line#*=}
        key=${key//[[:space:]]/}
        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ $allowed == *" $key "* ]] || continue
        if [[ ${#val} -ge 2 && ( ( $val == \"*\" ) || ( $val == \'*\' ) ) ]]; then
            val=${val:1:${#val}-2}
        fi
        _out[$key]=$val
    done
}

step="reading configuration for validation"
[ -e "$ENV_FILE" ] || die "Missing $ENV_FILE"
[ -e "$SECRETS_FILE" ] || die "Missing $SECRETS_FILE"
[ -e "$HOST_KEY_FILE" ] || die "Missing $HOST_KEY_FILE"

declare -A APP_ENV=()
parse_env APP_ENV ADMIN_EMAIL DOMAIN < "$ENV_FILE"

secrets_plain=$(gpg --batch --decrypt --passphrase-file "$HOST_KEY_FILE" "$SECRETS_FILE" 2>/dev/null) \
    || die "could not decrypt $SECRETS_FILE"

secret_keys=(ADMIN_PASSWORD DB_PASS JWT_SECRET CSRF_SECRET INTERNAL_SECRET)
declare -A SECRETS=()
parse_env SECRETS "${secret_keys[@]}" <<<"$secrets_plain"
unset secrets_plain

# Temporarily export variables for validation and execution
export DOMAIN="${APP_ENV[DOMAIN]}"
export ADMIN_EMAIL="${APP_ENV[ADMIN_EMAIL]}"
for k in "${secret_keys[@]}"; do
    export "$k=${SECRETS[$k]}"
done

compose_args=(-f ./docker-compose.yaml)
if [[ $gpu -eq 0 ]]; then
    compose_args+=(-f ./compose.amd.yaml)
elif [[ $gpu -eq 1 ]]; then
    compose_args+=(-f ./compose.nvidia.yaml)
fi

step="running pre-flight checks"
command -v docker >/dev/null 2>&1 \
  || die "docker is not installed."
docker compose version >/dev/null 2>&1 \
  || die "the 'docker compose' plugin is not available. Install Docker Compose v2."
docker info >/dev/null 2>&1 \
  || die "cannot connect to the Docker daemon. Is it running, and do you have permission to use it?"

step="validating docker compose configuration"
if ! cfg_out=$(docker compose --env-file "$ENV_FILE" "${compose_args[@]}" config -q 2>&1); then
  die "docker compose could not read the project in '$(pwd)'. Run this from the project directory."$'\n'"$cfg_out"
fi

step="stopping containers"
if [ -n "$service_name" ]; then
    echo "Stopping container: $service_name..."
else
    echo "Stopping all containers..."
fi

(
    stop_args=(compose --env-file "$ENV_FILE" "${compose_args[@]}" stop)
    if [ -n "$service_name" ]; then
        stop_args+=("$service_name")
    fi
    exec docker "${stop_args[@]}"
)
