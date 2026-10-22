-- Run once, by a superuser (or a role allowed to CREATE ROLE, CREATE DATABASE and CREATE
-- EXTENSION), against the Postgres server Nabu will use. Nabu does not bundle a database on the
-- Kubernetes path: the operator provides one, and gives Nabu its own database and role (never a
-- schema shared with another application).
--
-- Usage:
--   psql "$POSTGRES_ADMIN_URL" -v db_password='<a strong, generated password>' \
--     -f deploy/k8s/create-db.sql
--
-- Requirements: PostgreSQL 14 or newer with the pgvector extension installed on the server
-- (package `postgresql-17-pgvector` or similar, or the `pgvector/pgvector` image), plus
-- pg_trgm, which ships with PostgreSQL's contrib package. The compose path runs 17.
--
-- Why the extensions are created here: CREATE EXTENSION needs privileges the application role
-- should not have (pgvector is not a "trusted" extension). Nabu's migrations run
-- CREATE EXTENSION IF NOT EXISTS and tolerate the extension already being there, so creating
-- them as the superuser below is what lets the app run as an ordinary owner of its database.

\set ON_ERROR_STOP on

CREATE ROLE nabu WITH LOGIN PASSWORD :'db_password';
CREATE DATABASE nabu OWNER nabu;

\connect nabu

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

-- Nabu's migrations create every table inside the public schema of this database, as this role
-- (the database owner), so no further GRANTs are needed.

-- Build the Secret's DATABASE_URL from the same password, e.g.:
--   kubectl -n nabu create secret generic nabu \
--     --from-literal=DATABASE_URL="postgres://nabu:<db_password>@<postgres-host>:5432/nabu" \
--     --from-literal=NABU_SECRET_KEY="$(openssl rand -base64 32)"
