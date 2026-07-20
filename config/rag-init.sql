-- config/rag-init.sql — runs once on first Postgres init.
-- Enables pgvector and creates a starter schema for RAG.
-- nomic-embed-text emits 768-dim vectors; change the dimension if you swap models.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS documents (
    id          BIGSERIAL PRIMARY KEY,
    source      TEXT,                       -- provenance (file, url, corpus id)
    lang        TEXT,                       -- multilingual corpora — track it
    chunk       TEXT NOT NULL,              -- the text chunk
    metadata    JSONB DEFAULT '{}'::jsonb,
    embedding   VECTOR(768),
    created_at  TIMESTAMPTZ DEFAULT now()
);

-- Cosine-distance ANN index (HNSW). Tune m / ef_construction for your corpus.
CREATE INDEX IF NOT EXISTS documents_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE INDEX IF NOT EXISTS documents_lang_idx ON documents (lang);
CREATE INDEX IF NOT EXISTS documents_metadata_gin ON documents USING gin (metadata);
