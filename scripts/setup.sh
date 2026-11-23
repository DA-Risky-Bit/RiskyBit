#!/usr/bin/env bash

SECRETS_FILE="/etc/riskybit-secrets.gpg"
gen_secret() { openssl rand -hex 32; }

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
[ ! -e "$SECRETS_FILE" ] || die "$SECRETS_FILE already exists and gpg will not overwrite it. Remove it (or run the remove command) and re-run setup."

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

step="domain setup"
echo "\n--- Domain Setup ---"
read -r -p "Domain to run on [riskybit.at]: " DOMAIN
DOMAIN=${DOMAIN:-riskybit.at}
DOMAIN=${DOMAIN,,}
[[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] \
    || die "'$DOMAIN' is not a valid domain (use e.g. riskybit.at, without https:// or subdomains)."
export DOMAIN
echo "--> Using domain: $DOMAIN (admin.$DOMAIN, chat.$DOMAIN, app.$DOMAIN, api.$DOMAIN)"

step="TLS certificates"
CERT_DIR="config/traefik/certs"
CA_DIR="/etc/riskybit-ca"     # outside the repo and outside the Traefik mount
CERT_DAYS=825

echo -e "\n--- TLS Certificates ---"
echo "  1) Generate a private CA and a certificate for $DOMAIN (default)"
echo "  2) Use my own certificate (e.g. from an enterprise CA)"
read -r -p "Choice [1]: " CERT_MODE
CERT_MODE=${CERT_MODE:-1}
case $CERT_MODE in 1|2) ;; *) die "invalid choice: $CERT_MODE (use 1 or 2)" ;; esac
mkdir -p "$CERT_DIR"

if [ "$CERT_MODE" = "1" ]; then
    # ---- Generate CA (reused if it already exists, so clients keep trusting it) ----
    mkdir -p "$CA_DIR"; chmod 700 "$CA_DIR"
    if [ -s "$CA_DIR/ca.key" ] && [ -s "$CA_DIR/ca.pem" ]; then
        echo "--> Reusing existing CA in $CA_DIR."
    else
        openssl genrsa -out "$CA_DIR/ca.key" 4096 2>/dev/null
        chmod 600 "$CA_DIR/ca.key"
        # nameConstraints: even if this CA key leaks, it can't be used for other domains.
        openssl req -x509 -new -sha256 -key "$CA_DIR/ca.key" -days 3650 \
            -subj "/CN=RiskyBit Private CA" \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -addext "nameConstraints=critical,permitted;DNS:$DOMAIN" \
            -out "$CA_DIR/ca.pem"
        echo "--> Generated new CA (valid 10 years)."
    fi

    # ---- Generate server certificate signed by the CA ----
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/ext.cnf" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN
EOF
    openssl genrsa -out "$tmp/server.key" 2048 2>/dev/null
    openssl req -new -key "$tmp/server.key" -subj "/CN=$DOMAIN" -out "$tmp/server.csr"
    openssl x509 -req -sha256 -days "$CERT_DAYS" -in "$tmp/server.csr" \
        -CA "$CA_DIR/ca.pem" -CAkey "$CA_DIR/ca.key" -CAcreateserial \
        -extfile "$tmp/ext.cnf" -out "$tmp/server.pem" 2>/dev/null

    cat "$tmp/server.pem" "$CA_DIR/ca.pem" > "$CERT_DIR/cert.pem"   # full chain
    install -m 600 "$tmp/server.key" "$CERT_DIR/key.pem"
    chmod 644 "$CERT_DIR/cert.pem"
    install -m 644 "$CA_DIR/ca.pem" "$CERT_DIR/ca.pem"              # public CA, to hand to clients
    rm -rf "$tmp"; trap - EXIT

    echo "--> Certificate for $DOMAIN and *.$DOMAIN generated (valid $CERT_DAYS days)."
    echo "--> Install $(pwd)/$CERT_DIR/ca.pem as a trusted root on every client that should trust this site."
else
    # ---- Bring your own ----
    read -r -e -p "Path to certificate PEM (leaf, or full chain): " BYO_CERT
    read -r -e -p "Path to private key PEM (must not be passphrase-protected): " BYO_KEY
    read -r -e -p "Path to intermediate chain PEM (optional, Enter to skip): " BYO_CHAIN

    [ -r "$BYO_CERT" ] || die "cannot read certificate: '$BYO_CERT'"
    [ -r "$BYO_KEY" ]  || die "cannot read private key: '$BYO_KEY'"
    [ -z "$BYO_CHAIN" ] || [ -r "$BYO_CHAIN" ] || die "cannot read chain file: '$BYO_CHAIN'"

    openssl x509 -in "$BYO_CERT" -noout 2>/dev/null \
        || die "'$BYO_CERT' is not a valid PEM certificate (DER/PFX files must be converted first)."
    openssl pkey -in "$BYO_KEY" -passin pass: -noout 2>/dev/null \
        || die "'$BYO_KEY' is not a valid PEM key, or it is passphrase-protected (Traefik needs it unencrypted)."
    [ "$(openssl x509 -in "$BYO_CERT" -noout -pubkey)" = "$(openssl pkey -in "$BYO_KEY" -passin pass: -pubout)" ] \
        || die "the private key does not match the certificate."
    openssl x509 -in "$BYO_CERT" -noout -checkend 0 >/dev/null \
        || die "the certificate has already expired."

    missing=""
    for h in "$DOMAIN" "admin.$DOMAIN" "chat.$DOMAIN" "app.$DOMAIN" "api.$DOMAIN"; do
        openssl x509 -in "$BYO_CERT" -noout -checkhost "$h" | grep -q "does match" || missing="$missing $h"
    done
    if [ -n "$missing" ]; then
        echo "⚠️  The certificate does not cover:$missing" >&2
        read -r -p "Continue anyway? [y/N]: " ans
        [[ $ans =~ ^[Yy]$ ]] || die "aborted: certificate does not cover all hostnames."
    fi

    cat "$BYO_CERT" ${BYO_CHAIN:+"$BYO_CHAIN"} > "$CERT_DIR/cert.pem"
    install -m 600 "$BYO_KEY" "$CERT_DIR/key.pem"
    chmod 644 "$CERT_DIR/cert.pem"
    echo "--> Using your certificate (expires: $(openssl x509 -in "$BYO_CERT" -noout -enddate | cut -d= -f2))."
fi

step="storing secrets"
echo -e "\n--- Secrets ---"
JWT_SECRET=$(gen_secret)
CSRF_SECRET=$(gen_secret)
INTERNAL_SECRET=$(gen_secret)

printf 'ADMIN_PASSWORD=%s\nDB_PASS=%s\nJWT_SECRET=%s\nCSRF_SECRET=%s\nINTERNAL_SECRET=%s\n' \
    "$ADMIN_PASS" "$DB_PASS" "$JWT_SECRET" "$CSRF_SECRET" "$INTERNAL_SECRET" \
  | gpg --batch --symmetric --cipher-algo AES256 \
        --passphrase-file "$HOST_KEY_FILE" -o "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"
echo "--> Stored all secrets in $SECRETS_FILE."

step="writing /etc/docker-app.env"
cat > /etc/docker-app.env <<EOF
ADMIN_EMAIL=$ADMIN_EMAIL
DOMAIN=$DOMAIN
EOF
chmod 600 /etc/docker-app.env

step="pulling Github commits"
echo "Pulling last Github commits..."
git fetch >/dev/null
git pull  >/dev/null

if [ $dev -eq 1 ]; then
    step="updating git submodules"
    echo "Pulling git submodules..."
    git submodule update --init --recursive --remote >/dev/null
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
    ADMIN_EMAIL="$ADMIN_EMAIL" ADMIN_PASSWORD="$ADMIN_PASS" DOMAIN="$DOMAIN" DB_PASS="$DB_PASS" JWT_SECRET="$JWT_SECRET" CSRF_SECRET="$CSRF_SECRET" INTERNAL_SECRET="$INTERNAL_SECRET" docker compose build
    ADMIN_EMAIL="$ADMIN_EMAIL" ADMIN_PASSWORD="$ADMIN_PASS" DOMAIN="$DOMAIN" DB_PASS="$DB_PASS" JWT_SECRET="$JWT_SECRET" CSRF_SECRET="$CSRF_SECRET" INTERNAL_SECRET="$INTERNAL_SECRET" docker compose pull traefik db ollama
else
    ADMIN_EMAIL="$ADMIN_EMAIL" ADMIN_PASSWORD="$ADMIN_PASS" DOMAIN="$DOMAIN" DB_PASS="$DB_PASS" JWT_SECRET="$JWT_SECRET" CSRF_SECRET="$CSRF_SECRET" INTERNAL_SECRET="$INTERNAL_SECRET" docker compose pull
fi

unset ADMIN_PASS DB_PASS JWT_SECRET CSRF_SECRET INTERNAL_SECRET


echo -e "\nProject finished setup."
exit 0
