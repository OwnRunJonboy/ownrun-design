# OwnRun — deployment guide

**Try it first:** from this repo, `cd aio && ./up.sh`, then open http://localhost:8080 (`admin` / `ownrun`). See [aio/README.md](aio/README.md). That stack is for evaluation, not the production layout below.

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

**Knowledge-base uploads:** PHP’s default `upload_max_filesize` is often **2M**, which rejects most EPUBs. Set at least:

```ini
upload_max_filesize = 36M
post_max_size = 40M
```

in the **Apache/mod_php** `php.ini` (e.g. `/etc/php/8.2/apache2/php.ini`), then reload Apache. UserDir hosts usually cannot override this from `.htaccess`. Keep these ≥ `max_kb_upload_bytes` in `config.php` (default 32 MiB). `api/.user.ini` helps only on CGI/FPM hosts.

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

Ensure Ollama is running locally (`ollama serve`), **or** let OwnRun start/stop it via scripts when image generation is enabled (see below).

### Image generation (Forge)

Ollama and Stable Diffusion Forge must not run at the same time on a laptop that OOMs/crashes. Enable the exclusive backend gate:

```bash
php scripts/migrate_artifacts.php   # on ownrun-server once
# Add artifacts_* / sd_* keys from config.example.php to config.php if missing
# Apache must group-write storage/artifacts (same as storage/kb). migrate chmod 2770;
# if you created the dir by hand: chmod 2770 storage/artifacts

cp ownrun-runner/scripts/examples/*.sh ~/ownrun-scripts/
chmod +x ~/ownrun-scripts/*.sh
# Edit scripts for your Forge path / Ollama unit

export OWNRUN_SD_ENABLED=1
export OWNRUN_OLLAMA_START_SCRIPT=$HOME/ownrun-scripts/start-ollama.sh
export OWNRUN_OLLAMA_STOP_SCRIPT=$HOME/ownrun-scripts/stop-ollama.sh
export OWNRUN_SD_START_SCRIPT=$HOME/ownrun-scripts/start-sd.sh
export OWNRUN_SD_STOP_SCRIPT=$HOME/ownrun-scripts/stop-sd.sh
```

Smoke: **New image** → generate → view gallery; then **New chat** (runner stops Forge, starts Ollama). Do not start both stacks manually.

## End-to-end check (v1)

1. Log in at `/#/login`
2. Confirm runner badge shows **online** (runner sending heartbeats)
3. **New chat** → pick model, enter prompt, submit
4. Job moves queued → running → succeeded; result text appears on job detail
5. **New agent** → pick model, profile, and project (existing or new), enter a task; watch the tool trace while running
6. **Calendar** → `/#/calendar`; add an entry; optional project; confirm it remains after reload
7. **Knowledge** → `/#/knowledge`; create a knowledge base; upload a PDF/DOCX/EPUB; wait for status `ready` (runner must be online with `OWNRUN_KB_EMBED_MODEL` installed, e.g. `ollama pull nomic-embed-text`); run an agent task that calls `kb_search`
8. **New image** (when SD enabled) → prompt → succeeded job shows image gallery; confirm a following chat still works
9. Stop runner → badge **offline**; new jobs stay queued; calendar/journal/knowledge metadata still work (ingest waits)

For agent support on an existing database, run `php scripts/migrate_agent.php` in ownrun-server once (adds progress payload, agent capability columns, and `agent_projects`). For calendar support, run `php scripts/migrate_calendar.php` (adds `calendar_entries` and `runners.timezone`), then open `/#/calendar`. For knowledge bases, run `php scripts/migrate_kb.php` (adds `kb_bases` / `kb_documents` and creates `storage/kb`), add KB keys from `config.example.php` to `config.php`, and `pip install -r requirements.txt` on the runner. For image artifacts, run `php scripts/migrate_artifacts.php` (adds `job_artifacts` and runner SD columns) and add artifact keys from `config.example.php`. For login rate limits and lockout, run `php scripts/migrate_login_throttle.php` (adds `login_attempts` and `users.failed_login_count` / `locked_until`).

## Repository layout

| Path | Repo |
|------|------|
| `/home/jonboy/public_html/ownrun-server` | PHP API |
| `/home/jonboy/public_html/ownrun-web` | Vue SPA |
| `/home/jonboy/python/ownrun-runner` | Python runner |
| `/home/jonboy/Documents/ownrun-design` | Design doc |
