#!/usr/bin/env bash

set -e
step="starting up"
on_err() { echo "Error: down failed while ${step} (exit $1) at line $2: $3" >&2; }
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

die() { echo "Error: $1" >&2; exit "${2:-1}"; }

for a in "$@"; do
  case $a in
    --dev) ;;
    *) die "unknown option: $a (supported: --dev)" 2 ;;
  esac
done

step="running pre-flight checks"
command -v docker >/dev/null 2>&1 \
  || die "docker is not installed."
docker compose version >/dev/null 2>&1 \
  || die "the 'docker compose' plugin is not available. Install Docker Compose v2."
docker info >/dev/null 2>&1 \
  || die "cannot connect to the Docker daemon. Is it running, and do you have permission to use it?"
if ! cfg_out=$(docker compose config -q 2>&1); then
  die "docker compose could not read the project in '$(pwd)'. Run this from the project directory."$'\n'"$cfg_out"
fi

step="stopping containers"
echo "Stopping all Containers..."
docker compose stop
