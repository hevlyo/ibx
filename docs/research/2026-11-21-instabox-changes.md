# Instabox changes checked on 2026-11-21

This note updates [the 2026-11-06 note](2026-11-06-instabox-changes.md), which is the baseline.
It covers what changed at instabox between 2026-11-06 and 2026-11-21 and whether the unreleased
branch `fix/instabox-november-terms` still fits. It also answers whether ibx needs a new release
before the free-plan change on 2026-12-01. Four sweeps (product and API, branch fit, legal,
announcements) each went through an independent verification pass. Claims the verifier found
wrong were dropped or corrected. Overstated claims are softened below. Claims that existed
before the baseline are labeled as such, and claims nobody could check are marked UNVERIFIED. No
authenticated API route was called, ibx was not run against the service, and no pool box was
used. No credentials or personal identifiers are copied.

## Scope and sources

The primary sources were the [OpenAPI spec](https://api.instabox.sh/v1/openapi.json) (fetched
2026-11-21 between 16:23Z and 16:44Z), [llms-full.txt](https://instabox.sh/llms-full.txt)
(Last-Modified 2026-11-21T15:29Z), [llms.txt](https://instabox.sh/llms.txt),
[changelog.md](https://instabox.sh/changelog.md), [blog.md](https://instabox.sh/blog.md) and
their entries, and the docs under `/docs/*`. Legal text came from the live site bundle
[df1b260e9739e21b](https://instabox.sh/assets/df1b260e9739e21b/js/app.js), which embeds
/terms, /privacy and /subprocessors along with the plan config. Other sources were the new
[status page](https://status.instabox.sh/) and its [RSS feed](https://status.instabox.sh/feed.rss),
`npm view instabox`, `npm view @insforge/instabox-sdk`,
[PyPI](https://pypi.org/pypi/instabox-sdk/json), the unauthenticated GitHub API for the InsForge
org and the [instabox-cloud App](https://api.github.com/apps/instabox-cloud), and the
client-rendered [Vanta Trust Center](https://app.vanta.com/insforge.dev/trust/9dxtxcntvvv5ow2tx7e4dm).

The history rests on site bundles that archive.org captured after the baseline. These embed the
docs, legal text and plan config:
[2026-11-07](https://web.archive.org/web/20261107154924id_/https://instabox.sh/assets/42684b9d0b320259/js/app.js)
(all legal pages "November 6, 2026"),
[2026-11-12](https://web.archive.org/web/20261112000551id_/https://instabox.sh/assets/744e2c5c1280417e/js/app.js),
[2026-11-13](https://web.archive.org/web/20261113100842id_/https://instabox.sh/assets/6814f7b44b29d58e/js/app.js)
and
[2026-11-18](https://web.archive.org/web/20261118045445id_/https://instabox.sh/assets/e59675d239e8e4c9/js/app.js).
One archived docs page helps with dating:
[auto-pause, 2026-11-08T12:42Z](https://web.archive.org/web/20261108124255id_/https://instabox.sh/docs/machines/auto-pause).
archive.org holds no OpenAPI capture after 2026-10-14 and no llms-full.txt after 2026-10-27, so
an API item counts as "new" here only if it is absent from the 2026-11-07 bundle, from the
baseline note, or from the strings in CLI 0.8.201. The CLI binaries were searched for strings
and never run. A local copy of the spec dated 2026-10-27 was used to rule out false positives.
Downloads were kept as untrusted data in fresh directories under /tmp and never executed.

The spec changed while it was being read: it had 135 paths at 16:23Z and 136 at 16:44Z, after
`GET /auth/notice` (a sign-in refusal notice, no auth) appeared. Any count below is tied to its
timestamp.

The changelog is not a complete record. The legal changes of 2026-11-09 and the change to the
free-plan runtime have no changelog or blog entry. They were found only by diffing the bundles.
Future checks should diff the bundle text, not just read the changelog.

## What changed since 2026-11-06 (ranked)

Ranked by effect on the ibx pool, then on trust.

1. Dynamic runtime is now the documented rule for every free run.
   [auto-pause.md](https://instabox.sh/docs/machines/auto-pause.md#runtime-on-the-free-plan)
   says: "On the free plan the service sets the maximum runtime, and you cannot change it. Each
   run starts with 120 minutes." The OpenAPI `MaxRunMinutes` schema agrees: "each run starts at
   120 minutes and grows with use up to 480 ... A free machine that is not running reports 480,
   the most a run can last. The response reports the current limit from runStartedAt; it can
   change during the run." [limits.md](https://instabox.sh/docs/account/limits.md) says "Free:
   each run starts at 120 minutes and grows while the machine is in use, up to 480 minutes". Only
   the condition is new. The growth steps (+120 for 5 or more busy minutes in the last 30, +30
   for 1 to 4), the rule that leases and wake calls do not count as use, and the 480 cap were
   all quoted in the baseline. What is gone is "Dynamic runtime, when enabled" and the CLI
   reference's "fixed at 480". The archived auto-pause page still said "Free machines default to
   [480] minutes ... Dynamic runtime, when enabled" at 2026-11-08T12:42Z. The site config gained
   `freeRunWindowMinutes:120`, absent on 2026-11-07, by the bundle archived 2026-11-13. So the
   change landed between those two captures. No announcement covers it.

   The new risk is narrow. A job that waits with no CPU and no traffic is idle and pauses after
   30 minutes anyway, as before. What changes is a run that is busy enough to avoid the idle
   pause but not busy enough to count as "use": CPU under 0.25 vCPU with no commands, file
   access, port requests or terminal and SSH sessions. Such a run, or a claimed box used only
   lightly, now ends at 120 minutes instead of 480. Whether this account behaves this way live
   is UNVERIFIED, because reading `Machine.maxRunMinutes` on a running box needs an
   authenticated call.

2. The terms changed twice, and §2(e) did not. Every bundle shows the "Last updated" dates:
   all three legal pages read "November 6, 2026" on 11-07 and "November 9, 2026" on 11-12. By
   11-18 the terms read "November 16, 2026", and privacy and subprocessors stay on November 9.
   The free-plan paragraph in §2(e), "(ii) generate artificial activity, such as scheduled
   pings, activity leases renewed from outside the Sandbox, or busy loops, to keep a Sandbox
   from pausing after inactivity, or pause and resume a Sandbox to reset its maximum runtime",
   is byte-identical in all four bundles and the live one (same md5, 774 characters). Details
   are in the legal section.

3. A new error code, `restore_failed` (HTTP 500, not retryable). llms-full.txt (Errors) says:
   "A resume (`instabox resume`, or a request that wakes the sandbox) could not restore its
   suspended memory on its host. Its processes are lost; the sandbox is stopped with its files
   kept. The operation's error and the sandbox's lastError have this code." The fix: "Start the
   sandbox (`instabox start`): it boots from its disks." The code is absent from the 2026-11-07
   bundle's full error table, from the 2026-10-14 spec and from CLI 0.8.201. It is present in
   the current `Error.code` enum. A failed restore could probably happen before it had a name.
   What is new is the documentation, not necessarily the failure. How often it happens is not
   documented. The ibx impact is under Fit of the unreleased branch.

4. A new error code, `account_disabled` (HTTP 403, not retryable).
   [errors.md](https://instabox.sh/docs/reference/errors.md#account_disabled): "An
   administrator disabled the account. It can still sign in, but only to download its own data:
   every other route answers this." It does not appear in the bundles archived on 11-07, 11-13
   and 11-18, so it probably appeared after 2026-11-18.

5. A public status page went live on 2026-11-21
   ([changelog](https://instabox.sh/changelog/status-page.md),
   [docs](https://instabox.sh/docs/reference/status.md)): "Check status.instabox.sh when
   requests start to fail. Incidents are posted automatically within minutes, and you can
   subscribe to updates." Email and Slack subscriptions "only get the incidents a person on our
   team posts". The baseline found that `status.instabox.sh` did not resolve. Now it answers 200,
   and `/feed.rss` answers with `application/rss+xml`. The site's status link moved from
   instabox.instatus.com (11-12 and 11-13 bundles) to statuspage.incident.io/instabox (11-18) to
   status.instabox.sh (live). Most components were created on 2026-11-14 and 2026-11-15. "Create,
   Delete, Pause & Resume" was created on 2026-11-18T20:43Z
   ([summary.json](https://status.instabox.sh/api/v2/summary.json)). The feed holds 18 resolved
   incidents from 2026-11-15 to 2026-11-20. Six touch the operations claim depends on: three
   "Pausing or resuming boxes failing" (feed times 11-15 21:25Z, 11-17 16:21Z, 11-18 00:07Z) and
   three "Resuming boxes slow" (11-16 00:05Z, 11-17 17:08Z, 11-17 18:17Z). The other 12 are "CI
   jobs slow to start". Feed times may mark the last update rather than the start. Because most
   of these incidents happened before the pause/resume component was created, its 90-day uptime
   will not show them. The page was "All Systems Operational" when fetched.

6. Quiet exec requests now have an optional keepalive header. The OpenAPI `POST
   /v1/machines/{id}/exec` says: "Keepalive: without streaming, a quiet request can be closed by
   a proxy or NAT on the way (seen at about 270 s). Send `X-Instabox-Exec-Keepalive: 1` and,
   once the command has run 15 s, the server sends `200` and then a newline every 15 s ... An
   error after the `200` went out is the body `{"error": Error, "status": N}` ... The CLI
   sends the header." The string is absent from the 2026-10-14 spec and CLI 0.8.201 and present
   in CLI 0.8.341. It is not in llms-full.txt. Whether the path from a client to api.instabox.sh
   really gets cut at about 270 s is UNVERIFIED.

7. The free template list grew. The free plan "creates from agent-browser, android, omarchy, ci
   only" ([limits.md](https://instabox.sh/docs/account/limits.md)). The bundle's `freeTemplates`
   went from `[agent-browser, android, ci]` (11-07) to include `omarchy` (11-13). The
   [omarchy post](https://instabox.sh/blog/omarchy.md) (2026-11-08) describes an Arch Linux
   desktop with Hyprland on "Every plan, free included". limits.md adds that omarchy has "no
   computer-use agents". On the free plan a `ci` box can now be created only by GitHub Actions
   jobs (`403 template_job_only`, absent on 11-07). ibx creates no boxes, and recreating a pool
   box still means agent-browser.

8. Trust and hosting claims changed. On 2026-11-09 the privacy policy and /subprocessors added
   Latitude.sh, a second US host. On 2026-11-10 a [Trust Center
   post](https://instabox.sh/blog/trust-center.md) claimed SOC 2 Type II for InsForge, but the
   Trust Center itself says the audit does not cover InstaBox. Details are in the legal
   section.

9. Paid-only launches, none reaching the free pool: per-box cost breakdown
   ([blog](https://instabox.sh/blog/usage-by-box.md), 2026-11-09, `GET /v1/usage/machines`);
   macOS 26 boxes on whole Apple-silicon Macs with a 24-hour minimum lease (2026-11-12,
   `--accept-24h-minimum`, `minimum_lease_required`); faster creation from your own snapshot
   (2026-11-15, current agent-browser template at the same size only); the minimal template
   (2026-11-16, "Pro and up"); H100 GPUs (2026-11-17) and T4 and A100 (2026-11-18) with a GPU
   queue (`/v1/gpu-queue`, `queue_limit`, `queue_expired`); snapshots that create machines only
   at their source size (2026-11-17, every plan); warm CI runners from a snapshot (2026-11-21,
   which "needs a paid plan and a private repository with Run workflows from fork pull requests
   turned off"); and Rakazo integration (2026-11-17, needs an API key). All dates come from
   [changelog.md](https://instabox.sh/changelog.md) and blog.md. On a paid plan, macOS boxes
   could one day cover ibx's macOS CI leg, at the 24-hour lease minimum. The live footer
   advertises "Multi-OS (Linux, Android, macOS, Windows) and GPU sandboxes". The OpenAPI already
   models Windows templates (`Template.os` enum `macos`, `windows`), but there is no Windows
   changelog entry or page.

10. New InsForge repositories. [instabox-bridge](https://github.com/InsForge/instabox-bridge)
    (created 2026-11-19, v0.1.0 and v0.1.1 on 11-20, a prerelease on 11-21) is a macOS and
    Windows tray app that sets up T3 Code or cmux on a box. It ships an in-box activity probe:
    "instabox-guest-agent runs it as the machine user (UID 1000) with a 5 s timeout and reads
    one JSON line: {"busy": bool, ...}"
    ([t3-probe](https://raw.githubusercontent.com/InsForge/instabox-bridge/main/src-tauri/assets/t3-probe)).
    This in-box "busy" signal does not appear in the public docs. It might one day be a
    sanctioned in-box alternative to external leases. ibx should not build on it unless
    instabox documents it or confirms it is allowed on the free plan.
    [instabox-integrations](https://github.com/InsForge/instabox-integrations) (created
    2026-11-19) holds adapters for LangChain Deep Agents, Hermes Agent and Dify, plus an MCP
    Registry entry. Every adapter needs an API key. Neither repository affects ibx.

11. Client versions. The npm CLI `instabox` went from 0.8.201 (2026-11-07T02:09Z) to 0.8.341
    (2026-11-21T16:07Z), 140 releases, with up to 17 on 2026-11-20 and `latest` equal to
    `staging`. The TypeScript SDK `@insforge/instabox-sdk` went from 0.7.1 to 0.8.0
    (2026-11-10T01:44Z) and 0.9.0 (2026-11-11T05:39Z). Its repository field now names
    `github.com/InsForge/instabox-sdk`, not `InsForge/instabox`. The PyPI `instabox-sdk` went
    from 0.4.0 to 0.5.8 (2026-11-21T02:16Z, Python >=3.9) and still points to
    `InsForge/instabox`. Both GitHub repositories answer 404, so the client code still has no
    public source. The GitHub App `instabox-cloud` is unchanged (updated 2026-10-28,
    `administration: write`, `organization_self_hosted_runners: write`, events `workflow_job`).
    ibx calls the REST API with curl, so CLI churn does not touch it. The pace is still a reason
    to treat the preinstalled CLI in boxes as untrusted and to pin versions wherever it is
    installed.

12. General availability is UNVERIFIED from first-party text. A [post by an instabox
    co-founder](https://x.com/hanghuang_/status/2120909505290756137) on 2026-11-12T16:00Z reads
    "We launched in beta <1 month ago, and today, users have created 1M+ boxes". Its visible text
    does not say "GA", "out of beta" or "no waitlist". That wording comes from a third-party
    account. No instabox.sh changelog or blog entry announces GA. The account's own X timeline
    returned 429, and the Discord announcement channel needs a login, so neither was read.

Other API changes. The spec has 135 or 136 paths and 208 schemas, up from 129 paths at the
baseline. With high confidence, these are new and match dated launches: `GET /v1/gpu-queue`,
`DELETE /v1/gpu-queue/{id}` and `GET /v1/usage/machines`. `POST /v1/orgs/move-personal`,
`POST /v1/orgs/{id}/billing/move-personal` and `POST /v1/orgs/{id}/billing/credits/subscribe`
are likely new. At least one of them may have been among the baseline's org billing routes.
`Machine` gained `queue` (GPU queue), `lease` (the Mac lease of a macOS box, not an activity
lease) and `suspendable` (false on macOS). Besides `restore_failed`, `account_disabled` and
`template_job_only`, the new error codes include `queue_limit`, `queue_expired`,
`minimum_lease_required` and `logs_unavailable`. None of this touches the exec, file, lease,
history or wake routes ibx uses. `PUT /v1/me/terms` and `Me.termsVersion` look new but are not:
both were in the public spec on 2026-10-27. No new abuse reason code was added for resource
farming or key searches. The reason codes remain `abuse_cpu`, `abuse_egress_blocklist`,
`abuse_network_flows`, `abuse_pool`, `abuse_proxy` and `abuse_scan`.

Unchanged since the baseline, all checked on 2026-11-21:

- The `tiers.free` config is byte-identical between the 11-07 bundle and the live one:
  `maxMachines:1, maxSnapshots:5, maxStoredGiB:200, maxDiskGiB:20, freeEgressGiB:100,
  startsPerMinute:3, maxExecs:32, maxMembers:3`.
- The idle pause is fixed at 1800 s on free.
- The max-run cooldown table (5-20, then 60-75, then 120-135 minutes) and its reset rules are
  identical in both bundles. An abuse lock keeps the count. One sentence ("A new or forked
  machine starts at the 1st step; restoring a machine in place keeps its count") may be new.
  That could not be checked, and it has no effect on ibx.
- `429 rate_limited` with `Retry-After` and `retryAfterSeconds` is unchanged.
- `402 early_allowance_ended` is unchanged: 2026-12-01 00:00 UTC, the email on 2026-11-26, and
  "the one that stays running is the most recently active". The "instabox suspend" fix text was
  already in the 11-07 bundle.
- These fields are unchanged: `OrgLimits.earlyAllowanceEnded` and `freeSandboxes`,
  `Machine.free` and `earlyAllowanceEnded`, `cooldownReason` (still without `abuse_proxy`, which
  errors.md lists), the `MachineAbuseLock` shape, `noHistory` and `historyCommand`, `oomKilled`
  and `oomKill`, and `operation_conflict` with `operationId`.
- Exec history still keeps the newest 200 commands with 64 KiB per stream.
- Wake-on-use still holds the request up to 45 s.
- The activity-lease route is unchanged.

Not new, but newly noticed. errors.md documents `429 concurrency_limit`, retryable, for "too
many `exec` requests at once". The exec route and limits page say `429 quota_exceeded`. The
`concurrency_limit` text was already in the 2026-11-07 bundle. The wake docs give an SSH
connection through the gateway only 15 s before "machine ... is waking up". Whether that row
predates the baseline cannot be checked. `POST /wake` lists no 429 although wakes count as
starts. That is a documentation inconsistency only.

## Legal and privacy

The revision of 2026-11-09 was silent: no changelog, blog post or email that could be found. Its
dates rest on the "Last updated" strings and fall between the 11-07 and 11-12 captures.

- Privacy §2 and §12 and [/subprocessors](https://instabox.sh/subprocessors) add Latitude.sh:
  "bare-metal hosting for some of the machines you run, and storage for their disks and
  snapshots, in the United States", and in §12 "some machines and their disks and snapshots are
  in Latitude.sh data centers in the United States". The subprocessors entry reads "Bare-metal
  hosting and object storage for sandboxes (United States)". This explains the baseline's
  conflict between "AWS us-west-2" and "our own bare metal": some machines run on rented bare
  metal. It does not settle where a given pool box runs. Neither page says which machines,
  plans or templates go to Latitude.sh.
- Terms §7(g), new: "Customer will not store or process protected health information, as
  defined under the Health Insurance Portability and Accountability Act (HIPAA), using the
  Services unless Customer and InsForge have signed a Business Associate Agreement covering
  that use."

The revision of 2026-11-16 was announced
([changelog](https://instabox.sh/changelog/terms-acceptable-use.md)): "The Terms now ban
brute-force crypto key searches, and resource farming can be stopped without notice, like
mining. You accept the updated rules on your next dashboard visit."

- §3(a) adds "Searching for cryptocurrency private keys, seed phrases, or wallet addresses by
  brute force, including “puzzle,” bounty, and vanity-address searches."
- §3(g) changes "Cryptocurrency mining, scanning..." to "Cryptocurrency mining and resource
  farming (Section 3(a)), scanning ... may be stopped immediately and without notice". The ban
  on bandwidth-sharing, proxy-selling, "passive income", ad-viewing and reward-farming software
  was already in §3(a) on 2026-11-06. Only its enforcement without notice is new.
- Acceptance happens only in the dashboard. `PUT /v1/me/terms` is "Sign-in sessions only", and
  the spec's 76 error codes include no terms-related refusal. So API-key callers like ibx do
  not appear to be blocked before the user accepts. That remains UNVERIFIED until someone
  observes it.

Unchanged, from a sentence-level diff of the 11-07 text against the live text:

- the privacy policy's "automated and, at times, manual checks of the activity of running
  machines"
- the §3(g) monitoring sentence
- no training and no sale
- retention: 30 days after account deletion, backups up to 90 days, activity logs 12 months,
  usage 24 months
- the 30-day notice in privacy §10, and the "reasonable notice" clause in terms §11(b)
- §7(a) confidentiality, §7(c) authorization of sub-processors "through its Trust Center", §7(d)
  US location, and the §8 liability cap

There is still no customer DPA for InstaBox. [insforge.dev/dpa](https://insforge.dev/dpa) is
still dated June 20, 2026 and has zero hits for "instabox". The live bundle has zero hits for
LGPD, Brazil or Brasil. /dpa, /trust, /security, /acceptable-use, /aup and /legal on instabox.sh
still answer 307 to the homepage, and `/.well-known/security.txt` is still 404.

The sub-processor list is still incomplete. Google, named in privacy §2 for single sign-on, and
Mintlify, which serves the docs, are still missing. Neither is incident.io, which now hosts the
status page. No hardware provider is listed for the macOS and GPU machines launched after the
2026-11-09 update. They are paid-only, so this does not reach the pool.

Attestation. The Vanta Trust Center is not new: the same URL was linked on 2026-10-27 and the
baseline rendered it. New are the 2026-11-10 announcement, an InstaBox profile, a SOC 2 entry,
and footer badges that first appear in the 11-12 and 11-13 bundles: "InstaBox is built by
InsForge, Inc., which completed a SOC 2 Type II audit." The blog post adds "The report is
available on request" and does not state the audit's scope. The Trust Center does. One headless
render on 2026-11-21 showed: "InsForge completed a SOC 2 Type II audit of the InsForge Platform
covering April 22 to July 22, 2026. InstaBox launched after that period and will be included in
a future audit." So no SOC 2 report covers InstaBox yet, and the instabox.sh marketing
overstates its reach. The render was not repeated independently, so treat that scope as likely.
The badge names "InsForge, Inc." while the terms name "InsForge AI, Inc.". HIPAA is still
"controls aligned" with a BAA on request, with no third-party attestation. No ISO 27001,
pentest or bug bounty was found.

Verdict: none of the legal changes touches anything ibx does, and none relaxes the user's rules.
The pool rule set stays as the baseline left it: no credentials, sessions or personal data on
the boxes, US hosting, manual checks declared, no DPA and no LGPD terms. The 2026-12-01 change to
one free box at a time has no legal clause behind it. It appears only in the pricing FAQ and the
`early_allowance_ended` error doc, so the branch's handling rests on the API docs, not the terms.

## Fit of the unreleased ibx branch

Each assumption the branch makes, checked against the 2026-11-21 sources:

- No lease on free boxes and the keepalive timer off (Terms §2(e)): still valid. The clause is
  byte-identical through the 2026-11-16 revision. auto-pause.md now has a free-plan note: "On
  the free plan a lease keeps the machine from an idle pause, but it does not make the run
  longer". It is absent from the 2026-11-08 capture, but its content restates what the baseline
  already recorded. The docs still teach leases for silent tasks with no free-plan caveat, and
  the OpenAPI lease route has none either, so the docs-versus-terms conflict remains. The
  script's "(instabox Terms 2(e), 2026-11-06)" strings are correct as the date the clause was
  introduced. The docs could add "unchanged through the 2026-11-16 revision".
- `402 early_allowance_ended` as `free_limit`, with claim skipping the other free boxes: still
  valid. The date, eligibility wording, email date and fields are unchanged. What
  `OrgLimits.freeSandboxes` reads for this account before 2026-12-01 (1, or 5 as an override)
  is UNVERIFIED. The mock's `freeSandboxes: 5` is a guess. Also unchanged since the baseline:
  the advice "pause the running one and start it". The branch's message (around
  `skills/ibx/scripts/ibx:529`) tells agents to `ibx release` and let the box idle-pause, so a
  released box holds the only free slot for up to 30 minutes. That is a design choice the
  release should accept knowingly. Whether the boxes the service pauses at the cutover can be
  woken on use or need an explicit resume is UNVERIFIED.
- `429 rate_limited` waited out on start, resume and wake: still valid.
- `abuse_` prefix as `abuse_lock`: still valid. The prefix covers `abuse_proxy` and any future
  reason.
- `noHistory` for ibx's own execs, `historyCommand` for `ibx run` and `exec --tail`: still
  valid, with the same 4096-byte cut and the same rule that the two cannot be combined.
- `oomKilled` warning that never treats false as proof: still valid.
- `409 operation_conflict` during the wake hold, retried after the named operation: still
  valid.
- "Free max-run defaults to 480, dynamic runtime when enabled, not checked for this account":
  changed. Every free run starts at 120 minutes. The stale wording is at README.md:228-230,
  skills/ibx/SKILL.md:200-201, skills/ibx/references/keepalive.md:71-77,
  skills/ibx/references/field-notes.md:50-55, skills/ibx/references/api-notes.md:177 and
  skills/ibx/references/recipes.md:288. The branch spec's F4 and the user's INSTABOX.md rule
  file ("com runtime dinâmico começa em 2 h") use the same conditional wording. INSTABOX.md is
  the agent's to keep current. Two code-facing messages follow from this. Claim's warning "has
  under 60 minutes left before its max-run pause" (`skills/ibx/scripts/ibx:2117`) will fire
  about an hour into any free run, although use may extend it. `ibx status` computes `pausesAt`
  as `runStartedAt + maxRunMinutes` (around lines 570 and 1918). On a running free box that is
  only the current limit, which can grow. On a paused free box, `maxRunMinutes` reads 480 and
  `pausesAt` may be stale or in the past. How that looks live is UNVERIFIED. Both messages
  should say the limit may grow.
- Error classification: incomplete for two new codes.
  - `restore_failed`. In `ensure_running` (around lines 730-777), an idle-paused box gets
    `POST /wake`, which returns a Machine, not an Operation. A restore failure there comes back
    as an HTTP error and returns 1. A user-paused box goes through `wait_op`, whose failed-op
    branch also returns 1 (`wait_op ... || return 1` near line 755). Either way the command
    fails. The next command finds the box `stopped`, starts it, and `fresh_boot_check` warns
    that it came back with a fresh boot. So a detached job is killed by the server's failure,
    not by ibx, and the loss is reported one command later. The concrete gap is an exec or file
    transfer that wakes the box itself and gets 500 `restore_failed`. It falls into the default
    branch (around lines 1082-1085), which says the command "may or may not have run". The
    docs imply it did not run. Whether exec returns this code directly, rather than a 409, is
    UNVERIFIED. The failure mode is safe: claim moves on and exec does not retry.
  - `account_disabled`. `api_refusal` (lines 485-492) does not classify it, so it is treated
    as a per-box failure. Claim may walk every box and report a misleading per-box error, and
    exec reports "may or may not have run" for a refusal that came before anything ran.
- `429 concurrency_limit` on exec or file transfer: a gap that predates the baseline. ibx
  retries only `quota_exceeded` (around lines 1053-1059 and 1144-1151), which is what the exec
  route's own contract names. ibx rarely nears 32 concurrent requests. Treating
  `concurrency_limit` with `retryable: true` like `quota_exceeded` is harmless hardening.
- Long quiet execs: a gap that the new keepalive header exposes. ibx accepts `-t` from 1 to 600
  seconds (around lines 2285-2287) and sends no keepalive header. A quiet synchronous exec that
  runs between about 270 and 600 seconds could be cut on the way and surface as "may or may not
  have run". Adopting the header means handling a 200 whose body is `{"error": ..., "status":
  N}`, which ibx would otherwise read as an ExecResult. That is a follow-up, not needed for
  2026-12-01.
- Wake through `ibx ssh`: still valid. ibx runs `ensure_running` before it creates the SSH
  token (around lines 2444 and 2454), so the gateway's 15 s hold does not apply.
- `Machine.lease`: safe. It now means the Mac lease of a macOS box, and ibx never reads it.

Nothing new since 2026-11-06 breaks the branch's protocol handling, and nothing makes its main
changes unnecessary.

## Recommendation for ibx

Release the branch, before 2026-12-01 and preferably before the email on 2026-11-26. The reasons
the branch exists are still in force: §2(e) is unchanged, and the one-free-box limit starts on
2026-12-01 00:00 UTC. Without the release, the published v0.3.0 still treats
`early_allowance_ended` as `account_blocked` and still renews leases on free boxes. The branch
adds new error codes and behavior under "Added", so 0.4.0 fits its own changelog convention
better than 0.3.1. The version is the user's call.

Before tagging, in order:

1. Required: fix the dynamic-runtime wording at the six places listed above (each free run
   starts at 120 minutes, and only real use extends it to 480). Reword claim's "under 60
   minutes left" warning and the `pausesAt` and run-budget output in `status` and `doctor` to
   say the limit can grow. Detached jobs should expect a first window of 120 minutes. This is a
   docs and message change with no protocol change, and the offline tests that match those
   strings need updating.
2. Recommended, small and testable with the mock: classify `account_disabled` as
   `account_blocked`. Treat `restore_failed` from a wake, resume, exec or file transfer as "did
   not start, processes lost, start the box", with a regression test in tests/offline.sh and
   tests/mock_api.py for each path. Following the rule to fix the whole class, handle
   `concurrency_limit` (retryable) like `quota_exceeded` in the same pass.
3. Recommended docs:
   - In trust-model.md:89, add Latitude.sh next to AWS us-west-2, and say a box's provider is
     not stated.
   - Note that the SOC 2 Type II claim does not yet cover InstaBox.
   - Note the PHI ban without a BAA.
   - Add crypto key, seed and vanity-address brute force, and resource farming that can be
     stopped without notice, to the SKILL's list of workloads that trigger abuse handling.
   - Point agents and `doctor` hints to https://status.instabox.sh (feed
     https://status.instabox.sh/feed.rss) when API calls fail repeatedly.
   - Say §2(e) is unchanged through the 2026-11-16 revision.
   - Tell agents to use `--stream` or a detached job for quiet commands longer than about four
     minutes.
4. Later, not needed for 2026-12-01: adopt `X-Instabox-Exec-Keepalive` with handling for error
   bodies after a 200. Show `uname -r` in doctor (carried over from the baseline).

Outside the repository: update the max-run sentence in the user's INSTABOX.md. The user should
accept the 2026-11-16 terms on the next dashboard visit, even though no API gating is
documented. The pool-model decision for 2026-12-01 (one runnable free box, a paid plan, or
retiring the pool) is still the user's and is due by 2026-11-26.

## Open questions

- Whether an account that has not accepted the 2026-11-16 terms gets refusals on API-key calls.
  The spec documents none.
- How often `restore_failed` happens, whether exec or file calls return it directly, and whether
  any part of such a command ran.
- Whether the server sends `429 concurrency_limit` or `quota_exceeded` for too many concurrent
  execs. The docs contradict each other.
- Whether the path from a client to api.instabox.sh cuts quiet exec responses at about 270
  seconds.
- What `OrgLimits.freeSandboxes` and `Machine.maxRunMinutes` read for this account before and
  after 2026-12-01. Reading them needs an authenticated call.
- Whether the boxes the service pauses at the 2026-12-01 cutover wake on use or need a resume.
- Which machines run on Latitude.sh rather than AWS, and who hosts the macOS and GPU machines.
- Whether the 2026-11-09 privacy change counts as material under the 30-day notice in §10, and
  whether customers were emailed about either revision.
- Whether the in-box activity probe that instabox-bridge uses is supported for third-party use,
  and on the free plan. Only instabox can answer.
- Whether the gateway's 15-second SSH hold and the cooldown sentence about new or forked
  machines predate 2026-11-06.
- Whether InstaBox is officially out of beta. No first-party text says so.
- What the SOC 2 report contains and when InstaBox will be in scope.
