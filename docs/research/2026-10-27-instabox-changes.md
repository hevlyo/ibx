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
machine-not-found share a code. The user-only IBX_ALLOW_SECRETS requires proxy Secrets
selected by name and scoped to named hosts; `all` remains refused because it includes future
Secrets. It never permits env delivery, unknown delivery kinds or guest residue. The skill forbids agents to set it.
Doctor reads org metadata, warns for Secret names, and fails for env or unknown delivery and
for wildcard hosts, including a proxy Secret whose hosts are omitted or empty (SecretHosts:
that means `["*"]`). In-box checks print only
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

On box-5 on 2026-10-27, the agent-browser image contained a guest-readable port-agent
credential. Live result 39 checked its existence, mode and structure without retaining its
value; other boxes were not checked. Guest code can
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

CLI 0.7.1 includes exec streaming, background/jobs, argv, run, push/pull/cp, wake,
logs, ps, restart, fork, port-forward and Secrets. Its CLI reference (llms-full.txt lines
1011-1140) lists no max-run command, while the skill bundled with the CLI package shows
`instabox max-run BOX N` for paid boxes; SDK 0.5.3 has no max-run setting. The README
therefore names only the API for max-run. Official jobs hold no lease and bypass ibx's
reservations and pool guard. Activity leases remain specified only in OpenAPI. Whole-map
metadata updates from raw PATCH and SDK setMetadata replace pool membership and reservations,
so the docs now warn to preserve those keys; no source says the dashboard's label editor does. Sources are the PATCH description, SDK README line 142 and CLI reference lines
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

## Decisions from the review of the first 0.3.0

Two clean-context reviews of the first 0.3.0 commit found these; the choices and why:

- Unreadable dates. The jq date helper returned nothing, not null, for a date it could not
  parse, which dropped whole rows. It now parses every RFC 3339 offset and returns null
  otherwise. A cooldown ibx cannot read makes claim skip the box (fail closed), while
  keepalive still asks for the lease and lets the server refuse it: skipping would let a held
  box pause idle over a parsing problem, and a refused lease costs nothing.
- Keepalive exit status. `max_run_disabled` is a skip like a cooldown, and so is a billing
  block (402). The lease route does not list 402, but it wakes an idle-paused box first and
  wake does, so a running box later in the list still needs its lease: keepalive goes on. A
  billing block alone leaves the status at 0: install.sh's unit has Restart=on-failure,
  RestartSec=60 and StartLimitBurst=3, and repeating it a minute later cannot help.
- Claim start. Ports' createdAt is server time, so `ibx.claim.start` stores the `updatedAt`
  of the claim's PATCH reply, with a second metadata write. The spec does not say whether a
  metadata PATCH bumps `updatedAt` (it says it does not bump `revision`), so ibx uses it only
  when it moved past the value read just before the PATCH, and keeps its own clock otherwise:
  an old `updatedAt` would make release remove ports created before the claim. The HTTP Date
  header was rejected because its one-second resolution misorders ports created in the same
  second, which the offline tests do.
- Org Secrets that cannot be inspected make claim exit 125 (API failure), not 75; a busy pool
  and a broken inspection need different reactions from an agent.
- In `--stream` mode only a 4xx reply with an error envelope (`.error.code` a string)
  establishes that the command did not run. Every 503, retryable or not, says "may have run":
  the exec route uses `host_unavailable` both for dial failure and for an API restart that
  kills partly-run work. A 4xx HTML page, a 2xx cut off, a 500 or a gateway's page is also
  ambiguous. Quota, cooldown and not-running refusals remain safe to wait out.
- The mock's exec answers `409 machine_not_running` for an idle-paused box, as the exec route
  says, although the spec's lifecycle text and the prose docs say exec wakes it. ibx handles
  both, and only the 409 path needs a test.

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
