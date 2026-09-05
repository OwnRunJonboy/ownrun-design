# OwnRun Knowledge Base (RAG) Design

**Status:** Draft  
**Date:** 2026-09-03  
**Author:** Jonboy  
**Depends on:** [DESIGN.md](DESIGN.md) (hosting, pull model, job queue, artifacts), [AGENT.md](AGENT.md) (agent jobs, tool catalog, project ids), [TOOL_POLICY.md](TOOL_POLICY.md) (per-project / per-job tool disables)  
**Related:** [JOURNAL.md](JOURNAL.md) / [CALENDAR.md](CALENDAR.md) / [TASKS.md](TASKS.md) — server-backed user data with agent tools; KB differs because vectors and parsing must run on the home runner. [WEB_SEARCH.md](WEB_SEARCH.md) — external retrieval; KB is private local retrieval.

This document designs a **personal knowledge base** for OwnRun: users upload documents, the home runner parses and embeds them into a local vector store, and agents retrieve relevant chunks via tools. It is **not** a cloud RAG SaaS and not a replacement for workspace file tools.

No implementation in this document.

## 1. Purpose

OwnRun agents can read workspace files and call the web, but they cannot reliably use **large personal libraries** — PDFs, Word docs, ebooks — as grounded context. Without a knowledge base:

- The user dumps books into the project directory and hopes `read_file` + guessing paths is enough
- Agents cannot semantic-search across hundreds of pages
- Parsing binary formats on every agent turn is wasteful and fragile
- There is no durable index that survives across agent jobs

The knowledge base is OwnRun’s **RAG kit**: upload → parse → chunk → embed → search. The user builds their own private corpus; agents query it when the job’s tool policy allows.

## 2. Goals

- SPA UI to create **knowledge bases** (named collections), upload files, see ingest status, and delete documents.
- v1 parsers: **PDF**, **Word (DOCX)**, **EPUB**.
- Runner-side **ingest pipeline** (parse, chunk, embed) using **local Ollama** embeddings.
- Persistent **local vector index** on the home machine (no inbound ports, no cloud vector host).
- Agent tools to **search** (and lightly inspect) the knowledge base, scoped like journal: global ∪ job project.
- Reuse the existing **job queue** for ingest/delete work (lease, heartbeat, progress, fail/requeue).
- Stay compatible with shared hosting: PHP stores metadata + original blobs; heavy work stays on the runner.
- Tool-policy opt-out (`kb_search`, etc.) per [TOOL_POLICY.md](TOOL_POLICY.md).

## 3. Non-goals (KB v1)

- Multi-user / shared corpora / ACLs beyond the single OwnRun user + agent project rule.
- SPA semantic search box (agents search; the SPA manages documents). Optional later.
- Cloud embedding APIs or hosted vector DBs (Pinecone, etc.).
- OCR for scanned PDFs (image-only pages may yield empty text; surface a clear ingest warning).
- Legacy `.doc` (binary Word), RTF, HTML-as-upload, Markdown-as-KB-doc, or arbitrary archives.
- Auto-sync of the entire workspace directory into the KB (explicit upload only).
- Agent tools to **upload** or **delete** documents in v1 (user manages corpus in the SPA; agents only retrieve).
- Fine-grained ACL per document beyond knowledge-base project scoping.
- Hybrid BM25 + vector ranking, rerankers, or query rewriting frameworks.
- Streaming citations into chat jobs (`ollama.chat`); KB tools are for `agent.task` only.
- Cross-machine vector replication (one home runner owns the index).

## 4. Where it lives (split of roles)

Journal/calendar/tasks live entirely on the PHP host because they are small text rows. A knowledge base cannot:

| Concern | Why the PHP host is a poor fit |
|---------|--------------------------------|
| PDF / DOCX / EPUB parsing | Heavy native libs; not a good shared-hosting job |
| Embeddings | Need local Ollama on the home machine |
| Vector search | Shared hosting has no Chroma/Qdrant; DIY cosine over MariaDB BLOBs does not scale |
| Large binaries | Hosting disk + PHP upload limits already constrain us; processing them remotely would make it worse |

**Decision: hybrid.**

```
┌─────────────────┐         HTTPS          ┌──────────────────┐
│   ownrun-web    │ ─────────────────────► │  ownrun-server   │
│  Knowledge UI   │   user JWT CRUD        │  kb_* tables     │
│  upload files   │   store original blobs │  + blob storage  │
└─────────────────┘                        └────────┬─────────┘
                                                    │
                         runner token; claim        │
                         kb.ingest / kb.delete      │
                         download blob; report      │
                         document status            ▼
                                           ┌──────────────────┐
                                           │  ownrun-runner   │
                                           │  parse → chunk   │
                                           │  Ollama embed    │
                                           │  local vector DB │
                                           │  kb_* agent tools│
                                           └──────────────────┘
```

| Layer | Owns |
|-------|------|
| ownrun-web | Create/list KBs, upload docs, show status, delete |
| ownrun-server | `kb_bases`, `kb_documents` metadata; original file blobs; enqueue ingest/delete jobs; document status |
| ownrun-runner | Download blob, parse, chunk, embed, upsert/delete vectors; agent `kb_*` tools |
| Ollama | Embedding model (`/api/embed` or equivalent) + existing chat models for agents |

**Why not “everything on the runner”?** The phone UI must upload and browse the corpus while away. Metadata and originals on the server keep the SPA usable when the runner is briefly offline (uploads queue; ingest waits). Search still requires the runner (and a ready index).

**Why not “vectors on the server”?** Shared hosting cannot host a real vector engine, and shipping embedding math through PHP request/response fights DESIGN.md hosting constraints.

## 5. Concepts

### 5.1 Knowledge base (collection)

A named corpus the user creates.

| Field | Rules |
|-------|--------|
| `id` | Integer PK |
| `user_id` | Owner |
| `name` | Required; trim; max **80** chars; unique per user (case-insensitive) |
| `slug` | Derived or user-set; same pattern as project ids (`[a-zA-Z0-9]` + up to 63 of `[a-zA-Z0-9._-]`) — used in tool results and paths |
| `project` | Optional; when set, this KB is **project-scoped**; when NULL, **global** |
| `description` | Optional; max **500** chars |
| `created_at`, `updated_at` | UTC |

`project` is a **label**, not a filesystem FK — same pattern as calendar/journal.

### 5.2 Document

One uploaded file inside a knowledge base.

| Field | Rules |
|-------|--------|
| `id` | Integer PK |
| `kb_id` | FK to knowledge base |
| `user_id` | Owner (denormalized for simple queries) |
| `filename` | Original upload name (sanitized for display) |
| `content_type` | Detected / declared MIME |
| `format` | `pdf` \| `docx` \| `epub` |
| `size_bytes` | Original size |
| `storage_path` | Server-side blob path (outside web root if possible) |
| `status` | `pending` \| `queued` \| `running` \| `ready` \| `failed` \| `deleting` |
| `error_message` | Nullable; ingest failure detail |
| `chunk_count` | Nullable until ready |
| `page_count` / `chapter_count` | Optional metadata from parser |
| `content_hash` | SHA-256 of bytes; skip re-embed if unchanged on re-upload replace |
| `ingest_job_id` | Nullable; last job that processed this doc |
| `embedding_model` | Model id used when status became `ready` (must match search) |
| `created_at`, `updated_at` | UTC |
| `deleted_at` | Soft-delete on user delete request until runner purges vectors |

### 5.3 Chunk (runner-local; not MariaDB rows)

Logical retrieval unit stored in the vector DB:

- `chunk_id` (stable string, e.g. `{document_id}:{ordinal}`)
- `document_id`, `kb_id`, `kb_slug`, `project` (denormalized for filters)
- `text`
- `ordinal`, optional `page` / `chapter` / `section_title`
- `embedding` (vector)
- `embedding_model`

MariaDB does **not** store chunk text in v1 (avoids doubling disk on shared hosting). If the home index is lost, **re-ingest from server blobs**.

## 6. Project visibility (agents)

Same spirit as journal: **user sees everything in the SPA; agents are scoped.**

| Job | Searchable knowledge bases |
|-----|----------------------------|
| Has project `P` | Global KBs (`project` NULL) **and** KBs with `project = P` |
| No project | Global KBs only |

Rules:

- The model **cannot** pass a project or `kb_id` list that widens this set. Optional `kb` filter on `kb_search` may only **narrow** within the allowed set.
- Agents do **not** write/upload/delete documents in v1.
- Moving a KB’s `project` in the SPA changes agent visibility on the next job; runner filters by current server metadata (or a small meta cache refreshed at job start).

## 7. Ingest pipeline

### 7.1 Job type: `kb.ingest`

Not an agent loop. A dedicated runner adapter.

**Trigger:** user finishes upload → server stores blob, sets document `status = pending`, creates a `kb.ingest` job (or batches multiple pending docs into one job — **lean v1: one document per job** for simple progress/fail).

**Request payload (illustrative):**

```json
{
  "document_id": 42,
  "kb_id": 7,
  "format": "pdf",
  "embedding_model": "nomic-embed-text"
}
```

**Runner steps:**

1. Claim job; set document `status = running`.
2. Download original bytes from a runner-authenticated endpoint.
3. Parse to plain text (+ page/chapter markers when available).
4. Chunk (section 8).
5. Embed each chunk via Ollama with the configured embedding model.
6. Upsert into the local vector store; delete any prior chunks for this `document_id`.
7. Report `chunk_count`, optional page/chapter counts; set `status = ready`, record `embedding_model`.
8. Complete the job with a short result summary (no need to upload all chunk text).

**Failures:** parse error, empty text, Ollama down, unsupported encryption/DRM on EPUB, oversized extracted text → `status = failed` + `error_message`; user can fix/requeue.

**Progress:** heartbeat + optional progress payload (`pages_done`, `chunks_embedded`) so the SPA can show “Embedding 40/120…”.

### 7.2 Job type: `kb.delete`

When the user deletes a document (or a whole KB):

1. Server soft-deletes metadata (`deleted_at`) and sets `status = deleting`.
2. Enqueue `kb.delete` with `document_id` (or `kb_id` for cascade).
3. Runner removes vectors for those ids, then server hard-deletes blob + row (or leaves soft-deleted tombstone — **lean: hard-delete row after runner confirms**).

If the runner is offline, the SPA still shows “Deleting…” until purge completes. Requeue on fail.

### 7.3 Re-ingest / rebuild

- **Re-ingest one document:** new `kb.ingest` job; replace chunks.
- **Rebuild index:** operator/UI action that enqueues ingest for all `ready`/`failed` docs (needed after home disk wipe or embedding model change).
- **Embedding model change:** config bump invalidates semantic compatibility. On model change, mark all docs `pending` and re-ingest (or refuse search until rebuild). Store `embedding_model` on each document and on the local collection metadata; `kb_search` errors clearly if the index model ≠ configured model.

## 8. Parsing and chunking

### 8.1 Formats (v1)

| Format | Extensions | Parser direction (runner) | Notes |
|--------|------------|---------------------------|--------|
| PDF | `.pdf` | pypdf / pdfplumber / PyMuPDF — pick one primary | Text extraction only; no OCR in v1 |
| Word | `.docx` | `python-docx` | **Not** legacy `.doc` |
| EPUB | `.epub` | `ebooklib` (+ HTML→text strip) | Skip non-linear nav fluff where practical; DRM-encrypted → fail clearly |

MIME sniffing + extension allowlist on upload. Reject zip bombs / path traversal inside EPUB.

### 8.2 Chunking (v1)

Simple and predictable:

- Prefer splitting on headings / page breaks when the parser exposes them.
- Otherwise fixed-size character windows with overlap.
- Suggested defaults (config on runner): **~1200 characters**, **~200 overlap**, hard max chunk **4 KiB** text.
- Drop near-empty chunks; cap chunks per document (e.g. **2000**) to bound runaway books — fail ingest with a clear message if exceeded (user can split the book later).

Preserve metadata on each chunk: `filename`, `kb_slug`, `ordinal`, `page` or `chapter` when known.

### 8.3 Embeddings

- **Provider:** local Ollama only.
- **Config:** `OWNRUN_KB_EMBED_MODEL` (e.g. `nomic-embed-text`).
- Runner heartbeat advertises whether the embedding model is installed; SPA disables upload or shows a warning when missing.
- Batch embed where the API allows; respect timeouts; heartbeat during long books.

## 9. Vector store (runner-local)

**Requirements:** embedded (no extra daemon), persistent on disk, filter by `kb_id` / `project`, delete-by-document, single-user scale (thousands of chunks, not billions).

**Recommendation: Chroma persistent client** under `OWNRUN_KB_DIR` (default e.g. `~/ownrun-kb/`), one collection (or one per embedding model). Alternatives acceptable if they meet the same bar: LanceDB, or sqlite-vec. **Do not** require a separately managed Qdrant/Docker service for v1.

Path layout (illustrative):

```
~/ownrun-kb/
  chroma/           # or lancedb/
  .embedding_model  # recorded model id
```

The vector store is **not** under `OWNRUN_AGENT_WORKSPACE`. Workspace is for agent file tools; the KB index is system data for the runner, like its own state.

Backup: backing up `OWNRUN_KB_DIR` plus server blobs is enough to restore; blobs alone + rebuild also work.

## 10. Agent tools

Add to **every** profile (`workspace`, `web`, `workspace_web`), same as calendar/journal/task. Disable via tool policy.

| Id | Args | Behavior |
|----|------|----------|
| `kb_list` | optional `kb` (slug or id) | List allowed knowledge bases and document filenames/status summary (ready counts). Compact. |
| `kb_search` | `query` (required), optional `kb`, optional `top_k` | Semantic search over allowed ready docs. Default `top_k` **5**, clamp 1–**10**. |
| `kb_get` | `document_id` or (`kb` + `filename`) | Metadata + short excerpt / first chunk only — **not** full book dump. Cap output. |

### 10.1 `kb_search` result shape

Return a JSON list (then stringify / truncate to the usual **8 KiB** tool cap):

```json
{
  "hits": [
    {
      "score": 0.81,
      "text": "…chunk…",
      "kb": "manuals",
      "filename": "boiler-manual.pdf",
      "document_id": 42,
      "page": 12,
      "ordinal": 48
    }
  ]
}
```

Do not invent tool names like `rag_query`. System-prompt boilerplate should name `kb_search` / `kb_list` / `kb_get` and say: cite filename (and page/chapter when present); do not claim knowledge that was not retrieved.

### 10.2 Enforcement

- Runner loads allowed `kb_id`s at job start (from server: global ∪ project).
- Vector query always includes that filter.
- Missing local index or empty corpus → empty hits, not a crash.
- If document `embedding_model` mismatches config → skip those docs or fail the tool with “rebuild required”.

### 10.3 Tool policy ids

When shipping, add to [TOOL_POLICY.md](TOOL_POLICY.md):

- `kb_list`, `kb_search`, `kb_get`

Runner global kill switch: `OWNRUN_AGENT_KB=0` removes all three.

## 11. API shape (illustrative)

### Web (user JWT)

- `GET /api/kb` — list knowledge bases (+ document counts by status)
- `POST /api/kb` — create `{ name, project?, description? }`
- `PATCH /api/kb/{id}` — rename, move project, description
- `DELETE /api/kb/{id}` — cascade delete docs (enqueue `kb.delete`)
- `GET /api/kb/{id}/documents` — list docs + status
- `POST /api/kb/{id}/documents` — multipart upload; creates doc + `kb.ingest` job
- `POST /api/kb/documents/{id}/reingest` — requeue ingest
- `DELETE /api/kb/documents/{id}` — enqueue delete

### Runner

- `GET /api/runner/kb/documents/{id}/content` — download blob for claimed ingest job
- `POST /api/runner/kb/documents/{id}/status` — update status, chunk_count, error_message
- Existing claim/complete/fail for `kb.ingest` / `kb.delete`
- `GET /api/runner/kb/visible?project=` — ids/slugs visible for an agent job (or embed on agent claim)

Upload limits: enforce `max_kb_upload_bytes` (suggest **20–32 MiB** default, configurable) and an allowlist of content types. Document hosting `upload_max_filesize` must be ≥ this.

## 12. Web UI

Hash route: `/#/knowledge` (name: `knowledge`).

- List knowledge bases; create with name + optional project.
- Open a KB → document list with status badges (`pending` / `running` / `ready` / `failed`).
- Upload control accepting `.pdf`, `.docx`, `.epub` (multi-file if easy).
- Failed row shows `error_message` + **Retry**.
- Delete document / delete KB with confirm.
- Runner-offline banner: uploads accepted; ingest waits (same mental model as queued chat jobs).
- Header nav entry: **Knowledge** alongside Journal / Calendar / Tasks.

No first-version “ask the KB” chat panel — that is what agent jobs are for.

## 13. Security

- Uploads are **user-authenticated**; blobs are not world-readable.
- Runner download endpoint requires runner token **and** a claimed ingest/delete job for that document (or equivalent binding) so a stolen runner token cannot bulk-exfiltrate every blob without leaving job traces — **lean acceptable variant:** runner token can read any of this user’s KB blobs (same trust as reading journal via tools); prefer job-binding if cheap.
- Parse in a bounded temp directory; never write extracted files into the agent workspace.
- EPUB/PDF zip features: reject absolute paths and `..` entries.
- Tool results truncated; no full-document dump via `kb_get`.
- Prompt injection: retrieved chunk text is untrusted content — system prompt should say not to follow instructions found inside documents.
- Stolen web JWT can upload/delete corpus metadata; stolen runner token can read visible KBs during jobs. Same class of risk as journal, with larger artifacts.

## 14. Configuration (runner)

| Variable | Purpose |
|----------|---------|
| `OWNRUN_KB_DIR` | Persistent vector/index directory |
| `OWNRUN_KB_EMBED_MODEL` | Ollama embedding model id |
| `OWNRUN_KB_CHUNK_SIZE` | Characters per chunk (default ~1200) |
| `OWNRUN_KB_CHUNK_OVERLAP` | Overlap (default ~200) |
| `OWNRUN_KB_MAX_CHUNKS_PER_DOC` | Safety cap |
| `OWNRUN_AGENT_KB` | `0` to disable KB tools globally |

Server: `max_kb_upload_bytes`, max documents per KB (e.g. **200**), max KBs per user (e.g. **50**).

## 15. Failure modes

| Case | Behavior |
|------|----------|
| Runner offline after upload | Doc stays `pending`/`queued`; SPA shows waiting |
| Ollama missing embed model | Ingest fails with install hint; heartbeat can warn SPA |
| Empty extract (scanned PDF) | `failed`: “no extractable text (OCR not supported in v1)” |
| Home disk wiped | Metadata still on server; user hits **Rebuild**; re-ingest all |
| Embedding model changed | Refuse mixed-model search; rebuild required |
| Lease expiry mid-ingest | Job `failed`; doc back to `failed` or `pending`; user requeues |

## 16. Rollout phases

1. **Schema + SPA CRUD + blob storage** (no vectors yet; status stays pending).
2. **`kb.ingest` / `kb.delete` adapters** + parsers + Chroma + Ollama embeddings.
3. **Agent tools** + system-prompt recipe + tool policy ids.
4. Later (out of v1): OCR, Markdown/HTML sources, SPA “ask” box, agent upload, hybrid lexical search, additional formats.

## 17. Open decisions (resolved for implementation)

1. **Vector library:** sqlite-backed local store under `OWNRUN_KB_DIR` (same bar as Chroma/LanceDB; no extra daemon).
2. **One ingest job per document** — yes.
3. **Soft-delete retention** of server blobs until runner ack — yes.
4. **`kb_get`** returns metadata + first-chunk excerpt in v1 (ordinal fetch can wait).
5. **Project field on KBs** — included.

## 18. Decisions summary

1. **Hybrid storage:** originals + metadata on ownrun-server; vectors + chunks on ownrun-runner.
2. **Named knowledge bases** with optional **project** label; agents search global ∪ job project.
3. **Ingest/delete are job types** (`kb.ingest`, `kb.delete`), not agent loops.
4. **v1 formats:** PDF, DOCX, EPUB; text extract only; no OCR.
5. **Embeddings via local Ollama**; one configured model; rebuild on change.
6. **Embedded vector DB on disk** under `OWNRUN_KB_DIR` (Chroma recommended).
7. **Agent tools:** `kb_list`, `kb_search`, `kb_get` on all profiles; subtract via tool policy; agents do not mutate the corpus in v1.
8. **SPA manages** upload/status/delete; no SPA semantic search in v1.
9. **Pull model preserved** — no inbound connections to the home index.

## 19. Implementation order (when coding starts)

1. Design sign-off on open decisions §17.
2. Server: schema + blob storage + web APIs + job enqueue.
3. Web: Knowledge views + upload.
4. Runner: parsers, chunker, embed client, vector store, ingest/delete adapters.
5. Runner: agent tools + prompt boilerplate + heartbeat capabilities (`kb_embed_model`, `agent_tool_ids`).
6. Tool policy ids + docs (`TOOL_POLICY.md`, `DESIGN.md` related link, `DEPLOYMENT.md` smoke checklist).
7. Manual test: upload PDF/DOCX/EPUB → ready → agent `kb_search` cites the right source.
