# Generic Docker Compose Stack

A generic multi-service Compose sandbox for quickly spinning up throwaway environments. All services share the local `./dockerVol` bind mount as their working directory, so files are easy to pass between host and containers.

## Files

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Main stack — Ubuntu and nginx services, plus commented-out service definitions (Fedora, Node, Python, ActiveMQ) to enable as needed |
| `docker-compose-db.yml` | Local dev database stack — Postgres 14 (data persisted to `./db_data`), memcached, and [Adminer](https://www.adminer.org/) DB admin UI on port 8080 |
| `dcu.cmd` | `docker-compose up --build -d` — build and start the stack |
| `dcs.cmd` | `docker-compose stop` — stop containers without removing them |
| `dcd.cmd` | `docker-compose down` — stop and remove containers |
| `dcr.cmd` | `docker-compose down -v` — stop and remove containers **and volumes** (destructive reset) |
| `dockerVol/` | Shared bind-mount directory for the main stack services |

## Usage

```bash
# Main sandbox stack
./dcu.cmd                                  # up
docker compose exec ubuntu bash            # shell into a service
./dcd.cmd                                  # down

# DB stack
docker compose -f docker-compose-db.yml up -d
psql -h 127.0.0.1 -p 5432 -U postgres      # connect to Postgres
# Adminer UI: http://localhost:8080
```

## Notes

- The DB stack hardcodes dev credentials (`postgres`/`password123`) — it is for **local development only**; change credentials before any shared or remote use.
- The helper scripts use the legacy `docker-compose` v1 CLI; with modern Docker installs, substitute `docker compose`.
