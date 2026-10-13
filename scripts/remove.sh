#!/usr/bin/env bash

set -e
step="starting up"
on_err() { echo "Error: remove failed while ${step} (exit $1) at line $2: $3" >&2; }
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

die() { echo "Error: $1" >&2; exit "${2:-1}"; }

step="locating the project directory"
(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null) \
  || die "could not resolve the project directory from '${BASH_SOURCE[0]}'."

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

if [[ -z "$root" || "$root" == "/" || "$root" == "$HOME" ]]; then
  echo "Refusing to delete '$root'" >&2
  exit 1
fi

step="running safety checks"
script_name="$(basename "${BASH_SOURCE[0]}")"
[ -f "$root/scripts/$script_name" ] \
  || die "'$root' does not look like the project directory ('scripts/$script_name' not found). Refusing to delete it."
for h in "$HOME" "$(getent passwd "${SUDO_USER:-}" 2>/dev/null | cut -d: -f6)"; do
  [ -n "$h" ] || continue
  [[ "$h" != "$root" && "$h" != "$root"/* ]] \
    || die "refusing to delete '$root': it is or contains the home directory '$h'."
done
command -v docker >/dev/null 2>&1 \
  || die "docker is not installed, so the containers cannot be stopped. Nothing was removed."
docker compose version >/dev/null 2>&1 \
  || die "the 'docker compose' plugin is not available. Nothing was removed."
docker info >/dev/null 2>&1 \
  || die "cannot connect to the Docker daemon (is it running, and do you have permission?). Nothing was removed."
if ! cfg_out=$(cd "$root" && docker compose config -q 2>&1); then
  die "docker compose cannot read the project in '$root'. Nothing was removed."$'\n'"$cfg_out"
fi
if [ -e /etc/riskybit-host.key ] && [ ! -w /etc ]; then
  die "removing /etc/riskybit-host.key requires root. Re-run as root (e.g. with sudo). Nothing was removed."
fi
[ -t 0 ] || die "an interactive terminal is required for the confirmation prompt. Nothing was removed."

step="asking for confirmation"
trap - ERR; set +e
read -r -p "Remove the whole project at $root from your computer? (y/N) " remove
set -e; trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
[[ "$remove" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }

step="stopping containers and removing volumes (the project has NOT been deleted)"
cd "$root" || exit 1
docker compose down --volumes --remove-orphans

step="deleting the project directory"
cd / || exit 1
rm -rf -- "$root"
echo "Removed $root"
step="removing the encryption key"
rm -rf /etc/riskybit-host.key
echo "Removed encryption key"
exit 0
