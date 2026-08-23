# OwnRun Calendar Design

**Status:** Draft  
**Date:** 2026-08-23  
**Author:** Jonboy  
**Depends on:** [DESIGN.md](DESIGN.md) (hosting, auth, API shape), [AGENT.md](AGENT.md) (agent jobs, tool catalog, project ids)

This document designs a **personal calendar** stored on ownrun-server. The Vue SPA can view and edit it. Agents can search, view, add, edit, and delete entries through runner-defined tools. It is not a new job type.

No implementation in this document.

## 1. Purpose

OwnRun already lets a remote browser submit work for the home runner. It has no place to keep **dates and appointments** that both the user and agents can share.

Without a calendar:

- The user cannot glance at upcoming events from the phone while away
- An agent cannot answer “what’s on this week,” schedule a follow-up, or record a deadline next to the files it is working on
- Putting events in a workspace markdown file would hide them from the SPA unless every view became an agent job

The calendar is **user data on the PHP host**, like jobs. Viewing and adding from the browser does not need the runner. Agents reach the same rows through a runner-authenticated API, scoped by the job’s project.

## 2. Goals

- Month (and simple list) view in ownrun-web, usable on a phone.
- Logged-in user can create, edit, and delete entries without the runner.
- Agents can **search, view, add, edit, and delete** entries via the existing Autogen tool catalog. Delete is limited to the job’s project (same write set as edit).
- Optional **project** on each entry. When set, that entry is only **available to agents** whose job is running for that project.
- Entries **created by an agent** always get the job’s selected project (or stay unscoped if the job has no project).
- Stay compatible with shared hosting: MariaDB, request/response PHP, no cron, no WebSockets.
- Reuse existing auth (user JWT vs runner token) and the agent **project id** rules from AGENT.md §10.2.

## 3. Non-goals (calendar v1)

- Recurring events (RRULE / “every Monday”).
- Reminders, push notifications, or email. Shared hosting has no background workers.
- CalDAV, ICS import/export, Google Calendar sync.
- Timezone picker or multiple calendars. One calendar; times stored in UTC. The user’s zone is the runner’s `OWNRUN_TIMEZONE` (default `America/New_York`, see AGENT.md §10.4). The SPA may still use the browser zone for datetime widgets.
- Multi-user sharing or per-entry ACLs beyond the agent project rule.
- Treating the calendar as a job type or storing events in the workspace directory.
- A dedicated `calendar` agent profile (tools are added to existing profiles instead).

## 4. Where it lives

Calendar rows live in **MariaDB on ownrun-server**. They are not files under `OWNRUN_AGENT_WORKSPACE`.

```
┌─────────────────┐         HTTPS          ┌──────────────────┐
│   ownrun-web    │ ─────────────────────► │  ownrun-server   │
│  Calendar view  │   user JWT CRUD        │  calendar_entries│
└─────────────────┘                        └────────┬─────────┘
                                                    │
                         runner token, scoped by    │
                         the running job’s project  │
                                                    ▼
                                           ┌──────────────────┐
                                           │  ownrun-runner   │
                                           │  calendar_* tools│
                                           └──────────────────┘
```

**Why the server, not the workspace**

| Approach | Why not (for v1) |
|----------|------------------|
| Markdown/JSON in a project dir | SPA would need a job round-trip to read; other projects could not share unscoped events |
| Runner-only local DB | Phone UI is offline whenever the runner is; DESIGN.md’s pull model has no inbound home access |
| Job `result_payload` | Jobs are runs, not durable user records |

The runner never accepts inbound connections. Calendar tools are **outbound HTTPS** from the runner to ownrun-server, same as claim/heartbeat/complete.

The public web session still cannot execute tools. Only a claimed `agent.task` can call the runner calendar routes, and only while that job is `running` and owned by this runner.

## 5. Entry model

Logical fields (MariaDB table `calendar_entries`):

| Field | Rules |
|-------|--------|
| `id` | Integer PK, `AUTO_INCREMENT`, same as jobs |
| `user_id` | Owner; single-user app but matches `jobs.user_id` |
| `title` | Required; trim; max **200** chars |
| `description` | Optional; text; max **8 KiB** |
| `starts_at` | Required; UTC datetime |
| `ends_at` | Optional; UTC datetime; if set, must be `>= starts_at` |
| `all_day` | Boolean; default false |
| `project` | Optional; same pattern as AGENT.md §10.2 (`[a-zA-Z0-9]` then up to 63 of `[a-zA-Z0-9._-]`) |
| `created_by` | `user` \| `agent` |
| `created_job_id` | Nullable; set when an agent creates the row |
| `updated_job_id` | Nullable; last agent job that edited the row |
| `created_at`, `updated_at` | Server timestamps |

**All-day:** civil dates in `OWNRUN_TIMEZONE` (default America/New_York), not the UTC date. `starts_at` is the first inclusive day, `ends_at` the last (if omitted, one day). Persist as the UTC instant of local midnight on that date so range queries still work. Clock time is ignored for display. Agents must take “today” from `now`’s `local` date, not from `utc`.

**Point in time:** `all_day = false`, `ends_at` null — a reminder at `starts_at`, not a range.

**Overlaps:** allowed. No busy/free engine in v1.

Indexes: `(user_id, starts_at)`, `(user_id, project, starts_at)`.

`project` is a **label**, not a foreign key. It does not have to exist as a workspace directory yet. The SPA offers `agent_projects` from the last runner heartbeat plus distinct `project` values already on entries, and a free-text name (same pattern as the agent form).

## 6. Project visibility

The user owns the whole calendar. **Project scoping applies to agents only.**

### 6.1 Definitions

- **Unscoped entry:** `project` is NULL. Visible in the SPA always. Visible to **every** agent as read-only context (see §6.3 for writes).
- **Scoped entry:** `project` is a valid project id. Visible in the SPA always. Visible to an agent **only** if the running job’s `request_payload.project` equals that id.

### 6.2 Agent read set

Let `P` be the job’s project (string or absent).

| Job | Agent may search/view |
|-----|------------------------|
| Has project `P` | Unscoped entries **and** entries with `project = P` |
| No project (`web` profile with project omitted) | Unscoped entries only |

An agent running for `blog` never sees `notes`-scoped rows. It does see unscoped rows (dentist, travel) so it can avoid colliding with real life.

The model **cannot** pass a project filter to widen this set. The server derives visibility from the job row.

### 6.3 Agent write set

Stricter than read, so a prompt-injected agent cannot rewrite global appointments.

| Action | Rule |
|--------|------|
| **Add** | Server **ignores** any `project` in the tool args. If the job has project `P`, the new row gets `project = P`. If the job has no project, the new row is unscoped. `created_by = agent`, `created_job_id =` this job. |
| **Edit** | Allowed only on rows in the **write set**: if the job has `P`, only rows with `project = P` (not unscoped). If the job has no project, only unscoped rows. Agent cannot change `project`, `created_by`, or `created_job_id`. |
| **Delete** | Same write set as edit. Hard delete; 404 if the id is outside the write set. Not limited to rows this agent created — any entry in the job’s project (including user-created) is eligible. |

So: an agent on `blog` can read the dentist appointment and create, edit, or delete `blog` deadlines, but cannot retitle or remove the dentist row.

### 6.4 User writes

The SPA can set, clear, or change `project` on any entry, including ones agents created. Moving an entry into a project hides it from other projects’ agents; clearing project makes it unscoped.

User create: `created_by = user`, `created_job_id` null.

## 7. Web API

User JWT, same as jobs. All rows filtered by `user_id`.

Range queries are **required** so a month view and an agent search cannot dump the entire table.

### Endpoints

- `GET /api/calendar?from=<iso>&to=<iso>&project=<optional>`
  - `from` / `to` required, UTC ISO-8601. Inclusive overlap: an entry matches if it intersects `[from, to]`.
  - Max window: **92 days**. Wider → 422.
  - `project` omitted: all entries in range (user sees everything).
  - `project=` empty or `project=_none`: unscoped only.
  - `project=<id>`: that project only (still the user’s rows).
  - Response: `{ "entries": [ ... ] }` ordered by `starts_at`, then `id`. Cap **500** rows; if hit, include `"truncated": true` so the UI can zoom in.
- `GET /api/calendar/{id}`
- `POST /api/calendar` — body: `title`, `starts_at`, optional `ends_at`, `all_day`, `description`, `project`.
- `PATCH /api/calendar/{id}` — partial; same fields. User may set `project` to null to unscope.
- `DELETE /api/calendar/{id}`

JSON entry shape (web and runner, extra audit fields may be omitted for agents — see §8):

```json
{
  "id": 17,
  "title": "Draft blog outline",
  "description": "Use last week’s notes.md",
  "starts_at": "2026-08-25T14:00:00Z",
  "ends_at": "2026-08-25T15:30:00Z",
  "all_day": false,
  "project": "blog",
  "created_by": "agent",
  "created_job_id": 42,
  "created_at": "2026-08-23T19:01:00Z",
  "updated_at": "2026-08-23T19:01:00Z"
}
```

Validation: same project id pattern as jobs; unknown extra keys ignored; payload size under existing `max_request_payload_bytes` is plenty.

`GET /api/models` (or a tiny `GET /api/calendar/meta`) should expose project names for the form: union of runner `agent_projects` and distinct `calendar_entries.project`. Prefer extending the existing models payload with `calendar_projects` so the SPA already has a runner-online fetch. If the runner is offline, still list projects that appear on entries.

## 8. Runner API and agent tools

### 8.1 Why nested under the job

Do **not** add a global `/api/runner/calendar`. Visibility must come from the **running job**, not from tool arguments.

- Job must exist, `status = running`, `type = agent.task`, `runner_id` = this runner.
- `user_id` on new rows is the job’s user, not a tool-supplied id.

### 8.2 Endpoints

- `GET /api/runner/jobs/{jobId}/calendar?from=&to=&q=`
  - Same range rules as web (required `from`/`to`, max 92 days).
  - Optional `q`: case-insensitive substring on `title` and `description`.
  - Server applies the **read set** (§6.2).
  - Cap **50** rows (tighter than web) so the model context stays small. `{ "entries": [ ... ], "truncated": true|false }`.
- `GET /api/runner/jobs/{jobId}/calendar/{id}` — 404 if not in the read set.
- `POST /api/runner/jobs/{jobId}/calendar` — create; server stamps project (§6.3). Body: `title`, `starts_at`, optional `ends_at`, `all_day`, `description`. Reject `project` if present (422) so a confused adapter cannot think it chose one.
- `PATCH /api/runner/jobs/{jobId}/calendar/{id}` — edit if in the **write set**; 404 otherwise (do not leak that a `notes` event exists).
- `DELETE /api/runner/jobs/{jobId}/calendar/{id}` — delete if in the **write set**; 404 otherwise. Response `{ "ok": true, "id": n }`.

### 8.3 Tools (all existing profiles)

Add five tools to **every** profile (`workspace`, `web`, `workspace_web`). They are server calls, not filesystem. Do not invent extra profile ids.

| Tool | Args | Behavior |
|------|------|----------|
| `calendar_search` | `start` (ISO UTC), `end` (ISO UTC), optional `query` | GET list; compact rows: `id`, `title`, `starts_at`, `ends_at`, `all_day`, `project` (no long descriptions) |
| `calendar_get` | `id` | Full entry including `description` |
| `calendar_add` | `title`, `starts_at`, optional `ends_at`, `all_day`, `description` | POST; result is the created entry |
| `calendar_edit` | `id`, plus any updatable fields | PATCH; omit unchanged fields |
| `calendar_delete` | `id` | DELETE; confirmation is the `{ ok, id }` payload. Out-of-scope ids look like missing (404 → error string). |

Calendar **API fields** stay UTC ISO-8601. Agents call `now` first when they need “today,” “this week,” or a wall-clock time: use `local` / `weekday` in `OWNRUN_TIMEZONE`, then convert to UTC for `starts_at` / `ends_at` / search `from`/`to`. Truncate tool results with the existing 8 KiB helper.

If the range is invalid or over 92 days, the tool returns an error string to the model (loop continues), same as other tool errors.

### 8.4 System prompt addition

Append a short, profile-agnostic paragraph that names the real tools and a recipe:

- Stamp **today’s real date and year** (from `now` / `OWNRUN_TIMEZONE`) into the system prompt so “this week” uses the wall clock, not a training-cutoff guess. Include this week’s UTC `start`/`end` as copy-paste values. If the user names another year, search that year.
- Only `now`, `calendar_search`, `calendar_get`, `calendar_add`, `calendar_edit`, `calendar_delete`. Do not invent tools (no `project_calendar`).
- “What’s on this week”: `calendar_search` with those stamped UTC strings, or omit `start`/`end` (defaults to this week, Sunday–Saturday in `OWNRUN_TIMEZONE`).
- This job’s project (name it, or “none”) is applied automatically on add.
- You can read unscoped events for context; you can only add, edit, or delete events for this job’s project (or unscoped, if this job has no project).

### 8.5 Runner client

The Python client grows calendar methods that reuse the runner bearer token. Failures (401, 404, 422, network) become tool error strings, not job failures, unless the adapter itself is broken.

## 9. Web UI

Hash routes, same SPA chrome.

- Route: `/#/calendar` (`name: 'calendar'`).
- Header: add **Calendar** next to OwnRun / New chat / New agent. Jobs stay the home route (`/`).

### Month view (v1)

- One month at a time; prev/next; “Today”.
- Fetch `from`/`to` covering the visible grid (including leading/trailing days from adjacent months).
- Days show a short title list (cap per cell, e.g. 4, then “+N”).
- Filter control: All | No project | a project from `calendar_projects`.
- Badge or quiet marker for `created_by = agent`.

### Create / edit

- Click empty day → create, `starts_at` defaulting to that date (all-day or a default hour — UI choice; lean all-day for a tap on a day heading, timed if the user opens a full form).
- Click an entry → detail: edit fields, optional project select, **Delete**. (Agents may also delete via tools, but only within their project write set.)
- Fields: title, all-day toggle, start, end, description, project (optional; blank = unscoped).
- Works with the runner offline.

### List (optional in the same page)

Upcoming 14 days below the month, or a toggle. Not a separate app. Helps phones.

No live polling required; refresh on navigation and after save. Optional 30–60s poll while the tab is visible is enough if an agent might be adding rows in the background.

## 10. Security

Calendar expands what a stolen **web JWT** can do (read/write the schedule) and what a stolen **runner token** can do (same, but only through a running job’s scope — unless we added global runner calendar routes, which we must not).

Controls:

- User endpoints: JWT; rows always `user_id =` token subject.
- Runner endpoints: runner token **and** job ownership **and** `running` `agent.task`.
- Project on agent create/edit is **server-assigned**, never model-assigned.
- Agent edit 404 for out-of-scope ids (no existence leak across projects).
- Range caps, row caps, title/description size caps — hostile or verbose tool loops must not fill MariaDB.
- No extra outbound URL from tools: they only call ownrun-server, which the runner already trusts.
- Prompt injection: assume the model will try `calendar_edit` / `calendar_delete` on unscoped or other-project ids; write-set enforcement is the control, not the prompt.
- Do not put calendar descriptions into runner INFO logs.

DESIGN.md’s “no free-form remote code” still holds. Calendar tools are a fixed catalog, like `write_file`.

## 11. Configuration

No calendar-specific runner env vars. Timezone is `OWNRUN_TIMEZONE` from AGENT.md (default `America/New_York`). Server: none beyond the new table and the 92-day / 500 / 50 caps (constants are fine; optional config later).

Migrate existing DBs with a small `scripts/migrate_calendar.php` + `sql/migrate_calendar.sql`, same pattern as `migrate_agent.php`. Include `calendar_entries` in `sql/schema.sql` for new installs.

## 12. Observability

- Runner logs: job id, tool name, entry id, not title/description at INFO.
- Failed tool calls: error string in the trace as today.
- SPA: API error strings on the form.

## 13. Implementation phases

Calendar is **Phase 5** relative to DESIGN.md. It depends on agent jobs only for §8. Phase 5a can ship without touching Autogen.

### Phase 5a — Server + SPA

- Table + user CRUD API.
- Month view, create/edit/delete, optional project field, project filter.
- Runner offline is fine.

### Phase 5b — Agent tools

- Runner job-scoped calendar routes.
- `calendar_search` / `calendar_get` / `calendar_add` / `calendar_edit` / `calendar_delete` on all profiles.
- System prompt blurb; compact search results; write-set vs read-set.

### Phase 5c — Later (optional)

- Recurrence.
- ICS export.
- Week/day views.
- Reminders if a later design adds a worker or a runner-side nag job type.

## 14. Decisions

1. **Storage:** MariaDB on ownrun-server, not workspace files and not a job type.
2. **User sees everything.** Project scoping is an agent visibility/write rule.
3. **Read set:** unscoped ∪ matching job project. **Write set:** matching project only (or unscoped-only when the job has no project).
4. **Agent create** always stamps the job’s project (or unscoped if none). Tools have no `project` argument.
5. **Agent delete** is in v1, same write set as edit (own project only; not unscoped when the job has a project).
6. **Tools on all existing profiles**, not a new profile combinatorics.
7. **Runner routes nested under the running job**; no global runner calendar API.
8. **UTC** storage. Agent-facing local time is `OWNRUN_TIMEZONE` (default `America/New_York`) via `now`. SPA datetime widgets may use the browser zone.
9. **Range-required** list APIs; 92-day max window.
10. **Phase 5a (UI) can land before 5b (tools).**

## 15. Open decisions

- Default new-event UX on day click: all-day vs a suggested local hour (lean: all-day from the month cell, timed from an “Add timed” control).
- Whether `GET /api/models` grows `calendar_projects` or a dedicated meta endpoint (lean: extra field on models).
- Whether truncated month fetches should auto-split the range in the SPA or ask the user to filter by project (500 rows is enough for a personal month).
- Continue-jobs: calendar side effects persist like files; no extra continue payload.

## 16. Success criteria (calendar v1)

1. From a remote browser, a logged-in user can open `/#/calendar`, see a month, and add an entry with or without a project, with the runner offline.
2. That entry appears after reload; the user can edit and delete it.
3. An `agent.task` with project `blog` can search the current week, see unscoped events plus `blog` events, and add, edit, or delete a `blog` event. It cannot see, edit, or delete a `notes`-scoped event, and cannot edit or delete an unscoped event.
4. An agent-created row has `project` equal to the job’s project and `created_by = agent`.
5. `ollama.chat` and existing agent file/web tools are unchanged aside from the extra calendar tools on agent profiles.
6. No inbound connection to the home machine is required to use the SPA calendar.

Phase 5b is required for criteria 3–4. Phase 5a alone satisfies 1–2 and 5–6.

---

*Next step after this design: implement Phase 5a only (schema, user API, month view) unless agent tools are explicitly requested in the same change set.*
