# OwnRun System Prompt Design

**Status:** Draft  
**Date:** 2026-08-27  
**Author:** Jonboy  
**Depends on:** [DESIGN.md](DESIGN.md) (hosting, auth, jobs, `ollama.chat`), [AGENT.md](AGENT.md) (agent jobs, project ids, profile system message)

This document designs a **saved system-prompt library** and **defaults** (global and per-project) for both chat and agent jobs. It is not a new job type.

No implementation in this document.

## 1. Purpose

OwnRun already lets the user type an optional system prompt on New chat and New agent. That text lives only on that job. There is no way to reuse a voice, keep a list of past instructions, or say “when I work on `blog`, start from this.”

Without a library and defaults:

- The user retypes the same standing instructions on every job, or forgets and gets a generic model
- A project has a workspace directory, calendar rows, and journal entries, but no **standing brief** for chats and agents that touch it
- Continue copies whatever happened to be on the parent job, which is correct for a thread and useless as a catalog of voices

System prompts are **user data on the PHP host**, like journal and calendar. The SPA can manage them with the runner offline. When a job is created, the chosen text is **snapshotted** onto `request_payload.system_prompt` so later library edits do not rewrite history. The runner keeps doing what it does today: chat uses that string as the system message; the agent **appends** it to the runner-owned profile / calendar / journal boilerplate.

## 2. Goals

- Keep per-job system prompts on both `ollama.chat` and `agent.task` (already in the forms).
- Let the user **save** named prompts and **load** them on either form.
- Let the user set a **global default** for new chats and a **global default** for new agent tasks.
- Let the user set **per-project defaults** (chat and agent separately) so picking a project auto-fills the textarea.
- Snapshot the resolved text on the job. Continue and requeue keep that snapshot, not a live lookup.
- Stay compatible with shared hosting: MariaDB, request/response PHP, no cron, no WebSockets.
- Work with the runner offline. No new runner tools or runner routes.
- Leave the runner-owned agent system message (tools, date, project label, calendar/journal rules) non-overridable.

## 3. Non-goals (prompts v1)

- Agent tools to read or write the library (prompt injection must not change standing instructions for future jobs).
- Templating / variables in bodies (`{{project}}`, `{{date}}`). The agent profile message already stamps date and project.
- Version history, diffs, or restore of old prompt bodies.
- Sharing, import/export, or a prompt marketplace.
- Per-model or per-profile defaults (project + job type is enough).
- Replacing the agent profile boilerplate with a user prompt. User text is always extra.
- Changing the system prompt on continue (v1 inherits the parent snapshot).
- Markdown rendering in the library UI.
- Auto-capturing every ad-hoc job prompt into the library (save is explicit).

## 4. Where it lives

Library rows and default assignments live in **MariaDB on ownrun-server**. They are not files under `OWNRUN_AGENT_WORKSPACE`.

```
┌─────────────────┐         HTTPS          ┌──────────────────────┐
│   ownrun-web    │ ─────────────────────► │  ownrun-server       │
│  Prompts page   │   user JWT CRUD        │  system_prompts      │
│  New chat/agent │   job still carries    │  user_prompt_defaults│
│                 │   snapshotted text     │  project_prompt_     │
└─────────────────┘                        │    defaults          │
                                           └──────────┬───────────┘
                                                      │
                         job payload already has      │
                         request_payload.system_prompt│
                                                      ▼
                                           ┌──────────────────────┐
                                           │  ownrun-runner       │
                                           │  unchanged contract  │
                                           └──────────────────────┘
```

**Why the server, not the workspace**

| Approach | Why not (for v1) |
|----------|------------------|
| Markdown in a project dir | SPA would need a job round-trip to load a prompt before composing a chat; library would not span projects |
| Only on the job row | No reuse, no defaults, no catalog |
| Runner-only local files | Phone UI is offline whenever the runner is |

The runner never fetches the library. Resolution happens in the SPA (and optionally the server copies body from an id at create — see §9). The job the runner claims already has `system_prompt` text, same as today.

## 5. Prompt library

Logical fields (MariaDB table `system_prompts`):

| Field | Rules |
|-------|--------|
| `id` | Integer PK, `AUTO_INCREMENT` |
| `user_id` | Owner |
| `name` | Required; trim; max **80** chars; unique per user |
| `body` | Required; text; max **8 KiB** UTF-8 |
| `applies_to` | `chat` \| `agent` \| `both` (default `both`) |
| `created_at`, `updated_at` | Server timestamps (UTC) |

`applies_to` filters pickers: the chat form lists `chat` and `both`; the agent form lists `agent` and `both`. A `chat`-only row cannot be assigned as an agent default (422).

**Caps:** max **100** library rows per user (create beyond that → 422). Enough for a personal catalog; stops a runaway client from filling MariaDB.

**Delete:** hard delete. Jobs keep their snapshotted `system_prompt` text. Default assignments that pointed at the row become NULL (`ON DELETE SET NULL`). No soft delete in v1.

Empty name or empty body after trim → 422. Unknown extra keys ignored.

## 6. Defaults

Two layers. Both **reference** a library id (not a copied body). Editing the library body changes what future jobs auto-fill; it does not change jobs already created.

### 6.1 Global defaults

Table `user_prompt_defaults` (one row per user, created on first set):

| Field | Rules |
|-------|--------|
| `user_id` | PK, FK to `users` |
| `chat_prompt_id` | Nullable FK to `system_prompts` |
| `agent_prompt_id` | Nullable FK to `system_prompts` |

Missing row or NULL id = no global default for that job type (today’s empty textarea).

### 6.2 Project defaults

Table `project_prompt_defaults`:

| Field | Rules |
|-------|--------|
| `id` | Integer PK |
| `user_id` | Owner |
| `project` | Required; same id pattern as AGENT.md §10.2 |
| `chat_prompt_id` | Nullable FK to `system_prompts` |
| `agent_prompt_id` | Nullable FK to `system_prompts` |
| unique `(user_id, project)` | One row per project |

`project` is a **label**, not a foreign key — same as calendar and journal. The SPA offers `agent_projects` from the last runner heartbeat plus distinct `project` values already in this table, and a free-text name.

If both FKs are NULL, delete the row (no empty default rows).

Chat and agent slots are independent. The same library id may fill both. One library row may be the default for many projects.

### 6.3 Optional project on chat jobs

`ollama.chat` today has no project. Per-project chat defaults need a project on the form.

Add optional `project` on `ollama.chat` `request_payload`:

- Same id pattern as agent projects.
- **Label only.** Chat stays one Ollama call; no file tools, no calendar/journal write-set.
- The runner Ollama adapter ignores `project` if present.
- Continue copies the parent’s `project` (and system prompt snapshot) as it already copies model and messages.
- Job list / detail may show a project badge, same as agent jobs.

Without this field, project defaults would only apply to `agent.task`. Chats would still have the library and a global chat default.

## 7. Resolution (composing a job)

The server does **not** inject a default when `system_prompt` is omitted. An empty textarea means no extra system prompt, even if a default exists. That lets the user clear the field on purpose.

The SPA fills the textarea. What is submitted is what the job stores.

### 7.1 Auto-fill order

Let `K` be `chat` or `agent` for the form being edited. Let `P` be the selected project, or none.

1. If the textarea is **dirty** (the user typed, loaded a library row, or cleared it this session) → do not overwrite.
2. Else if `P` is set and that project has a default for `K` → fill that body.
3. Else if a global default for `K` exists → fill that body.
4. Else leave empty.

Changing the project re-runs this, still respecting dirty. If the field is not dirty and the new project has no default, fall back to the global default (or empty).

When the filled body differs from the applicable default because the field is dirty, show a quiet control: **Apply project default** (or **Apply chat default**). One click replaces the textarea and clears dirty. No modal.

Loading a row from the saved-prompt picker sets the textarea and marks dirty.

### 7.2 Snapshot

`POST /api/jobs` continues to accept `system_prompt` text (trim; empty → omit / null). That string is the snapshot.

Do **not** store a live `system_prompt_id` on the job in v1. The body is the contract. Library edits must not change a queued or finished job, continue, or requeue.

Continue (existing `POST /jobs/{id}/continue`): copy parent `system_prompt` and `project`. Do not re-resolve defaults.

Requeue: same payload, same snapshot.

### 7.3 Agent composition (runner, unchanged contract)

For `agent.task`, the runner still builds:

```
<profile boilerplate>
<calendar tool paragraph>
<journal tool paragraph>
<task tool paragraph>
Additional instructions:
<user system_prompt>
```

The user library cannot hide tools, dates, or project write-set rules. If `system_prompt` is null, there is no “Additional instructions” block (today’s behavior). Task tools are specified in [TASKS.md](TASKS.md).

For `ollama.chat`, `system_prompt` is the **entire** system message. There is no profile boilerplate.

## 8. Web API

User JWT, same as jobs. All rows filtered by `user_id`. No runner endpoints.

### Library

- `GET /api/system-prompts`
  - Returns the library plus current defaults (one round-trip for the forms and the Prompts page).

```json
{
  "prompts": [
    {
      "id": 3,
      "name": "Blog editor",
      "body": "You are a careful editor for the personal blog…",
      "applies_to": "both",
      "created_at": "2026-08-27T18:00:00Z",
      "updated_at": "2026-08-27T18:00:00Z"
    }
  ],
  "defaults": {
    "chat_prompt_id": 3,
    "agent_prompt_id": null
  },
  "project_defaults": [
    {
      "project": "blog",
      "chat_prompt_id": 3,
      "agent_prompt_id": 3
    }
  ]
}
```

  - `prompts` ordered by `name` ASC. No pagination (hard cap 100).
- `GET /api/system-prompts/{id}` — 404 if missing or wrong user.
- `POST /api/system-prompts` — body: `name`, `body`, optional `applies_to` (default `both`). 201 + row. 422 on duplicate name, empty fields, oversize, or cap.
- `PATCH /api/system-prompts/{id}` — partial; same fields. Renaming onto another row’s name → 422.
- `DELETE /api/system-prompts/{id}` — hard delete; `{ "ok": true, "id": n }`. Defaults that referenced it become null.

### Global defaults

- `PUT /api/system-prompts/defaults`
  - Body: `chat_prompt_id` and/or `agent_prompt_id` (JSON `null` clears that slot).
  - Ids must exist, belong to this user, and `applies_to` must include that job type.
  - Upserts the `user_prompt_defaults` row.

### Project defaults

- `PUT /api/system-prompts/defaults/projects/{project}`
  - `{project}` must match the project id pattern (422 otherwise).
  - Body: `chat_prompt_id` and/or `agent_prompt_id` (JSON `null` clears).
  - Same ownership / `applies_to` checks.
  - Upserts the row; if both slots are null after the update, delete the row.
- `DELETE /api/system-prompts/defaults/projects/{project}` — remove that project’s default row. 404 if none.

Job create/continue APIs stay as they are, plus optional `project` on `ollama.chat`. Do not add a `system_prompt_id` field to job create in v1.

## 9. Web UI

Hash routes, same SPA chrome.

- Route: `/#/prompts` (`name: 'prompts'`).
- Header: add **Prompts** next to Journal / Calendar.

### Prompts page

Two sections on one page (phone-usable; no separate settings app).

**Library**

- List: name, `applies_to` badge, body excerpt (~120 chars).
- New / edit: name, body (textarea), applies-to (chat / agent / both).
- Delete with confirm.
- On a row: **Set as default chat**, **Set as default agent** (toggles; shows which is current).

**Defaults**

- Global: two dropdowns (Chat default, Agent default) including a None option. Options filtered by `applies_to`.
- Per project: a list of known projects. Each row has chat and agent dropdowns. **Add project** uses the same name rules as the agent form (existing select + new name).
- Saving a dropdown writes immediately (PUT), not a giant form at the bottom.

Works with the runner offline. Project names still come from last-known `agent_projects` on `GET /api/models` when that fetch succeeds; union with `project_defaults[].project`.

### New chat / New agent

Keep the system prompt textarea. Add:

- **Saved prompts** `<select>`: “Load saved…” plus filtered library names. Choosing one copies `body` into the textarea.
- **Save as…** — small inline name field + save. Pre-fill `applies_to` from the form (`chat` vs `agent`). Optional checkboxes: set as global default for this job type; if a project is selected, set as that project’s default for this job type.
- **Project** on the chat form, optional (existing control on the agent form). Changing it auto-fills per §7.1.
- Quiet caption when auto-filled: “Using default for project `blog`” (or “Using default chat prompt”).
- **Apply project default** if dirty and a default exists (§7.1).

Empty system prompt remains valid.

### Job detail

If `request.system_prompt` is set (already shown): add **Save to library**. Opens the same name field as Save as…, body taken from the job snapshot. Does not change the job.

Continue form: no system-prompt editor in v1.

## 10. Security

The library expands what a stolen **web JWT** can do (read/write standing instructions). It does not expand the runner token.

Controls:

- User endpoints: JWT; rows always `user_id =` token subject.
- No runner routes. A stolen runner token cannot list or edit prompts.
- No agent tools. A prompt-injected `agent.task` cannot PATCH the library or change defaults for the next job. It can only influence the current run through the user task text, as today.
- Name uniqueness, body size (8 KiB), library cap (100), project id pattern.
- Runner-owned agent boilerplate stays first; user extra is appended and cannot strip tools.
- Do not put prompt bodies into runner INFO logs (jobs already carry them in payload; same care as prompts today).

## 11. Configuration

No new runner env vars. Server: constants are fine (8 KiB body, 80-char name, 100-row cap).

Migrate existing DBs with `scripts/migrate_system_prompts.php` + `sql/migrate_system_prompts.sql`, same pattern as calendar/journal. Include the three tables in `sql/schema.sql` for new installs.

Existing jobs are unchanged. Their `system_prompt` values are not auto-imported into the library.

## 12. Observability

- SPA: API error strings on the Prompts page and the Save as… control.
- Failed default assignment (wrong `applies_to`, missing id) → 422 with a clear message.
- No extra job status values.

## 13. Implementation phases

System prompts are **Phase 7** relative to DESIGN.md (after journal Phase 6). They do not depend on journal or calendar. They do depend on both job forms existing. No Autogen work.

### Phase 7a — Library + pickers + global defaults

- Tables `system_prompts` and `user_prompt_defaults`.
- CRUD API + `PUT` global defaults.
- Prompts page (library + global dropdowns).
- New chat / New agent: load saved, save as, auto-fill from global default.
- Job detail: save snapshot to library.
- Runner untouched.

### Phase 7b — Project defaults + optional chat project

- Table `project_prompt_defaults`.
- PUT/DELETE project default endpoints.
- Prompts page: per-project dropdowns.
- Optional `project` on `ollama.chat` create + continue inherit.
- Auto-fill on project change; Apply default control.
- Chat job list/detail: project badge when set.

Phase 7a is useful alone. 7b is what makes “default for this project” real on both forms.

### Phase 7c — Later (optional)

- Override system prompt on continue.
- `system_prompt_id` on the job for “open this library row.”
- Variables in bodies.
- Per-profile agent defaults (`workspace` vs `web`).
- Import a prompt from a workspace file via an agent (still user-confirmed in the SPA).

## 14. Decisions

1. **Storage:** MariaDB on ownrun-server, not workspace files.
2. **Both job types** use the same library; `applies_to` filters pickers and default slots.
3. **Defaults reference library ids.** Jobs snapshot **body text** at submit. Continue/requeue do not re-resolve.
4. **Server does not auto-inject** when the client omits `system_prompt`. Clearing the textarea is a real empty prompt.
5. **Separate chat vs agent defaults** globally and per project. Same id may fill both slots.
6. **User extra never replaces** the agent profile / calendar / journal system message.
7. **Optional `project` on `ollama.chat`** for default lookup and a badge; no sandbox.
8. **No agent tools** for the library.
9. **Hard delete** library rows; defaults null out; jobs keep text.
10. **Phase 7a can land before 7b.**

## 15. Open decisions

- Whether chat project should also appear in the same project dropdown data as calendar/journal (`GET /api/models` vs the prompts payload). Lean: forms already load models; union `agent_projects` with `project_defaults`.
- Whether duplicate names should be allowed (lean: unique per user).
- Whether Save as… from the job form should require a unique name or offer “overwrite existing.” Lean: unique; user picks a new name or edits on the Prompts page.
- Header crowding (Calendar / Journal / Prompts / New chat / New agent). Lean: add Prompts anyway; overflow menu later if needed.

## 16. Success criteria (prompts v1)

1. From a remote browser, a logged-in user can open `/#/prompts`, create a named prompt, and see it after reload, with the runner offline.
2. New chat and New agent can load that prompt into the system field and submit; the job’s `request.system_prompt` equals the library body at submit time.
3. Editing the library body does **not** change that already-created job (or a continue of it).
4. Setting a global chat default auto-fills New chat on the next visit; the user can clear the textarea and submit with no system prompt.
5. Setting project `blog`’s agent default auto-fills New agent when `blog` is selected; selecting another project without a default falls back to the global agent default (or empty).
6. An `ollama.chat` job can carry an optional `project`; continue keeps that project and the snapshotted system prompt.
7. `agent.task` still prepends the runner profile / calendar / journal boilerplate; the saved prompt only appears under additional instructions.
8. No inbound connection to the home machine is required to manage the library or defaults.

Phase 7b is required for criteria 5–6. Phase 7a alone satisfies 1–4, 7–8.

---

*Next step after this design: implement Phase 7a only (library, global defaults, pickers on both forms) unless project defaults are explicitly requested in the same change set.*
