#!/bin/sh
set -e

# Creates the first admin (always id 0). Runs once, on first initialization of
# an empty data directory. Requires the schema script to run first (name it
# e.g. 01-schema.sql; this file e.g. 02-admin.sh, since files run alphabetically).

: "${ADMIN_EMAIL:?ADMIN_EMAIL is empty, refusing to create admin}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is empty, refusing to create admin}"

# Values are passed as psql variables and quoted with :'var', so special
# characters in the password or email can't break or inject into the SQL.
# The heredoc is quoted so the shell does not expand anything inside it.
psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v admin_email="$ADMIN_EMAIL" \
     -v admin_pass="$ADMIN_PASSWORD" <<'EOSQL'
INSERT INTO public.users (id, username, email, role, hashpass)
OVERRIDING SYSTEM VALUE
VALUES (0, 'admin', :'admin_email', 1, :'admin_pass')
ON CONFLICT (id) DO UPDATE
    SET email    = EXCLUDED.email,
        role     = 1,
        hashpass = EXCLUDED.hashpass,
        deleted  = false;
EOSQL

echo "--> Admin user (id 0) initialized."
