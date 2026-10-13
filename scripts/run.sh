#!/usr/bin/env bash

set -e
step="starting up"
on_err() { echo "Error: run failed while ${step} (exit $1) at line $2: $3" >&2; }
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

die() { echo "Error: $1" >&2; exit "${2:-1}"; }

dev=0
for a in "$@"; do
  case $a in
    --dev) dev=1 ;;
    *) die "unknown option: $a (supported: --dev)" 2 ;;
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

step="running pre-flight checks"
for cmd in docker curl grep sed awk tr sort gpg; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done
docker compose version >/dev/null 2>&1 \
    || die "the 'docker compose' plugin is not available. Install Docker Compose v2."
docker info >/dev/null 2>&1 \
    || die "cannot connect to the Docker daemon. Is it running, and do you have permission to use it?"
if ! cfg_out=$(docker compose config -q 2>&1); then
    die "docker compose could not read the project in '$(pwd)'. Run this from the project directory."$'\n'"$cfg_out"
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
if [ ! -f /etc/docker-app.env ] || [ ! -f /etc/docker-password.gpg ] || [ ! -f /etc/admin-password.gpg ]; then
    echo "❌ Missing setup configurations. Please run the setup command first."
    exit 1
fi

for f in /etc/docker-app.env /etc/docker-password.gpg /etc/admin-password.gpg /etc/riskybit-host.key; do
    [ -r "$f" ] || die "cannot read $f (it is missing, or you need to run as root). Run the setup command if it is missing."
done

step="decrypting secrets (wrong or damaged /etc/riskybit-host.key?)"
DB_PASS=$(gpg --batch --decrypt --passphrase-file /etc/riskybit-host.key /etc/docker-password.gpg 2>/dev/null)
ADMIN_PASS=$(gpg --batch --decrypt --passphrase-file /etc/riskybit-host.key /etc/admin-password.gpg 2>/dev/null)
[ -n "$DB_PASS" ]    || die "decrypted database password is empty. Re-run the setup command."
[ -n "$ADMIN_PASS" ] || die "decrypted admin password is empty. Re-run the setup command."

step="starting containers"
DB_PASS="$DB_PASS" ADMIN_PASS="$ADMIN_PASS" docker compose --env-file /etc/docker-app.env up -d

unset DB_PASS
unset ADMIN_PASS

echo "Admin Frontend running via admin.localhost"
echo "Chat Frontend running via chat.localhost"
echo "App Frontend running via app.localhost"

exit 0
