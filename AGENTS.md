# Repository Guidelines

## Project Overview

`vectum` v0.1.0 is a lightweight, self-hosted event router built with Gleam on the BEAM. HTTP webhooks are normalized into a common envelope, routed by TOML rules, and delivered to HTTP destinations. SQLite provides local persistence, at-least-once delivery, retries, and dead-letter operations without an external database.

The supported deployment is single-node and offline-capable except for destination network access. There is no broker/cluster, web UI, hot reload, or automatic retention subsystem.

## Architecture & Data Flow

- Boot: `src/vectum.gleam:main` passes argv to `src/vectum/app.gleam`. `run_server` loads and validates TOML, initializes shutdown state, performs one-time SQLite recovery, starts the OTP tree, then binds Mist.
- Ingress: `src/vectum/ingress.gleam` serves `GET /health`, `/ready`, `/metrics`, and `POST /events/:source`. It resolves live actor references through `registry`, enforces shutdown admission and body limits, and maps typed rejection errors to HTTP status codes.
- Admission: `src/vectum/accept.gleam` validates source/content type/HMAC/JSON/event type, normalizes metadata, and calls `route.select_destinations`. `storage.call_accept` atomically persists the event and one pending delivery per unique destination before returning `202`.
- Core: `event`, `filter`, `route`, `config`, `hmac`, and `retry` are transport-independent value/validation modules. Keep HTTP, OTP, and FFI concerns at the edges.
- Egress: `src/vectum/dispatcher.gleam` ticks every 200 ms, computes available concurrency, claims due rows, and runs guarded workers. `delivery.build_outgoing` creates the envelope and idempotency headers; results become success, retry with capped exponential backoff/jitter, or dead letter.
- Runtime: `supervisor.gleam` owns Metrics, Storage, and Dispatcher under a `OneForOne` tree. `storage.gleam` serializes SQLite access. `registry.gleam` stores live actor subjects and must be consulted after restarts; do not cache subjects across actor death.
- Shutdown: `shutdown.gleam` plus the Erlang signal handler stop new intake/claims, drain accepted requests and workers until `VECTUM_SHUTDOWN_GRACE_MS` (default 10 seconds), then halt.

## Key Directories

- `src/vectum/`: flat snake_case Gleam modules; pure domain modules and OTP/HTTP edge modules live side by side.
- `src/`: executable entrypoint plus `vectum_ffi.erl` and `vectum_signal_handler.erl`.
- `test/`: gleeunit tests, local fixtures, and `http_ffi.erl` for raw TCP ingress checks.
- `examples/`: `minimal.toml` for secret-free validation, `router.toml` for HMAC/filter/fan-out, and `docker.toml` for container defaults.
- `docs/`: specification and operational decisions; read `docs/README.md` for the intended order.
- `.github/workflows/`: the test and formatting CI gate. `tmp/` and `/data` are runtime/test storage locations and are ignored.

## Development Commands

```sh
direnv allow                         # or: nix develop
gleam deps download
gleam test
gleam test -- --target-logs         # gleeunit output
gleam format --check src test       # CI gate
gleam format src test               # apply formatting
gleam build
gleam run -- validate --config examples/minimal.toml
cp examples/minimal.toml router.toml
gleam run -- run --config router.toml
```

The config precedence is `--config <path>` > `$VECTUM_CONFIG` > `./router.toml`. HMAC environment variables named by `hmac_secret_env` must be present when validating or running a config.

For a local smoke request, run the server and post JSON to `http://127.0.0.1:8080/events/internal`. The compiled CLI supports `vectum run`, `validate`, `dead list`, `dead retry <delivery-id>`, and `dead delete <delivery-id>`; during development use `gleam run --` with the same arguments.

Container commands:

```sh
docker build -t vectum:0.1.0 .
docker run --rm -p 8080:8080 -v ./data:/data vectum:0.1.0
```

## Code Conventions & Common Patterns

- Keep modules flat; use snake_case module/function names and PascalCase tagged unions/constructors.
- Prefer pure functions over actor coupling. Return `Result` with typed errors; ingress translates errors to HTTP responses instead of raising.
- Inject boundaries used by tests, such as environment lookup and outbound send functions. Stateful tests use real SQLite actors with `:memory:` databases and local stub closures.
- Treat the Storage actor as the SQLite serialization boundary. Preserve transaction atomicity, the unique `(event_id, destination)` invariant, and `status = 'delivering'` guards on mark operations.
- Routing uses exact or `*` event types, dotted paths, stable destination deduplication, and AND semantics for filters on one route. Metadata keys are normalized case-insensitively.
- Outbound requests always include `Content-Type: application/json`, `X-Event-Id`, and `Idempotency-Key` (both IDs match); destination HMAC is optional.
- Use `registry` lookups for actor references on every request/tick. FFI belongs in the Erlang `*_ffi.erl` files with a thin Gleam wrapper.
- Logs are single-line JSON on stdout. `[log]` TOML configuration is not implemented; source `path` is parsed but ingress remains `/events/<name>`. Config changes require a restart.

## Important Files

- Boot and commands: `src/vectum.gleam`, `src/vectum/app.gleam`, `src/vectum/cli.gleam`.
- HTTP/admission: `src/vectum/ingress.gleam`, `src/vectum/accept.gleam`.
- Domain: `event.gleam`, `filter.gleam`, `route.gleam`, `config.gleam`, `hmac.gleam`, `retry.gleam`.
- Persistence/delivery: `storage.gleam`, `dispatcher.gleam`, `delivery.gleam`.
- OTP/runtime: `supervisor.gleam`, `registry.gleam`, `shutdown.gleam`, `metrics.gleam`, `env.gleam`, `clock.gleam`, and the Erlang FFI files.
- Tooling and contracts: `gleam.toml`, `manifest.toml`, `flake.nix`, `Dockerfile`, `.env.example`, `examples/*.toml`, and `.github/workflows/test.yml`.
- Product contract: `README.md` for quickstart/API; `docs/architecture.md`, `docs/decisions.md`, and `docs/spec-compliance.md` for design constraints and intentional gaps.

## Runtime/Tooling Preferences

- Use the Erlang target only. `gleam.toml` requires Gleam `>= 1.18.0`; CI and Docker use Gleam `1.18.1`.
- README/Docker require Erlang/OTP 27+; the Docker runtime is OTP 27, CI uses OTP 29, and Nix derives Erlang from its locked `nixos-unstable` package set.
- Dependencies are Hex packages managed by Gleam; `manifest.toml` is the generated lockfile and should not be hand-edited. `sqlight` brings the `esqlite` NIF and rebar3 build path.
- SQLite development headers/libraries are required (`libsqlite3-dev` in CI); Nix supplies SQLite/OpenSSL, compiler tools, rebar3, and Gleam tooling through `direnv`/`nix develop`.
- There is no npm/pnpm/yarn/cargo workflow, Makefile, or project `justfile`. The Nix shell installs `just`, but no repository commands use it.
- Docker runs as non-root user `vectum`; keep persistent SQLite under writable `/data`. Override `/config/router.toml` with `VECTUM_CONFIG` when deploying a real destination.

## Testing & QA

- Framework: gleeunit, entered through `test/vectum_test.gleam` calling `gleeunit.main()`. There are 18 `*_test.gleam` files (17 test modules plus the runner) with 110 exported `pub fn *_test` tests.
- Run `gleam test` for the full suite; no per-file command, coverage configuration, upload, or minimum coverage gate is documented.
- Pure tests construct `Event`, filters, routes, retry policies, config TOML, HMAC inputs, and CLI values inline. Stateful tests use real `sqlight` `:memory:` connections/actors, injected send closures, process kills, panic closures, and bounded polling helpers.
- Test isolation is explicit because gleeunit has no shared setup/teardown. File-backed cases clean `tmp/vectum-{recover,wal,durability,corrupt}-test.db` and SQLite sidecars.
- Ingress tests start real Mist listeners on fixed localhost ports `18771`–`18773` and send raw TCP requests. One delivery test intentionally attempts `127.0.0.1:9`; the suite is mostly local but is not purely in-memory.
- CI (`.github/workflows/test.yml`) provisions OTP 29, Gleam 1.18.1, rebar3, and SQLite headers, then runs `gleam deps download`, `gleam test`, and `gleam format --check src test`.
