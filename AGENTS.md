# Repository Guidelines

## Project Overview

`vectum` (v0.1.0) is a lightweight, self-hosted event router on Gleam/BEAM.
HTTP ingress → normalized Envelope → TOML-declared routes/filters/fan-out → HTTP destinations.
SQLite-only at-least-once delivery with exp-backoff retry and dead-letter CLI.
Single-node, offline-capable. Non-goals: broker/cluster, Web UI, hot reload, auto-retention.

## Architecture & Data Flow

- Ingress (`src/vectum/ingress.gleam`, `accept.gleam`): `mist` serves `GET /health|/ready|/metrics`, `POST /events/:source`. `persist_event` checks shutdown flag (→ 503), bounded body read, `accept.normalize` validates: unknown source → 404, content-type → 415, HMAC → 401, JSON/type → 400. `route.select_destinations` picks targets; `storage.call_accept` persists event + one `Delivery` row per destination atomically; returns `202 {id, accepted, deliveries}`.
- Egress (`src/vectum/dispatcher.gleam`, `delivery.gleam`, `retry.gleam`): dispatcher actor self-sends `Tick` every 200ms, re-reads Store/Metrics from `registry` each tick, `capacity = concurrency - shutdown.active_workers()`, `call_claim_due`, spawns one BEAM process per delivery under `run_guarded` (always releases slot, even on panic). `process_one_inner`: fetch event → find destination → `delivery.build_outgoing` (envelope JSON + `X-Event-Id`/`Idempotency-Key` + optional HMAC) → `gleam_httpc` send → `retry.classify` (2xx success; 408/429/5xx/timeout/conn-err retry; else fail) → `mark_success/mark_retry/mark_dead` with capped exponential backoff + optional jitter.
- Reaper: every 10s resets stale `delivering` rows (`cutoff = max(2 × longest destination timeout, 10s)`) to `pending`.
- OTP (`src/vectum/supervisor.gleam`, `registry.gleam`, `shutdown.gleam`): `static_supervisor`, `OneForOne` (intensity 10/period 5) over Metrics → Storage → Dispatcher. Actor `Subject`s published to `persistent_term` registry; ingress/dispatcher re-read per request/tick, never cache across restarts. Boot `storage.open_and_recover` runs once; actor restarts must not re-recover.
- Shutdown: SIGTERM/SIGINT → persistent_term flag (ingress 503, dispatcher stops claiming) → wait workers up to `$VECTUM_SHUTDOWN_GRACE_MS` (default 10s) → `halt(0)`.
- Envelope: wire JSON key `time`, Gleam field `timestamp`; `[[sources]] path` parsed but ignored (always `POST /events/<name>`).

## Key Directories

- `src/vectum/`: flat modules only — keep it flat. Pure core (`event`, `filter`, `route`, `config`, `hmac`, `retry`, `storage` logic) vs OTP edge (`ingress`, `dispatcher`, `supervisor`, `registry`, `shutdown`).
- `src/`: `vectum.gleam` entry, `vectum_ffi.erl` (persistent_term/atomics/signals/env), `vectum_signal_handler.erl`.
- `test/`: 16 `*_test.gleam` files, gleeunit auto-discovery.
- `examples/`: `minimal.toml` (secret-free) → `router.toml` (HMAC/filters) → `docker.toml` (container default).
- `docs/`: spec; reading order in `docs/README.md`. `decisions.md` pins v0.1; `spec-compliance.md` lists intentional gaps.

## Development Commands

```sh
gleam deps download
gleam test                          # full suite (:memory: SQLite, no external services)
gleam format --check src test       # CI gates this; fix with `gleam format src test`
gleam run -- validate --config examples/minimal.toml
gleam run -- run --config router.toml
gleam build
direnv allow                        # or: nix develop
docker build -t vectum:0.1.0 .
docker run -p 8080:8080 -v ./data:/data -v ./router.toml:/config/router.toml:ro vectum:0.1.0
```

Config resolution: `--config <path>` > `$VECTUM_CONFIG` > `./router.toml`.
Secrets (`hmac_secret_env`, e.g. `GITHUB_WEBHOOK_SECRET`) must exist in env at `validate`/`run` time; see `.env.example`.

## Code Conventions & Common Patterns

- Flat modules under `src/vectum/`; e.g. `src/vectum/route.gleam`, not nested dirs.
- Pure/testable core takes plain values; stub HTTP send as `fn(_outgoing) { delivery.Status(200) }` (see `test/integration_test.gleam`, `dispatcher_test.gleam`).
- Error handling: `Result` + typed errors (`ConfigError`); ingress maps to HTTP codes, never raises. Tests use plain `assert` / `let assert`.
- State: single `storage` actor serializes SQLite (`process.call`, 5s timeouts); `events`/`deliveries` tables, `unique(event_id, destination)`. Always re-read refs via `registry.gleam`, never stash `Subject`s.
- Routing: `route.select_destinations` dedups per (event, destination); same-rule `[[routes.filters]]` are AND; `filter` ops `eq/neq/gt/gte/lt/lte/contains/exists/not_exists` over dotted paths (`event.get_path`), case-insensitive `parse_op`.
- Outbound: always set `X-Event-Id` + `Idempotency-Key` (= event id); HMAC defaults — source header `X-Hub-Signature-256` (`sha256=<hex>`, bare hex accepted), dest header `X-Vectum-Signature`.
- Logging: single-line JSON to stdout (`src/vectum/log.gleam`); `[log]` config section unimplemented — don't add.
- FFI lives in `*_ffi.erl` + thin `env.gleam` wrapper (`get_env` → `os:getenv`).

## Important Files

- Entry/boot: `src/vectum.gleam` (`main` → `app.run_command`), `src/vectum/app.gleam` (`run_server`/`validate`/`dead`), `src/vectum/cli.gleam` (`Run/Validate/DeadList/DeadRetry/DeadDelete` + table format).
- Domain: `src/vectum/event.gleam` (Envelope/EventValue, `get_path`), `filter.gleam`, `route.gleam`, `accept.gleam`, `ingress.gleam`, `dispatcher.gleam`, `delivery.gleam`, `retry.gleam`, `storage.gleam`, `config.gleam`.
- OTP/support: `supervisor.gleam`, `registry.gleam`, `shutdown.gleam`, `metrics.gleam`, `hmac.gleam`, `id.gleam` (UUIDv7 via `youid`), `clock.gleam`, `log.gleam`, `env.gleam`.
- Config/tooling: `gleam.toml` (package `vectum`, Erlang target), `manifest.toml` (locked), `examples/minimal.toml|router.toml|docker.toml`, `.env.example`, `Dockerfile` (`gleam export erlang-shipment`, user `vectum`, `/config/router.toml`, `/data/router.db`), `flake.nix` + `.envrc`, `.github/workflows/test.yml`.
- Docs: `README.md` (quickstart/API) → `docs/README.md` (index) → `overview/use-cases/architecture/event-model/ingress/routing/delivery/persistence/security/configuration/cli/observability/operations` → `decisions.md` + `spec-compliance.md`.

## Runtime/Tooling Preferences

- Required: Gleam ≥1.18 (pinned 1.18.1), Erlang/OTP 27 runtime (CI uses OTP 29 + rebar3), Erlang target only.
- Package manager: Hex via `gleam.toml`/`manifest.toml` (`mist`, `sqlight`/`esqlite`, `tom`, `argv`, `gleam_httpc`, `youid`). No npm/make/just.
- SQLite NIF needs `sqlite` + `openssl` headers (`libsqlite3-dev` in CI; Nix flake provides them).
- Docker: storage path must be under `/data` (runs as non-root `vectum`); override baked `/config/router.toml` via `$VECTUM_CONFIG` mount; exposed containers need source HMAC. Default destination placeholder fails until overridden.

## Testing & QA

- Framework: `gleeunit` only dev-dep; entry `test/vectum_test.gleam` calls `gleeunit.main()` which runs every `pub fn *_test` in `test/*_test.gleam`. No suites/helpers/mocks/coverage tooling.
- Run: `gleam test` (full suite). No per-file target documented.
- Patterns: pure units construct values inline (`event/filter/route/hmac/retry/config/delivery/metrics/cli`); stateful suites use real `:memory:` SQLite actors + stub send fns (`storage/integration/dispatcher/shutdown/supervisor`); timing tests poll via `wait_until` loops; `storage_test` uses gitignored `tmp/vectum-recover-test.db`.
- CI (`.github/workflows/test.yml`): `gleam deps download` → `gleam test` → `gleam format --check src test`.
- Coverage expectation: per-module happy-path (`let assert`) + negative rejects (e.g. `config_test` unknown source/dest, bad URL/filter op/missing env; `accept_test` 404/415/400/401); no coverage gate.
