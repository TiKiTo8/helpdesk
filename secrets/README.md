# Secrets

Chaque mot de passe est un fichier de ce dossier, monté dans le conteneur sous `/run/secrets/<nom>`.
Les `*.txt` ne sont pas versionnés : chacun crée les siens avant le premier `docker compose up`.

| Fichier | Utilisé par |
|---|---|
| `db_password.txt` | `db`, `backup` |
| `replication_password.txt` | `db`, `db-replica` |

Linux / macOS :

```bash
openssl rand -base64 24 | tr -d '\n' > secrets/db_password.txt
openssl rand -base64 24 | tr -d '\n' > secrets/replication_password.txt
```

Windows (PowerShell) :

```powershell
[IO.File]::WriteAllText("$PWD\secrets\db_password.txt", "mot-de-passe")
[IO.File]::WriteAllText("$PWD\secrets\replication_password.txt", "autre-mot-de-passe")
```

Sous Linux, garder les droits par défaut (`644`) : le fichier est lu par l'utilisateur `postgres` du conteneur.
