#!/usr/bin/env bash

set -e
step="starting up"
on_err() { echo "Error: run failed while ${step} (exit $1) at line $2: $3" >&2; }
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

die() { echo "Error: $1" >&2; exit "${2:-1}"; }

ENV_FILE="/etc/docker-app.env"
SECRETS_FILE="/etc/riskybit-secrets.gpg"
HOST_KEY_FILE="/etc/riskybit-host.key"

dev=0
gpu=2
for a in "$@"; do
  case $a in
    --dev) dev=1 ;;
    amd)   gpu=0 ;;
    nvidia)gpu=1 ;;
    null)  gpu=2 ;;
    *) die "unknown option: $a (supported: --dev, amd, nvidia, null)" 2 ;;
  esac
done

__error_submodules_missing="
Submodules are missing or out of sync.

Please run './riskybit.sh setup' to setup the project.
"

__error_images_missing="
Docker images are missing.

Please run './riskybit.sh setup' to setup the project or manually build via Docker Compose.
"

__error_images_not_up_to_date="
Docker images are not up to date.

Please run './riskybit.sh update' to update the projects git and .
"

ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

remote_digest() {
    local ref=${1%%@*} tag=latest registry repo first url hdr www realm service token

    if [[ ${ref##*/} == *:* ]]; then tag=${ref##*:}; ref=${ref%:*}; fi

    first=${ref%%/*}
    if [[ $ref == */* && ( $first == *.* || $first == *:* || $first == localhost ) ]]; then
        registry=$first; repo=${ref#*/}
    else
        registry=registry-1.docker.io; repo=$ref
        [[ $repo == */* ]] || repo=library/$repo
    fi

    url="https://$registry/v2/$repo/manifests/$tag"
    hdr=$(curl -sI -H "Accept: $ACCEPT" "$url")

    if grep -qi '^HTTP/[0-9.]* 401' <<<"$hdr"; then
        www=$(grep -i '^www-authenticate:' <<<"$hdr" | tr -d '\r')
        realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$www")
        service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$www")
        token=$(curl -s "$realm?service=$service&scope=repository:$repo:pull" \
                | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
        hdr=$(curl -sI -H "Accept: $ACCEPT" -H "Authorization: Bearer $token" "$url")
    fi

    grep -i '^docker-content-digest:' <<<"$hdr" | awk '{print $2}' | tr -d '\r'
}

# parse_env <array-name> <allowed key>...
# Reads KEY=VALUE lines from stdin into the associative array. Never sources or
# evals the input: only whitelisted keys are kept, values are taken literally
# (split on the first '='), CRLF and one pair of surrounding quotes are stripped.
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

# Temporarily export for docker compose config validation
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
for cmd in docker curl grep sed awk tr sort gpg; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done
(( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3 ) )) \
    || die "bash 4.3 or newer is required."
docker compose version >/dev/null 2>&1 \
    || die "the 'docker compose' plugin is not available. Install Docker Compose v2."
docker info >/dev/null 2>&1 \
    || die "cannot connect to the Docker daemon. Is it running, and do you have permission to use it?"
step="validating docker compose configuration"
if ! cfg_out=$(docker compose --env-file "$ENV_FILE" "${compose_args[@]}" config -q 2>&1); then
   die "docker compose configuration check failed."$'\n'$cfg_out
fi

step="fetching git updates"
trap - ERR; set +e
git fetch >/dev/null
fetch_rc=$?
set -e; trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
[ "$fetch_rc" -eq 0 ] || echo "Warning: 'git fetch' failed (exit $fetch_rc); continuing with local git state." >&2

if [ $dev -eq 1 ]; then
    step="checking git submodules"
    git submodule status --recursive >/dev/null 2>&1 \
        || die "unable to read git submodule status (is '$(pwd)' a git repository?)"
fi

if [ $dev -eq 1 ]; then
    if git submodule status --recursive | grep -q '^[-+U]'; then
        echo "$__error_submodules_missing"
        exit 1
    else
        echo "All submodules are up to date"
    fi
fi

step="checking for missing docker images"
missing=0
for img in $(docker compose config --images); do
    docker image inspect "$img" >/dev/null 2>&1 || { echo "Missing: $img"; missing=1; }
done

if [ $missing -eq 1 ]; then
    echo "$__error_images_missing"
    exit 1
fi

step="checking for image updates"
echo "Checking for updates for images."
outdated=0
for img in $(docker compose config --images | sort -u); do
    local_digests=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$img" 2>/dev/null | sed 's/.*@//')

    if [ -z "$local_digests" ]; then
        echo "Skipped (missing locally or built locally): $img"
        continue
    fi

    remote=$(remote_digest "$img")

    if [ -z "$remote" ]; then
        echo "Could not query registry: $img"
    elif grep -qx "$remote" <<<"$local_digests"; then
        echo "Up to date:  $img"
    else
        echo "Outdated:    $img"
        outdated=1
    fi
done

if [ $outdated -eq 1 ]; then
    echo "$__error_images_not_up_to_date"
    exit 1
fi

step="checking setup configuration"
for f in "$ENV_FILE" "$SECRETS_FILE" "$HOST_KEY_FILE"; do
    if [ ! -e "$f" ]; then
        echo "❌ Missing setup configurations ($f). Please run the setup command first."
        exit 1
    fi
    [ -r "$f" ] || die "cannot read $f (you need to run as root)."
done

step="reading $ENV_FILE"
declare -A APP_ENV=()
parse_env APP_ENV ADMIN_EMAIL DOMAIN < "$ENV_FILE"
[ -n "${APP_ENV[ADMIN_EMAIL]:-}" ] || die "ADMIN_EMAIL is missing in $ENV_FILE. Re-run the setup command."
[ -n "${APP_ENV[DOMAIN]:-}" ]      || die "DOMAIN is missing in $ENV_FILE. Re-run the setup command."

step="decrypting secrets (wrong or damaged $HOST_KEY_FILE?)"
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

step="starting containers"
# Secrets are exported only inside this subshell, so they never reach this shell's
# environment or any process's argument list.
(
    for k in "${secret_keys[@]}"; do export "$k=${SECRETS[$k]}"; done
    exec docker compose --env-file "$ENV_FILE" "${compose_args[@]}" up -d
)

domain=${APP_ENV[DOMAIN]}
unset SECRETS

echo "Admin Frontend running via admin.$domain"
echo "Chat Frontend running via chat.$domain"
echo "App Frontend running via app.$domain"
echo "API running via api.$domain"

exit 0
