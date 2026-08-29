# OwnRun Task Tracker Design

**Status:** Draft  
**Date:** 2026-08-28  
**Author:** Jonboy  
**Depends on:** [DESIGN.md](DESIGN.md) (hosting, auth, API shape), [AGENT.md](AGENT.md) (agent jobs, tool catalog, project ids), [CALENDAR.md](CALENDAR.md) and [JOURNAL.md](JOURNAL.md) (project scoping pattern)  
**Related:** [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md) — standing instructions for chat/agent jobs; not task bodies.

This document designs a **personal task tracker** stored on ownrun-server. The Vue SPA can view, edit, and manually add tasks. Agents can fully manage tasks for their job’s project and can search and read global tasks. It is not a new job type.

No implementation in this document.

## 1. Purpose

OwnRun already tracks jobs, dated calendar events, and narrative journal entries. It has no durable place for **work items** — things to do, in progress, or finished — that both the user and agents can share.

Without a task list:

- The user cannot glance at open work from the phone while away
- An agent cannot record a follow-up, mark something done, or see what is already queued for this project unless it invents notes in the workspace
- Putting todos only in markdown under a project hides them from the SPA unless every view becomes an agent job
- Calendar dates are appointments, not a todo workflow (priority, status, optional due day)

Tasks are **user data on the PHP host**, like jobs, calendar rows, and journal entries. Viewing and adding from the browser does not need the runner. Agents reach the same rows through a runner-authenticated API, scoped by the job’s project.

## 2. Goals

- Simple task list in ownrun-web, usable on a phone.
- Logged-in user can create, edit, and delete tasks without the runner.
- Optional **project** on each task. When set, that task is primarily **owned by that project’s agents** for writes; the user still sees everything.
- Agents can **search, read, create, update, and delete** tasks scoped to the running job’s project.
- Agents can **search and read** global (unscoped) tasks as read-only context — not create, edit, or delete them.
- Fields: **name**, **description**, **due date** (nullable), **project** (nullable), **priority** (`high` / `normal` / `low`), **status** (`todo` / `in_progress` / `finished` / `deleted`).
- Stay compatible with shared hosting: MariaDB, request/response PHP, no cron, no WebSockets.
- Reuse existing auth (user JWT vs runner token) and the agent **project id** rules from AGENT.md §10.2.

## 3. Non-goals (tasks v1)

- Subtasks, checklists, assignees, tags, or estimates.
- Recurring tasks, reminders, push notifications, or email. Shared hosting has no background workers.
- Kanban boards, drag-and-drop ranking, or custom statuses.
- Sharing tasks with other users or per-task ACLs beyond the agent project rule.
- Treating tasks as a job type or storing them in the workspace directory.
- A dedicated `tasks` agent profile (tools are added to existing profiles instead).
- Markdown rendering or attachments in descriptions (plain text only).
- Hard purge of deleted rows (status `deleted` is the trash; rows remain for a later path).
- Agent-created global tasks (global rows are user-authored; agents never stamp unscoped rows in v1).
- Syncing with calendar entries (a due date is not an appointment). Creating a calendar event from a task is a later convenience, not v1.

## 4. Where it lives

Task rows live in **MariaDB on ownrun-server**. They are not files under `OWNRUN_AGENT_WORKSPACE`.

```
┌─────────────────┐         HTTPS          ┌──────────────────┐
│   ownrun-web    │ ─────────────────────► │  ownrun-server   │
│  Tasks view     │   user JWT CRUD        │  task_entries    │
│  Due (home)     │   GET due summary      │                  │
└─────────────────┘                        └────────┬─────────┘
                                                    │
                         runner token, scoped by    │
                         the running job’s project  │
                                                    ▼
                                           ┌──────────────────┐
                                           │  ownrun-runner   │
                                           │  task_* tools    │
                                           └──────────────────┘
```

**Why the server, not the workspace**

| Approach | Why not (for v1) |
|----------|------------------|
| Markdown in a project dir | SPA would need a job round-trip to read; global todos would not span projects |
| Runner-only local DB | Phone UI is offline whenever the runner is; DESIGN.md’s pull model has no inbound home access |
| Job `result_payload` | Jobs are runs, not durable user records |
| Calendar rows with a “todo” flag | Calendar is time-first (month grid, required start). Tasks are work-first (status, priority, optional due day) |

The runner never accepts inbound connections. Task tools are **outbound HTTPS** from the runner to ownrun-server, same as calendar, journal, and claim/heartbeat/complete.

The public web session still cannot execute tools. Only a claimed `agent.task` can call the runner task routes, and only while that job is `running` and owned by this runner.

## 5. Task model

Logical fields (MariaDB table `task_entries`):

| Field | Rules |
|-------|--------|
| `id` | Integer PK, `AUTO_INCREMENT`, same as jobs |
| `user_id` | Owner; single-user app but matches `jobs.user_id` |
| `name` | Required; trim; max **200** chars |
| `description` | Optional; text; max **8 KiB**; empty stored as NULL |
| `due_date` | Optional; **civil date** the task is due (what day), not a time of day; NULL = no due date |
| `project` | Optional; same pattern as CALENDAR.md / JOURNAL.md / AGENT.md §10.2 (`[a-zA-Z0-9]` then up to 63 of `[a-zA-Z0-9._-]`) |
| `priority` | `high` \| `normal` \| `low`; default **`normal`** |
| `status` | `todo` \| `in_progress` \| `finished` \| `deleted`; default **`todo`** |
| `created_by` | `user` \| `agent` |
| `created_job_id` | Nullable; set when an agent creates the row |
| `updated_job_id` | Nullable; last agent job that edited the row |
| `created_at`, `updated_at` | Server timestamps (UTC) |

**`due_date` vs timestamps:** `due_date` is a **DATE** column (no time-of-day). “Today,” “overdue,” and “due today” use the civil date in `OWNRUN_TIMEZONE` (default `America/New_York`, see AGENT.md §10.4) — same “today” agents get from `now`. `created_at` / `updated_at` are audit fields.

**Status `deleted`:** there is no separate `deleted_at` column. Delete sets `status = deleted` and bumps `updated_at`. This is the field the user asked for; it is the trash flag. **Live** queries (default list, get-for-agents, due summary, agent search) exclude `deleted`. Re-deleting an already-deleted id is 404. No hard-delete or purge API in v1 (row stays for a later admin/migration path).

**User restore:** the SPA can list `status=deleted` and `PATCH` status back to `todo` (or `in_progress` / `finished`). Agents never see or restore deleted rows.

**Default on create:** if the client omits `priority`, store `normal`. If it omits `status`, store `todo`. `due_date` and `project` stay NULL unless set. Empty `name` after trim → 422.

Indexes:

- `(user_id, status, due_date, id)` — default open list and due summary
- `(user_id, project, status, due_date)` — project-filtered lists

`project` is a **label**, not a foreign key. The SPA offers `agent_projects` from the last runner heartbeat plus distinct `project` values already on tasks, and a free-text name (same pattern as calendar, journal, and the agent form).

## 6. Project visibility

The user owns the whole task list. **Project scoping applies to agents only.** Write rules match **journal** (stricter than calendar): agents never mutate global tasks.

### 6.1 Definitions

- **Global task:** `project` is NULL. Visible in the SPA always. Visible to **every** agent for **read/search**. **Not writable by agents** in v1 (see §6.3).
- **Project task:** `project` is a valid project id. Visible in the SPA always. Visible to an agent **only** if the running job’s `request_payload.project` equals that id.

### 6.2 Agent read set

Let `P` be the job’s project (string or absent). Deleted rows are never in the read set.

| Job | Agent may search/read |
|-----|------------------------|
| Has project `P` | Global **live** tasks **and** live tasks with `project = P` |
| No project (`web` profile with project omitted) | Global live tasks only |

An agent running for `blog` never sees `notes`-scoped rows. It does see global rows so it can avoid duplicating personal todos the user chose to share across projects.

The model **cannot** pass a project filter to widen this set. The server derives visibility from the job row.

### 6.3 Agent write set

Stricter than read. **Agents can only manage tasks for their own project.**

| Action | Rule |
|--------|------|
| **Add** | Only when the job has project `P`. Server **ignores** any `project` in tool args. New row gets `project = P`, `created_by = agent`, `created_job_id =` this job. If the job has **no** project → **403** (or tool error string), not an unscoped create. |
| **Edit** | Allowed only on live rows with `project = P` where `P` is the job’s project. Agent cannot edit global rows, other projects’ rows, or deleted rows. Cannot change `project`, `created_by`, or `created_job_id`. May change `name`, `description`, `due_date`, `priority`, `status` (`todo` / `in_progress` / `finished` only — use delete for `deleted`). |
| **Delete** | Same write set as edit. Sets `status = deleted`; 404 if the id is outside the write set or already deleted (do not leak that a `notes` task exists). |

So: an agent on `blog` can read global todos and project tasks, and can create, edit, finish, or delete `blog` tasks, but cannot add or change global tasks even if the user asked it to “put this on my main list.”

### 6.4 User writes

The SPA can set, clear, or change `project` on any live task, including ones agents created. Moving a task into a project hides it from other projects’ agents; clearing `project` makes it global (and agent-read-only).

User create: `created_by = user`, `created_job_id` null. User may create global or project-scoped tasks freely. User may set any status, including restoring `deleted` → `todo`.

## 7. Web API

User JWT, same as jobs, calendar, and journal. All rows filtered by `user_id`.

List queries must be **bounded** so the SPA and agents cannot dump the entire table in one response.

### Endpoints

- `GET /api/tasks?project=<optional>&status=<optional>&priority=<optional>&q=<optional>&due_from=<optional>&due_to=<optional>&limit=<optional>&offset=<optional>`
  - Default **open** list: `status` omitted means `todo` and `in_progress` only (never `deleted` unless explicitly requested).
  - `status`: optional. One value or comma-separated (`todo,in_progress,finished`). `deleted` is allowed for the trash view. Unknown value → 422.
  - `priority`: optional. One of `high` / `normal` / `low`.
  - `project` omitted: all matching tasks (user sees everything).
  - `project=` empty or `project=_none`: global only.
  - `project=<id>`: that project only.
  - `q`: optional case-insensitive substring on `name` and `description` (trim; max 200 chars).
  - `due_from` / `due_to`: optional ISO dates (`YYYY-MM-DD`). If either is set, both are required. Inclusive civil dates on `due_date`. Tasks with `due_date` NULL are **excluded** when a due window is set. Max window: **366 days** (wider → 422).
  - `limit`: optional; default **50**, max **100**.
  - `offset`: optional; default **0**.
  - **Sort:** `due_date` ASC with NULLs last, then priority (`high`, `normal`, `low`), then `id` ASC. Open work that is overdue or due soon sorts to the top.
  - Response:

```json
{
  "tasks": [ ... ],
  "truncated": true,
  "total": 81
}
```

  - `truncated`: true when `offset + len(tasks) < total` for this filter.
  - `total`: count matching the same filters (for the SPA pager / “N open”). Cheap on a personal table.

- `GET /api/tasks/{id}` — full row. 404 if missing or wrong user. **User** GET returns deleted rows (so restore works). **Agent** GET never does (see §8).
- `POST /api/tasks` — body: `name` (required), optional `description`, `due_date`, `project`, `priority`, `status` (`todo` / `in_progress` / `finished`; `deleted` on create → 422).
- `PATCH /api/tasks/{id}` — partial; same fields. User may set `project` to null to make a task global, and may set `status` to any of the four values (including restore from `deleted`). Unknown extra keys ignored.
- `DELETE /api/tasks/{id}` — sets `status = deleted` (and `updated_at`). Response `{ "ok": true, "id": n }`. Already deleted or missing → 404.

**Due summary (home page):**

- `GET /api/tasks/due`
  - No query params in v1.
  - “Today” is the civil date in `OWNRUN_TIMEZONE`.
  - Live rows only (`status` in `todo`, `in_progress`).
  - Response:

```json
{
  "today": "2026-08-28",
  "overdue": 2,
  "due_today": 1,
  "open": 7,
  "tasks": [ ... ]
}
```

  - `tasks`: up to **10** open tasks with `due_date <= today`, same sort as the list (overdue first). Enough for a home card; the Tasks page is the full list.
  - Counts are for **all** matching live rows, not just the 10 returned.
  - If there are no open tasks at all: zeros and `"tasks": []`. Hide the card when `open === 0`, or show a quiet empty state — SPA choice; lean **hide** when `overdue === 0 && due_today === 0` so the home page stays a job list until something is actually due.

JSON task shape (web and runner; audit fields may be omitted or shortened for compact agent search — see §8):

```json
{
  "id": 12,
  "name": "Draft blog outline",
  "description": "Use last week’s notes.md",
  "due_date": "2026-08-30",
  "project": "blog",
  "priority": "high",
  "status": "todo",
  "created_by": "agent",
  "created_job_id": 42,
  "created_at": "2026-08-28T19:01:00Z",
  "updated_at": "2026-08-28T19:01:00Z"
}
```

Validation: same project id pattern as jobs; unknown extra keys ignored; `name` required on create; strip description to NULL if empty; `due_date` if present must be `YYYY-MM-DD`.

Extend `GET /api/models` with `task_projects`: union of runner `agent_projects` and distinct `task_entries.project`. Prefer one extra field on the existing models payload so the SPA already has a runner-online fetch. If the runner is offline, still list projects that appear on tasks.

## 8. Runner API and agent tools

### 8.1 Why nested under the job

Do **not** add a global `/api/runner/tasks`. Visibility must come from the **running job**, not from tool arguments.

- Job must exist, `status = running`, `type = agent.task`, `runner_id` = this runner.
- `user_id` on new rows is the job’s user, not a tool-supplied id.

### 8.2 Endpoints

- `GET /api/runner/jobs/{jobId}/tasks?status=&priority=&q=&due_from=&due_to=`
  - Server applies the **read set** (§6.2). Never returns `deleted`.
  - Default `status`: `todo,in_progress` (the working set). Agent may pass `finished` to look at done work; `deleted` → 422.
  - Optional `q`, `priority`, `due_from` / `due_to` (same date-window rules as web when set).
  - **No required date window** — unlike journal/calendar search. The useful default is “open tasks I can see,” not a month of history.
  - Cap **50** rows. `{ "tasks": [ ... ], "truncated": true|false }`.
  - Compact rows omit long `description` or truncate to e.g. **200** chars with `"description_truncated": true` — same spirit as `calendar_search` / `journal_search`.
- `GET /api/runner/jobs/{jobId}/tasks/{id}` — full task including `description`; 404 if not in the read set or deleted.
- `POST /api/runner/jobs/{jobId}/tasks` — create only if job has a project (§6.3). Body: `name`, optional `description`, `due_date`, `priority`, `status` (`todo` / `in_progress` / `finished`). Reject `project` if present (422).
- `PATCH /api/runner/jobs/{jobId}/tasks/{id}` — edit if in the **write set** and live; 404 otherwise. Reject `status=deleted` (422; use DELETE). Reject `project` if present.
- `DELETE /api/runner/jobs/{jobId}/tasks/{id}` — mark deleted if in the **write set** and live; 404 otherwise. Response `{ "ok": true, "id": n }`.

No runner route for the due summary; that is a user-facing affordance only. Agents call `task_search` (default open list) or pass a due window.

### 8.3 Tools (all existing profiles)

Add five tools to **every** profile (`workspace`, `web`, `workspace_web`). They are server calls, not filesystem.

| Tool | Args | Behavior |
|------|------|----------|
| `task_search` | optional `status`, `priority`, `query`, `due_start` (ISO date), `due_end` (ISO date) | GET list; compact rows: `id`, `name`, `due_date`, `project`, `priority`, `status`, truncated `description` |
| `task_get` | `id` | Full task including `description` |
| `task_add` | `name`, optional `description`, `due_date`, `priority`, `status` | POST; fails with clear error if job has no project. Result is the created task. |
| `task_edit` | `id`, plus any updatable fields | PATCH; omit unchanged fields. To finish work: `status=finished`. |
| `task_delete` | `id` | Soft delete (`status=deleted`); confirmation is the `{ ok, id }` payload. Deleted or out-of-scope ids look like missing (404 → error string). |

Agents call `now` when they need “today” for due dates: use `local` in `OWNRUN_TIMEZONE`, then pass **ISO dates** (`YYYY-MM-DD`) for `due_date` / `due_start` / `due_end`. Truncate tool results with the existing 8 KiB helper.

If a due window is invalid or over 366 days, the tool returns an error string to the model (loop continues), same as other tool errors.

### 8.4 System prompt addition

Append a short, profile-agnostic paragraph that names the real tools and a recipe:

- Stamp **today’s real civil date** (from `now` / `OWNRUN_TIMEZONE`) into the system prompt.
- Only `now`, `task_search`, `task_get`, `task_add`, `task_edit`, `task_delete`. Do not invent tools.
- This job’s project (name it, or “none — task writes disabled”) determines whether `task_add` / `task_edit` / `task_delete` are available.
- You can **read** global tasks for context; you can only **add, edit, finish, or delete** tasks for this job’s project.
- Prefer `task_search` (no args) before adding a duplicate; use `task_edit` with `status=finished` when the work is done; use `task_add` for follow-ups this project should not forget.
- Due dates are civil dates (`YYYY-MM-DD`), not timestamps. Omit `due_date` when there is no deadline.

### 8.5 Runner client

The Python client grows task methods that reuse the runner bearer token. Failures (401, 403, 404, 422, network) become tool error strings, not job failures, unless the adapter itself is broken.

## 9. Web UI

Hash routes, same SPA chrome.

- Route: `/#/tasks` (`name: 'tasks'`).
- Header: add **Tasks** next to Journal / Calendar / Prompts.

### Task list (v1)

Default: **open** tasks (`todo` + `in_progress`), sorted as the API sorts.

**Groups** (hide a group when empty):

| Group | Rule |
|-------|------|
| Overdue | `due_date < today`, open |
| Due today | `due_date = today`, open |
| Upcoming | `due_date > today`, open |
| No date | `due_date` null, open |

Today is `OWNRUN_TIMEZONE` via models `timezone` (same as journal’s date default).

- Filter: All | Global | a project from `task_projects`.
- Status chips: Open (default) | Finished | Deleted (trash). Open is `todo` + `in_progress`.
- Optional priority filter (All / High / Normal / Low).
- Each row: name, due date (or “No date”), priority badge, project badge if set, status, quiet marker for `created_by = agent`.
- Tap row → detail: full description, edit fields, **Mark in progress** / **Mark finished** / **Delete**.
- Inline status change (e.g. a select or two buttons) should `PATCH` without opening the full form.

Pagination: if `truncated`, a **More** control with `offset`. Personal lists should rarely need it; 50 is the first page.

Changing filters resets `offset`.

### Create / edit

- **New task** button and empty-state link.
- Fields: name, description (textarea), due date (date picker, optional / clearable), priority (default Normal), status (default To do), project (optional; blank = global).
- Works with the runner offline.

### Due card (jobs home)

- On `JobsView`, near the journal memory card: a compact card when `GET /api/tasks/due` has `overdue > 0` or `due_today > 0`.
- Shows counts (“2 overdue · 1 due today”) and up to a few names; link to `/#/tasks`.
- Hide when nothing is due (keep home a job list).
- Refresh on mount and when returning to the route; no polling required.

No live polling on the tasks page; refresh on navigation and after save. Optional 30–60s poll while the tab is visible is enough if an agent might be adding rows in the background.

## 10. Security

Tasks expand what a stolen **web JWT** can do (read/write the todo list) and what a stolen **runner token** can do (same, but only through a running job’s scope).

Controls:

- User endpoints: JWT; rows always `user_id =` token subject.
- Runner endpoints: runner token **and** job ownership **and** `running` `agent.task`.
- Project on agent create is **server-assigned**, never model-assigned.
- Agent cannot create or mutate global tasks (403 on add when job has no project; 404 on edit/delete outside write set).
- Agent edit/delete 404 for out-of-scope or deleted ids (no existence leak across projects).
- Agent cannot set `status=deleted` via PATCH (must DELETE); cannot pass `project`.
- Row caps, name/description size caps, due-window cap — hostile or verbose tool loops must not fill MariaDB.
- No extra outbound URL from tools: they only call ownrun-server.
- Prompt injection: assume the model will try `task_edit` on global or other-project ids; write-set enforcement is the control, not the prompt.
- Do not put task names or descriptions into runner INFO logs (id only, same as calendar/journal).

## 11. Configuration

No task-specific runner env vars. Civil “today” and overdue math use `OWNRUN_TIMEZONE` from AGENT.md (default `America/New_York`). Server: none beyond the new table and the web page size / 366-day / agent 50-row / home 10-row caps (constants are fine).

Migrate existing DBs with `scripts/migrate_tasks.php` + `sql/migrate_tasks.sql`, same pattern as calendar/journal. Include `task_entries` in `sql/schema.sql` for new installs.

## 12. Observability

- Runner logs: job id, tool name, task id, not name/description at INFO.
- Failed tool calls: error string in the trace as today.
- SPA: API error strings on the form.

## 13. Implementation phases

Tasks are **Phase 8** relative to DESIGN.md (after system prompts Phase 7). They do not depend on the prompt library. They do depend on agent jobs for §8. Phase 8a can ship without touching Autogen.

### Phase 8a — Server + SPA

- Table + user CRUD API + `GET /api/tasks/due`.
- Tasks list (grouped open view), create/edit/delete, optional project field, filters.
- Due card on jobs home.
- Runner offline is fine.

### Phase 8b — Agent tools

- Runner job-scoped task routes.
- `task_search` / `task_get` / `task_add` / `task_edit` / `task_delete` on all profiles.
- System prompt blurb; compact search results; read set vs write set; no global agent writes.

### Phase 8c — Later (optional)

- Restore / trash polish (bulk restore, empty trash / hard purge).
- Subtasks or a checklist inside `description` (still not a second table until needed).
- “Add to calendar” from a due date.
- Drag-to-reorder / explicit `sort_rank`.
- Reminders if a later design adds a worker or a runner-side nag job type.

## 14. Decisions

1. **Storage:** MariaDB on ownrun-server (`task_entries`), not workspace files and not a job type.
2. **User sees everything.** Project scoping is an agent visibility/write rule.
3. **Read set:** global ∪ matching job project, live rows only. **Write set:** matching project only; **no agent writes to global** (same as journal, stricter than calendar).
4. **Agent create** always stamps the job’s project; jobs without a project cannot use `task_add`.
5. **Deleted is a status**, not a `deleted_at` column and not a hard remove. Default lists hide `deleted`. User can restore via PATCH; agents cannot.
6. **Tools on all existing profiles**, not a new profile.
7. **Runner routes nested under the running job**; no global runner tasks API.
8. **`due_date`** is an optional civil DATE; “today” / overdue use `OWNRUN_TIMEZONE`.
9. **Web list:** offset pagination (default 50). **Agent search:** working-set default (open tasks); date window optional, not required.
10. **Priority** defaults to `normal`; **status** defaults to `todo`.
11. **Phase 8a (UI + due card) can land before 8b (tools).**

## 15. Open decisions

- Whether `GET /api/models` grows `task_projects` or a dedicated meta endpoint (lean: extra field on models, mirroring calendar/journal).
- Whether compact `task_search` omits `description` entirely vs truncated — lean truncated for skimming.
- Whether the home due card should list names or only counts (lean: counts plus a few names).
- Header crowding (Calendar / Journal / Prompts / Tasks / New chat / New agent). Lean: add Tasks anyway; overflow menu later if needed.
- Whether finished tasks should sort by `updated_at` DESC instead of due date (lean: same sort as open; filter Finished is enough).
- Offset vs keyset pagination if the personal list ever gets large (lean: offset in v1; 50-row pages).

## 16. Success criteria (tasks v1)

1. From a remote browser, a logged-in user can open `/#/tasks`, see open tasks, and add a global or project task with the runner offline.
2. That task appears after reload; the user can edit it, mark it finished, and delete it; after delete it disappears from the default list (`status = deleted`) but the row remains.
3. The jobs home page shows a due card when at least one open task is overdue or due today.
4. An `agent.task` with project `blog` can search tasks, see global tasks plus `blog` tasks, and add, edit, finish, and delete a `blog` task. It cannot see other projects’ tasks, and cannot create or edit global tasks.
5. An agent job with **no** project can search and read global tasks only; `task_add` returns a clear error.
6. An agent-created row has `project` equal to the job’s project and `created_by = agent`.
7. `ollama.chat` and existing agent file/web/calendar/journal tools are unchanged aside from the extra task tools on agent profiles.
8. No inbound connection to the home machine is required to use the SPA task list or due card.

Phase 8b is required for criteria 4–6. Phase 8a alone satisfies 1–3 and 7–8.

---

*Next step after this design: implement Phase 8a only (schema, user API, tasks view, home due card) unless agent tools are explicitly requested in the same change set.*
