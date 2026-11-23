# CI — what each job proves

`.github/workflows/ci.yml` is the only workflow. It runs on every push to any
branch, on every pull request, and on demand:

```sh
gh workflow run ci.yml --repo c1tymorgu3/zifiri
gh run list --repo c1tymorgu3/zifiri --workflow ci.yml
```

A job is a question with an exit code. If a job is green, the sentence in the
right-hand column was executed against that commit — not asserted in prose.

| Job | Runs | Proves |
|---|---|---|
| `elixir` | `mix format --check-formatted`, `mix compile --force --warnings-as-errors`, `mix test` | The suite (383 tests, 4 excluded) passes on OTP 27.2 / Elixir 1.18.4, the versions in `.tool-versions`. Formatting is uniform and the compiler emits no warning. |
| `client` | `npm ci`, `npx tsc --noEmit`, `npx vitest run`, `npm run build`, `node scripts/size.mjs` | The client typechecks, its 297 tests pass, the production bundle builds, and the JS total stays under the 100 KiB gzip budget. |
| `architecture` | six greps over `lib/`, `test/`, `infra/` | No `Logger.info`/`Logger.debug`/`IO.inspect`/`dbg(` in `lib/`; no peer or proxy header read outside `lib/zifiri/transport.ex`; no `log:` enabled on an Ecto repo; nginx has `access_log off` and `error_log /dev/null`; the container image uses a numeric `USER`, `read_only: true` and `no-new-privileges:true`. |
| `claims` | `python3` over `docs/claims.md`, `docs/verify.md`, `README.md` | Both documents carry the same 49 IDs, `C-01`…`C-49`, with no gap; every ID is a table row in `claims.md` and a `###` section in `verify.md`; the range sentence matches the last ID; the README cites no ID that `claims.md` does not define. |
| `docs` | `python3` link check, two greps | Every relative link in `README.md` and `docs/*.md` resolves to a file in the tree; the README links `docs/claims.md` and `docs/verify.md`; `log: false` and `secure_delete` are still present in code. |
| `e2e-gate` | one `test -f` | Whether `scripts/e2e/run.sh` exists. Always runs; costs ~15 s. |
| `e2e` | Chrome + `mix phx.server` + `scripts/e2e/run.sh` | A real Chrome loads `/`, `/?demo=1` and `/?demo=1&surface=listings` from a running dev server: the shell is drawn with three rail tabs, the demo badge and both lists render from the fixture chunk, and nothing reaches Chrome's console (10 checks, plus a self-test that proves the console detector can fail). Skipped only when the script is absent. |

## What is deliberately not in CI

`docs/verify.md` §6 also lists checks that need a live host: `journalctl`,
`swapon`, core-dump settings, the live SQLite file, and the nginx `-T` dump.
Those live in `infra/deploy.md` and `scripts/drill/run-all.sh` and are run on the
target, not on a runner. The `docs` job prints that list at the end of its run so
the gap is visible rather than implied.

## Estimated duration

Measured warm on a workstation, then padded for a cold GitHub runner:

| Job | Cold | Warm (cache hit) |
|---|---|---|
| `elixir` | 3.5–4.5 min (Hex fetch + 6 deps compiled) | 1.5–2 min |
| `client` | 60–75 s (`npm ci` from scratch) | 35–45 s |
| `architecture` | 20 s | 20 s |
| `claims` | 15 s | 15 s |
| `docs` | 20 s | 20 s |
| `e2e-gate` | 15 s | 15 s |
| `e2e` | 2–3 min (Chrome + build) | 90 s–2 min |

Wall clock, not sum: `client`, `claims` and `e2e-gate` start together with
`elixir`; `architecture` waits for `elixir`; `docs` waits for `claims`; `e2e`
waits for `elixir` and the gate, then runs in parallel with `architecture`,
`docs` and `client`. A cold run is ~5 min, a warm one ~3 min. Measured locally,
the browser suite itself is ~9 s; the CI minutes go to `mix deps.get`, the
compile and Chrome's first start.

## Cache keys

Two caches, both keyed on what would invalidate them:

| Cache | Path | Key |
|---|---|---|
| BEAM | `deps`, `_build` | `<os>-mix-otp27.2-1.18.4-<sha of mix.lock>` |
| npm | `~/.npm` | `setup-node`'s built-in cache, `client/package-lock.json` |

The OTP and Elixir versions are in the key because BEAM bytecode is not portable
across them — a cache shared between versions is a cache that produces
"module compiled with a different version" failures instead of test results.
`restore-keys` lets a lock-file change reuse the old tree and pay only for the
new dependency.

### Why `_build` is cached *and* `--force` is used

Caching `_build` is what makes a warm run 2 minutes instead of 4. But a restored
`_build` holds artifacts from an earlier compile, and `mix compile` will happily
skip a file whose mtime and hash have not changed — including a file that was
compiled in a run that then failed. `mix compile --force --warnings-as-errors`
recompiles this project's 35 modules (deps stay cached, ~10 s) so that every
warning is printed on every run. Without `--force`, `--warnings-as-errors` would
only ever be enforced on files that changed in that particular commit.

The `_build` cache also carries `_build/test/zifiri_test.db`, so the `test` step
deletes the database, its `-wal` and its `-shm` before running: a restored
database is not a clean one, and `test/test_helper.exs` migrates from scratch.

## Why `--warnings-as-errors`

In this codebase a warning is not style. An unused variable, an unreachable
clause or a shadowed match is usually a claim that quietly stopped being true: a
redaction branch nobody calls any more, a `case` arm that can no longer fire, a
guard that now always matches. Those compile fine and pass tests — the tests
exercise the paths someone thought of. The compiler is the only thing that reads
every line.

The cost is that an intentional warning cannot be merged. That is the trade: an
intentional warning can be silenced at the call site (`_ = value`,
`@compile {:nowarn_unused_function, ...}`) and the silence is then visible in the
diff.

## Why the e2e job is gated

`e2e` runs only when `scripts/e2e/run.sh` is in the tree. The script is there
now, so the job runs on every push; the gate exists so a tree without it (a
branch that has not picked the harness up, a fork) stays green instead of red
for a missing file:

- `hashFiles()` cannot be used as a job-level `if:` — job conditions are
  evaluated before `actions/checkout`, so the workspace is empty and the
  function returns `""` on every run. A job that "passes" because the file was
  never checked out is worse than no job.
- Instead `e2e-gate` checks out, writes the script path (or nothing) to a job
  output, and `e2e` runs only when that output is non-empty. When the script is
  missing, `e2e-gate` is green and `e2e` shows as **skipped** — which is the
  truth, not a pass.

The contract between the job and the script:

| Contract | Value |
|---|---|
| Server | `mix phx.server` in `MIX_ENV=dev`, already started by the job, `/health` returning 200 |
| Base URL | `ZIFIRI_BASE_URL` (`http://127.0.0.1:4000`) |
| Browser | `CHROME_BIN` and `CHROME_PATH`, pointing at the runner image's `google-chrome` |
| Artifacts | anything written to `e2e/artifacts` is uploaded, plus the server log, retained 7 days |
| Exit code | non-zero fails the job |

`run.sh` treats an already-running server as its own (it does not stop what it
did not start) and skips its own `serve.exs` start, so the job's `mix phx.server`
is the process under test — the dev path, not a test-only harness.

`docs/verify.md` §10.1 names `npx playwright test e2e/csp.spec.ts` as the CSP
inline-script test. That spec does not exist; the checks that do exist drive
`chrome --headless --dump-dom` from `run.sh`, so a Playwright CSP spec would be a
second entry point in the same job rather than a replacement.

Chrome comes from the runner image (`ubuntu-latest` ships
`google-chrome-stable`) rather than `browser-actions/setup-chrome`: one fewer
third-party action in a repository that bans them from `lib/`, at the cost of a
Chrome version that moves with the image. The job prints `chrome --version` so a
failure can be tied to a specific build.

## The CI file is itself tested

`test/architecture_test.exs` reads `.github/workflows/ci.yml` and fails `mix
test` if the logging or peer-data token lists drift from the ones the test
enforces. That is why the four logging tokens appear literally
(`Logger\.info|Logger\.debug|IO\.inspect|dbg\(`) instead of as a
`Logger\.(info|debug)` group, and why the transport exemption is written as the
full path `'^lib/zifiri/transport\.ex:'` — a prefix match would exempt
`transport_extra.ex`, which is exactly the hole the test exists to close.

Consequence: editing the greps without running `mix test` turns CI red on a test
that has nothing to do with the change. Run the suite after touching this
workflow.
