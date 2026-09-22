# OwnRun all-in-one (try it)

Run the SPA, PHP API, Python runner, MariaDB, and Ollama with one command. This is for **trying OwnRun**, not a replacement for the production split (shared hosting + home runner).

Production still looks like [DEPLOYMENT.md](../DEPLOYMENT.md): static web + PHP on a host, runner on the home PC.

## Quick start

Clone the three code repos as siblings of this design repo (or point `.env` at them):

```text
ownrun-server/
ownrun-web/
ownrun-runner/
ownrun-design/     ← you are here, in aio/
```

```bash
cd ownrun-design/aio
cp .env.example .env   # edit paths if your clones are not siblings
./up.sh
```

`up.sh` copies the three repos into `src/` (so the image build works with Docker Compose 1.29 and v2), then runs `docker compose up --build`. Equivalent:

```bash
./prepare-context.sh
docker-compose up --build
```

Then open **http://localhost:8080** and log in as `admin` / `ownrun`.

The first start downloads images, builds the OwnRun image, and pulls `llama3.2`, `frob/qwen3.5-instruct:4b`, and `nomic-embed-text` into Ollama. That can take several minutes and a few GB of disk.

## What is in the stack

| Service | Role |
|---------|------|
| `ownrun` | Nginx + PHP-FPM (SPA + API) + Python runner |
| `db` | MariaDB 11 |
| `ollama` | Local LLM API the runner calls |
| `ollama-init` | One-shot `ollama pull` of chat + KB embed models |

Image generation (Stable Diffusion Forge) is **off**. The exclusive GPU gate is a home-machine concern; use the normal runner install for that.

## Useful environment

Set these in `.env` (see `.env.example`):

| Variable | Default | Meaning |
|----------|---------|---------|
| `OWNRUN_SERVER_DIR` | `../ownrun-server` | Build context for the PHP API |
| `OWNRUN_WEB_DIR` | `../ownrun-web` | Build context for the Vue SPA |
| `OWNRUN_RUNNER_DIR` | `../ownrun-runner` | Build context for the Python runner |
| `OWNRUN_PORT` | `8080` | Host port |
| `OWNRUN_ADMIN_USER` / `OWNRUN_ADMIN_PASSWORD` | `admin` / `ownrun` | Login (re-applied on each start) |
| `OWNRUN_TIMEZONE` | `UTC` | Runner timezone for journal/tasks |
| `OWNRUN_OLLAMA_MODEL` | `llama3.2 frob/qwen3.5-instruct:4b` | Space-separated chat models pulled on first start; empty skips |
| `OWNRUN_KB_EMBED_MODEL` | `nomic-embed-text` | KB embeddings; empty skips the pull |
| `OLLAMA_BASE_URL` | `http://ollama:11434` | Runner → Ollama |
| `OLLAMA_API_KEY` | empty | Optional cloud `web_search` for agent jobs |

JWT secret and runner token are generated on first boot and stored in the `data` volume (`/data/secrets.env`). You can set `OWNRUN_JWT_SECRET` / `OWNRUN_RUNNER_TOKEN` to pin them.

Use **`frob/qwen3.5-instruct:4b`** in the SPA for agent/tool work; keep `llama3.2` if you want a lighter option.

## Extra models

If you started before these defaults, pull what you need:

```bash
docker-compose exec ollama ollama pull frob/qwen3.5-instruct:4b
docker-compose exec ollama ollama pull nomic-embed-text
```

Or re-run init after updating `.env`:

```bash
docker-compose up ollama-init
```

A smaller first pull: `OWNRUN_OLLAMA_MODEL=llama3.2:1b`.

## GPU

CPU Ollama works but is slow. With an NVIDIA GPU:

```bash
docker-compose -f docker-compose.yml -f docker-compose.gpu.yml up --build
```

Requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).

## Use Ollama on the host

If you already run Ollama on the machine:

```env
OLLAMA_BASE_URL=http://host.docker.internal:11434
OWNRUN_OLLAMA_MODEL=
```

The bundled `ollama` container still starts but is unused. You can `docker-compose up --build ownrun db` to skip it.

## Persistence

Compose volumes: MariaDB (`db`), Ollama models (`ollama`), runner workspace/KB index (`data`), and PHP uploads/artifacts (`storage`).

On each `ownrun` start, `setup.php` plus every `scripts/migrate_*.php` run so an existing DB volume picks up new columns/tables after you rebuild. Wipe a try-it instance with `docker-compose down -v`.

## Health

`GET /api/index.php/health` returns `{"ok":true}` when PHP can talk to MariaDB.
