# n8n with Traefik (Docker Compose)

Self-hosted [n8n](https://n8n.io/) workflow automation behind [Traefik](https://traefik.io/) as a reverse proxy, with automatic HTTPS certificates from Let's Encrypt (TLS challenge), HSTS/security headers, and HTTP→HTTPS redirect. Based on the [official n8n server setup docs](https://docs.n8n.io/hosting/installation/server-setups/docker-compose/).

## Files

| File | Purpose |
| --- | --- |
| `compose.yaml` | Traefik + n8n services, named volumes for certs (`traefik_data`) and n8n data (`n8n_data`) |
| `.env` | Required environment variables (see below) — **gitignored**, so a fresh clone won't have one; create it before `docker compose up` |
| `local-files/` | Bind-mounted into the n8n container at `/files` for reading/writing local files from workflows |

## Setup

1. Create a `.env` file next to `compose.yaml`:

   ```dotenv
   # Where n8n will be reachable: https://${SUBDOMAIN}.${DOMAIN_NAME}
   DOMAIN_NAME=example.com
   SUBDOMAIN=n8n

   # Timezone used by Cron and other scheduling nodes
   GENERIC_TIMEZONE=America/Chicago

   # Email for Let's Encrypt certificate registration
   SSL_EMAIL=you@example.com
   ```

2. Point DNS for `${SUBDOMAIN}.${DOMAIN_NAME}` at the host (Let's Encrypt must be able to reach it on ports 80/443).

3. Start the stack:

   ```bash
   docker compose up -d
   ```

n8n is then available at `https://${SUBDOMAIN}.${DOMAIN_NAME}` (and bound locally at `127.0.0.1:5678`).

## Notes

- Traefik runs with `--api.insecure=true` (dashboard/API without auth). Fine for a homelab behind a firewall; disable or secure it for anything internet-facing.
- n8n data persists in the `n8n_data` named volume; removing volumes (`docker compose down -v`) wipes workflows and credentials.
