#!/bin/bash
set -e

# TODO: THIS IS A PROOF OF CONCEPT TO INSERT THE FIRST ADMIN.
#       WILL LATER NEED PROPER HASHING.

# Securely query Postgres using internal environment variables passed by Docker Compose
#psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
#    INSERT INTO users (email, password_hash, role)
#    VALUES ('$ADMIN_EMAIL', '$ADMIN_PASSWORD', 'admin')
#    ON CONFLICT (email)
#    DO UPDATE SET password_hash = '$ADMIN_PASSWORD';
#EOSQL
#
#echo "--> Admin user ($ADMIN_EMAIL) successfully initialized in database."
