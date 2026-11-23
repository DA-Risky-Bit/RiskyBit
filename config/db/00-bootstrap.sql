/* ============================================================================================== */
/* EXTENSIONS                                                                                     */
/* ============================================================================================== */
-- gen_random_uuid() is built into core since PG13; pgcrypto is only needed for crypt()/gen_salt().
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

/* ============================================================================================== */
/* DOMAIN: DOUBLE                                                                                 */
/* ============================================================================================== */
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type
        WHERE typname = 'double' AND typnamespace = 'public'::regnamespace
    ) THEN
        CREATE DOMAIN public.double AS double precision;
    END IF;
END
$$;

/* ============================================================================================== */
/* TRIGGER FUNCTION: enforce_secure_pwd_storage()                                                 */
/* - NULL/blank  -> random, unknowable password (account cannot log in)                           */
/* - bcrypt hash -> stored as-is (prevents double hashing on UPDATE ... SET hashpass = hashpass)  */
/* - anything else is treated as cleartext and bcrypt-hashed (cost 12)                            */
/* ============================================================================================== */
CREATE OR REPLACE FUNCTION public.enforce_secure_pwd_storage()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_catalog
AS $$
BEGIN
    IF NEW.hashpass IS NULL OR btrim(NEW.hashpass) = '' THEN
        NEW.hashpass := crypt(gen_random_uuid()::text, gen_salt('bf', 12));
    ELSIF NEW.hashpass !~ '^\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}$' THEN
        NEW.hashpass := crypt(NEW.hashpass, gen_salt('bf', 12));
    END IF;
    RETURN NEW;
END;
$$;

/* ============================================================================================== */
/* TABLE: database_update_statuses                                                                */
/* ============================================================================================== */
CREATE TABLE IF NOT EXISTS public.database_update_statuses (
    id          integer GENERATED ALWAYS AS IDENTITY,
    name        varchar NOT NULL,
    label       varchar NOT NULL,
    description varchar NOT NULL,
    deleted     boolean NOT NULL DEFAULT false,
    CONSTRAINT pk_database_update_statuses PRIMARY KEY (id),
    CONSTRAINT ak_database_update_statuses UNIQUE (name)
);

COMMENT ON TABLE public.database_update_statuses IS
'Potential Data:
  Pending - Script execution has not occurred, yet. This is the default status when a new autoupdate script is INSERTed into database_updates.
  Successful - Script execution completed without error. Results (number of records added, modified, deleted...) of successful script executions should be added to script_results in database_updates.
  Failed - Script execution was unsuccessful. Results (error messages/codes...) of failed script executions should be added to script_results in database_updates.';

/* ============================================================================================== */
/* TABLE: database_updates                                                                        */
/* ============================================================================================== */
CREATE TABLE IF NOT EXISTS public.database_updates (
    id                 integer GENERATED ALWAYS AS IDENTITY,
    id_dbupdate_status integer NOT NULL,
    script_name        varchar NOT NULL,
    script_sql         varchar NOT NULL,
    script_results     varchar,
    execution_date     timestamptz,
    description        varchar,
    deleted            boolean NOT NULL DEFAULT false,
    CONSTRAINT pk_database_updates PRIMARY KEY (id),
    CONSTRAINT fk_database_updates_statuses FOREIGN KEY (id_dbupdate_status)
        REFERENCES public.database_update_statuses (id)
);

CREATE INDEX IF NOT EXISTS ix_database_updates_status_name
    ON public.database_updates (id_dbupdate_status, script_name);

COMMENT ON TABLE public.database_updates IS
'Newly INSERTed scripts would, by default, have a status of Pending.
During an autoupdate, Successful or Failed scripts would be marked as such,
script results would be updated as noted in the comments of the
database_update_statuses TABLE. Script execution stops whenever a script fails.
A previously Failed script of a given name is added again to database_updates during the next autoupdate;
the original Failed script record is NOT removed or modified.
Therefore, this TABLE also acts as a record of script execution attempts.
(More accurately, ALL scripts whose dated and numbered filename is subsequent to the
last successfully executed script and has not previously been INSERTed are added to the
database_updates TABLE during each API server boot.)';

/* ============================================================================================== */
/* TABLE: users                                                                                   */
/* ============================================================================================== */
CREATE TABLE IF NOT EXISTS public.users (
    id       integer GENERATED ALWAYS AS IDENTITY,
    username varchar NOT NULL,
    email    varchar NOT NULL,
    role     integer NOT NULL DEFAULT 0,   -- 0 = standard user, 1 = admin
    hashpass varchar NOT NULL,             -- bcrypt hash (bcrypt embeds its own salt, so no salt column)
    deleted  boolean NOT NULL DEFAULT false,
    CONSTRAINT pk_users PRIMARY KEY (id),
    CONSTRAINT ak_user_username UNIQUE (username),
    CONSTRAINT ak_user_email UNIQUE (email),
    CONSTRAINT ck_users_role CHECK (role IN (0, 1))
);

COMMENT ON COLUMN public.users.role IS '0 = standard user (default), 1 = administrator';

/* ============================================================================================== */
/* TABLE: lobby_code (singleton: exactly one row, ever)                                           */
/* ============================================================================================== */
CREATE TABLE IF NOT EXISTS public.lobby_code (
    id      boolean     NOT NULL DEFAULT true,
    code    varchar     NOT NULL,
    updated timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_lobby_code PRIMARY KEY (id),
    CONSTRAINT ck_lobby_code_singleton CHECK (id)   -- id can only be true, so only one row can exist
);

COMMENT ON TABLE public.lobby_code IS
'Singleton table: holds the one and only lobby code. The boolean primary key is constrained to true, so a second row cannot be inserted.';


/* ============================================================================================== */
/* TRIGGERS                                                                                       */
/* ============================================================================================== */
CREATE OR REPLACE TRIGGER users_enforce_secure_pwd_storage
    BEFORE INSERT OR UPDATE OF hashpass ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.enforce_secure_pwd_storage();

/* ============================================================================================== */
/* SEED: update statuses                                                                          */
/* ============================================================================================== */
INSERT INTO public.database_update_statuses (name, label, description)
VALUES
    ('pending',    'Pending',
     'Script execution has not occurred, yet. This is the default status when a new autoupdate script is INSERTed into database_updates.'),
    ('successful', 'Successful',
     'Script execution completed without error. Results (number of records added, modified, deleted...) of successful script executions should be added to script_results in database_updates.'),
    ('failed',     'Failed',
     'Script execution was unsuccessful. Results (error messages/codes...) of failed script executions should be added to script_results in database_updates.')
ON CONFLICT (name) DO NOTHING;

/* ============================================================================================== */
/* FUNCTION: db_auto_schema_update()                                                              */
/* Runs all 'pending' scripts whose name sorts after the last 'successful' script, in name order. */
/* Stops at the first failure. Each script runs in its own subtransaction, so a failing script's  */
/* changes are rolled back. An advisory lock stops two app servers booting at once from running   */
/* the same scripts twice.                                                                        */
/* ============================================================================================== */
CREATE OR REPLACE FUNCTION public.db_auto_schema_update()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    rec          record;
    v_pending    integer;
    v_successful integer;
    v_failed     integer;
    v_last_name  text;
    v_has_error  boolean := false;
    v_msg        text;
    v_rows       bigint  := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('public.db_auto_schema_update'));

    SELECT id INTO STRICT v_pending    FROM public.database_update_statuses WHERE name = 'pending';
    SELECT id INTO STRICT v_successful FROM public.database_update_statuses WHERE name = 'successful';
    SELECT id INTO STRICT v_failed     FROM public.database_update_statuses WHERE name = 'failed';

    -- Empty string when nothing has succeeded yet, so every pending script qualifies.
    SELECT COALESCE(MAX(script_name), '')
      INTO v_last_name
      FROM public.database_updates
     WHERE id_dbupdate_status = v_successful;

    -- A temp table lets scripts run DDL against database_updates itself
    -- (ALTER TABLE fails while a cursor is open on the table being altered).
    DROP TABLE IF EXISTS pg_temp.update_scripts;
    CREATE TEMPORARY TABLE update_scripts AS
        SELECT id, script_name, script_sql
          FROM public.database_updates
         WHERE id_dbupdate_status = v_pending
           AND script_name > v_last_name;

    FOR rec IN SELECT * FROM update_scripts ORDER BY script_name, id
    LOOP
        BEGIN
            EXECUTE rec.script_sql;
            GET DIAGNOSTICS v_rows = ROW_COUNT;
        EXCEPTION
            WHEN OTHERS THEN
                v_has_error := true;
                v_msg := format('Database schema update failed on script having id = %s (%s). Error: %s - %s',
                                rec.id, rec.script_name, SQLSTATE, SQLERRM);
                RAISE WARNING '%', v_msg;
        END;

        IF v_has_error THEN
            UPDATE public.database_updates
               SET id_dbupdate_status = v_failed,
                   script_results     = 'WARNING: ' || v_msg,
                   execution_date     = clock_timestamp()
             WHERE id = rec.id;
            EXIT;  -- stop on first error
        END IF;

        UPDATE public.database_updates
           SET id_dbupdate_status = v_successful,
               script_results     = format('Affected rows from last SQL call in %s: %s', rec.script_name, v_rows),
               execution_date     = clock_timestamp()
         WHERE id = rec.id;
    END LOOP;

    DROP TABLE IF EXISTS pg_temp.update_scripts;
    RETURN NOT v_has_error;
END;
$$;


/* ============================================================================================== */
/* LOBBY CODE: guard, generator, regenerator                                                      */
/* ============================================================================================== */
CREATE OR REPLACE FUNCTION public.protect_lobby_code()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'lobby_code is a singleton and its row cannot be deleted';
END;
$$;

CREATE OR REPLACE TRIGGER lobby_code_no_delete
    BEFORE DELETE OR TRUNCATE ON public.lobby_code
    FOR EACH STATEMENT EXECUTE FUNCTION public.protect_lobby_code();

CREATE OR REPLACE FUNCTION public.generate_lobby_code(p_length integer DEFAULT 6)
RETURNS varchar
LANGUAGE sql
SET search_path = public, pg_catalog
AS $$
    -- 32-char alphabet (no I, O, 0, 1); masking with 31 avoids modulo bias.
    SELECT string_agg(
               substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                      (get_byte(gen_random_bytes(1), 0) & 31) + 1, 1),
               '')::varchar
      FROM generate_series(1, p_length);
$$;

CREATE OR REPLACE FUNCTION public.regenerate_lobby_code(p_length integer DEFAULT 6)
RETURNS varchar
LANGUAGE sql
SET search_path = public, pg_catalog
AS $$
    INSERT INTO public.lobby_code (code)
    VALUES (public.generate_lobby_code(p_length))
    ON CONFLICT (id) DO UPDATE
        SET code = EXCLUDED.code, updated = now()
    RETURNING code;
$$;
