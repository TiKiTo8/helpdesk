CREATE TABLE tickets (
    id          SERIAL PRIMARY KEY,
    title       TEXT        NOT NULL,
    description TEXT        NOT NULL,
    email       TEXT        NOT NULL,
    status      TEXT        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Rempli par le service backup
CREATE TABLE backup_log (
    id          SERIAL PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    file        TEXT        NOT NULL,
    size_bytes  BIGINT      NOT NULL,
    source      TEXT        NOT NULL,
    kept        INTEGER     NOT NULL
);
