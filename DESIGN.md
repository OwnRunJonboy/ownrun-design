# OwnRun Design Document

**Status:** Draft  
**Date:** 2026-08-16  
**Author:** Jonboy

**Related:** [AGENT.md](AGENT.md) — agent jobs (`agent.task`) via Autogen AgentChat on the home runner. [CALENDAR.md](CALENDAR.md) — personal calendar in the SPA, with agent search/view/add/edit/delete tools. [JOURNAL.md](JOURNAL.md) — personal journal in the SPA, home-page memory card, and agent journal tools (project CRUD; global read-only). [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md) — saved system-prompt library and global/per-project defaults for chat and agent jobs. [TASKS.md](TASKS.md) — personal task tracker in the SPA, home-page due card, and agent task tools (project CRUD; global read-only). [WEB_SEARCH.md](WEB_SEARCH.md) — agent web search via Ollama’s cloud API (`web_search` + existing `http_fetch`). [TOOL_POLICY.md](TOOL_POLICY.md) — per-project and per-job tool disables. [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md) — personal RAG: upload PDF/DOCX/EPUB, runner embed/index, agent `kb_*` tools. [IMAGE_GENERATION.md](IMAGE_GENERATION.md) — Stable Diffusion txt2img jobs, artifacts, and exclusive Ollama↔SD backend gate. None of these replace this document.

## 1. Purpose

OwnRun makes local AI tools running on a home computer available when away from that computer.

The user submits requests from a web frontend while remote. A lightweight runner on the home machine picks up those requests, executes them against local AI tools, and uploads results. The user then views results in the same web frontend.

OwnRun is a **personal remote-access bridge** for local AI—not a multi-tenant SaaS product.

## 2. Goals

- Submit AI jobs from a phone or another computer while away from home.
- Execute those jobs on the home machine against local AI tools (**Ollama** for text in v1; **Stable Diffusion** for images later).
- Return results to the web UI for later viewing (text in v1; image files in a later phase).
- Run the public backend on **shared hosting** (PHP + MariaDB, no long-lived server processes).
- Keep the home runner simple, reliable, and restartable.

## 3. Non-goals (initial version)

- Multi-user or multi-tenant accounts.
- Real-time streaming of model tokens to the browser.
- Peer-to-peer or direct inbound connections to the home machine (no port forwarding required).
- Running arbitrary shell commands from the web UI (only predefined tool/job types).
- Image generation in v1 (deferred until text flow is solid; then Stable Diffusion).
- Agentic tool loops in v1 (deferred; see [AGENT.md](AGENT.md) for the agent job type).
- High availability / multi-runner clustering.
- Mobile native apps.

## 4. System overview

OwnRun has three components:

| Component | Stack | Where it runs | Role |
|-----------|--------|---------------|------|
| **ownrun-server** | PHP | Shared hosting | Web API + persistence; stores jobs and results |
| **ownrun-web** | Vue | Shared hosting (static / SPA) | Remote UI for submitting jobs and viewing results |
| **ownrun-runner** | Python | Home computer | Polls for jobs, runs local AI tools, uploads results |

```
┌─────────────────┐         HTTPS          ┌──────────────────┐
│   ownrun-web    │ ─────────────────────► │  ownrun-server   │
│  (Vue SPA)      │ ◄───────────────────── │  (PHP + MariaDB) │
└─────────────────┘                        └────────┬─────────┘
                                                    │
                         HTTPS poll / claim / upload│
                                                    ▼
                                           ┌──────────────────┐
                                           │  ownrun-runner   │
                                           │  (Python @ home) │
                                           └────────┬─────────┘
                                                    │
                                                    ▼
                                           ┌──────────────────┐
                                           │  Ollama (v1)     │
                                           │  (+ SD later)    │
                                           └──────────────────┘
```

**Key architectural choice:** The home machine never accepts inbound connections. The runner **pulls** work from the server. This fits shared hosting and avoids exposing the home network.

## 5. Components

### 5.1 ownrun-server (PHP)

**Responsibilities**

- Authenticate the web user and the runner.
- Accept new job submissions from the web UI.
- Queue jobs for the runner.
- Allow the runner to claim pending jobs and report progress/completion.
- Store and serve job metadata and results.
- Enforce basic rate limits and job size limits appropriate for shared hosting.

**Hosting constraints**

- No persistent background workers on the server.
- Request/response PHP only (typical shared hosting).
- File uploads and result blobs must respect hosting disk and PHP upload limits.
- Prefer a simple relational schema (MariaDB) over exotic infrastructure.

**Suggested layout (conceptual)**

- Public API entrypoints (REST-style JSON).
- Auth middleware / token validation.
- Job and result storage (DB + filesystem for large artifacts).
- Config via environment / local config outside the web root where possible.

### 5.2 ownrun-web (Vue)

**Responsibilities**

- Login against ownrun-server (optional **Remember me**); persist JWT + refresh tokens so return visits stay signed in. Send `Authorization: Bearer <access_jwt>` on API calls.
- Create jobs (v1: text prompt + selected Ollama model; later: image jobs via Stable Diffusion).
- List jobs with status (queued, running, succeeded, failed, cancelled).
- Show job detail and results (v1: text; later: downloadable images).
- Optionally cancel a queued job before the runner claims it.
- Requeue a failed job (including lease-timeout failures) back to `queued` for another attempt.

**UX principles (v1)**

- Small personal tool: job list + job detail + new text job form.
- New job form includes a **user-selectable model list** (not a hidden fixed model).
- Clear status and timestamps (created, started, finished).
- Failures surfaced with runner error messages.
- No dashboard clutter; one primary flow: pick model → submit prompt → wait → read text result.

### 5.3 ownrun-runner (Python)

**Responsibilities**

- Authenticate to ownrun-server with a runner credential.
- Periodically poll for claimable jobs.
- Claim one job at a time (or a small concurrency limit, default 1).
- Dispatch to the correct local tool adapter (Ollama `/api/chat` in v1; Stable Diffusion later).
- Upload status updates and final results.
- Handle retries for transient network errors; mark hard failures clearly.
- Be safe to stop and restart (idempotent claim/heartbeat where practical).

**Runtime model**

- Long-running process on the home machine (systemd user service, launchd, or simple foreground loop).
- Configurable poll interval (e.g. 5–15 seconds).
- Local config for server URL, runner token, tool endpoints, and timeouts.

## 6. Job lifecycle

```
created ──► queued ──► claimed/running ──► succeeded
                         │
                         ├──► failed
                         └──► cancelled (only if still queued, or via explicit cancel support later)
```

### States

| State | Meaning |
|-------|---------|
| `queued` | Accepted by server; waiting for runner |
| `running` | Claimed by runner; execution in progress |
| `succeeded` | Runner uploaded a successful result |
| `failed` | Runner or server recorded a failure |
| `cancelled` | User cancelled before execution completed (v1: primarily pre-claim) |

### Happy path

1. User creates a job in ownrun-web.
2. Server stores the job as `queued`.
3. Runner polls `GET` pending jobs (or a claim endpoint).
4. Runner claims a job; server marks it `running` and records claim time / runner id.
5. Runner executes against local AI.
6. Runner uploads result payload and marks `succeeded` (or `failed` with error detail).
7. Web UI refreshes or polls and shows the result.

### Failure and timeout handling

- **Runner crash / stalled job after claim:** If a job stays `running` past a **long** lease/heartbeat timeout, the server marks it `failed` with an error such as “runner lease expired”. It does **not** auto-requeue.
- **Manual requeue:** The user can requeue a `failed` job from the web UI. Requeue clears runner ownership and result/error fields as needed and sets status back to `queued` so the runner can claim it again.
- **Lease duration:** Intentionally long (on the order of tens of minutes to an hour+), because local Ollama jobs can be slow. Exact default is configurable on the server (e.g. 60 minutes); heartbeats from the runner extend the lease while work is in progress.
- **Ollama down:** Runner marks job `failed` with a clear error; does not silently drop the job.
- **Upload failure:** Runner retries result upload with backoff; if still failing after N attempts, leave local log and rely on lease expiry on the server (then manual requeue).
- **Duplicate claim:** Claiming must be atomic (DB transaction / conditional update) so two runner instances cannot both own the same job.

## 7. Data model (logical)

### User

Personal single-user is enough for v1, but store a user record for future flexibility.

- `id`, `email` or `username`, `password_hash`, `token_version`, `created_at`

### Refresh token

Server-stored, hashed; used to mint new access JWTs without re-entering a password.

- `id`, `user_id`, `token_hash`, `family_id`, `expires_at`, `remember_me` (bool), `created_at`, `last_used_at`, `revoked_at` (nullable)

### Runner

- `id`, `name`, `token_hash`, `last_seen_at`, `enabled`
- `available_models` (JSON list last reported from Ollama; used by `GET /api/models`)

One active runner expected initially; schema should still allow multiple named runners later.

### Job

- `id` (integer primary key; MariaDB `AUTO_INCREMENT`)
- `user_id`
- `runner_id` (nullable until claimed)
- `type` (v1: `ollama.chat`; later: `agent.task`, `stablediffusion.txt2img`)
- `status`
- `request_payload` (JSON: messages and/or prompt fields mapped to Ollama chat, model, parameters)
- `result_payload` (JSON: text response and metadata in v1; image metadata later)
- `error_message` (nullable)
- `created_at`, `queued_at`, `claimed_at`, `finished_at`
- `lease_expires_at` (nullable; for running jobs)

### Job artifact (filesystem mapping; needed when images land)

- `id`, `job_id`, `kind` (`input` | `output`), `filename`, `content_type`, `storage_path`, `size_bytes`

v1 text results can live entirely in `result_payload`. Artifact storage becomes important when Stable Diffusion outputs images.

## 8. API shape (conceptual)

All API traffic over HTTPS. JSON request/response bodies unless uploading files (multipart).

### Auth

- **Web user (SPA):** JWT access tokens + refresh tokens + remember-me. Login returns a signed **access JWT**. ownrun-web sends `Authorization: Bearer <access_jwt>` on API requests. No server session cookies.
- **Runner:** long-lived opaque runner API token (stored hashed on server; presented as bearer token). Not a JWT—machine credentials stay rotatable and revocable without waiting for JWT expiry.

Separate credentials for UI and runner. Compromising a web access JWT should not grant runner privileges.

**Access JWT**

- Signed JWT (HS256 with a server secret; reject any other `alg`).
- Claims: user id (`sub`), token version (`ver`), expiry, issued-at; keep payload small.
- Lifetime: **short** (e.g. **15 minutes**). The SPA refreshes before expiry and retries once on 401.
- `ver` must match `users.token_version`. Logout (and refresh-token reuse) increments the version so outstanding access JWTs die immediately.

**Refresh tokens**

- Opaque random secrets, stored **hashed** in MariaDB (revocable). Grouped by `family_id` so rotation can detect reuse.
- `POST /api/auth/refresh` returns a new access JWT and a **rotated** refresh token in the same family.
- Presenting a already-revoked refresh token revokes the whole family and bumps `token_version`.
- Default (login without Remember me): e.g. **7 days**, persisted in `sessionStorage` so closing the browser ends the refresh chain.

**Remember me**

- Login accepts `remember_me: true`.
- Issues a remember-me refresh token with a **30 day** lifetime (survive browser restart, not a year).
- SPA stores **only the refresh token** in `localStorage`. The access JWT stays in memory / `sessionStorage`.
- Same refresh endpoint; rotation keeps the remember-me expiry policy (do not silently downgrade a remember-me token to a short one).

**Logout / revocation**

- `POST /api/auth/logout` revokes the presented refresh **family** and increments `users.token_version`.
- Other devices keep their own refresh families and mint a new access JWT on the next refresh.
- Password change (if added later) should revoke all refresh tokens and bump `token_version`.

**SPA storage**

- Access JWT: memory plus `sessionStorage` only — never `localStorage`.
- Refresh / remember-me token: `localStorage` if Remember me, else `sessionStorage`.
- On app load: if a refresh token exists, refresh immediately.

Same-origin SPA + `/api` means the browser does not need CORS for ownrun-web. Cookies are not the primary auth mechanism. The runner is a non-browser client, so CORS does not apply to it.

### Web-facing endpoints (illustrative)

- `POST /api/auth/login` — `{ username, password, remember_me }`; returns access JWT + refresh token
- `POST /api/auth/refresh` — `{ refresh_token }`; returns new access JWT + rotated refresh token
- `POST /api/auth/logout` — revoke the presented refresh family and bump token version (SPA then discards JWTs)
- `GET  /api/jobs`
- `POST /api/jobs` — create job (includes selected `model`)
- `GET  /api/jobs/{id}`
- `POST /api/jobs/{id}/cancel` — if still `queued`
- `POST /api/jobs/{id}/requeue` — if `failed`; returns job to `queued`
- `GET  /api/models` — models last reported by the runner (for the SPA selector)
- `GET  /api/jobs/{id}/artifacts/{artifactId}` — download (post-v1, for images)

### Runner-facing endpoints (illustrative)

- `POST /api/runner/heartbeat` — update `last_seen_at`; may include current Ollama model list
- `POST /api/runner/jobs/claim` — atomically claim next eligible job (filter by type/capabilities optional)
- `POST /api/runner/jobs/{id}/heartbeat` — extend lease while running
- `POST /api/runner/jobs/{id}/complete` — success + result metadata
- `POST /api/runner/jobs/{id}/fail` — failure + error message
- `POST /api/runner/jobs/{id}/artifacts` — upload output files (post-v1)

Exact paths can evolve; the important v1 contract is **claim → heartbeat → complete/fail**. Artifact upload is added with image support.

## 9. Job types and local tool adapters

Jobs are typed. The runner maps `type` to a local adapter.

**v1 (text only — Ollama)**

1. **Ollama chat** (`ollama.chat`) — call Ollama on localhost at `/api/chat` with `stream: false` and the **model chosen in the web UI**; return assistant text (and optional model/timing metadata). The web form collects model + user prompt (and optional system prompt, from a saved library or project default — see [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md)); the runner builds the `messages` array.
2. **Health / echo** (optional) — diagnostic job to verify runner connectivity without invoking a model.

**Model list**

- The web UI presents a selectable list of models when creating a job.
- The runner periodically reports models available from Ollama (e.g. via heartbeat / capabilities sync, using Ollama’s local model list).
- ownrun-server stores the latest reported list and exposes it to the SPA (e.g. `GET /api/models`).
- The selected model name is stored on the job (`request_payload.model`) and passed through to `/api/chat`.
- If the user selects a model that is no longer installed when the runner runs the job, the runner marks the job `failed` with a clear error (user can requeue after fixing models).

**Later (after text flow is solid)**

3. **Agent task** (`agent.task`) — runner adapter runs Autogen AgentChat against local Ollama plus a sandboxed tool catalog. See [AGENT.md](AGENT.md). Independent of images.
4. **Stable Diffusion text-to-image** — runner adapter invokes the local SD toolchain; uploads image artifact(s) to the server; web UI displays/downloads images.

**Adapter interface (conceptual)**

- Input: normalized job request JSON.
- Output: normalized result JSON + optional file paths (unused in v1 text path).
- Errors: raised as structured failures the runner reports to the server.

The web UI only offers job types the server advertises (static config at first; later dynamic from runner capabilities). v1 UI is a text job form with a model selector populated from the runner’s reported Ollama models.

## 10. Security

OwnRun deliberately exposes a path from the public internet to local compute. Security is foundational.

### Threat model (personal use)

- Attacker discovers the hosted URL and tries to submit jobs or steal results.
- Attacker steals runner token and drains/abuses the queue.
- Shared hosting neighbor or misconfiguration exposes files.
- Prompt injection against local tools is secondary; arbitrary remote code execution via job types must be avoided by limiting job types.

### Controls (v1)

- HTTPS only.
- Strong password hashing for the web user (e.g. Argon2id / bcrypt).
- Runner token: long random secret, stored hashed, rotatable.
- Authorization checks on every job access (user owns job).
- Runner endpoints require runner auth; web endpoints require user auth.
- Do not allow free-form shell job types in v1.
- Limit request payload size, artifact size, and jobs created per time window.
- Store secrets outside the web-accessible document root where hosting allows.
- Same-origin SPA at `/` with API at `/api` (no CORS required for the web UI). If a separate origin is used later, restrict CORS to that origin.
- Basic audit fields: created IP (optional), timestamps, status transitions.

### Operational practices

- Rotate runner token if the home machine is untrusted or the token leaks.
- Keep Ollama (and later Stable Diffusion) bound to localhost on the home machine.
- Runner should only call configured local base URLs (localhost), not arbitrary remote URLs from job payloads.

## 11. Polling, latency, and UX expectations

- Default poll interval: ~5–15s. Acceptable for personal asynchronous jobs.
- Web UI may poll job detail every few seconds while status is `queued` or `running`.
- No WebSockets required on shared hosting for v1.
- Users should expect “submit and check back,” not interactive chat latency—though short jobs may complete within one or two poll cycles when the runner is online.

**Runner online indicator:** derived from `last_seen_at` within a recent window (e.g. 60s). Show “Runner offline” in the UI when stale so the user knows queued jobs will wait.

## 12. Configuration

### Server

- Database credentials
- App secret for **JWT signing**
- Refresh-token hashing
- Access JWT TTL (short; e.g. 15 minutes)
- Refresh TTL (e.g. 7 days) and remember-me TTL (e.g. 30 days)
- Artifact storage path
- Max upload sizes
- Allowed CORS origins (optional; not required while SPA and API share one origin)
- Job lease timeout (long default, e.g. 60 minutes)

### Runner

- `OWNRUN_SERVER_URL`
- `OWNRUN_RUNNER_TOKEN`
- Poll interval, claim batch size (1)
- Ollama base URL (default `http://127.0.0.1:11434`)
- Per-job timeout
- Working directory for temp files
- Later: Stable Diffusion executable/API path and defaults

(No fixed “only this model” setting required; the UI selects the model per job. An optional runner-side allowlist can be added later if desired.)

### Web

- API base URL: same origin, `/api` (relative, e.g. `/api`)
- SPA public path: site root (`/`)

## 13. Deployment topology

```
Shared hosting (single domain)
├── /               → ownrun-web (built SPA static assets)
├── /api/           → ownrun-server (PHP)
└── MariaDB         (jobs, users, tokens metadata)
    + artifact files on disk (outside public root if possible)

Home computer
├── ownrun-runner      (Python service)
├── Ollama             (localhost only; v1)
└── Stable Diffusion   (localhost only; later)
```

API and SPA share one domain. The Vue SPA is served at **site root** (`https://example.com/`); the PHP API lives under **`/api`** (`https://example.com/api/...`). Same-origin deployment simplifies CORS for the bearer-token SPA; HTTPS is still required.

SPA history-mode routing (if used) must rewrite unknown paths to `index.html` **except** `/api` (and static assets), so PHP requests are not swallowed by the frontend.

## 14. Observability and operations

**v1 needs**

- Server: structured error responses; PHP error logging.
- Runner: local log file / stdout with job id, state transitions, durations.
- UI: display server/runner error strings on failed jobs.

**Helpful later**

- Simple admin “runner last seen” and recent failures list.
- Retention policy: delete old jobs/artifacts after N days.

## 15. Implementation phases

### Phase 0 — Foundations

- Design finalized (this document).
- Repos/directories for server, web, runner.
- Auth + empty job list end-to-end.

### Phase 1 — Minimal vertical slice (text / Ollama)

- Create text job from web (prompt + **user-selected model** from runner-reported list).
- Runner claims and completes via Ollama `/api/chat` on localhost.
- View result text in web UI.
- Runner online/offline indicator.

### Phase 2 — Robustness

- Heartbeats / long lease expiry → `failed` (no auto-requeue).
- Manual requeue of failed jobs from the web UI.
- Cancel queued jobs.
- Better error surfaces and size limits.
- Retention cleanup; runner packaging (systemd / install docs).

### Phase 3 — Images (Stable Diffusion)

Specified in [IMAGE_GENERATION.md](IMAGE_GENERATION.md).

- Artifact upload/download on server and web.
- Runner Stable Diffusion adapter (`stablediffusion.txt2img`).
- **Exclusive backend gate:** runner fully stops Ollama before starting SD and vice versa (simultaneous use crashes this laptop).
- Web UI: submit image jobs and view/download results.
- Keep Ollama text/agent/KB adapters unchanged aside from going through the gate.

### Phase 4 — Agents (Autogen AgentChat)

Independent of Phase 3. Specified in [AGENT.md](AGENT.md).

- New job type `agent.task`; keep `ollama.chat` unchanged.
- Runner adapter: single `AssistantAgent` + Ollama client + sandboxed tools.
- Web UI: new agent task form; job detail shows a tool/message trace.
- No Magentic-One, no shell, no human-in-the-loop in the first agent slice.

### Phase 5 — Calendar

Independent of images. Specified in [CALENDAR.md](CALENDAR.md). Can follow agent Phase 4a; agent tools (5b) need `agent.task`.

- MariaDB `calendar_entries`; SPA month view and user CRUD (works with the runner offline).
- Optional `project` on entries; agents see/write a job-scoped slice.
- Runner tools on existing agent profiles; not a new job type.

### Phase 6 — Journal

Independent of images. Specified in [JOURNAL.md](JOURNAL.md). Can follow calendar Phase 5; agent tools (6b) need `agent.task`.

- MariaDB `journal_entries`; SPA list/create/edit/delete and home-page memory card (works with the runner offline).
- Optional `project` on entries; agents read global ∪ job project, write job project only.
- Runner tools on existing agent profiles; not a new job type.

### Phase 7 — System prompts

Independent of journal tools. Specified in [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md). Needs both chat and agent forms. No new runner tools.

- MariaDB prompt library plus global and per-project defaults (works with the runner offline).
- New chat / New agent load, save, and auto-fill; jobs still snapshot `system_prompt` text.
- Optional `project` on `ollama.chat` for default lookup only.

### Phase 8 — Tasks

Independent of the prompt library. Specified in [TASKS.md](TASKS.md). Can follow journal Phase 6; agent tools (8b) need `agent.task`.

- MariaDB `task_entries`; SPA list/create/edit/delete and home-page due card (works with the runner offline).
- Optional `project` on tasks; agents read global ∪ job project, write job project only.
- Runner tools on existing agent profiles; not a new job type.

### Phase 9 — Web search and project tool policy

Independent of the prompt library and of tasks. Specified in [WEB_SEARCH.md](WEB_SEARCH.md) and [TOOL_POLICY.md](TOOL_POLICY.md). Needs agent web profiles (Phase 4b).

- Native `web_search` tool calling Ollama’s cloud API (`OLLAMA_API_KEY` on runner); `http_fetch` unchanged.
- Per-project and per-job `disabled_tools` (subtract-only); New agent web search checkbox; full project settings UI later.
- Not a new job type. No custom MCP.

## 16. Decisions

1. **Local text backend:** Ollama (not LocalAI).
2. **v1 scope:** text jobs only.
3. **Images later:** Stable Diffusion, after the text path is solid.
4. **Web auth:** token-based SPA auth (bearer access JWT; no session-cookie auth).
5. **Job IDs:** integer primary keys (`AUTO_INCREMENT` in MariaDB). Sequential IDs are fine for this personal app.
6. **Lease / runner timeout:** mark the job `failed` (do not auto-requeue); allow **manual requeue** from the UI. Use a **long** lease timeout (configurable; default on the order of ~60 minutes) so slow Ollama runs are not cut off early.
7. **Hosting paths:** same domain; **SPA at site root** (`/`), **PHP API at `/api`**—not separate subdomains, and not an `/app` subdirectory for the frontend.
8. **Ollama API:** `/api/chat` (job type `ollama.chat`), non-streaming for v1.
9. **Model selection:** user-selectable list in the web UI; runner reports available Ollama models to the server; SPA loads them via `GET /api/models`; selected model is stored on each job.
10. **Token details:** **JWT access tokens**; **refresh tokens** and **remember-me tokens** to keep login rare. Suggested TTLs: access JWT ~15 minutes; session refresh ~7 days; remember-me refresh ~30 days. Rotate refresh tokens on use; store refresh/remember-me hashes in MariaDB; include `ver` in the access JWT so logout revokes it. Runner credentials remain opaque hashed tokens, not JWTs.
11. **Agents (post-v1):** Autogen AgentChat on the home runner, Ollama as the model only. Job type `agent.task`. Details in [AGENT.md](AGENT.md).

## 17. Open decisions

None remaining for v1 path layout. SPA is at `/`; PHP is at `/api`. Agent design decisions live in [AGENT.md](AGENT.md).

## 18. Success criteria (v1)

OwnRun v1 is successful when:

1. From a remote browser, a logged-in user can submit a text job.
2. While the home runner is online, the job completes against **Ollama** without any inbound home networking.
3. The user can open the job and read the model text output.
4. If the runner is offline, the job remains queued and the UI makes that obvious.
5. A stolen web access JWT cannot mint a new runner token; runner auth remains separate.
6. No image/artifact pipeline is required for v1 success.

---

*Next step after this design: scaffold ownrun-server, ownrun-web, and ownrun-runner without expanding scope beyond Phase 1 (Ollama text).*
