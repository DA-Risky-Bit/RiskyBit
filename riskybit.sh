#!/usr/bin/env bash

set -e
trap 'echo "Error: command failed (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

__usage="
Usage: sudo $(basename "$0") <command> [OPTIONS]

Manage the project's Docker Compose stack.

Commands:
  setup     First-time setup: pulls the latest git commits and the Docker
            images, creates the encryption key, and asks for the admin email
            and passwords (stored encrypted in /etc).
  run       Checks that the images are present and up to date, then starts
            all containers in the background. Refuses to start if they are
            missing or outdated.
  down      Stops all containers. They are not deleted; use 'run' to start
            them again.
  status    Shows each service's state, ports, CPU and memory usage.
  remove    PERMANENTLY deletes the project: stops the containers, deletes
            their volumes and the project folder, and removes the encryption
            key. Asks for confirmation first. This cannot be undone.

Options:
      --dev     Developer mode:
                  setup   also init/update git submodules, and build the
                          images locally instead of pulling them
                  run     also verifies that the git submodules are in sync
                  others  no effect
  -h, --help    Show this help

Examples:
  sudo $(basename "$0") setup          First-time install
  sudo $(basename "$0") setup --dev    First-time install for development
  sudo $(basename "$0") run            Start the project
  sudo $(basename "$0") status         See what is running
  sudo $(basename "$0") down           Stop the project

Notes:
  - Needs root privileges; if you are not root, the script asks for sudo.
  - Run it from the project directory.
"

dev=0
args=()
for a in "$@"; do
  case $a in
    --dev)     dev=1 ;;
    -h|--help) echo "$__usage"; exit 0 ;;
    -*)        echo "Error: unknown option: $a" >&2; echo "$__usage" >&2; exit 1 ;;
    *)         args+=("$a") ;;
  esac
done
set -- "${args[@]}"

if [ "$EUID" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Error: this script requires root privileges, but 'sudo' is not installed. Re-run as root." >&2
        exit 1
    fi
    echo "This setup script requires root privileges. Prompting for sudo..."
    SCRIPT_PATH=$(realpath "$0")
    exec sudo "$SCRIPT_PATH" "$@"
fi
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

extra=()
[ "$dev" -eq 1 ] && extra+=(--dev)

if [ -z "${1:-}" ]; then
  echo "Error: no command given." >&2
  echo "$__usage" >&2
  exit 1
fi

if [ "$#" -gt 1 ]; then
  echo "Error: too many arguments (expected one command, got $#): $*" >&2
  echo "$__usage" >&2
  exit 1
fi

case $1 in
  setup|run|down|status|remove) ;;
  *) echo "Error: unknown command: $1" >&2; echo "$__usage" >&2; exit 1 ;;
esac

if [ ! -f "$SCRIPT_DIR/scripts/$1.sh" ]; then
  echo "Error: script not found: $SCRIPT_DIR/scripts/$1.sh" >&2
  exit 1
fi

case $1 in
  setup)  bash "$SCRIPT_DIR/scripts/setup.sh"   "${extra[@]}";;
  run)    bash "$SCRIPT_DIR/scripts/run.sh"     "${extra[@]}";;
  down)   bash "$SCRIPT_DIR/scripts/down.sh"    "${extra[@]}";;
  status) bash "$SCRIPT_DIR/scripts/status.sh"  "${extra[@]}";;
  remove) bash "$SCRIPT_DIR/scripts/remove.sh"  "${extra[@]}";;
  *)      echo "$__usage" ;;
esac
