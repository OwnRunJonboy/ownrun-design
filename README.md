# ownrun-design

Design documents and deployment notes for **OwnRun** — a personal remote-access bridge for local AI.

OwnRun lets you submit AI jobs from a phone or another computer while away from home. A lightweight runner on the home machine polls a PHP API on shared hosting, runs work against local tools (Ollama for text, Stable Diffusion for images), and uploads results for viewing in a Vue SPA. The home machine never accepts inbound connections.

This repository holds the product architecture and feature designs that guide the three implementation repos:

| Repo | Role |
|------|------|
| **ownrun-server** | PHP API + MariaDB persistence |
| **ownrun-web** | Vue SPA for jobs and results |
| **ownrun-runner** | Python poller on the home computer |

For a quick local try of the full stack, see [aio/README.md](aio/README.md).

## Documents

| Document | Description |
|----------|-------------|
| [DESIGN.md](DESIGN.md) | Core architecture: components, job queue, security, and hosting model |
| [AGENT.md](AGENT.md) | Agent jobs (`agent.task`) via Autogen AgentChat on the home runner |
| [CALENDAR.md](CALENDAR.md) | Personal calendar in the SPA, with agent search/view/add/edit/delete tools |
| [JOURNAL.md](JOURNAL.md) | Personal journal, home-page memory card, and agent journal tools |
| [TASKS.md](TASKS.md) | Personal task tracker, home-page due card, and agent task tools |
| [SYSTEM_PROMPTS.md](SYSTEM_PROMPTS.md) | Saved system-prompt library and global/per-project defaults |
| [WEB_SEARCH.md](WEB_SEARCH.md) | Agent web search via Ollama’s cloud API |
| [TOOL_POLICY.md](TOOL_POLICY.md) | Per-project and per-job agent tool disables |
| [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md) | Personal RAG: document upload, embed/index, and agent `kb_*` tools |
| [IMAGE_GENERATION.md](IMAGE_GENERATION.md) | Stable Diffusion txt2img jobs, artifacts, and Ollama↔SD backend gate |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Production deployment of server, web, and runner |
| [aio/README.md](aio/README.md) | All-in-one Docker stack for local evaluation |

## License

OwnRun design materials in this repository are distributed under the [GNU Affero General Public License v3](COPYING.txt) (AGPL-3.0).
