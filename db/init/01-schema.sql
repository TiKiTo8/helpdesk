-- Schéma initial, joué une seule fois au premier démarrage (volume db-data vide).
-- À ajuster avec l'équipe application selon les besoins de l'appli.

CREATE TABLE tickets (
    id          SERIAL PRIMARY KEY,
    title       TEXT        NOT NULL,
    description TEXT        NOT NULL,
    email       TEXT        NOT NULL,
    status      TEXT        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
