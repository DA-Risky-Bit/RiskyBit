#!/bin/sh
set -e

DIR=/docker-entrypoint-initdb.d/updates
PSQL="psql -v ON_ERROR_STOP=1 --username ${POSTGRES_USER:-${PGUSER:-postgres}} --dbname ${POSTGRES_DB:-${PGDATABASE:-riskybit}}"

# 1. Register new scripts as pending (same logic as the old migrate()).
# pg_read_file runs on the DB server, which has the same mount, so no
# quoting of the SQL content is needed.
for f in "$DIR"/*.sql; do
  [ -e "$f" ] || continue   # no updates yet
  name=$(basename "$f")
  $PSQL -v name="$name" -v path="$f" <<'EOSQL'
INSERT INTO public.database_updates (id_dbupdate_status, script_name, script_sql)
SELECT s.id, :'name', pg_read_file(:'path')
  FROM public.database_update_statuses s
 WHERE s.name = 'pending'
   AND NOT EXISTS (
         SELECT 1 FROM public.database_updates u
          WHERE u.script_name = :'name'
            AND u.id_dbupdate_status IN (
                  SELECT id FROM public.database_update_statuses
                   WHERE name IN ('pending', 'successful')));
EOSQL
done

# 2. Run them
ok=$($PSQL -tA -c "SELECT public.db_auto_schema_update()")
if [ "$ok" != "t" ]; then
  echo "Schema update failed; see database_updates.script_results" >&2
  exit 1
fi
echo "--> Schema updates applied."
