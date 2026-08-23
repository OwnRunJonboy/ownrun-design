# OwnRun — deployment guide

Three repos deploy to one domain. **No `mod_rewrite`.**

```
https://example.com/                    → ownrun-web (Vue SPA, hash routes)
https://example.com/api/index.php/...   → ownrun-server (PHP front controller)
```

Home computer runs **ownrun-runner** (Python) with Ollama.

## 1. ownrun-server

1. Copy `config.example.php` → `config.php`; set DB credentials and a long random `jwt_secret`.
2. Create MariaDB database and user.
3. Run setup (prints runner token once):

```bash
php scripts/setup.php --username=admin --password=YOUR_PASSWORD
```

4. Deploy so `api/` is web-reachable as `/api/` (keep `config.php` and `src/` one level above `api/`).

Clients call the front controller with PATH_INFO — no rewrite needed:

```
POST /api/index.php/auth/login
POST /api/index.php/runner/heartbeat
POST /api/index.php/runner/jobs/claim
```

If PATH_INFO is disabled on the host, the same routes work as ` /api/index.php?r=/runner/heartbeat `.

Local PHP built-in server (router script, still no Apache rewrite):

```bash
php -S localhost:8080 -t api api/index.php
```

Local Apache (this machine): API is at `http://localhost/ownrun-server/api/index.php/...`.

## 2. ownrun-web

```bash
npm install
npm run build
```

Deploy `dist/` to site root. The SPA uses **hash routing** (`/#/login`) so Apache does not need rewrite. Asset URLs are relative (`base: './'`), so the same build also works in a subdirectory.

API calls go to `/api/index.php/...` on the same host.

Local Apache (this machine): open `http://localhost/~jonboy/ownrun-web/dist/` after build. The client detects `/ownrun-web` in the path and calls the sibling API (`/~jonboy/ownrun-server/api/index.php`). Override with `VITE_API_BASE` if needed:

```bash
VITE_API_BASE=/ownrun-server/api/index.php npm run build
```

Local Vite (proxies `/api` → `http://localhost:8080`):

```bash
npm run dev
```

## 3. ownrun-runner (home PC)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export OWNRUN_SERVER_URL=https://example.com
export OWNRUN_RUNNER_TOKEN=<token from setup>
python run.py
```

`OWNRUN_SERVER_URL` is the site origin only (no `/api`). The runner appends `/api/index.php`.

Local Apache example:

```bash
export OWNRUN_SERVER_URL=http://localhost/ownrun-server
```

Ensure Ollama is running locally (`ollama serve`).

## End-to-end check (v1)

1. Log in at `/#/login`
2. Confirm runner badge shows **online** (runner sending heartbeats)
3. **New chat** → pick model, enter prompt, submit
4. Job moves queued → running → succeeded; result text appears on job detail
5. **New agent** → pick model + profile, enter a task; watch the tool trace while running
6. Stop runner → badge **offline**; new jobs stay queued

For agent support on an existing database, run `php scripts/migrate_agent.php` in ownrun-server once.

## Repository layout

| Path | Repo |
|------|------|
| `/home/jonboy/public_html/ownrun-server` | PHP API |
| `/home/jonboy/public_html/ownrun-web` | Vue SPA |
| `/home/jonboy/python/ownrun-runner` | Python runner |
| `/home/jonboy/Documents/ownrun-design` | Design doc |
