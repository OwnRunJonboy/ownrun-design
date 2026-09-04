# OwnRun Project Tool Policy Design

**Status:** Draft  
**Date:** 2026-08-31  
**Author:** Jonboy  
**Depends on:** [DESIGN.md](DESIGN.md) (hosting, auth), [AGENT.md](AGENT.md) (profiles, tool catalog, project ids)  
**Related:** [WEB_SEARCH.md](WEB_SEARCH.md) — first optional tool gated by this policy (`web_search`). [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md) — same “project label on server, not a filesystem FK” pattern as per-project prompt defaults.

This document designs **which agent tools a project (and a single job) may use**. It is not a new job type and not a plugin system. The runner still owns the catalog; the user can only **turn off** tools the profile already allows — never add tools the profile omits or the runner does not implement.

No implementation in this document.

## 1. Purpose

Today, an agent job’s tools come entirely from its **profile** (`workspace`, `web`, `workspace_web`) plus calendar/journal/task tools on every profile. There is no way to say:

- “Project `blog` may edit files and calendar, but **no web search**”
- “Project `notes` is workspace-only — **no HTTP fetch**”
- “This one agent run should not search, even though `blog` usually can”

Profiles are coarse. Project labels already scope calendar/journal/task **data**; they should also scope **capabilities** where the user wants tighter control.

Web search ([WEB_SEARCH.md](WEB_SEARCH.md)) is the first tool that benefits from an off switch. The same mechanism should cover `http_fetch`, file tools, and server-backed tools without a one-off flag per feature.

## 2. Goals

- **Per-project** persisted policy: disable named tools for all future agent jobs on that project.
- **Per-job** override on New agent: disable named tools for this run only (snapshotted on the job).
- **Runner enforcement** — the model cannot re-enable tools via arguments; disabled tools are not registered with Autogen.
- **Subtract-only** — policy removes tools from the profile catalog; it never grants extra tools.
- Stay compatible with shared hosting: MariaDB + SPA CRUD; runner applies policy at job start (may fetch policy once per job from server or receive it on claim — see §8).
- Work with runner offline for **creating** jobs only if we accept stale policy (lean: require runner online for agent jobs anyway; policy fetch is best-effort from server when job runs).

## 3. Non-goals (tool policy v1)

- Enabling tools outside the job’s profile (e.g. `web_search` on `workspace`).
- User-supplied tool names, MCP servers, or shell.
- Agent tools to read or change policy mid-job (prompt injection must not widen the catalog).
- Per-model or per-profile **defaults** stored on the server (profile stays the primary bundle; project policy is an overlay).
- Replacing profiles with a fully custom tool picker on every job (too easy to misconfigure; profile + project subtract is enough).
- Tool policy on `ollama.chat` (no tools).
- Audit log of policy changes (timestamps on the row are enough).
- “Allowlist only these five tools” mode in v1 (subtract `disabled_tools` only; allowlist is a later optimization if subtract lists get long).

## 4. Tool names (canonical)

Policy references **stable string ids** matching trace `tool_call.name` and runner registration.

| Id | Profile / scope |
|----|------------------|
| `now` | All profiles |
| `list_dir`, `read_file`, `write_file` | `workspace`, `workspace_web` |
| `http_fetch` | `web`, `workspace_web` |
| `web_search` | `web`, `workspace_web` (when runner search is enabled — [WEB_SEARCH.md](WEB_SEARCH.md)) |
| `calendar_search`, `calendar_get`, `calendar_add`, `calendar_edit`, `calendar_delete` | All profiles |
| `journal_search`, `journal_get`, `journal_add`, `journal_edit`, `journal_delete` | All profiles |
| `task_search`, `task_get`, `task_add`, `task_edit`, `task_delete` | All profiles |

New tools get a id here when they ship. Server validation rejects unknown ids on PUT.

Runner heartbeat may advertise the full list as `agent_tool_ids` so the SPA can render toggles without hard-coding.

## 5. Effective tool set

At job start, the runner computes:

```
base = tools_for_profile(profile)     # AGENT.md §10 + calendar/journal/task
disabled = runner_global_disabled
         ∪ project_policy(project)    # if project set
         ∪ job_disabled               # from request_payload
effective = { t ∈ base | t.id ∉ disabled }
```

Rules:

- If `project` is omitted (`web` profile only), only runner global + job disabled apply.
- Disabling a tool not in `base` is a no-op (do not error).
- Disabling `now` is allowed but discouraged in UI copy (breaks calendar date recipes).
- **Runner global:** e.g. `OWNRUN_AGENT_WEB_SEARCH=0` adds `web_search` to runner global disabled without touching MariaDB.
- Register **only** `effective` tools with `AssistantAgent`. System prompt lists **only** effective tool names (no “you might have web_search” if it was disabled).

Continue copies parent `project` and parent `disabled_tools` (job snapshot), same as `system_prompt` — do not re-resolve project policy from DB on continue (history consistency).

Requeue copies the failed job’s payload including `disabled_tools`.

## 6. Data model

Table `project_tool_policies` (MariaDB on ownrun-server):

| Field | Rules |
|-------|--------|
| `user_id` | Owner |
| `project` | Label; same id pattern as AGENT.md §10.2 |
| `disabled_tools` | JSON array of tool id strings; default **`[]`** |
| `updated_at` | UTC timestamp |

Primary key `(user_id, project)`. No row = nothing disabled for that project.

**Not stored on the project directory.** Same as calendar/journal/prompt defaults: the label is shared; metadata lives on the server.

### Job snapshot

`request_payload` for `agent.task` grows optional:

```json
{
  "disabled_tools": ["web_search"]
}
```

Omitted or `[]` = no extra job-level disables beyond project policy. Server validates each id against the known catalog (422 on unknown). Max **20** ids per job.

Optional convenience on create (SPA only, expanded server-side before store):

```json
{ "web_search": false }
```

Server translates to `disabled_tools` containing `web_search` if not already present. Prefer storing **`disabled_tools` only** on the job row for one source of truth.

## 7. Web API

User JWT. All rows filtered by `user_id`.

- `GET /api/project-tool-policies` — list all project policies for this user.

```json
{
  "policies": [
    { "project": "blog", "disabled_tools": ["web_search"], "updated_at": "..." }
  ]
}
```

- `GET /api/project-tool-policies/{project}` — one row. 404 if no policy row (SPA treats as `disabled_tools: []`).
- `PUT /api/project-tool-policies/{project}` — body: `{ "disabled_tools": [ ... ] }`. Creates or replaces. Validates project id pattern and tool ids.
- `DELETE /api/project-tool-policies/{project}` — remove row (same as empty policy).

Extend `GET /api/models` (or system-prompts payload pattern) with `project_tool_policies`: map `project → disabled_tools[]` so New agent can grey out toggles without an extra round-trip. Lean: **extra field on models** when policies are loaded, union project keys with `agent_projects`.

No runner-authenticated write API in v1. Agents never mutate policy.

## 8. Runner behavior

When processing `agent.task`:

1. Read `profile`, `project`, `disabled_tools` from `request_payload`.
2. Load project policy: **GET** from ownrun-server (runner token + job’s user) once at start, or server includes `project_disabled_tools` on an existing job detail endpoint the runner already calls — lean: **small GET** `GET /api/runner/jobs/{id}/tool-policy` returning `{ "disabled_tools": [...] }` merged server-side from project row (404/empty if none). Job-level `disabled_tools` merged on the runner: `effective_disabled = server_project_disabled ∪ job_disabled`.
3. Apply runner global disables.
4. Build `effective` list; pass to `build_tools` / `AssistantAgent`.

If policy fetch fails (network), **fail the job** with a clear error when `project` is set and policy could matter — or lean for v1: **treat as empty project policy** and log warning (user asked for enforcement; lean **fail** if server unreachable and project has ever had a policy — too complex). **Decision:** unreachable server → empty project policy, job-level disabled still apply; log WARNING. Policy is a convenience layer; job snapshot is authoritative for job disables.

System message builder takes `effective_tool_ids` and omits paragraphs for disabled groups (e.g. no web search blurb if `web_search` ∉ effective).

## 9. Web UI

### 9.1 New agent form

When profile includes web tools (`web` or `workspace_web`) and models say search is available:

- Checkbox **Web search** — default **on**.
- When project is selected, default the checkbox from project policy (`web_search` not in `disabled_tools`).
- User unchecking sets `disabled_tools: ["web_search"]` on create (merge with any future job-level toggles).

When profile is `workspace_web`, optional advanced collapsible **Tools for this job** with checkboxes for each tool in the profile’s base set (all on by default; project policy pre-unchecks). v1 UI may ship **web search only**; schema supports the rest.

Caption when project disables search: “Project `blog` disables web search by default” with link to project settings.

### 9.2 Project tool settings (v1 minimal)

Route: `/#/projects/{project}/tools` or a section on a future project hub. v1 can be a simple list:

- One row per tool id in the union of profile tools (or only tools relevant to “usually workspace_web” projects).
- Toggle = “allowed for this project” (inverted UI for `disabled_tools`).

**Phase 9b UI lean:** only **Web search** and **HTTP fetch** toggles plus “Reset to defaults.” Full matrix in Phase 9c.

### 9.3 What we are not building in 9a

A 20-toggle spreadsheet on first ship. Infrastructure + web search toggle + project PUT API first; expand toggles once the pattern works.

## 10. Security

- Policy is user JWT only; runner reads merged policy via runner auth + job ownership.
- Subtract-only: disabling `write_file` does not block prompt injection from trying; it removes the tool so calls fail at registration (model should not see the tool — if the model hallucinates a call, Autogen returns tool missing).
- Do not let `disabled_tools` on the job **remove** disables from project policy (union only, never subtract project disables from job payload).
- Prompt injection cannot PATCH project policy (no agent route).
- Unknown tool ids on create → 422.

## 11. Configuration

### Runner

| Variable | Role |
|----------|------|
| `OWNRUN_AGENT_WEB_SEARCH` | Global subtract: adds `web_search` to runner global disabled when `0` |

Future globals (e.g. disable all fetch) follow the same pattern.

### Server

No env beyond migration.

## 12. Implementation phases

Tool policy is **Phase 9** alongside web search ([WEB_SEARCH.md](WEB_SEARCH.md)).

### Phase 9a — Policy core + web search toggle

- Table + user CRUD API.
- `disabled_tools` on job create; server validation.
- Runner merge + effective tool registration.
- New agent: **Web search** checkbox; project default from policy.
- `GET /api/models` includes policies map (or embedded list).
- [WEB_SEARCH.md](WEB_SEARCH.md) Phase 9a (Ollama search) uses this gate.

### Phase 9b — Project settings page

- `/#/projects/.../tools` or equivalent.
- Toggles for `web_search` and `http_fetch` at minimum.

### Phase 9c — Full matrix (optional)

- All tool ids toggleable per project.
- Optional global defaults (not per-project): “new projects start with search off.”

## 13. Decisions

1. **Subtract-only** `disabled_tools`; profile defines the ceiling.
2. **Project policy in MariaDB**; not files in the workspace.
3. **Job snapshot** `disabled_tools`; continue/requeue copy payload, do not re-read project policy.
4. **Canonical tool ids** on runner, server, and SPA.
5. **First UI surface:** New agent web search checkbox + project policy API; full matrix deferred to 9b/9c.
6. **Runner global** env still overrides (operator kill switch).
7. **No agent write** to policy.

## 14. Open decisions

- Dedicated runner GET for merged policy vs embedding on claim response (lean: runner GET once at job start).
- Whether to show project tool settings under Prompts nav or a new Projects nav (lean: link from New agent caption first; small settings route in 9b).
- Fail vs warn when project policy fetch fails (lean: warn, job disables still apply).

## 15. Success criteria (tool policy v1 / Phase 9a)

1. User can `PUT` policy disabling `web_search` for project `blog`.
2. New agent with project `blog` and profile `workspace_web` creates a job whose trace never contains `web_search`, even if the checkbox would default off from policy.
3. Same project, user checks **Web search** on one job → that job’s trace may use `web_search`; other jobs without the override still respect project policy.
4. Disabling `web_search` in project policy does not remove `http_fetch`.
5. `workspace` profile jobs ignore `web_search` in policy (no-op).
6. Continue inherits parent `disabled_tools`.
7. Agent cannot call a disabled tool by name in a hallucinated tool_call (tool not registered).

---

*Next step: implement Phase 9a policy core together with [WEB_SEARCH.md](WEB_SEARCH.md) Ollama search — not the full project settings page unless requested.*
