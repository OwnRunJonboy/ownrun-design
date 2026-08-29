# OwnRun Agent Design

**Status:** Draft  
**Date:** 2026-08-23  
**Author:** Jonboy  
**Depends on:** [DESIGN.md](DESIGN.md) (product architecture, job queue, security, hosting constraints)  
**Related:** [CALENDAR.md](CALENDAR.md) — personal calendar; agents search/view/add/edit/delete via extra tools, scoped by job project. [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md) — saved system-prompt library and per-project defaults; user extra is still appended to the profile system message.

This document designs an **agent job type** for OwnRun. It does not replace the existing `ollama.chat` path. Chat stays the simple one-shot / continue-conversation flow. Agents are a new kind of job that can plan, call tools, and loop until a task is done.

No implementation in this document.

## 1. Purpose

OwnRun already lets a remote browser submit a prompt and get a local Ollama reply. That is **one model call**. It cannot:

- Decide to use a tool, run it, and feed the result back into the model
- Repeat that loop until the task is finished
- Keep a bounded working memory of tool traces
- Stop on a policy (max turns, timeout, user cancel)

Those behaviors are what “agentic” means here. Ollama stays the **local LLM**. An agent framework on the home runner owns the **loop**.

The user submits a **task** from ownrun-web while away. The home runner claims the job, runs an Autogen AgentChat agent against local Ollama plus a fixed tool catalog, and uploads a final answer plus a readable trace.

## 2. Why Ollama alone is not enough

Ollama is a model server. `/api/chat` generates a reply. Some models also emit `tool_calls` if the client sends a `tools` schema. Ollama does **not**:

- Execute those tools
- Append tool results and call the model again
- Enforce max iterations or cancellation
- Present a stable tool catalog to the user
- Turn a stream of inner events into something OwnRun can store and show

A thin “if tool_calls then run function” loop in the runner would reinvent what AgentChat already does (`AssistantAgent.run` / `run_stream`, `CancellationToken`, termination conditions, typed events). OwnRun should not grow a second agent runtime.

**Split of roles**

| Layer | Owns |
|-------|------|
| Ollama | Weights, `/api/chat`, optional native tool-calling |
| Autogen AgentChat | Agent loop, tool dispatch, termination, event stream |
| ownrun-runner | Job claim, heartbeats, sandbox, upload |
| ownrun-server | Queue, auth, persistence |
| ownrun-web | Task form, trace view, cancel / requeue / continue |

## 3. Goals

- Submit an **agent task** from the same remote UI as text jobs.
- Execute it on the home machine with **Ollama + AgentChat**, no inbound home networking.
- Return a **final answer** and a **step trace** (messages, tool calls, tool results).
- Keep tools **predefined and sandboxed**. The web UI never sends arbitrary code or shell.
- Stay compatible with shared hosting: PHP request/response, polling, no WebSockets.
- Leave `ollama.chat` unchanged.

## 4. Non-goals (agent v1)

- Magentic-One, Swarm, or other multi-agent teams.
- Human-in-the-loop mid-job (UserProxyAgent). The runner is single-threaded on jobs; blocking on a remote “approve this?” would stall the queue. OwnRun remains “submit and check back.”
- Arbitrary shell, unrestricted filesystem, or browser-use / WebSurfer.
- Streaming tokens to the browser. Progress is coarse: a growing trace snapshot on poll.
- Cloud model providers (OpenAI, Azure, Anthropic). Local Ollama only.
- MCP tool servers (later, once the built-in catalog is stable).
- Persistent Autogen agent state across jobs (save/load component dumps).
- Image generation (still the later Stable Diffusion track in DESIGN.md).

## 5. Framework choice: Autogen AgentChat

**Use AutoGen 0.4+ AgentChat**, not the 0.2 `ConversableAgent` API.

Packages on the runner:

- `autogen-agentchat` — `AssistantAgent`, `run` / `run_stream`, messages, termination
- `autogen-ext[ollama]` — `OllamaChatCompletionClient`
- `autogen-core` — comes in as a dependency (`CancellationToken`, model protocol)

**Why this stack**

- Native Ollama client (`OllamaChatCompletionClient`); no OpenAI-compat shim required.
- `AssistantAgent` is the right first topology: one model, a tool list, loop until the model stops calling tools or a bound is hit.
- `run_stream()` yields `ToolCallRequestEvent`, `ToolCallExecutionEvent`, and chat messages — enough to build an OwnRun trace without scraping logs.
- `CancellationToken` maps onto OwnRun cancel.
- `max_tool_iterations` plus a wall-clock timeout bound runaway loops.
- Same language and machine as ownrun-runner.

**Why not Magentic-One in v1**

Magentic-One (orchestrator + FileSurfer + MultimodalWebSurfer + Coder + code executor) fights OwnRun’s security non-goals: code execution, a real browser, and a lot of tokens. Local 7B–14B models also struggle as orchestrators. Teams can be a later profile if a single assistant with tools is not enough.

**Risk accepted:** Autogen’s Ollama client is still documented as experimental. Pin package versions. Fail the job clearly if the client cannot talk to Ollama or the model rejects tools.

## 6. Where it runs

The agent loop runs **only on the home computer**, inside ownrun-runner. The PHP host never imports Autogen, never calls Ollama, and never executes tools.

```
┌─────────────────┐         HTTPS          ┌──────────────────┐
│   ownrun-web    │ ─────────────────────► │  ownrun-server   │
│  New agent task │ ◄───────────────────── │  queue + jobs    │
└─────────────────┘                        └────────┬─────────┘
                                                    │ claim / heartbeat /
                                                    │ progress / complete
                                                    ▼
                                           ┌──────────────────┐
                                           │  ownrun-runner   │
                                           │  agent adapter   │
                                           │  (AgentChat)     │
                                           └────────┬─────────┘
                                    ┌───────────────┼───────────────┐
                                    ▼               ▼               ▼
                               ┌─────────┐   ┌────────────┐   ┌──────────┐
                               │ Ollama  │   │ Tool catalog│   │ Workspace│
                               │ :11434  │   │ (allowlist) │   │ dir      │
                               └─────────┘   └────────────┘   └──────────┘
```

This preserves DESIGN.md’s pull model. Shared hosting still has no long-lived workers.

The runner’s main loop stays “claim one job at a time.” AgentChat is asyncio; the adapter runs `asyncio.run(...)` for that job. Existing `ollama.chat` jobs stay on the current synchronous Ollama HTTP client. Heartbeats during an agent job keep using the existing 30s job-heartbeat thread.

## 7. Job type

New type: **`agent.task`**.

`ollama.chat` remains for prompts that should not enter a tool loop.

| Type | Runner adapter | UI |
|------|----------------|----|
| `ollama.chat` | Ollama `/api/chat`, `stream: false` | New text job (existing) |
| `agent.task` | AgentChat `AssistantAgent` + tools | New agent task (new) |

The queue is shared. The runner dispatches on `job.type`. Concurrency stays 1, so a long agent run delays later chat jobs. That is acceptable for a personal runner; a later option is a type-aware claim filter, not required now.

## 8. Agent topology (v1)

One `AssistantAgent` per job:

- **name:** `ownrun_assistant` (stable; not user-facing)
- **model_client:** `OllamaChatCompletionClient` with the job’s model and `host` = runner `OLLAMA_BASE_URL`
- **tools:** the selected **profile**’s catalog (section 10)
- **system_message:** profile default, optionally appended with a user system prompt (typed, loaded from the prompt library, or auto-filled from a project/global default — see [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md))
- **reflect_on_tool_use:** `true` so the final message is a natural-language answer, not a raw tool dump
- **max_tool_iterations:** from the job, capped by the server (suggested default **8**, hard cap **20**)
- **model_client_stream:** `false` — no token streaming to the server

Each job constructs a **fresh** agent. Do not reuse in-memory AgentChat state across jobs. Continue (section 13) is a new job with prior text copied into the request, same as chat continue.

If the selected model is not in Autogen’s built-in Ollama `model_info` table, the adapter must pass explicit `model_info`. For `agent.task`, require `function_calling: true`. If the model cannot do tools, fail the job with a message that names the model and says to pick a tools-capable one (examples: Llama 3.1/3.2, Qwen 2.5, Mistral small tool-capable tags — actual support is whatever Ollama reports and Autogen can drive).

The runner should prefer models that actually support Ollama native tool calling. A later heartbeat field can mark models as `tools: true|false`; v1 can filter the agent form to models the runner flags, or show all models and fail clearly.

## 9. Lifecycle

Same states as DESIGN.md: `queued` → `running` → `succeeded` | `failed` | `cancelled`.

### Happy path

1. User creates an `agent.task` job (task text, model, profile, optional max iterations).
2. Server stores it `queued` with `type = agent.task`.
3. Runner claims it; server marks `running` and starts the lease.
4. Adapter builds the client, agent, and tools; runs `run_stream(task=...)`.
5. On each AgentChat event, the adapter appends a trace step and periodically POSTs **progress**.
6. Job heartbeats continue every 30s; the lease stays alive.
7. On `TaskResult`, adapter POSTs **complete** with final text + full trace.
8. Web UI, already polling, shows the growing trace then the final answer.

### Extra transitions for agents

- **Cancel while `running`:** allowed for `agent.task` (and, once implemented, can apply to chat too). Server sets a cancel flag. Runner sees it on job heartbeat (or a cheap status field) and cancels the Autogen `CancellationToken`. Job becomes `cancelled`. Partial trace may remain in progress/result for debugging.
- **Max iterations / timeout:** not a crash. Complete as `succeeded` with `stop_reason` `max_iterations` or `timeout`, and whatever answer exists. The UI should show that the agent stopped because of a bound, not because it finished the task.
- **Tool error:** the tool returns an error string to the agent (the loop continues) unless the error is a sandbox violation or adapter bug — those fail the job.
- **Ollama down / missing model:** `failed`, same as chat jobs.
- **Lease expiry:** still `failed` with “runner lease expired”; no auto-requeue. Manual requeue as today.

Agent jobs can be slower than chat (many round-trips). The existing long lease (default 60 minutes) plus heartbeats is the right mechanism. Do not shorten it. An optional **per-job wall clock** (e.g. 20 minutes, runner-enforced) can stop the Autogen run before the lease dies.

## 10. Tool catalog and sandbox

Tools are **runner-defined**. The web UI picks a **profile** (named bundle). The job payload names the profile; it does not list Python callables or shell.

This keeps DESIGN.md’s rule: no free-form remote code execution. Prompt injection can still *try* to abuse tools; the catalog and sandbox are the control.

### 10.1 Profiles (v1)

| Profile id | Tools | Intended use |
|------------|--------|----------------|
| `workspace` | `list_dir`, `read_file`, `write_file`, `now` | Work on files in a designated directory |
| `web` | `http_fetch`, `now` | Read public HTTP(S) pages/APIs the user points at |
| `workspace_web` | union of the two | Default for “do something useful at home” |

The runner advertises which profiles are enabled. The SPA only offers those.

**Not in v1:** `web_search` (needs a search provider or scraping HTML search pages), code execution, subprocess, browser automation, email, anything that talks to LAN services. Calendar tools (`calendar_search`, `calendar_get`, `calendar_add`, `calendar_edit`, `calendar_delete`) are specified in [CALENDAR.md](CALENDAR.md) and land in a later phase; they attach to these same profiles rather than adding new ones.

### 10.2 Projects and workspace tools

Config: `OWNRUN_AGENT_WORKSPACE` (absolute path). Default something like `~/ownrun-workspace`. Create it if missing; do not default to `$HOME`.

That path is the **projects root**, not the agent’s working directory. Each agent run that uses file tools is scoped to one **project**: a subdirectory of the root.

```
~/ownrun-workspace/          ← OWNRUN_AGENT_WORKSPACE
  notes/                     ← project "notes"
    notes.md
    summary.md
  blog/                      ← project "blog"
    draft.md
```

**Project id rules** (server + runner enforce the same):

- Required for profiles that include file tools (`workspace`, `workspace_web`).
- Optional / ignored for `web` (no file tools).
- Pattern: start with `[a-zA-Z0-9]`, then up to 63 more chars of `[a-zA-Z0-9._-]`. No `/`, `\`, `..`, or absolute paths.
- **Create if missing:** when the job starts, the runner creates `<workspace>/<project>/` if it does not exist.
- Continue inherits the parent job’s `project`.

**Discovery:** the runner lists immediate child directories of the workspace root and advertises them as `agent_projects` on heartbeat. The SPA offers that list plus a free-text “new project” name. The server does not own project metadata beyond what is stored on each job’s `request_payload`.

**File tools** sandboxed to the **project directory** (not the whole workspace root):

- Resolve all paths under the project real path. Reject `..`, symlinks that escape, and absolute paths outside.
- `list_dir(path=".")` — names and types only; cap entries.
- `read_file(path)` — text files only; cap size (e.g. 64 KiB); refuse binary.
- `write_file(path, content)` — text only; cap size; no overwrite of files outside the project (already guaranteed by resolve).

The agent must not see the real host path in tool results if we can avoid it; show **project-relative** paths. Tool docs and system prompts should say “project,” not the host workspace path.

### 10.3 HTTP fetch

- `http_fetch(url)` — GET only.
- Allow `http` and `https` only.
- **SSRF:** refuse loopback, link-local, private IPv4/IPv6, and metadata IPs **after DNS resolution** (not just by hostname). The home machine is the operator’s, but a prompt-injected fetch to `127.0.0.1:11434` or a router admin UI is still a problem.
- Timeouts (e.g. 15s), max response size (e.g. 256 KiB), follow a small redirect cap.
- Prefer text: HTML (stripped to text), JSON, XML, CSV, plain text. Refuse obvious binaries.
- No cookies, no custom headers from the model, no POST/PUT/DELETE.

### 10.4 `now`

Return the current time in **UTC and the runner’s configured timezone**. Cheap, useful for “today’s date” and calendar work, no extra risk.

Config: `OWNRUN_TIMEZONE` — IANA name, default **`America/New_York`**. Validate with the platform tz database at runner start (or before the first agent job). An unknown name is a hard error; do not silently fall back to UTC.

The tool takes **no arguments**. The model cannot pick a zone per call.

Result is a small JSON object (stringify it as the tool output):

```json
{
  "utc": "2026-08-23T19:52:00Z",
  "timezone": "America/New_York",
  "local": "2026-08-23T15:52:00-04:00",
  "weekday": "Sunday",
  "today": {"start": "2026-08-23T04:00:00Z", "end": "2026-08-24T04:00:00Z"},
  "this_week": {"start": "2026-08-23T04:00:00Z", "end": "2026-08-30T04:00:00Z"},
  "next_7_days": {"start": "2026-08-23T04:00:00Z", "end": "2026-08-30T04:00:00Z"}
}
```

`local` includes the numeric offset so DST is explicit. `weekday` is the local civil day. Use the IANA zone for conversion; never hard-code `-05:00`.

`today` / `this_week` / `next_7_days` are UTC instants the agent should copy into `calendar_search` (`this_week` is Sunday 00:00 through next Sunday 00:00 in `OWNRUN_TIMEZONE`). `calendar_search` may omit `start`/`end` and will default to this week.

System prompts must stamp the **real current date and year** so “today / this week” is not a training-cutoff guess. Include this week’s UTC `start`/`end`. Name the real tools (`now`, `calendar_search`, …); do not invent `project_calendar`. If the user names another year, search that year as given.

### 10.5 Tool result hygiene

Truncate every tool result (suggested 8 KiB) before it goes back to the model **and** before it goes into the stored trace. Log locally if truncation happened.

Never put secrets from the runner environment into tool results.

## 11. Request and result payloads

### Request (`request_payload` for `agent.task`)

```json
{
  "model": "qwen2.5:14b",
  "prompt": "Read notes.md and draft a summary in summary.md",
  "profile": "workspace",
  "project": "notes",
  "system_prompt": "optional extra instructions",
  "max_tool_iterations": 8,
  "parent_job_id": 12
}
```

`prompt` is the task. `project` is the sandbox subdirectory under `OWNRUN_AGENT_WORKSPACE` (required for workspace-capable profiles). `messages` is optional on continue (section 13): prior user/assistant turns only, not the full inner trace.

Server validation:

- `type` is `agent.task` or inferred from the create endpoint.
- `model`, `prompt`, `profile` required.
- `project` required when `profile` is `workspace` or `workspace_web`; must match the project id pattern (section 10.2).
- `profile` must be a known id (or the server can allow any string and let the runner fail — prefer server allowlist synced from runner heartbeat).
- `max_tool_iterations` integer, default 8, max 20.
- Same `max_request_payload_bytes` as today (64 KiB is enough for request; traces are the size problem).

### Result

```json
{
  "text": "Wrote summary.md with three bullets.",
  "model": "qwen2.5:14b",
  "profile": "workspace",
  "project": "notes",
  "duration_ms": 184230,
  "stop_reason": "completed",
  "iterations": 4,
  "trace": [
    {"kind": "user", "content": "Read notes.md and draft a summary in summary.md"},
    {"kind": "tool_call", "name": "read_file", "args": {"path": "notes.md"}},
    {"kind": "tool_result", "name": "read_file", "ok": true, "content": "...truncated..."},
    {"kind": "message", "source": "ownrun_assistant", "content": "Wrote summary.md with three bullets."}
  ]
}
```

`stop_reason`: `completed` | `max_iterations` | `timeout` | `cancelled`.

`text` is the last assistant-facing message (reflection), so existing job-detail “result text” still works.

### Trace size

Traces can blow past 64 KiB easily. Do **not** reuse `max_request_payload_bytes` for results.

- New server cap, e.g. `max_result_payload_bytes` = 512 KiB.
- Runner truncates oldest inner tool results first, always keeps the final `text` and the latest few steps.
- Progress posts use the same cap.

## 12. API changes

Existing auth, claim, complete, fail stay. Additive changes only.

### Web

- `POST /api/jobs` today always creates `ollama.chat`. Either:
  - add `type` (`ollama.chat` | `agent.task`) and profile fields, or
  - add `POST /api/jobs/agent` that only creates `agent.task`.

  Prefer **one create endpoint with `type`**, so list/detail/cancel/requeue stay generic.

- `POST /api/jobs/{id}/cancel` — also succeeds when status is `running` (sets cancel requested). If the runner is dead, lease expiry still fails the job; cancel of a running job without a runner is best-effort (mark cancelled immediately, or wait until heartbeat/lease). **Decision:** mark `cancelled` immediately; the runner, if still alive, sees cancel and stops. If a complete arrives after cancel, ignore it (status is no longer `running`).

- `POST /api/jobs/{id}/continue` — allow `agent.task` parents that `succeeded` (and optionally `cancelled` with a trace). New job is also `agent.task`, same model and profile.

- `GET /api/models` — extend with agent capability, not a breaking change:

```json
{
  "models": ["llama3.2:latest", "qwen2.5:14b"],
  "runner_online": true,
  "runner_last_seen_at": "...",
  "agent_profiles": ["workspace", "web", "workspace_web"],
  "agent_models": ["qwen2.5:14b"],
  "agent_projects": ["notes", "blog"],
  "timezone": "America/New_York"
}
```

`agent_models` optional; if omitted, the UI uses `models` and the runner fails unsupported ones. `agent_projects` is the runner’s current list of project directories (may be empty). `timezone` is `OWNRUN_TIMEZONE` so the SPA can highlight the same civil “today” agents get from `now` (default `America/New_York` if omitted).

### Runner

- `POST /api/runner/heartbeat` — may include `agent_profiles`, `agent_models`, `agent_projects`, and `timezone` next to `available_models`. Store JSON on the runner row (new columns or one `capabilities` JSON). Keep `available_models` as-is for chat.

- `POST /api/runner/jobs/{id}/heartbeat` — response includes `{ "ok": true, "cancel_requested": false }` so the adapter can trip `CancellationToken`.

- `POST /api/runner/jobs/{id}/progress` — **new**. Body: `{ "result": { ...partial result with trace... } }`. Allowed only while `running` and owned by this runner. Overwrites `progress_payload` (new column) or `result_payload` while still running.

**Decision:** add `progress_payload` (nullable JSON). `result_payload` is written only on complete. `GET /jobs/{id}` returns `progress` for running jobs and `result` for finished ones. The SPA can show `job.progress || job.result`.

Claim, complete, fail: unchanged. `complete` still requires status `running`.

## 13. Continue

Chat continue today copies `messages` + last assistant text + new user prompt into a new job.

Agent continue:

1. Parent must be `agent.task` and `succeeded` (v1).
2. New job: same `model`, `profile`, `project`, and `system_prompt` snapshot (do not re-resolve library/project defaults — [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md)).
3. `messages`: compact history — previous **user prompts** and **final `text` answers** only. Do not replay tool calls into the next AgentChat task; they confuse small models and explode tokens.
4. `prompt`: the new user task.
5. `parent_job_id`: set as today.

The new run is a new `AssistantAgent`. Prior tool side effects (files in the project directory) are still on disk; that is enough memory for workspace profiles.

## 14. Web UI

Keep the job list as the hub. Distinguish types in the list (badge: `chat` vs `agent`) and in the snippet line.

### New agent task

- Route: `/#/jobs/new-agent` or a type toggle on the existing new-job page. A **toggle or second form** is enough; do not hide chat.
- Fields: model (from `agent_models` if present), profile, **project** (select from `agent_projects` or type a new name; required for workspace-capable profiles), task textarea, optional system prompt (library picker, save-as, auto-fill from project/global default — [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md)), optional max iterations (advanced, collapsed).
- Same runner online badge. If no agent profiles are advertised, explain that the runner is old or agent support is disabled.

### Job detail

- Chat jobs: unchanged conversation view.
- Agent jobs:
  - Task and profile/project/model header
  - **Trace timeline** while running and after: user, tool_call (name + args), tool_result (ok/fail + truncated content), assistant message
  - Final `text` emphasized
  - `stop_reason` when not `completed`
- Continue form on succeeded agent jobs (task follow-up, not “chat turn” copy).
- Cancel visible for `queued` and `running`.
- Requeue unchanged for `failed`.

No live token stream. Polling every few seconds (already 4s on detail) is the UX.

## 15. Runner internals (conceptual)

Keep `main.py`’s claim loop. `_process_job` gains a branch:

- `ollama.chat` → existing `run_ollama_chat`
- `agent.task` → `run_agent_task` (new module)

`run_agent_task`:

1. Validate profile against runner config; validate/resolve `project` under the workspace root (create dir if needed).
2. Build `OllamaChatCompletionClient`.
3. Instantiate tools closed over the **project** path and HTTP policy.
4. Create `AssistantAgent` with `CancellationToken`.
5. `async for` event in `run_stream(task=prompt or messages)`:
   - map event → trace step
   - every N seconds or every step, POST progress (do not progress-spam; e.g. at most once every 2s plus always on tool_result)
   - check cancel flag from the latest heartbeat
6. On finish, POST complete. On exception, POST fail. Always close the model client.

Dependencies: add AgentChat + `autogen-ext[ollama]` to `requirements.txt` with pins. Keep `requests` for the server client.

## 16. Security

Agents increase the blast radius of a stolen web session: the attacker can queue a task that reads the workspace or fetches URLs from the home IP. Existing auth still applies. Additional controls:

- **Fixed catalog** — no user-supplied tools, URLs for code exec, or shell.
- **Project directory** — file tools only touch `<OWNRUN_AGENT_WORKSPACE>/<project>/`; project names are constrained so they cannot escape the root.
- **SSRF policy** on `http_fetch`.
- **No LAN tools** in v1 (no “hit my NAS API”).
- **Truncation and size caps** so a hostile page cannot fill MariaDB.
- **Cancel + max iterations + wall clock** so a runaway loop is stoppable.
- **Prompt injection** is expected. Tools must be safe even if the model is fully compliant with an injected instruction. Do not add a tool whose correctness depends on the model “not being tricked.”
- **Secrets:** runner token, DB, and JWT material never enter the workspace by default; do not point `OWNRUN_AGENT_WORKSPACE` at the OwnRun repos or `~/.ssh`.
- DESIGN.md’s “runner only calls configured local base URLs” still holds for Ollama. Tool HTTP is a **new** outbound path and must stay allow-listed as above.

Magentic-One-style code execution stays out until there is a Docker (or equivalent) executor and an explicit later design.

## 17. Configuration

### Server

- Existing job lease, payload limits.
- `max_result_payload_bytes` (new).
- Optional: allowed agent profile names (or trust the last runner heartbeat).

### Runner

| Variable | Role |
|----------|------|
| Existing `OWNRUN_*` / `OLLAMA_BASE_URL` | Unchanged |
| `OWNRUN_AGENT_WORKSPACE` | Parent directory for agent projects (each project is a subdirectory) |
| `OWNRUN_AGENT_PROFILES` | Comma list; default `workspace,web,workspace_web` |
| `OWNRUN_AGENT_WALL_CLOCK` | Seconds; default e.g. 1200 |
| `OWNRUN_AGENT_FETCH_TIMEOUT` | Seconds for `http_fetch` |
| `OWNRUN_TIMEZONE` | IANA timezone for `now` (and calendar “local” time). Default `America/New_York` |

No API keys required for v1 tools.

### Web

No extra origin/CORS changes. New form and detail rendering only.

## 18. Observability

- Runner logs: job id, profile, project, model, each tool name, duration, stop_reason.
- Do not log full file contents or fetched bodies at INFO.
- Failed jobs: adapter exception string as today.
- UI: trace + `error_message` + `stop_reason`.

## 19. Implementation phases

Agent work is **Phase 4** relative to DESIGN.md. Images (Phase 3) stay independent; either can land first. Do not couple them.

### Phase 4a — Vertical slice

- Job type `agent.task`, create + list + detail.
- Runner adapter: `AssistantAgent` + `workspace` profile only.
- Complete/fail with final `text` + full `trace` (no live progress yet).
- UI: new form, trace view, no continue/cancel-running yet.
- Model: user-selected; fail clearly if tools unsupported.

### Phase 4b — Operability

- `progress_payload` + progress POST; detail page shows a live trace.
- Cancel running jobs via heartbeat `cancel_requested` + Autogen cancellation.
- Continue as a new `agent.task`.
- `web` and `workspace_web` profiles.
- Heartbeat advertises `agent_profiles` / `agent_models`.

### Phase 4c — Later (optional)

- MCP tools from a runner-configured command (still not user-supplied).
- Search tool if a local SearXNG (or similar) URL is configured.
- A second topology (e.g. two-agent reviewer) as another profile — still not Magentic-One.
- Type-aware claim / second worker so chat is not blocked by a long agent.
- Calendar tools on these profiles — specified separately in [CALENDAR.md](CALENDAR.md) (Phase 5), not as a new profile.

## 20. Decisions

1. **Ollama remains the only model backend.** AgentChat is the loop, not a replacement for Ollama.
2. **Framework:** Autogen AgentChat 0.4+ with `OllamaChatCompletionClient`.
3. **Topology:** single `AssistantAgent` per job. No teams in v1.
4. **Job type:** `agent.task`, separate from `ollama.chat`.
5. **Tools:** runner-defined profiles; per-job **project** sandbox under the workspace root + SSRF-safe GET fetch + `now` (UTC plus `OWNRUN_TIMEZONE`, default `America/New_York`).
6. **No HITL, no shell, no Magentic-One, no MCP** in v1.
7. **Fresh agent per job.** Continue copies user/final-answer text only.
8. **Progress:** new `progress_payload` and runner progress POST (Phase 4b). Final result still goes to `result_payload`.
9. **Cancel running** is in scope for agents (Phase 4b).
10. **Bounds:** `max_tool_iterations` (default 8, cap 20) + runner wall clock + existing lease/heartbeats.
11. **Bounded failure that is not a crash:** hitting max iterations or wall clock completes with `stop_reason`, not `failed`.
12. **Shared queue, concurrency 1.**

## 21. Open decisions

- Exact Autogen / `autogen-ext` version pins (choose at implementation time; prefer current stable 0.4/0.5 line).
- Whether `POST /jobs` grows a `type` field or a dedicated create path (lean: `type` on the existing endpoint).
- How aggressively to filter the model dropdown (`agent_models` vs all Ollama tags).
- Whether cancel of a running job with a dead runner should stay `cancelled` or become `failed` after lease expiry (lean: stay `cancelled`).
- Phase 3 (images) vs Phase 4 (agents) order — product choice; technically independent.

## 22. Success criteria (agent v1 / Phase 4a)

1. From a remote browser, a logged-in user can submit an `agent.task` with a workspace profile.
2. With the home runner online, the agent reads/writes only under `OWNRUN_AGENT_WORKSPACE/<project>/` and returns a final answer plus a tool trace.
3. `ollama.chat` jobs still work as they do today.
4. A task that would require shell or paths outside the selected project cannot do so via the catalog.
5. If Ollama is down or the model cannot call tools, the job `failed` with a readable error.
6. No inbound connection to the home machine is required.

Phase 4b adds: watching the trace grow while running, and stopping a running agent from the UI.

---

*Next step after this design: implement Phase 4a only (workspace profile, final trace, no Magentic-One). Do not start images and agents in the same change set unless explicitly requested.*
