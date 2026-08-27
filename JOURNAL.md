# OwnRun Journal Design

**Status:** Draft  
**Date:** 2026-08-23  
**Author:** Jonboy  
**Depends on:** [DESIGN.md](DESIGN.md) (hosting, auth, API shape), [AGENT.md](AGENT.md) (agent jobs, tool catalog, project ids), [CALENDAR.md](CALENDAR.md) (project scoping pattern)

This document designs a **personal journal** stored on ownrun-server. The Vue SPA can view, edit, and manually add entries. The jobs home page surfaces a daily **memory** from the past. Agents can fully manage entries for their job’s project and can search and read global entries. It is not a new job type.

No implementation in this document.

## 1. Purpose

OwnRun already tracks jobs, agent work in project directories, and (with calendar) dated events. It has no durable place for **narrative notes** — reflections, decisions, session summaries, or life log entries — that both the user and agents can reuse.

Without a journal:

- The user cannot browse or add personal notes from the phone while away
- An agent cannot recall what was decided last week in this project unless it re-reads workspace files or re-derives context from old job traces
- Putting notes only in markdown under a project hides them from the SPA unless every view becomes an agent job
- The home page has no gentle “on this day” hook into past writing

The journal is **user data on the PHP host**, like jobs and calendar rows. Viewing and adding from the browser does not need the runner. Agents reach the same rows through a runner-authenticated API, scoped by the job’s project.

## 2. Goals

- Chronological journal view in ownrun-web, usable on a phone.
- Logged-in user can create, edit, and delete entries without the runner.
- Optional **project** on each entry. When set, that entry is primarily **owned by that project’s agents** for writes; the user still sees everything.
- Agents can **search, read, create, update, and delete** entries scoped to the running job’s project.
- Agents can **search and read** global (unscoped) entries as read-only context — not create, edit, or delete them.
- Jobs home page (`/#/`) shows one **memory** card: prefer an entry whose date is an anniversary of today (10 years, 1 year, or 1 month ago in the user’s civil calendar), otherwise a random past entry.
- Stay compatible with shared hosting: MariaDB, request/response PHP, no cron, no WebSockets.
- Reuse existing auth (user JWT vs runner token) and the agent **project id** rules from AGENT.md §10.2.

## 3. Non-goals (journal v1)

- Rich text, markdown rendering, or attachments/images in entries (plain text body only).
- Tags, moods, geolocation, or structured metadata beyond optional title, body, date, and project.
- Full-text search ranking tuning, semantic/embedding search, or “related entries.”
- Sharing entries with other users or per-entry ACLs beyond the agent project rule.
- Treating the journal as a job type or storing entries in the workspace directory.
- A dedicated `journal` agent profile (tools are added to existing profiles instead).
- Push notifications or scheduled “memory of the day” emails.
- Import/export (Day One, Obsidian, etc.).
- Restore UI, trash view, or hard purge of soft-deleted rows (rows remain with `deleted_at` set for a later path).
- Agent-created global entries (global rows are user-authored or migrated later; agents never stamp unscoped rows in v1).

## 4. Where it lives

Journal rows live in **MariaDB on ownrun-server**. They are not files under `OWNRUN_AGENT_WORKSPACE`.

```
┌─────────────────┐         HTTPS          ┌──────────────────┐
│   ownrun-web    │ ─────────────────────► │  ownrun-server   │
│  Journal view   │   user JWT CRUD        │  journal_entries │
│  Memory (home)  │   GET memory           │                  │
└─────────────────┘                        └────────┬─────────┘
                                                    │
                         runner token, scoped by    │
                         the running job’s project  │
                                                    ▼
                                           ┌──────────────────┐
                                           │  ownrun-runner   │
                                           │  journal_* tools │
                                           └──────────────────┘
```

**Why the server, not the workspace**

| Approach | Why not (for v1) |
|----------|------------------|
| Markdown in a project dir | SPA would need a job round-trip to read; global notes would not span projects |
| Runner-only local DB | Phone UI is offline whenever the runner is; DESIGN.md’s pull model has no inbound home access |
| Job `result_payload` | Jobs are runs, not durable user records |

The runner never accepts inbound connections. Journal tools are **outbound HTTPS** from the runner to ownrun-server, same as calendar and claim/heartbeat/complete.

The public web session still cannot execute tools. Only a claimed `agent.task` can call the runner journal routes, and only while that job is `running` and owned by this runner.

## 5. Entry model

Logical fields (MariaDB table `journal_entries`):

| Field | Rules |
|-------|--------|
| `id` | Integer PK, `AUTO_INCREMENT`, same as jobs |
| `user_id` | Owner; single-user app but matches `jobs.user_id` |
| `title` | Optional; trim; max **200** chars; empty stored as NULL |
| `body` | Required; text; max **64 KiB** (journal entries may be longer than calendar descriptions) |
| `entry_date` | Required; **civil date** of the entry (what day the note is “about”), not necessarily `created_at` |
| `project` | Optional; same pattern as CALENDAR.md / AGENT.md §10.2 (`[a-zA-Z0-9]` then up to 63 of `[a-zA-Z0-9._-]`) |
| `created_by` | `user` \| `agent` |
| `created_job_id` | Nullable; set when an agent creates the row |
| `updated_job_id` | Nullable; last agent job that edited the row |
| `deleted_at` | Nullable UTC datetime; NULL = live, set = soft-deleted |
| `created_at`, `updated_at` | Server timestamps (UTC) |

**`entry_date` vs timestamps:** `entry_date` is a **DATE** column (no time-of-day). The user or agent sets it when writing (“today,” “yesterday,” or a specific day). It drives list ordering, search windows, and anniversary matching for the memory card. `created_at` / `updated_at` are audit fields.

**Soft delete:** `DELETE` never removes the row. It sets `deleted_at` to now (UTC) and bumps `updated_at`. Live queries (list, get, search, memory) require `deleted_at IS NULL`. Soft-deleted ids look like missing (404) to both user and agent APIs — no existence leak and no body returned. Re-deleting an already soft-deleted id is also 404. No restore or purge API in v1 (row stays for a later admin/migration path).

**Default on create:** if the client omits `entry_date`, the server sets it to **today’s civil date** in `OWNRUN_TIMEZONE` (default `America/New_York`, see AGENT.md §10.4) — same “today” agents get from `now`. `deleted_at` is NULL.

Indexes:

- `(user_id, entry_date DESC, id DESC)` — main list and memory queries; all live queries add `AND deleted_at IS NULL`
- `(user_id, project, entry_date DESC)` — project-filtered lists
- Optional `FULLTEXT(title, body)` for substring/search performance if MariaDB full-text is enabled on the host; otherwise `LIKE` with sane caps (see §7)

`project` is a **label**, not a foreign key. The SPA offers `agent_projects` from the last runner heartbeat plus distinct `project` values already on entries, and a free-text name (same pattern as calendar and the agent form).

## 6. Project visibility

The user owns the whole journal. **Project scoping applies to agents only.**

### 6.1 Definitions

- **Global entry:** `project` is NULL. Visible in the SPA always. Visible to **every** agent for **read/search**. **Not writable by agents** in v1 (see §6.3).
- **Project entry:** `project` is a valid project id. Visible in the SPA always. Visible to an agent **only** if the running job’s `request_payload.project` equals that id.

### 6.2 Agent read set

Let `P` be the job’s project (string or absent).

| Job | Agent may search/read |
|-----|------------------------|
| Has project `P` | Global entries **and** entries with `project = P` |
| No project (`web` profile with project omitted) | Global entries only |

An agent running for `blog` never sees `notes`-scoped rows. It does see global rows so it can reuse personal context the user chose to share across projects.

The model **cannot** pass a project filter to widen this set. The server derives visibility from the job row.

### 6.3 Agent write set

Stricter than read, and **stricter than calendar** for global rows: agents never mutate global journal entries.

| Action | Rule |
|--------|------|
| **Add** | Only when the job has project `P`. Server **ignores** any `project` in tool args. New row gets `project = P`, `created_by = agent`, `created_job_id =` this job. If the job has **no** project → **403** (or tool error string), not an unscoped create. |
| **Edit** | Allowed only on rows with `project = P` where `P` is the job’s project. Agent cannot edit global rows or other projects’ rows. Cannot change `project`, `created_by`, or `created_job_id`. |
| **Delete** | Same write set as edit. Soft delete (`deleted_at` set); 404 if the id is outside the write set or already deleted (do not leak that a `notes` entry exists). |

So: an agent on `blog` can read global memories and project notes, and can create, edit, or delete `blog` journal rows, but cannot add or change global entries even if the user asked it to “write this in my main journal.”

### 6.4 User writes

The SPA can set, clear, or change `project` on any entry, including ones agents created. Moving an entry into a project hides it from other projects’ agents; clearing `project` makes it global (and agent-read-only).

User create: `created_by = user`, `created_job_id` null. User may create global or project-scoped entries freely.

## 7. Web API

User JWT, same as jobs and calendar. All rows filtered by `user_id`.

List/search queries must be **bounded** so the SPA and agents cannot dump the entire table in one response. The web list uses **keyset pagination** (infinite scroll). Agent search keeps a required **date window** (see §8).

### Endpoints

- `GET /api/journal?project=<optional>&q=<optional>&limit=<optional>&before_date=<optional>&before_id=<optional>&from=<optional>&to=<optional>`
  - Ordered by `entry_date` DESC, then `id` DESC (newest first).
  - `limit`: optional; default **30**, max **100** for web.
  - **Pagination (default SPA list):** omit `from`/`to`. First page: no cursor. Later pages: pass `before_date` + `before_id` from the last row of the previous page. Server returns rows strictly older than that cursor: `(entry_date, id) < (before_date, before_id)` in sort order.
  - **Optional date filter:** `from` / `to` as ISO dates (`YYYY-MM-DD`), inclusive civil dates. If either is set, both are required. Max window: **366 days** (wider → 422). Can combine with cursor for infinite scroll inside a filtered range.
  - `project` omitted: all entries (user sees everything).
  - `project=` empty or `project=_none`: global only.
  - `project=<id>`: that project only.
  - `q`: optional case-insensitive substring on `title` and `body` (trim; max 200 chars).
  - Only live rows (`deleted_at IS NULL`).
  - Response:

```json
{
  "entries": [ ... ],
  "truncated": true,
  "next": { "before_date": "2024-03-01", "before_id": 40 }
}
```

  - `truncated`: true when more live rows exist beyond this page.
  - `next`: present when `truncated` is true; the SPA passes those values as the next request’s cursor. Omit `next` when the page is complete.
- `GET /api/journal/{id}` — 404 if missing, wrong user, or soft-deleted.
- `POST /api/journal` — body: `body` (required), optional `title`, `entry_date`, `project`.
- `PATCH /api/journal/{id}` — partial; same fields. User may set `project` to null to make an entry global. Soft-deleted → 404.
- `DELETE /api/journal/{id}` — soft delete; sets `deleted_at` (and `updated_at`). Response `{ "ok": true, "id": n }`. Already deleted or missing → 404.

**Memory (home page):**

- `GET /api/journal/memory`
  - No query params in v1.
  - Response:

```json
{
  "entry": {
    "id": 91,
    "title": "First deploy",
    "body": "Shipped the blog theme …",
    "entry_date": "2016-08-23",
    "project": null,
    "created_by": "user",
    "created_at": "2016-08-23T21:15:00Z",
    "updated_at": "2016-08-23T21:15:00Z"
  },
  "memory_kind": "anniversary_10y",
  "memory_label": "10 years ago today"
}
```

  - `memory_kind`: `anniversary_10y` \| `anniversary_1y` \| `anniversary_1m` \| `random`
  - `memory_label`: short human string for the UI (e.g. “1 year ago today”, “A while back”).
  - If the user has **no** journal entries at all → `{ "entry": null, "memory_kind": null, "memory_label": null }`.

JSON entry shape (web and runner; audit fields may be omitted or shortened for compact agent search — see §8):

```json
{
  "id": 91,
  "title": "Blog relaunch notes",
  "body": "Decided to drop the old theme …",
  "entry_date": "2025-08-23",
  "project": "blog",
  "created_by": "agent",
  "created_job_id": 42,
  "created_at": "2025-08-23T19:01:00Z",
  "updated_at": "2025-08-23T19:01:00Z"
}
```

Validation: same project id pattern as jobs; unknown extra keys ignored; `body` required on create; strip title to NULL if empty.

Extend `GET /api/models` (or reuse calendar meta pattern) with `journal_projects`: union of runner `agent_projects` and distinct `journal_entries.project`. Prefer one extra field on the existing models payload so the SPA already has a runner-online fetch.

## 8. Runner API and agent tools

### 8.1 Why nested under the job

Do **not** add a global `/api/runner/journal`. Visibility must come from the **running job**, not from tool arguments.

- Job must exist, `status = running`, `type = agent.task`, `runner_id` = this runner.
- `user_id` on new rows is the job’s user, not a tool-supplied id.

### 8.2 Endpoints

- `GET /api/runner/jobs/{jobId}/journal?from=&to=&q=`
  - Required `from`/`to` ISO dates, inclusive; max window **366 days** (wider → 422). Unlike the web list, agent search is **not** cursor-paginated — the model must pick a bounded window.
  - Optional `q`: case-insensitive substring on `title` and `body`.
  - Server applies the **read set** (§6.2).
  - Only live rows (`deleted_at IS NULL`). Cap **50** rows. `{ "entries": [ ... ], "truncated": true|false }`.
  - Compact rows omit long `body` or truncate to e.g. **500** chars with `"body_truncated": true` — same spirit as `calendar_search`.
- `GET /api/runner/jobs/{jobId}/journal/{id}` — full entry including `body`; 404 if not in the read set or soft-deleted.
- `POST /api/runner/jobs/{jobId}/journal` — create only if job has a project (§6.3). Body: `body`, optional `title`, `entry_date`. Reject `project` if present (422).
- `PATCH /api/runner/jobs/{jobId}/journal/{id}` — edit if in the **write set** and live; 404 otherwise.
- `DELETE /api/runner/jobs/{jobId}/journal/{id}` — soft delete if in the **write set** and live; 404 otherwise. Response `{ "ok": true, "id": n }`.

No runner route for `memory`; that is a user-facing affordance only.

### 8.3 Tools (all existing profiles)

Add five tools to **every** profile (`workspace`, `web`, `workspace_web`). They are server calls, not filesystem.

| Tool | Args | Behavior |
|------|------|----------|
| `journal_search` | `start` (ISO date), `end` (ISO date), optional `query` | GET list; compact rows: `id`, `title`, `entry_date`, `project`, truncated `body` |
| `journal_get` | `id` | Full entry including `body` |
| `journal_add` | `body`, optional `title`, optional `entry_date` | POST; fails with clear error if job has no project. Result is the created entry. |
| `journal_edit` | `id`, plus any updatable fields | PATCH; omit unchanged fields |
| `journal_delete` | `id` | Soft DELETE; confirmation is the `{ ok, id }` payload. Soft-deleted or out-of-scope ids look like missing (404 → error string). |

Agents call `now` when they need “today” or “this month” for search bounds: use `local` / `weekday` in `OWNRUN_TIMEZONE`, then pass **ISO dates** for `start`/`end`. Truncate tool results with the existing 8 KiB helper.

If the range is invalid or over 366 days, the tool returns an error string to the model (loop continues), same as other tool errors.

### 8.4 System prompt addition

Append a short, profile-agnostic paragraph that names the real tools and a recipe:

- Stamp **today’s real civil date** (from `now` / `OWNRUN_TIMEZONE`) into the system prompt.
- Only `now`, `journal_search`, `journal_get`, `journal_add`, `journal_edit`, `journal_delete`. Do not invent tools.
- This job’s project (name it, or “none — journal writes disabled”) determines whether `journal_add` / `journal_edit` / `journal_delete` are available.
- You can **read** global journal entries for context; you can only **add, edit, or delete** entries for this job’s project.
- Prefer `journal_add` at end of a long task to record decisions; use `journal_search` before repeating work.

### 8.5 Runner client

The Python client grows journal methods that reuse the runner bearer token. Failures (401, 403, 404, 422, network) become tool error strings, not job failures, unless the adapter itself is broken.

## 9. Memory selection algorithm

The memory card runs **on the server** so the home page gets one cheap request (`GET /api/journal/memory`) without loading the full journal.

**Reference date:** “today” as a civil date in `OWNRUN_TIMEZONE` (same as calendar all-day and agent `now`). Call it `T`.

**Anniversary target dates** (also civil dates):

| Kind | Target date | Label |
|------|-------------|-------|
| 10 year | `T` minus 10 calendar years | “10 years ago today” |
| 1 year | `T` minus 1 calendar year | “1 year ago today” |
| 1 month | `T` minus 1 calendar month | “1 month ago today” |

Use calendar-aware subtraction (MariaDB `DATE_SUB` or PHP `DateTimeImmutable::modify`), so Jan 31 minus one month becomes a valid civil date (e.g. Jan 31 → Dec 31, not an invalid Feb 31).

**Priority:** check 10y, then 1y, then 1m. For each kind, select **live** entries (`deleted_at IS NULL`) where `entry_date` equals that target date. If multiple match one kind, pick **one at random** among those ties. Use the same deterministic daily seed as the random fallback (e.g. `CRC32(user_id || T)`) so the chosen anniversary entry stays stable for the day.

**Fallback:** if no anniversary match, pick **one random** live entry for this user where `entry_date < T` (strictly in the past). Use the same daily seed, then index into the ordered list of past entry ids. Label: `memory_kind = random`, `memory_label = "From your journal"` (or include formatted `entry_date`: “August 12, 2024”). Soft-deleted rows are never candidates.

**Display excerpt:** the API returns full `body`; the SPA shows the first ~280 characters with ellipsis if longer. Title optional in the card header.

**Scope:** memory draws from **all live** entries (global and project-scoped). The user owns everything; the home page is not project-filtered.

## 10. Web UI

Hash routes, same SPA chrome.

- Route: `/#/journal` (`name: 'journal'`).
- Header: add **Journal** next to Calendar / New chat / New agent. Jobs stay the home route (`/`).

### Journal list (v1)

- Reverse chronological by `entry_date`, then `id`.
- **Infinite scroll:** first fetch with default `limit` (30); when the user nears the bottom and `truncated` is true, fetch again with `next.before_date` / `next.before_id`. Append results; stop when `truncated` is false or the list is empty.
- Changing project filter or `q` resets the list and cursor to the first page.
- Filter: All | Global | a project from `journal_projects`.
- Each row: date, optional title (or first line of body), project badge if set, quiet marker for `created_by = agent`.
- Tap row → detail: full body, edit fields, optional project select, **Delete**.
- No fixed “last 90 days” window; optional date-range filter can be added later without changing the pagination model.

### Create / edit

- **New entry** button and empty-state link.
- Fields: `entry_date` (date picker, default today in browser or server timezone — lean server `OWNRUN_TIMEZONE` via models `timezone` for default), optional title, body (textarea), project (optional; blank = global).
- Works with the runner offline.

### Memory card (jobs home)

- On `JobsView`, above the job list: a compact card when `GET /api/journal/memory` returns an entry.
- Shows `memory_label`, date, title if any, body excerpt, link to `/#/journal` (optionally with query to scroll/highlight that id).
- Hide the card when `entry` is null (no journal yet).
- Refresh on mount and when returning to the route; no polling required.

No live polling on the journal page; refresh on navigation and after save.

## 11. Security

Journal expands what a stolen **web JWT** can do (read/write personal notes) and what a stolen **runner token** can do (same, but only through a running job’s scope).

Controls:

- User endpoints: JWT; rows always `user_id =` token subject.
- Runner endpoints: runner token **and** job ownership **and** `running` `agent.task`.
- Project on agent create is **server-assigned**, never model-assigned.
- Agent cannot create or mutate global entries (403 on add when job has no project; 404 on edit/delete outside write set).
- Agent edit/delete 404 for out-of-scope ids (no existence leak across projects).
- Date window caps, row caps, title/body size caps — hostile or verbose tool loops must not fill MariaDB.
- No extra outbound URL from tools: they only call ownrun-server.
- Prompt injection: assume the model will try `journal_edit` on global or other-project ids; write-set enforcement is the control, not the prompt.
- Do not put journal bodies into runner INFO logs.

## 12. Configuration

No journal-specific runner env vars. Civil “today” and memory anniversaries use `OWNRUN_TIMEZONE` from AGENT.md (default `America/New_York`). Server: none beyond the new table and the web page size / 366-day / agent 50-row caps (constants are fine).

Migrate existing DBs with `scripts/migrate_journal.php` + `sql/migrate_journal.sql`, same pattern as calendar. Include `journal_entries` in `sql/schema.sql` for new installs.

## 13. Observability

- Runner logs: job id, tool name, entry id, not title/body at INFO.
- Failed tool calls: error string in the trace as today.
- SPA: API error strings on the form.

## 14. Implementation phases

Journal is **Phase 6** relative to DESIGN.md (after calendar Phase 5). It depends on agent jobs for §8. Phase 6a can ship without touching Autogen.

### Phase 6a — Server + SPA

- Table + user CRUD API + `GET /api/journal/memory`.
- Journal list, create/edit/delete, optional project field, project filter.
- Memory card on jobs home.
- Runner offline is fine.

### Phase 6b — Agent tools

- Runner job-scoped journal routes.
- `journal_search` / `journal_get` / `journal_add` / `journal_edit` / `journal_delete` on all profiles.
- System prompt blurb; compact search results; read set vs write set; no global agent writes.

### Phase 6c — Later (optional)

- Markdown rendering in the SPA (read-only).
- Tags or pin favorites.
- Week/month calendar strip linking entry dates.
- Export.
- Restore from soft delete / trash view; optional hard purge.

## 15. Decisions

1. **Storage:** MariaDB on ownrun-server, not workspace files and not a job type.
2. **User sees everything.** Project scoping is an agent visibility/write rule.
3. **Read set:** global ∪ matching job project. **Write set:** matching project only; **no agent writes to global** (stricter than calendar).
4. **Agent create** always stamps the job’s project; jobs without a project cannot use `journal_add`.
5. **Agent delete** is in v1, same write set as edit; **soft delete** via `deleted_at` (not hard remove). Soft-deleted rows are invisible to list/get/search/memory (404).
6. **Tools on all existing profiles**, not a new profile.
7. **Runner routes nested under the running job**; no global runner journal API.
8. **`entry_date`** is a civil DATE; anniversaries and “today” defaults use `OWNRUN_TIMEZONE`.
9. **Web list:** keyset infinite scroll (`before_date` + `before_id`, default page size 30). **Agent search:** date-window-required; max 366 days.
10. **Memory** is server-computed with anniversary priority 10y → 1y → 1m; ties on the same anniversary day are broken randomly (daily-seeded); then deterministic daily random fallback; live rows only.
11. **Phase 6a (UI + memory) can land before 6b (tools).**

## 16. Open decisions

- Whether `GET /api/models` grows `journal_projects` or a dedicated meta endpoint (lean: extra field on models, mirroring calendar).
- Whether compact `journal_search` omits `body` entirely (title + date only) vs truncated body — lean truncated body for skimming.
- Whether the memory card should deep-link to a future `/#/journal/{id}` route or only the list with a highlight query param.
- Restore / trash UI and eventual hard purge (lean: none in v1; soft-deleted rows stay until a later phase).

## 17. Success criteria (journal v1)

1. From a remote browser, a logged-in user can open `/#/journal`, see recent entries, and add a global or project entry with the runner offline.
2. That entry appears after reload; the user can edit it; after soft delete it disappears from list/get/memory and returns 404, but the row remains with `deleted_at` set.
3. The jobs home page shows a memory when at least one past entry exists; on an anniversary date, the card prefers the matching entry over random.
4. An `agent.task` with project `blog` can search journal rows, see global entries plus `blog` entries, and add, edit, and delete a `blog` entry. It cannot see, edit, or delete a `notes`-scoped entry, and cannot create or edit global entries.
5. An agent job with **no** project can search and read global entries only; `journal_add` returns a clear error.
6. An agent-created row has `project` equal to the job’s project and `created_by = agent`.
7. `ollama.chat` and existing agent file/web/calendar tools are unchanged aside from the extra journal tools on agent profiles.
8. No inbound connection to the home machine is required to use the SPA journal or memory card.

Phase 6b is required for criteria 4–6. Phase 6a alone satisfies 1–3 and 7–8.

---

*Next step after this design: implement Phase 6a only (schema, user API, journal view, home memory card) unless agent tools are explicitly requested in the same change set.*
