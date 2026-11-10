"""API Helpdesk : tickets de support.

Dépendances externes (toutes configurées par variables d'environnement) :
  DATABASE_URL  obligatoire  PostgreSQL (écritures + lectures)
  REPLICA_URL   optionnel    réplica PostgreSQL pour /api/stats (sinon : primaire)
  REDIS_URL     optionnel    cache de la liste des tickets (sinon : pas de cache)
  SMTP_HOST     optionnel    serveur mail (sinon : aucun mail envoyé)
  SMTP_PORT     optionnel    1025 par défaut
"""
import json
import os
import smtplib
from contextlib import asynccontextmanager
from email.message import EmailMessage

import psycopg
from fastapi import BackgroundTasks, FastAPI, HTTPException, Response
from prometheus_client import Counter, make_asgi_app
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field

try:
    import redis
except ImportError:  # redis n'est qu'un accélérateur
    redis = None

CACHE_KEY = "tickets"
CACHE_TTL = 30  # secondes
COLUMNS = "id, title, description, email, status, to_char(created_at, 'DD/MM/YYYY HH24:MI') AS created_at"

DATABASE_URL = os.environ["DATABASE_URL"]
REPLICA_URL = os.environ.get("REPLICA_URL")
REDIS_URL = os.environ.get("REDIS_URL")
SMTP_HOST = os.environ.get("SMTP_HOST")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "1025"))

primary = ConnectionPool(DATABASE_URL, kwargs={"row_factory": dict_row}, open=False)
replica = (
    ConnectionPool(REPLICA_URL, kwargs={"row_factory": dict_row}, timeout=2, open=False)
    if REPLICA_URL
    else None
)
cache = (
    redis.Redis.from_url(REDIS_URL, decode_responses=True, socket_timeout=1)
    if REDIS_URL and redis
    else None
)

# Métriques Prometheus (exposées sur /metrics)
TICKETS_CREATED = Counter("helpdesk_tickets_created_total", "Tickets créés")
TICKETS_CLOSED = Counter("helpdesk_tickets_closed_total", "Tickets fermés")
CACHE_REQUESTS = Counter("helpdesk_cache_requests_total", "Lectures de la liste", ["result"])
MAIL_SENT = Counter("helpdesk_mail_sent_total", "Mails envoyés")
MAIL_ERRORS = Counter("helpdesk_mail_errors_total", "Mails non envoyés")


@asynccontextmanager
async def lifespan(_: FastAPI):
    primary.open()
    if replica:
        replica.open()
    yield
    primary.close()
    if replica:
        replica.close()


app = FastAPI(title="Helpdesk", lifespan=lifespan)
app.mount("/metrics", make_asgi_app())  # à scraper en interne, ne pas router vers l'extérieur


class TicketIn(BaseModel):
    title: str = Field(min_length=3, max_length=120)
    description: str = Field(min_length=1, max_length=2000)
    email: str = Field(pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$", max_length=254)


# Le cache est un accélérateur, pas une dépendance : si Redis tombe, on lit la base.
def cache_get() -> list | None:
    if not cache:
        return None
    try:
        raw = cache.get(CACHE_KEY)
    except redis.RedisError:
        return None
    return json.loads(raw) if raw else None


def cache_set(tickets: list) -> None:
    if cache:
        try:
            cache.set(CACHE_KEY, json.dumps(tickets), ex=CACHE_TTL)
        except redis.RedisError:
            pass


def cache_invalidate() -> None:
    if cache:
        try:
            cache.delete(CACHE_KEY)
        except redis.RedisError:
            pass


def send_mail(ticket: dict) -> None:
    if not SMTP_HOST:
        return
    try:
        msg = EmailMessage()
        msg["From"] = "helpdesk@helpdesk.localhost"
        msg["To"] = ticket["email"]
        title = " ".join(ticket["title"].split())  # pas de retour à la ligne dans un en-tête
        msg["Subject"] = f"Ticket #{ticket['id']} créé : {title}"
        msg.set_content(f"Votre demande a bien été enregistrée.\n\n{ticket['description']}")
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=5) as smtp:
            smtp.send_message(msg)
        MAIL_SENT.inc()
    except Exception:
        MAIL_ERRORS.inc()


@app.get("/health")
def health():
    with primary.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


@app.get("/api/tickets")
def list_tickets(response: Response):
    tickets = cache_get()
    hit = tickets is not None
    if not hit:
        with primary.connection() as conn:
            tickets = conn.execute(f"SELECT {COLUMNS} FROM tickets ORDER BY id DESC").fetchall()
        cache_set(tickets)
    CACHE_REQUESTS.labels("hit" if hit else "miss").inc()
    response.headers["X-Cache"] = "HIT" if hit else "MISS"
    return tickets


@app.post("/api/tickets", status_code=201)
def create_ticket(ticket: TicketIn, background: BackgroundTasks):
    with primary.connection() as conn:
        row = conn.execute(
            f"INSERT INTO tickets (title, description, email) VALUES (%s, %s, %s) RETURNING {COLUMNS}",
            (ticket.title, ticket.description, ticket.email),
        ).fetchone()
    cache_invalidate()
    TICKETS_CREATED.inc()
    background.add_task(send_mail, row)  # après la réponse : un SMTP lent ne ralentit pas l'utilisateur
    return row


@app.post("/api/tickets/{ticket_id}/close")
def close_ticket(ticket_id: int):
    with primary.connection() as conn:
        row = conn.execute(
            f"UPDATE tickets SET status = 'closed' WHERE id = %s RETURNING {COLUMNS}", (ticket_id,)
        ).fetchone()
    if row is None:
        raise HTTPException(404, "Ticket introuvable")
    cache_invalidate()
    TICKETS_CLOSED.inc()
    return row


@app.get("/api/stats")
def stats():
    # Lecture de reporting : tolère quelques ms de retard, donc servie par le réplica s'il existe.
    # Réplica absent ou indisponible -> repli sur le primaire.
    query = "SELECT status, count(*) AS total FROM tickets GROUP BY status"
    source = "primary"
    rows = None
    if replica:
        try:
            with replica.connection() as conn:
                rows, source = conn.execute(query).fetchall(), "replica"
        except psycopg.OperationalError:
            rows = None
    if rows is None:
        with primary.connection() as conn:
            rows, source = conn.execute(query).fetchall(), "primary"
    return {"source": source, "counts": {r["status"]: r["total"] for r in rows}}
