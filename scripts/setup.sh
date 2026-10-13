#!/usr/bin/env bash

set -e
set -o pipefail
step="starting up"
on_err() { echo "Error: setup failed while ${step} (exit $1) at line $2: $3" >&2; }
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

die() { echo "Error: $1" >&2; exit "${2:-1}"; }

dev=0
for a in "$@"; do
  case $a in
    --dev) dev=1 ;;
    *) die "unknown option: $a (supported: --dev)" 2 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
    die "this script must be run as root (it writes to /etc). Run it via the main script or with sudo."
fi

step="checking Docker"
command -v docker >/dev/null 2>&1 && docker_installed=1 || docker_installed=0

__error_docker_not_found="
Docker is not installed, please install it for your distro.

Refer to the official docker documentation for installation.
DockerDoc: https://docs.docker.com/engine/install/
"

__error_docker_not_running="
Docker is installed but the daemon is not running (or not reachable).

Try starting it:
  systemd:  sudo systemctl start docker
  OpenRC:   sudo rc-service docker start
  SysV:     sudo service docker start

DockerDoc: https://docs.docker.com/config/daemon/start/
"

__error_docker_permission="
Docker is running, but you don't have permission to access it.

Add your user to the docker group and re-login:
  sudo usermod -aG docker \$USER

DockerDoc: https://docs.docker.com/engine/install/linux-postinstall/
"

if [ $docker_installed -eq 0 ]; then
    echo "$__error_docker_not_found" >&2
    exit 1
fi

if ! output=$(docker info 2>&1); then
    if grep -qi "permission denied" <<< "$output"; then
        echo "$__error_docker_permission" >&2
    else
        echo "$__error_docker_not_running" >&2
    fi
    exit 1
fi

step="running pre-flight checks"
for cmd in git find sed grep tr head openssl gpg; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done
docker compose version >/dev/null 2>&1 \
    || die "the 'docker compose' plugin is not available. Install Docker Compose v2."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "'$(pwd)' is not inside a git repository. Run setup from the project directory."
[ -t 0 ] || die "an interactive terminal is required (setup prompts for admin credentials)."
for f in /etc/admin-password.gpg /etc/docker-password.gpg; do
    [ ! -e "$f" ] || die "$f already exists and gpg will not overwrite it. Remove it (or run the remove command) and re-run setup."
done

step="pulling Github commits"
echo "Pulling last Github commits..."
git fetch >/dev/null
git pull  >/dev/null

if [ $dev -eq 1 ]; then
    step="updating git submodules"
    echo "Pulling git submodules..."
    git submodule update --init --recursive >/dev/null
fi

step="preparing config files"
[ -d config ] || die "config directory not found in '$(pwd)'."
echo "Preparing files for docker..."
trap - ERR; set +e
find config -type f -exec sh -c '
    for f; do
        grep -qI . "$f" && sed -i "s/\r$//" "$f"
    done
' sh {} +
set -e; trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

step="getting docker images"
echo "Getting docker images..."
if [ $dev -eq 1 ]; then
    docker compose build
else
    docker compose pull
fi

TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

LABEL=" Setup "
LABEL_LEN=${#LABEL}

FILL_LEN=$(( (TERM_WIDTH - LABEL_LEN) / 2 ))

PAD_LEFT=$(printf '%*s' "$FILL_LEN" '' | tr ' ' '=')
PAD_RIGHT=$(printf '%*s' "$(( TERM_WIDTH - LABEL_LEN - FILL_LEN ))" '' | tr ' ' '=')

echo "${PAD_LEFT}${LABEL}${PAD_RIGHT}"

step="creating the host key"
HOST_KEY_FILE="/etc/riskybit-host.key"
if [ -e "$HOST_KEY_FILE" ] && [ ! -s "$HOST_KEY_FILE" ]; then
    echo "Warning: removing empty host key file $HOST_KEY_FILE from a previous failed run." >&2
    rm -f "$HOST_KEY_FILE"
fi
if [ ! -f "$HOST_KEY_FILE" ]; then
    openssl rand -base64 32 > "$HOST_KEY_FILE"
    chmod 600 "$HOST_KEY_FILE"
fi

step="admin user setup"
echo "--- Admin User Setup ---"
read -p "Admin Email Address: " ADMIN_EMAIL
while [ -z "$ADMIN_EMAIL" ]; do
    echo "⚠️  Email cannot be empty."
    read -p "Admin Email Address: " ADMIN_EMAIL
done

read -s -p "Admin Password (press Enter to auto-generate [req. openssl]): " INPUT_ADMIN_PASS
echo ""
if [ -z "$INPUT_ADMIN_PASS" ]; then
    ADMIN_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
    echo "--> Auto-generated Admin Password: $ADMIN_PASS"
else
    ADMIN_PASS="$INPUT_ADMIN_PASS"
fi
unset INPUT_ADMIN_PASS
[ -n "$ADMIN_PASS" ] || die "admin password is empty (password generation failed)."
echo -n "$ADMIN_PASS" | gpg --batch --symmetric --cipher-algo AES256 --passphrase-file "$HOST_KEY_FILE" -o /etc/admin-password.gpg
unset ADMIN_PASS
chmod 600 /etc/admin-password.gpg


step="database setup"
echo -e "\n--- Database Setup ---"
read -s -p "Database Password (press Enter to auto-generate [req. openssl]): " INPUT_DB_PASS
echo ""
if [ -z "$INPUT_DB_PASS" ]; then
    DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
    echo "--> Auto-generated Database Password: $DB_PASS"
else
    DB_PASS="$INPUT_DB_PASS"
fi
unset INPUT_DB_PASS
[ -n "$DB_PASS" ] || die "database password is empty (password generation failed)."
echo -n "$DB_PASS" | gpg --batch --symmetric --cipher-algo AES256 --passphrase-file "$HOST_KEY_FILE" -o /etc/docker-password.gpg
unset DB_PASS
chmod 600 /etc/docker-password.gpg


step="writing /etc/docker-app.env"
echo "ADMIN_EMAIL=$ADMIN_EMAIL" > /etc/docker-app.env
chmod 600 /etc/docker-app.env

echo -e "\nProject finished setup."
exit 0
