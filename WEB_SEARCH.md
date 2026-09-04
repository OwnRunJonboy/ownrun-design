# OwnRun Web Search Design

**Status:** Draft  
**Date:** 2026-08-31  
**Author:** Jonboy  
**Depends on:** [DESIGN.md](DESIGN.md) (hosting, pull model, security), [AGENT.md](AGENT.md) (agent jobs, profiles, `http_fetch`, tool catalog), [TOOL_POLICY.md](TOOL_POLICY.md) (per-project and per-job tool disables)  
**Related:** [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md) — user extra is still appended to the runner-owned profile message; search recipe lives in that boilerplate.

This document designs **web search** for OwnRun agents: a native runner tool backed by **Ollama’s cloud search API**. It is not a new job type, not a SPA search box, and not a custom MCP or DuckDuckGo scraper.

No implementation in this document.

## 1. Purpose

Agents can **fetch a URL** (`http_fetch`) when they know the address. They cannot **find** URLs. Without search, `web` / `workspace_web` profiles guess links or fail.

[AGENT.md](AGENT.md) deferred search until the built-in catalog was stable. That catalog is in place. Ollama now exposes `POST https://ollama.com/api/web_search` (and a Python `ollama.web_search()` helper) with a free tier. OwnRun already depends on Ollama locally; adding a cloud search call from the home runner is simpler than operating a custom MCP or HTML scraper.

**Privacy:** web search is not private — queries go to Ollama’s service (and whatever engines they use). That is acceptable for this product; disabling search per project or per job is [TOOL_POLICY.md](TOOL_POLICY.md).

## 2. Why Ollama’s API (and not the old MCP design)

| Approach | Decision |
|----------|----------|
| Custom stdio MCP + DuckDuckGo | **Dropped.** Extra process, scraping fragility, no real privacy win if the user accepts cloud search anyway. |
| Ollama’s bundled MCP (`web_search` + `web_fetch`) | **Do not use as-is.** `web_fetch` bypasses AGENT.md SSRF rules and duplicates `http_fetch`. |
| **Native `web_search` tool → Ollama cloud API** | **Chosen.** One HTTP call, maintained provider, same vendor as the model stack. Pages still read via existing `http_fetch`. |
| Ollama `web_fetch` | **Out.** Keep runner `http_fetch` only. |
| SearXNG / Brave / SerpAPI | Optional later as alternate backend env; not v1. |

## 3. Goals

- Agents on **`web` and `workspace_web`** can call `web_search` when the tool is in the **effective** set ([TOOL_POLICY.md](TOOL_POLICY.md)).
- **`http_fetch` stays** the page reader; search returns snippets only.
- Runner calls **`https://ollama.com/api/web_search`** with **`OLLAMA_API_KEY`** (free Ollama account).
- Per-project and per-job **opt-out** via tool policy (not a one-off flag).
- Operator kill switch: `OWNRUN_AGENT_WEB_SEARCH=0` removes the tool globally.
- Same Autogen AgentChat loop; **no** `autogen-ext[mcp]` for search.
- Truncate results to OwnRun’s **8 KiB** tool cap (Ollama snippets can be huge).

## 4. Non-goals (search v1)

- Custom MCP, `ddgs`, or SearXNG default path.
- Ollama `web_fetch` or any second fetch implementation.
- Stored search history, SPA search UI, new job type.
- Cloud LLM providers (Ollama local models only for chat).
- `web_search` on **`workspace`** profile.
- Model-controlled backend, region, or safesearch args beyond `query` / `max_results`.
- Generic user MCP plugins.

## 5. Where it lives

```
┌─────────────────┐         HTTPS          ┌──────────────────┐
│   ownrun-web    │ ─────────────────────► │  ownrun-server   │
│  New agent      │   job + disabled_tools │  project_tool_   │
└─────────────────┘                        │  policies        │
                                                    │
                                                    ▼
                                           ┌──────────────────┐
                                           │  ownrun-runner   │
                                           │  web_search ────────► ollama.com
                                           │  http_fetch ───────► public URLs
                                           │  Ollama :11434   │   (local chat)
                                           └──────────────────┘
```

Search runs in the **runner process** (same as `http_fetch`). No subprocess. Queries leave the home machine to **ollama.com**, not to a self-hosted scraper.

## 6. Tool contract

Same tool name and shape as before; implementation is native Python calling Ollama.

### 6.1 `web_search`

| Arg | Rules |
|-----|--------|
| `query` | Required string. Trim. Max **200** chars. |
| `max_results` | Optional int. Default **5**, clamp 1–**8**. |

**Backend request:** `POST https://ollama.com/api/web_search` with `Authorization: Bearer $OLLAMA_API_KEY`, body `{ "query", "max_results" }`. Ollama allows up to 10; OwnRun caps at 8 before the call.

**Result** (normalized JSON string for the model):

```json
{
  "query": "autogen agentchat ollama",
  "provider": "ollama",
  "results": [
    {
      "title": "Using Ollama with AutoGen",
      "url": "https://example.com/docs",
      "snippet": "How to attach OllamaChatCompletionClient…"
    }
  ]
}
```

Map Ollama’s `content` field → `snippet`, truncated to **280** chars. Drop non-`http(s)` URLs. Whole payload ≤ **8 KiB** (drop hits from the end if needed).

Errors:

- Missing/invalid API key at job start when search would be offered → **fail job** with readable message (configure `OLLAMA_API_KEY`).
- HTTP 401/403/429/5xx on a call → `Error: search failed: …` tool string; loop continues.
- Empty `results` → valid `{ "results": [] }`, not a failure.

**Per-job budget:** max **5** `web_search` calls per job (including empty/error attempts that reached the API). Further calls → `Error: search budget exceeded (max 5 per job)` without calling Ollama.

### 6.2 Recipe with `http_fetch`

1. One `web_search` with a tight query  
2. `http_fetch` one or two result URLs  
3. Answer from fetched text  

Ollama’s docs suggest large context for search-heavy agents; OwnRun keeps **8 KiB** tool truncation and default **8** max iterations — the prompt must discourage search loops.

## 7. When the tool is available

| Layer | Rule |
|-------|------|
| Profile | `web` or `workspace_web` only |
| Runner | `OWNRUN_AGENT_WEB_SEARCH` not `0`; `OLLAMA_API_KEY` set |
| Project policy | `web_search` ∉ `disabled_tools` ([TOOL_POLICY.md](TOOL_POLICY.md)) |
| Job | `web_search` ∉ job `disabled_tools`; New agent **Web search** checkbox |

If any layer removes the tool, it is not registered and the system prompt omits the web-search paragraph.

`ollama.chat` unchanged.

## 8. Runner integration

### 8.1 Implementation sketch

- Add `web_search(query, max_results)` beside `http_fetch` in `build_tools()` when profile includes web **and** effective set contains `web_search`.
- Use `requests.post` to `https://ollama.com/api/web_search` or pinned `ollama` Python package (`pip install ollama>=0.6.0`) — pick one at implementation; pin version.
- Reuse **`OWNRUN_AGENT_FETCH_TIMEOUT`** for the HTTP timeout (default 15s).
- Do **not** pass `OLLAMA_API_KEY` into tool results or traces.

### 8.2 System prompt

When `web_search` ∈ effective tools, append:

- Use `web_search` then `http_fetch`; do not invent URLs or tools.
- Snippets are not full pages; fetch to verify.
- `http_fetch` may refuse private/loopback URLs (AGENT.md §10.3).
- Prefer one search per task.

When disabled for this job/project, do not mention `web_search` (avoid hallucinated calls).

### 8.3 Trace and logs

Standard `tool_call` / `tool_result`. INFO: job id, hit count, duration — **not** query text.

## 9. Web API and SPA

- **`GET /api/models`:** `web_search_available: true` when last heartbeat reported search enabled **and** runner indicated API key configured (heartbeat flag `ollama_web_search: true` — runner sets false if key missing at start).
- **New agent:** **Web search** checkbox (default from project policy). See [TOOL_POLICY.md](TOOL_POLICY.md) §9.
- No search-specific server tables beyond project tool policy.

Runner heartbeat may include:

```json
{
  "ollama_web_search": true,
  "agent_tool_ids": ["now", "http_fetch", "web_search", "..."]
}
```

## 10. Security

- **`OLLAMA_API_KEY`** on the runner only (env or local config). Never in job payload, SPA, or MariaDB.
- Stolen runner env → attacker can use search quota and local Ollama; rotate key if leaked.
- Queries are visible to Ollama; do not log them at INFO.
- Search snippets are untrusted; `http_fetch` SSRF still applies to chosen URLs.
- Do not adopt Ollama MCP example that bundles unaudited `web_fetch`.

## 11. Configuration

### Runner

| Variable | Role |
|----------|------|
| `OLLAMA_API_KEY` | Bearer token for `ollama.com/api/web_search` (**required** for search) |
| `OWNRUN_AGENT_WEB_SEARCH` | `1`/`0`; default **on**. `0` = tool omitted globally. |
| `OLLAMA_BASE_URL` | Unchanged; local chat only |
| `OWNRUN_AGENT_FETCH_TIMEOUT` | Search HTTP timeout (reuse) |

### Server

Pass through heartbeat `ollama_web_search` / `web_search_available` on models. Project policy via [TOOL_POLICY.md](TOOL_POLICY.md).

## 12. Implementation phases

**Phase 9** in [DESIGN.md](DESIGN.md). Depends on agent web profiles (Phase 4b).

### Phase 9a — Search + policy core

- Native `web_search` → Ollama API; caps and budget.
- [TOOL_POLICY.md](TOOL_POLICY.md) table, API, runner merge, New agent checkbox.
- Heartbeat flags; system prompt gating.
- **No** project settings page yet.

### Phase 9b — Project settings UI

- Per-project toggles for search (and optionally fetch). See TOOL_POLICY §9.2.

### Phase 9c — Later (optional)

- Alternate backend env (SearXNG URL) if Ollama limits bite.
- Full per-project tool matrix UI.

## 13. Decisions

1. **Backend:** Ollama cloud `web_search` API, not custom MCP or DDG scrape.
2. **Native runner tool**, same pattern as `http_fetch`.
3. **No Ollama `web_fetch`.**
4. **`OLLAMA_API_KEY`** required on runner for search.
5. **Opt-out** via [TOOL_POLICY.md](TOOL_POLICY.md) (project + job), plus runner global off.
6. **No MCP** for search; dropped from prior draft.
7. Web search is **not private**; product accepts that; policy provides off switches.

## 14. Open decisions

- `requests` vs `ollama` Python package (lean: **`requests`** to avoid new dep if JSON is trivial).
- Heartbeat: separate `ollama_web_search` vs infer from env at heartbeat time.
- Whether 429 from Ollama should surface “rate limited — upgrade Ollama account” in the tool error string (lean: yes, short hint).

## 15. Success criteria (Phase 9a)

1. User submits `workspace_web` agent job without URL in prompt; trace shows `web_search` then `http_fetch`; answer cites real pages.
2. Project policy with `web_search` disabled → trace has no search calls.
3. New agent unchecked **Web search** → same for that job only.
4. `OWNRUN_AGENT_WEB_SEARCH=0` → tool absent; models flag false.
5. Missing `OLLAMA_API_KEY` with search enabled → job fails at start with clear error.
6. `http_fetch` SSRF unchanged.
7. At most 5 search calls per job; queries not in INFO logs.
8. `workspace` jobs never get `web_search`.

---

*Next step: implement Phase 9a (Ollama search + tool policy core + New agent checkbox). Defer project settings page to 9b unless requested.*
