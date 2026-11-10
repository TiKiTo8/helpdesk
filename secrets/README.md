# Secrets

Chaque mot de passe est un fichier de ce dossier, monté dans le conteneur sous `/run/secrets/<nom>`.
Les `*.txt` ne sont pas versionnés : chacun crée les siens avant le premier `docker compose up`.

| Fichier | Utilisé par |
|---|---|
| `db_password.txt` | `db`, `backup` (administrateur de la base) |
| `replication_password.txt` | `db`, `db-replica` |
| `app_password.txt` | `db`, l'application (compte `app`) |

Linux / macOS :

```bash
openssl rand -base64 24 | tr -d '\n' > secrets/db_password.txt
openssl rand -base64 24 | tr -d '\n' > secrets/replication_password.txt
openssl rand -base64 24 | tr -d '\n' > secrets/app_password.txt
```

Windows (PowerShell) :

```powershell
[IO.File]::WriteAllText("$PWD\secrets\db_password.txt", "mot-de-passe")
[IO.File]::WriteAllText("$PWD\secrets\replication_password.txt", "autre-mot-de-passe")
[IO.File]::WriteAllText("$PWD\secrets\app_password.txt", "encore-un-autre")
```

Sous Linux, garder les droits par défaut (`644`) : le fichier est lu par l'utilisateur `postgres` du conteneur.
