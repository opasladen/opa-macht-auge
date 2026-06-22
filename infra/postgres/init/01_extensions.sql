-- Aktiviert pgvector fuer Embedding-Spalten.
-- Wird beim ersten Container-Start von Postgres automatisch ausgefuehrt.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
