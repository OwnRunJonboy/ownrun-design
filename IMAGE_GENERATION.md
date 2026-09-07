# OwnRun Image Generation Design

**Status:** Implemented (v1)  
**Date:** 2026-09-05  
**Author:** Jonboy  
**Depends on:** [DESIGN.md](DESIGN.md) (hosting, pull model, job queue, artifacts), [AGENT.md](AGENT.md) (agent jobs stay Ollama-backed), [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md) (KB ingest embeds via Ollama)  
**Related:** [TOOL_POLICY.md](TOOL_POLICY.md) — image jobs are not agent tools in v1; policy unchanged. [WEB_SEARCH.md](WEB_SEARCH.md) — Ollama cloud search is HTTP-only and does not need the local Ollama daemon. [DEPLOYMENT.md](DEPLOYMENT.md) — migrate_artifacts + Forge scripts.

This document designs **text-to-image** for OwnRun via **local Stable Diffusion Forge** on the home runner, plus the **exclusive local-backend gate** required because Ollama and Stable Diffusion cannot safely share the laptop’s GPU/VRAM at the same time.

Implementation landed across ownrun-server (artifacts + job type), ownrun-runner (BackendGate + txt2img), and ownrun-web (New image + gallery).

## 1. Purpose

OwnRun already runs local text work (`ollama.chat`, `agent.task`, `kb.ingest`) against Ollama. DESIGN.md deferred images to Phase 3. The remaining gap:

- Submit a prompt (and basic SD parameters) from the SPA while away
- Generate image(s) on the home machine with a local Stable Diffusion toolchain
- Upload image artifacts to ownrun-server and view/download them in the SPA

**Hardware constraint (binding):** On this laptop, running **Ollama and Stable Diffusion simultaneously crashes the machine**. Model unload alone is not enough. OwnRun must **fully stop one stack before starting the other**, and must never claim a job that needs the “cold” backend while the “hot” backend still owns the GPU.

## 2. Goals

- New job type **`stablediffusion.txt2img`** on the existing pull/claim/complete path.
- Runner adapter talks to a **local SD HTTP API** (localhost only).
- **Artifact upload** for PNG/JPEG outputs; SPA gallery on job detail.
- **Exclusive backend gate** on the runner: at most one of `{ollama, stablediffusion}` is running.
- Automatic **stop → wait until free → start** via configurable user scripts when the next claimed job needs the other backend.
- Heartbeat reports which backend is **active**, SD readiness, and available SD models/checkpoints (when SD is up).
- Keep Ollama text/agent/KB paths unchanged aside from going through the gate.
- Fail clearly if a backend will not start or stop within configured timeouts.

## 3. Non-goals (image v1)

- Agent tools that generate images mid-loop (`image_gen` tool) — SPA job type only in v1.
- img2img, inpainting, ControlNet, LoRA pickers, multi-step Comfy graphs.
- Cloud image APIs (DALL·E, Flux hosted, etc.).
- Running SD and Ollama concurrently “sometimes” or “with low VRAM settings.”
- Multi-runner / multi-GPU orchestration.
- Streaming partial previews to the browser.
- Video / animation.
- Editing generated images in the SPA beyond view + download + delete-with-job retention.

## 4. Why exclusivity must be a first-class subsystem

| Approach | Why it fails here |
|----------|-------------------|
| Leave both daemons up; unload Ollama models (`keep_alive: 0`) | Daemon + CUDA context can still fight SD; user already crashes |
| Ask the user to SSH home and `systemctl stop ollama` before image jobs | Defeats “away from home” |
| Fail image jobs with “stop Ollama first” | Same |
| Run SD in CPU mode while Ollama holds GPU | Too slow; not the product |
| **Runner owns start/stop of both backends** | **Chosen.** Serializes GPU ownership with the job queue |

Claim batch size is already **1**. Exclusivity is therefore “which process owns the GPU between jobs,” not “two jobs at once.”

### Jobs by GPU owner

| Job type | Needs |
|----------|--------|
| `ollama.chat` | Ollama up |
| `agent.task` | Ollama up |
| `kb.ingest` | Ollama up (embeddings) |
| `kb.delete` | Neither (local vector/files only) |
| `stablediffusion.txt2img` | Stable Diffusion up; **Ollama must be down** |

`web_search` (Ollama cloud HTTP) does **not** require the local Ollama daemon. It only appears inside `agent.task`, which already needs Ollama for the LLM.

## 5. Where it lives (split of roles)

```
┌─────────────────┐         HTTPS          ┌──────────────────┐
│   ownrun-web    │ ─────────────────────► │  ownrun-server   │
│  Image job form │   create job + view    │  jobs + artifacts│
│  artifact gallery│   download images     │  blob storage    │
└─────────────────┘                        └────────┬─────────┘
                                                    │
                         claim / heartbeat /        │
                         complete + artifact upload │
                                                    ▼
                                           ┌──────────────────┐
                                           │  ownrun-runner   │
                                           │  BackendGate     │
                                           │   ├─ Ollama      │
                                           │   └─ SD Forge    │
                                           │  txt2img adapter │
                                           └──────────────────┘
```

PHP never talks to SD or Ollama. The runner is the only process allowed to start/stop local AI daemons.

## 6. Local SD toolchain (v1 choice)

**Chosen for v1:** [Stable Diffusion WebUI Forge](https://github.com/lllyasviel/stable-diffusion-webui-forge) with **`--api`**, bound to `127.0.0.1` only.

| Option | Decision |
|--------|----------|
| **Forge `--api`** | **Chosen default.** Same `/sdapi/v1/txt2img` and `/sdapi/v1/sd-models` surface as A1111; better fit for modern GPUs/VRAM on a laptop. |
| A1111 WebUI `--api` | Compatible fallback if the operator already runs it; sample scripts and docs target Forge. |
| ComfyUI | Deferred. Powerful but graph JSON is a worse SPA + job-payload fit for v1. |
| InvokeAI / raw Diffusers in-process | Deferred. Prefer a separate SD process OwnRun can start/stop like Ollama. |

Config points at:

- Paths to **user start/stop scripts** for SD (and for Ollama when the gate is enabled) — see §7.3
- Base URL (default `http://127.0.0.1:7860`)
- Optional API auth if the local UI enables it

Exact install path is operator-specific; OwnRun does not vendor the Forge repo. Sample start/stop scripts assume a Forge checkout and launch with localhost + `--api`.

## 7. Backend gate (core design)

### 7.1 State machine

Runner-local only (not stored in MariaDB):

```
        ┌─────────────┐
        │   idle_*    │  preferred warm backend (default: ollama)
        └──────┬──────┘
               │ claim job needing other backend
               ▼
        ┌─────────────┐
        │  switching  │  stop current → wait ports/VRAM quiet → start next
        └──────┬──────┘
               ▼
        ┌─────────────┐
        │ active_ollama│  or  active_sd
        └─────────────┘
```

Named states for logs / heartbeat:

| State | Meaning |
|-------|---------|
| `active_ollama` | Ollama process up; SD stopped |
| `active_sd` | SD process up; Ollama stopped |
| `switching` | Stop/start in progress; **do not claim** new jobs |
| `failed` | Last switch failed; runner may still poll but must not claim GPU jobs until recovered |

`kb.delete` may run in any healthy state (no GPU). Optionally allow it during `switching` only if the gate exposes a non-GPU lane; **lean default:** claim nothing while `switching`.

### 7.2 Ensure before each job

Before adapter work:

```
ensure_backend(required):
  if current == required and healthy: return
  enter switching
  stop_other()
  wait_until_stopped(timeout)
  start_required()
  wait_until_healthy(timeout)
  current = required
```

- **Ollama healthy:** `GET {OLLAMA_BASE_URL}/api/tags` succeeds.
- **SD healthy:** `GET {SD_BASE_URL}/sdapi/v1/sd-models` (or `/sdapi/v1/options`) succeeds.
- **Stopped:** configured stop action completed **and** health check fails (connection refused), within timeout.

If ensure fails → mark the **job** `failed` with a readable error (`Could not start Stable Diffusion within 120s`, `Could not stop Ollama`, etc.). Leave gate in `failed` or retry once on the next claim (implementation choice; lean: retry switch on next job).

### 7.3 How to stop / start (user scripts)

The runner does **not** embed systemd, PID tracking, or vendor-specific launch logic. Lifecycle is entirely **user-supplied scripts** configured by path.

| Role | Env var | Contract |
|------|---------|----------|
| Start Ollama | `OWNRUN_OLLAMA_START_SCRIPT` | Executable; exit 0 when start was initiated successfully |
| Stop Ollama | `OWNRUN_OLLAMA_STOP_SCRIPT` | Executable; exit 0 when stop was initiated successfully |
| Start SD | `OWNRUN_SD_START_SCRIPT` | Same |
| Stop SD | `OWNRUN_SD_STOP_SCRIPT` | Same |

**Runner behavior:**

1. Invoke the script with no required CLI args (cwd = runner process cwd unless the script is absolute and self-contained).
2. Capture stdout/stderr to the runner log (truncate if huge).
3. Non-zero exit → gate failure (do not proceed to start the other backend after a failed stop).
4. After the script returns, the runner still runs its own **health wait** (§7.2): stop is not done until the API is down; start is not done until the API is up. Scripts may return as soon as they have signaled the service; they need not block for full readiness (though they may).
5. Script wall-clock timeout separate from health timeout (e.g. script must exit within 60s; health may wait longer).

**What belongs in the user’s scripts (examples, not OwnRun code):**

- `systemctl --user start|stop ollama`
- `pkill` / `kill` of a known PID file
- Launch Forge (`webui.sh --api --listen 127.0.0.1` or equivalent) in the background and write a PID file
- Any conda/venv activation the install needs
- Machine-specific quirks (wait for GPU reset, `nvidia-smi`, etc.)

**Requirements on scripts:**

- Stop must tear down the **GPU-using process**, not only unload a model.
- Start must bind the service to **localhost only** (operator responsibility; OwnRun will not rewrite script contents).
- Scripts must be executable by the same user that runs ownrun-runner.
- OwnRun ships **example** scripts in deployment docs / repo samples; operators copy and edit them. The runner only receives paths.

**Image jobs disabled unless SD scripts + base URL are set.** Ollama scripts are required once the gate is enabled (even for text-only), because exclusivity means the runner must be able to stop/start Ollama around SD work. If image generation is off (`OWNRUN_SD_ENABLED=0`), existing “Ollama already running externally” behavior can remain: no Ollama scripts required.

### 7.4 Idle preference

After a job completes, **leave the backend that just ran warm** (no immediate flip back). Rationale: image and text bursts are often consecutive; flipping every job costs tens of seconds to minutes.

Optional later: idle timer that returns to Ollama after N minutes of SD idle (text is the common path). **Not required for v1.**

Default cold start of the runner: bring up **Ollama** (text/KB are the majority), leave SD stopped.

### 7.5 Interaction with heartbeat and model list

While `active_sd` or `switching`:

- **Do not** call Ollama `/api/tags` (that would require starting Ollama).
- Heartbeat still runs on schedule with:
  - `backend_state`: `active_ollama` | `active_sd` | `switching` | `failed`
  - `ollama_models`: last known list (stale OK) or empty with `ollama_models_stale: true`
  - `sd_available`: whether SD config is present
  - `sd_models`: checkpoint list when `active_sd`, else last known / empty
  - existing agent/KB capability fields unchanged in meaning

SPA uses `backend_state` to explain wait time (“Runner is switching to Stable Diffusion…”).

While `active_ollama`, skip SD model refresh (same rule inverted).

### 7.6 Lease / timeout implications

Switching can take **1–3+ minutes** (SD cold start especially). Job lease must cover:

`switch_timeout_stop + switch_timeout_start + generation_timeout`

Use the existing long lease + job heartbeat. Surface progress events during switch:

```json
{ "phase": "stopping_ollama" }
{ "phase": "starting_stable_diffusion" }
{ "phase": "generating" }
{ "phase": "uploading" }
```

## 8. Job type: `stablediffusion.txt2img`

### 8.1 Request payload (SPA → server → runner)

```json
{
  "prompt": "a red sailboat at dusk, watercolor",
  "negative_prompt": "blurry, low quality",
  "model": "sdxl_turbo.safetensors",
  "width": 1024,
  "height": 1024,
  "steps": 30,
  "cfg_scale": 7,
  "seed": -1,
  "batch_size": 1
}
```

**v1 caps (server-enforced):**

| Field | Cap |
|-------|-----|
| prompt / negative | length limits (e.g. 2 KiB / 2 KiB) |
| width / height | max 1024 (or 1280 if operator raises); multiples of 8 |
| steps | max 50 |
| batch_size | max 4 |
| seed | integer; `-1` = random |

Unknown fields ignored. No arbitrary sampler script / alwayson scripts in v1 (prompt injection into SD APIs is limited by refusing extra keys).

### 8.2 Result payload

```json
{
  "seed": 123456789,
  "model": "sdxl_turbo.safetensors",
  "width": 1024,
  "height": 1024,
  "steps": 30,
  "cfg_scale": 7,
  "duration_ms": 18420,
  "backend_switch_ms": 67300,
  "images": [
    { "artifact_id": 42, "filename": "00001.png", "content_type": "image/png" }
  ]
}
```

Binary pixels live in **artifacts**, not base64 in `result_payload` (hosting JSON size / PHP limits).

### 8.3 Runner adapter flow

1. `ensure_backend(stablediffusion)`
2. If `request.model` set, select checkpoint via SD API options (or fail if missing).
3. `POST /sdapi/v1/txt2img` with mapped fields; `stream: false` equivalent (single response).
4. Decode returned images to temp files under runner work dir.
5. Upload each via `POST /api/runner/jobs/{id}/artifacts`.
6. `complete` with metadata listing artifact ids.
7. Leave gate in `active_sd` (no auto-restart Ollama).

Cancel: if job heartbeat reports cancel during switch or generate, abort HTTP call if possible, delete temp files, skip complete (existing cancel semantics).

## 9. Artifacts (server + web)

DESIGN.md already sketched artifact rows. Image v1 makes them real.

### 9.1 Storage

- MariaDB `job_artifacts`: `id`, `job_id`, `kind` (`output`), `filename`, `content_type`, `storage_path`, `size_bytes`, `created_at`
- Files on disk outside the public docroot when hosting allows
- Max size per artifact and per job (e.g. 15 MiB each, 4 images → headroom under PHP/`post_max_size`)

### 9.2 API

**User JWT**

- `GET /api/jobs/{id}/artifacts` — list
- `GET /api/jobs/{id}/artifacts/{artifactId}` — download / inline image (`Content-Type` image/*)

**Runner token**

- `POST /api/runner/jobs/{id}/artifacts` — multipart upload; only for `running` job owned by this runner

AuthZ: same job ownership rules as job detail.

### 9.3 SPA

- New job form: Image (prompt, negative, model select from last-reported `sd_models`, size presets, steps, seed, batch).
- Job detail: thumbnail grid → full image; download button.
- While queued/running: show runner online + `backend_state` hint when switching.
- Hide Image form or show setup hint when heartbeat says `sd_available: false`.

## 10. Queue behavior under exclusivity

Single runner, claim 1:

1. Text job finishes under Ollama → gate stays `active_ollama`.
2. Image job claimed → switch to SD (stop Ollama, start SD) → generate → upload.
3. Next text/agent/KB ingest job → switch back to Ollama.

**Fairness:** FIFO of the existing queue is enough. No priority lane in v1.

**User expectation:** After an image job, the first chat may wait for Ollama cold start. SPA copy should say so when `backend_state` is `switching` or when an image job just completed and a text job is queued.

**Do not** claim an image job while an Ollama job is running (already true). **Do not** start SD in a background thread “to warm up” while Ollama is serving — that is the crash case.

## 11. Security

- SD and Ollama remain **localhost-only**.
- Job type is fixed (`stablediffusion.txt2img`); no shell, no arbitrary SD script fields.
- Cap dimensions / steps / batch / prompt size on the server.
- Artifact content-type allowlist: `image/png`, `image/jpeg`, `image/webp`.
- Stolen runner token can generate images and burn GPU time / disk — same class as today’s Ollama abuse; rotate token if leaked.
- Do not put SD admin credentials in job payloads; only in runner env.

## 12. Configuration (runner)

| Variable | Purpose |
|----------|---------|
| `OWNRUN_SD_ENABLED` | `1` to enable image jobs and the exclusive gate |
| `OWNRUN_SD_BASE_URL` | Default `http://127.0.0.1:7860` |
| `OWNRUN_SD_START_SCRIPT` | Path to executable that starts Stable Diffusion |
| `OWNRUN_SD_STOP_SCRIPT` | Path to executable that stops Stable Diffusion |
| `OWNRUN_OLLAMA_START_SCRIPT` | Path to executable that starts Ollama (**required** when `OWNRUN_SD_ENABLED=1`) |
| `OWNRUN_OLLAMA_STOP_SCRIPT` | Path to executable that stops Ollama (**required** when `OWNRUN_SD_ENABLED=1`) |
| `OWNRUN_BACKEND_SCRIPT_TIMEOUT_SEC` | Max time for a start/stop script to exit (e.g. 60) |
| `OWNRUN_BACKEND_STOP_TIMEOUT_SEC` | Wait for health fail after stop script (e.g. 60) |
| `OWNRUN_BACKEND_START_TIMEOUT_SEC` | Wait for health ok after start script (e.g. 180 for SD) |
| `OWNRUN_SD_JOB_TIMEOUT_SEC` | txt2img HTTP timeout |
| `OWNRUN_BACKEND_IDLE` | `ollama` (default) — backend to start on runner boot when gate is enabled |

`sd_available` on heartbeat is true only when `OWNRUN_SD_ENABLED=1` and all four script paths are set, exist, and are executable (plus SD base URL).

Server: max artifact bytes; advertise image job type from runner heartbeat `sd_available`.

**Example layout (operator-owned, not required paths):**

```
~/ownrun-scripts/
  start-ollama.sh
  stop-ollama.sh
  start-sd.sh
  stop-sd.sh
```

```bash
export OWNRUN_SD_ENABLED=1
export OWNRUN_OLLAMA_START_SCRIPT=$HOME/ownrun-scripts/start-ollama.sh
export OWNRUN_OLLAMA_STOP_SCRIPT=$HOME/ownrun-scripts/stop-ollama.sh
export OWNRUN_SD_START_SCRIPT=$HOME/ownrun-scripts/start-sd.sh
export OWNRUN_SD_STOP_SCRIPT=$HOME/ownrun-scripts/stop-sd.sh
```

## 13. Failure modes

| Case | Behavior |
|------|----------|
| SD not installed / start script fails | Job `failed`; log script exit code + stderr; `backend_state=failed` |
| Script path missing or not executable | Refuse to enable gate / `sd_available=false`; fail jobs that need a switch |
| Stop script exits 0 but API still up | Wait until `OWNRUN_BACKEND_STOP_TIMEOUT_SEC`; then fail (do **not** start the other backend) |
| Start script exits 0 but API never healthy | Wait until start timeout; fail job |
| Ollama will not stop | Do **not** start SD; fail image job; log hard |
| SD will not stop before text job | Do **not** start Ollama; fail text/agent/ingest job |
| Laptop still OOM/crashes despite gate | Out of software scope; gate is best-effort serialization — document that operator must not manually start the other stack |
| Checkpoint missing | Fail job with install/select hint |
| Artifact upload fails | Retry with backoff; then fail job (lease path as today) |
| User starts SD manually while Ollama up | Runner health checks may disagree; prefer “only via OwnRun scripts” in deployment docs |
| `kb.delete` during SD | Allowed (no GPU); implement after GPU jobs or same claim loop when gate idle |

## 14. Observability

- Log every gate transition with timestamps: `stop_ollama_begin`, `stop_ollama_ok`, `start_sd_ok`, durations.
- Job progress JSON phases (§7.6) for SPA.
- Heartbeat `backend_state` for global indicator (e.g. “GPU: Stable Diffusion”).

## 15. Rollout phases

1. **Artifact pipeline** on server + SPA download path (can land before SD).
2. **BackendGate** invoking configurable Ollama start/stop scripts; prove chat still works when gate-managed.
3. **SD start/stop scripts + txt2img adapter** + heartbeat SD fields; ship example scripts.
4. **SPA Image job form** + gallery on job detail.
5. Later (out of v1): idle flip-back to Ollama, img2img, ComfyUI, agent `image_gen` tool, sampler/LoRA UI.

## 16. Open decisions

1. **Whether `kb.delete` bypasses `switching`** — lean no for v1 simplicity.
2. **Stale Ollama model list in SPA while SD-active** — show last-known with “may be stale” vs hide model dropdown until Ollama returns; lean last-known + badge.
3. **PNG only vs JPEG/WebP** — lean PNG from SD API default.
4. **Script argv** — none in v1 vs pass `start|stop` and backend name for a single multi-call script; lean **four separate script paths** (simpler permissions and logging).

## 17. Decisions summary

1. **Job type** `stablediffusion.txt2img`; artifacts for image bytes.
2. **Local SD default:** **Forge** with `--api` on localhost (A1111 compatible if the operator prefers).
3. **Exclusive BackendGate** on the runner: never run Ollama and SD at once; full process stop, not model unload.
4. **Start/stop via configurable user scripts** (`OWNRUN_*_START_SCRIPT` / `*_STOP_SCRIPT`); runner only execs + health-waits.
5. **ensure_backend(required)** before every GPU job; claim size stays 1.
6. **Leave last backend warm** after each job; default boot → Ollama.
7. **Heartbeat** exposes `backend_state` and SD model list when safe to query.
8. **No agent image tool** in v1.
9. **Pull model preserved** — no inbound ports to home for SD.

## 18. Acceptance criteria (when implementing)

1. With Ollama running, an image job stops Ollama, starts SD, generates, uploads, and shows the image in the SPA — without a manual SSH step.
2. A following `ollama.chat` job stops SD, starts Ollama, and completes.
3. Starting SD while Ollama is still healthy never occurs (asserted in gate; logged).
4. Heartbeat during SD does not call Ollama.
5. Failed stop/start fails the job with an actionable error string.
6. `agent.task` and `kb.ingest` still work when the gate is `active_ollama`.

## 19. Implementation order (when coding starts)

1. Design sign-off on open decisions §16.
2. Server: artifact table + runner upload + user download APIs; job type allowlist.
3. Runner: BackendGate + Ollama lifecycle hooks; wrap existing adapters in `ensure_backend(ollama)`.
4. Runner: SD lifecycle + txt2img adapter + progress phases.
5. Web: Image create form + job detail gallery; backend_state indicator.
6. Deployment docs: example Forge start/stop scripts (plus optional A1111 variants), “do not auto-start both,” smoke test for switch both ways.
7. Manual test on the crash-prone laptop: chat → image → chat with no manual intervention and no hang/crash.
