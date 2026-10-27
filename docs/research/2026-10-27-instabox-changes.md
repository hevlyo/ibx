# Instabox changes checked on 2026-10-27

This records the evidence and implementation decisions for ibx 0.3.0. The baseline is ibx
0.2.0, released on 2026-10-17. The research used the downloaded OpenAPI spec, info.md,
llms-full.txt, CLI 0.7.1, SDK 0.5.3, verified findings and 42 live-probe records. Implementation
and regression testing used the mock only. No live API call belongs to this implementation.

Public sources are [OpenAPI](https://api.instabox.sh/v1/openapi.json),
[full docs](https://instabox.sh/llms-full.txt), [CLI docs](https://instabox.sh/docs/cli) and
[SDK docs](https://instabox.sh/docs/sdk). Line numbers below refer to the research snapshot
from 2026-10-27, not a promise about future versions of those pages. Live result numbers
identify that snapshot's live-results.json. No credentials or personal identifiers are copied.

## Lifecycle and billing

Free boxes now reject any idle-pause setting other than 1800 seconds with 403. Paid plans
allow 300-1800 in steps of 300, or 0 with always-on. Only admin-granted manualLifecycle
accounts use 120-86400. PATCH values had returned 200 without changing 1800 on October 15-16;
the docs date the refusal change to October 25, and live results 9 and 29 confirmed it on
October 27. Sources are AutoSuspendAfterSeconds, Machine.free and llms-full.txt lines 61,
287, 739 and 1235. The old ready-to-send bug reports were removed.

MaxRunMinutes and Machine.runStartedAt/cooldownUntil describe the independent max-run limit.
Free boxes pause after 480 continuous minutes, despite leases. Every wake path refuses with
machine_cooldown until the deadline; 0 disables waking with max_run_disabled. Live result 6
found eight-hour runs and 5-17-minute cooldowns; result 15 observed preserved processes.
The documented default cooldown is ten minutes. ibx skips known cooldowns in keepalive, treats
a raced cooldown as a successful skip, waits within its start/exec budget, avoids spent boxes
at claim, and exposes pause/cooldown times. The explicit --all option keeps its behavior.
The user reported switching the installed timer to reserved-only keepalive on 2026-10-27.
This implementation does not edit that timer.

OrgLimits.freeSandboxHours is conditional, with 0 meaning no cap. Live result 1 found an
included-usage stop on October 18. GET /v1/orgs/{orgId}, unlike the org-list response, supplies
concrete limits and usage. ibx doctor now reads that route, shows tier, running-hour usage,
startsPerMinute and account-block timestamps. Wake responses with 402 or billing codes stop
claim immediately with account_blocked rather than walking the pool. Sources are the
start/resume/wake response tables, PaymentRequired, Org.cardMissingAt and Org.disabledAt.

## Command execution

The exec description now explicitly says an API restart kills a running command and can
return retryable 503 host_unavailable. Retrying repeats partly-run work. ibx refuses to repeat
user exec after that response. Quota, cooldown and not-running refusals are safe before-start
cases. Current credential codes and missing_scope get auth, cleaned hints and requiredScopes.
Sources are POST /v1/machines/{id}/exec, Error, llms-full.txt lines 1311-1343 and 1757, and
live results 0, 5, 14 and 38. A bad key normally fails during name resolution, before exec.

ExecResult.invalidUtf8 reports changed bytes, signal gives the actual terminating signal,
and diskWarning reports disk pressure. Live result 17 confirmed invalid UTF-8 replacement
and TERM, USR1 and KILL signal names. Buffered output remains capped at 1 MiB per stream.
The API allows 32 requests per user, shared with files, desktop, forwarding and Secret
refresh, but usage does not report that limit. Sources are ExecResult, DiskWarning and
llms-full.txt lines 1234 and 1745. ibx reports these fields and retains the remote status.

Live result 13 found that exec returns shortly after the parent exits. Later writes by a
background child can be lost and fail with broken pipes; a loop can survive its writer.
Detached jobs need a new session and redirected stdin/stdout/stderr. Live result 18 did not
reproduce the old pkill self-match with exec, whose text now runs through an environment
variable and eval. SSH behavior was not verified, so its caution remains.

Closing an exec connection kills its process group, including partly-run work. A child in a
new session can survive. ibx now waits on curl in its main shell so an interrupt closes curl
promptly. SSH disconnect behavior remains uncertain, and its message preserves that caveat.

## Credential boundaries

Org Secrets are independent of the legacy Vault. MachineSecrets exposes proxy and env
selections, effective items, application state and guest residue. Proxy all includes future
Secrets. Env delivery exposes actual values inside the VM. Dashboard boxes select all proxy
Secrets; basic setup also enrolls credentials. Live results 4, 24 and 35 found empty
selections and an empty org. That is the safe baseline, not proof that the stores are linked.
Sources are MachineSecrets, SecretSelection, Machine.vault and llms-full.txt lines 502,
515-517, 563-568, 582 and 615.

Claim, pool add and doctor now fail closed for unsafe or uninspectable selections. A 404 is
clean only when usage says orgSecrets is disabled; result 23 showed route-not-found and
machine-not-found share a code. The user-only IBX_ALLOW_SECRETS permits proxy Secrets, never
env delivery or guest residue. The skill forbids agents to set it. Doctor reads org metadata,
warns for Secret names, and fails for env delivery or wildcard hosts. In-box checks print only
names and counts. No code creates or selects Secrets.

Vault 403 remains unsafe, with an explanation for workspace keys or non-creators. Applied
files and kept files also count as unsafe. Sources are GET /v1/machines/{id}/vault,
VaultApplied/VaultKept and live result 26. Workspace keys need explicit scopes, or they carry
workspace:admin. The pool guidance now requires --no-vault --secrets none.

## Files and access

PUT /v1/machines/{id}/files streams up to 5 GiB, atomically renames the upload, follows a
target symlink, and returns FileWritten.sha256. GET /files/content returns raw bytes with
Content-Length. Live results 19 and 40 confirmed a five-MB checksum and binary round-trip.
Sources are those routes, FileWritten and llms-full.txt lines 1739-1926. ibx uses streaming
upload, verifies the digest, stages bounded downloads and replaces output only on success.
IBX_GET_MAX defaults to 2G. Only an explicit route-not-found response enables the old 750 KB
exec fallback. Credential checks run before either upload transport. Repeated not-running refusals have
a bounded retry count. A lost upload reply can follow a committed replacement, so its error
reports that uncertainty; staged download failures preserve the existing local file. Raw
file-transfer interruptions use destination-specific wording rather than claiming an exec
process group was involved. The exec disconnect rule still applies to the legacy fallback.

Live results 22 and 34 confirmed SSH port-forwarding. ibx forward reuses host-CA pinning and
one-hour tokens, binds both tunnel endpoints to loopback, runs in the foreground, and revokes
the token on exit. Whether a live tunnel outlasts token expiry is unverified. Sources are
connection-info capabilities and llms-full.txt lines 374, 409 and 1080-1081.

The agent-browser image already contains a guest-readable port-agent credential. Live result
39 checked its existence, mode and structure without retaining its value. Guest code can
publish unauthenticated ports. Release now removes ports created at or after ibx.claim.start,
whatever their name, plus older ibx-prefixed ports. Renew leaves start unchanged. Older
non-ibx ports remain with a warning. A process left running can republish after release.
Doctor audits GET /v1/ports for unreserved pool boxes. Sources are PublicPort.createdAt,
securitySchemes.portAgent and llms-full.txt lines 407 and 2340.

The prose docs say public visits wake an idle-paused box and wait, but the spec still says
503. Live results 10, 20 and 33 did not test this. ibx documents the conflict and does not
claim either behavior was observed. Manual pauses and stops still answer 503.

## Platform and documentation

New free orgs normally get one sandbox and five snapshots; this pool has a grandfathered
five-box limit. Read usage limits rather than hard-coding that exception. Keys reach all
boxes of their org, not other orgs. Paid workspaces form another boundary. Sources are
info.md lines 84-86 and 118-134, llms-full.txt lines 1229-1235 and live results 1-2.

CLI 0.7.1 includes exec streaming, background/jobs, argv, run, push/pull/cp, max-run, wake,
logs, ps, restart, fork, port-forward and Secrets. SDK 0.5.3 was used for comparison. Official
jobs hold no lease and bypass ibx's reservations and pool guard. Activity leases remain
specified only in OpenAPI. Whole-map metadata updates from raw PATCH, SDK setMetadata and
dashboard labels replace pool membership and reservations, so the docs now warn to preserve
those keys. Sources are the PATCH description, SDK README line 142 and CLI reference lines
1011-1140. The sandbox NODE_OPTIONS preload remains documented in field notes section 11.

## Implemented plan scope

All six must items and eleven should items are covered by code, mock regressions or the
corresponding documentation changes. The public-URL should item is implemented as an explicit
uncertainty; a live probe is outside this task's authorization.

The selected could items are also covered. Live-test definitions check both available run
budget and the actual boxes claimed, and the leases of their own two boxes. Metadata
replacement is documented, and Vault 403 and
residue checks fail closed. Live tests were edited but not run. Installation remains bash 3.2
compatible; no timer configuration or installed command was changed.

The optional SSE item was started only after the required suites were green. It is an opt-in
exec transport, with buffered exec left as the default. Live result 16 had already confirmed
stdout/stderr/exit events, 15-second ping comments and 1.5 MiB of uncapped output. The parser
shares pre-start refusal classification, but any in-stream error or missing exit event is
terminal. A dropped connection kills the command; partial output remains visible. The mock
and offline regressions cover UTF-8, uncapped output, timeout fields, pre-start refusals,
started errors, transport loss and parent-only interruption. The real-mode mock streams live
processes and watches the connection; a cancellation regression verifies the process group dies before a delayed write.
An independent mock watchdog enforces the command timeout even if a slow reader blocks an
output write; socket writes also have a deadline. The slow-reader regression leaves the
response body unread and verifies that no delayed side effect survives the command deadline.
Key-bearing shell variables clear inherited export attributes, so an exported variable with
the same name cannot put the API key back into a child environment.

## Plan inventory after recovery

The working-tree audit found implementations for every required item. No required item was
not started. The remaining work was final verification of the SSE mock's timeout under a
stalled reader, static checks and both complete offline suites. A public-URL wake probe is
excluded by the instruction to avoid the real API.

| Priority | Plan item | Status | Implementation evidence |
|---|---|---|---|
| Must | Keepalive cooldown is not a failure | Done | Known and raced cooldown branches; platform regressions |
| Must | Exec refusal classification and never retry partly-run commands | Done | Shared auth classification, bounded safe waits, user host_unavailable refusal |
| Must | Guard Org Secrets | Done | secrets_state, pool/claim/doctor checks, JSON risk field, mock fixtures |
| Must | Max-run awareness | Done | Cooldown waits, candidate budget ordering, pause/cooldown output |
| Must | Replace the ignored-idle-setting bug story | Done | Plan-specific settings and dated history; obsolete feedback removed |
| Must | Clean up guest-published ports | Done | Stable claim.start, timestamp comparison, renew/release regressions |
| Should | Official put/get routes | Done | Raw bounded file API, digest verification, explicit older-server fallback |
| Should | Auth errors and safe hints | Done | Shared fatal record survives subshells; auth JSON regression |
| Should | Account-wide billing refusals | Done | account_blocked stops candidates immediately and preserves server guidance |
| Should | Doctor plan, budget and access audits | Done | Concrete org route, token/port/Secret checks and timer visibility |
| Should | Prompt interruption and accurate messages | Done | Main-shell curl wait, cleanup, command-specific signal regressions |
| Should | ExecResult fields | Done | UTF-8, signal, disk and timeout warnings preserve remote status |
| Should | Current mock API | Done | Machine, lifecycle, Secrets, file and token routes; retry metadata |
| Should | Private forward | Done | Shared SSH pinning/revocation, loopback listeners and capability check |
| Should | Current exec facts | Done | Shared request limit, background writers and exec-only pkill findings |
| Should | Platform documentation | Done | CLI/SDK table, limits, org boundary, fork and lifecycle guidance |
| Should | Public-URL wake uncertainty | Done for authorized scope | Contradiction documented throughout; live probe not run |
| Selected could | Live-suite run budget and own-box keepalive checks | Done | Preflight and actual-claim guards tested offline; live definitions updated |
| Selected could | Whole-map metadata warning | Done | README and trust-model warn to preserve membership and reservation keys |
| Selected could | Vault 403 and residue | Done | Fail-closed inspections include applied/kept files and actionable 403 advice |
| Optional could | SSE exec | Done | Opt-in parser, real process streaming, disconnect and stalled-reader regressions |

## Verification after recovery

The final plain offline suite passed 968 assertions with zero failures in 629 seconds.
The final MOCK_EXEC=real suite passed 1,022 assertions with zero failures in 652 seconds.
Both ran on a separate Linux host with executable tmpfs scratch files after disk I/O stalls
caused the normal scratch directory to exceed the unchanged test watchdogs. The helper,
mock and test scripts matched the working tree by SHA-256 throughout these final runs.

Shellcheck 0.11.0 produced no warnings and exited 0. The originally supplied executable path
was absent, so verification used the pinned shellcheck-py 0.11.0.1 package, whose binary
reports Shellcheck 0.11.0. Each shell file passed bash -n, the mock passed Python AST parsing,
Markdown links resolved locally, and git diff --check passed. The installer was unchanged.

The stalled-reader regression failed against the previous mock and passed after the
independent timeout watchdog was added. The complete real-mode run includes that regression,
real incremental SSE output, process-group cancellation and the existing transfer, locking,
JSON, credential and installer checks. The live suite was edited but never run, and this
implementation made no real API calls.

## Deferred and rejected options

- Server-side pool filters and name refs are deferred. The five-box pool gains little, and
  client-side pool checks remain the access guard.
- Desktop-link revocation is deferred. ibx never creates those links; this task did not select
  that could item. The bearer-link risk remains documented.
- A detached-job wrapper is deferred. The setsid recipe works without adding job management.
- Workspace-only pool keys are rejected for this release. New workspaces require a paid plan,
  free boxes cannot be moved into them, and treating Vault 403 as empty would fail open.
- Signed upload URLs are rejected. They are reusable bearer credentials with overwrite access;
  direct guarded PUT is sufficient.
- Sending argv instead of quoted cmd is rejected. It would change shell builtins and VAR=x
  behavior, while current quoting round-trips and exec no longer self-matches pkill.
- Fork is rejected for pool recreation. It cannot pass --no-vault or --secrets none. Interactive
  rm examples retain their confirmation prompt.
- Delegating pool jobs to official background/jobs is rejected. Those commands hold no lease
  and bypass ibx's reservations and guards.
- Speculative rate_limited, exec 402 and unknown_field branches are omitted. Exec documents
  quota_exceeded, billing refusals belong to lifecycle operations, and unknown_field belongs
  to creation, which ibx does not perform.
- Changing keepalive --all is rejected. It promises every pool box. The user separately
  switched the timer to reserved-only keepalive on 2026-10-27.
- Public-URL wake probes, key creation, lifecycle setting changes and any other live mutation
  are outside this implementation's authorization.
