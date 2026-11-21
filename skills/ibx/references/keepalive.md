# Keepalive: idle pause, max-run and the paid-plan timer

A pool box pauses when it is idle and when it reaches its run limit. This file says when, what
ibx does about it on each plan, and how a user on a **paid** plan installs the optional
keepalive timer. Facts checked on 2026-11-06 against the [terms](https://instabox.sh/terms),
[auto-pause](https://instabox.sh/docs/machines/auto-pause.md),
[errors](https://instabox.sh/docs/reference/errors.md), the OpenAPI spec and
[the research note](../../../docs/research/2026-11-06-instabox-changes.md).

**Free plan: no timer.** The terms, last updated 2026-11-06, say in §2(e): "On the free plan,
Customer may not: ... (ii) generate artificial activity, such as scheduled pings, activity
leases renewed from outside the Sandbox, or busy loops, to keep a Sandbox from pausing after
inactivity, or pause and resume a Sandbox to reset its maximum runtime." The timer renews a
lease from the user's computer every 15 minutes, which is that pattern. The terms make no
exception for real work held in the box. Enforcement (§3(g)) can pause or stop sandboxes,
block network, lower limits, or suspend or terminate the account. So on a free box
`ibx keepalive` sends no lease and prints
`NAME: free plan: renewing a lease from outside the sandbox is not allowed (instabox Terms 2(e), 2026-11-06), skipped`,
`ibx claim` sets no lease, and `ibx doctor` fails when a timer is installed and any pool box
is free. The docs have not caught up: the auto-pause page still suggests a lease for a silent
task, with no free-plan caveat. ibx follows the terms.

**Agents.** Installing or removing a timer changes the user's computer. Do not do it yourself.
Never work around idle pauses on a free box by other means either (section 1). If sandboxes
keep pausing under you, make the work restartable and tell the user.

## Contents

1. [Free plan: idle pause and wake](#1-free-plan-idle-pause-and-wake)
2. [Max-run and cooldowns](#2-max-run-and-cooldowns)
3. [Abuse locks](#3-abuse-locks)
4. [How activity leases work](#4-how-activity-leases-work)
5. [What ibx keepalive does](#5-what-ibx-keepalive-does)
6. [Paid plans: reserved only, or --all](#6-paid-plans-reserved-only-or---all)
7. [Install on Linux: systemd user timer](#7-install-on-linux-systemd-user-timer)
8. [Install on macOS: launchd agent](#8-install-on-macos-launchd-agent)
9. [Fallback: cron](#9-fallback-cron)
10. [Check that it works](#10-check-that-it-works)
11. [What to expect](#11-what-to-expect)
12. [Uninstall](#12-uninstall)

## 1. Free plan: idle pause and wake

- The free plan fixes idle pause at 30 minutes (`autoSuspendAfterSeconds` 1800; other values
  get 403). Paid plans allow 300-1800 in whole minutes, or 0 to turn it off. Only
  admin-granted manual lifecycle accounts use the 120-86400 range. See
  [field-notes.md](field-notes.md#1-idle-pause-and-plan-rules).
- "Idle means no coding agent working, no terminal or SSH traffic, and no CPU load. An exec, a
  file read, a public port request, or a task lease in progress keeps the machine busy. When a
  signal is missing or unclear, the machine counts as busy." A detached job that waits without
  CPU or traffic (on a network reply, a lock, a model API) can therefore be paused. A resume
  normally brings memory and processes back, but it can fall back to a fresh boot
  (`runtime.processesPreserved: false`), and open network connections can drop. Check the job's
  PID and `processesPreserved` after any wake, not only after a max-run pause.
- A box that paused itself (`autoSuspendedAt` set) resumes on use: an exec, a file read, an
  SSH connection, a request to a public port URL, or a wake. The request waits up to 45
  seconds for the resume, then gets a retryable `409 operation_conflict` naming the operation.
  So the next `ibx` command wakes it. When the resume outlasts the hold, exec, put and get wait
  until the box runs and send the request again (nothing had started); `ibx run` and `ibx job`
  fail and say nothing started, so run them again.
- A box paused or stopped by hand does not wake on use, and its public URLs answer 503.
- What is not allowed on a free box: renewing a lease from outside it, busy loops, scheduled
  pings or polls whose purpose is to prevent a pause, and pausing and resuming to reset the run
  limit. ibx does none of these. Real work, including polling a job when you need its result,
  is not artificial activity.

## 2. Max-run and cooldowns

- Max-run pauses a box after that many minutes of continuous running, even while it is busy.
  Leases and activity never extend a fixed limit.
- On the free plan the service sets the limit, and only an admin can change it. Since
  mid-November 2026 every free run starts with 120 minutes and "grows with use up to 480
  (commands, file access, port requests, terminal or SSH traffic and CPU load count as use;
  activity leases and wake calls do not)" (OpenAPI `MaxRunMinutes`,
  [auto-pause](https://instabox.sh/docs/machines/auto-pause#runtime-on-the-free-plan)). The
  2026-11-06 docs described the same extension rule for "dynamic runtime, when enabled": five
  minutes before the deadline, at least 5 work minutes in the preceding 30 extend it by 2
  hours, 1 to 4 by 30 minutes, none pauses the box. `maxRunMinutes` on a running free box is
  the current limit; a free box that is not running reports 480, the most a run can last. ibx
  shows `pausesAt` for a free box as a time that can move later.
- Paid boxes default to -1 (unlimited) and their users can change it. A limit of 0 pauses at
  once and refuses wakes with `409 max_run_disabled` once the cooldown ends.
- A max-run pause starts a cooldown; an idle pause has none. Until `cooldownUntil` every way
  of waking or starting the box is refused with retryable `409 machine_cooldown` (with
  `Retry-After` and `retryAfterSeconds`). Stopping, pausing or changing settings does not
  shorten it. On the free plan, back-to-back max-run pauses rest longer:

  | Max-run pause in a row | Cooldown |
  |---|---|
  | 1st | 5 to 20 minutes |
  | 2nd | 60 to 75 minutes |
  | 3rd and later | 120 to 135 minutes |

  The count starts over when a run ends with no cooldown owed (an idle pause, or a pause or
  stop by hand), or when a run starts 2 hours or more after the last cooldown ended. A paid
  box always gets the first step. Pausing a box by hand just before its limit would avoid the
  cooldown, but doing it to reset the run limit is what the terms forbid, so ibx never does it.
- Checkpoint long jobs, and do not read a refused poll as a dead job. After the wake, check
  the job's PID and `runtime.processesPreserved` in `ibx ls --json`.

## 3. Abuse locks

An automatic abuse check can pause a box and lock it for up to 24 hours. The box's
`cooldownReason` then names the check (`abuse_egress_blocklist`, `abuse_network_flows`,
`abuse_cpu`; the errors page also lists `abuse_proxy`), and a wake's `409 machine_cooldown`
carries the same value in `reason`. `abuseLock` gives when, a one-sentence `explanation`, the
finding in `what` and an `appeal` path (`instabox feedback` or support@instabox.sh). Whether an
appeal lifts a lock early is not stated.

ibx does not wait out a lock: commands fail at once with `abuse_lock` and print the
explanation and appeal, claim skips the box, `ls` shows an abuse lock instead of a max-run
cooldown, keepalive prints `NAME: abuse lock until TIME, skipped`, and doctor prints the lock's
`what`, `explanation` and `appeal`. A lock counts as a cooldown for the escalating count above.
Heavy network fan-out, port sweeps or sustained CPU that looks like mining can trigger one;
tell the user rather than retrying. The terms revised on 2026-11-16 also ban brute force
searches for cryptocurrency private keys, seed phrases or wallet addresses (puzzle, bounty and
vanity-address searches), and let instabox stop mining and resource farming without notice.
The free plan's §2(e), which forbids keeping a box awake from outside it, is unchanged
through that revision. When API calls keep failing, check https://status.instabox.sh: from
2026-11-15 to 2026-11-18 it recorded several "Pausing or resuming boxes failing" incidents.

## 4. How activity leases work

`PUT /v1/machines/{id}/activity-leases/{leaseID}` with `{"ttlSeconds": 30-3600}`
(spec: same route):

- It creates or renews the lease. If the sandbox is paused for idleness, it is woken first.
- While a lease is live, the sandbox does not pause for idleness.
- When the lease expires, a **full idle period starts**, so the pause comes about 30 minutes
  later.
- An explicit start, stop, suspend or resume invalidates every lease, so the next renewal
  creates it again.
- `DELETE` on the same path releases the lease and starts the idle clock without waking the
  sandbox.
- No route lists leases. The PUT reply's `expiresAt` is the only record.

ibx uses one lease ID, `ibx-keepalive`, with a 1-hour TTL, on paid boxes only (`Machine.free`
false or absent). With renewals every 15 minutes, the lease survives up to three missed runs.

## 5. What ibx keepalive does

```
ibx keepalive          # pool sandboxes that are reserved (held, not abandoned)
ibx keepalive --all    # every pool sandbox
```

- It considers only pool sandboxes (`ibx.pool` = `1`). A reservation older than
  `IBX_STALE_SECS` (default 24 h) counts as abandoned and is skipped unless you pass `--all`.
  Agents running jobs past 24 h use `ibx renew BOX`.
- A free box (`Machine.free` true) never gets a lease, with or without `--all`. It prints the
  free-plan line quoted at the top of this file and counts as a skip.
- **Running** paid sandboxes get the lease, and so do paid sandboxes **paused for idleness**
  (which wakes them). Sandboxes paused or stopped by hand, or in the middle of an operation,
  are skipped.
- Output is one line per sandbox: `NAME: lease until TIME`, `NAME: suspended, skipped`, or
  `NAME: FAILED {code, message, retryAfterSeconds}`. A max-run pause prints
  `NAME: max-run cooldown until TIME, skipped`; it sends no lease request if known in advance.
  An abuse lock prints `NAME: abuse lock until TIME, skipped`. A raced `409 machine_cooldown`
  is also a successful skip, so other boxes still get leases, and so is `409 max_run_disabled`
  (`NAME: max-run is disabled (maxRunMinutes 0), skipped`). A `cooldownUntil` ibx cannot read
  is left to the server, which refuses the lease if it applies.
- A billing block (402, such as `credit_exhausted`) comes from the wake that the lease route
  does first for an idle-paused box. Keepalive prints `NAME: account blocked by billing: ...;
  skipped` for that box and goes on: a running box needs no wake and still gets its lease. A
  `402 early_allowance_ended` (`free_limit` in ibx) is a skip too.
- A wake refused by the start rate limit (`429 rate_limited`; wakes count against
  `limits.startsPerMinute`) prints `NAME: the start rate limit was reached, retry after N s,
  skipped`. Keepalive does not wait for it; the next tick tries again.
- Exit status: 0 when every eligible lease was renewed or skipped, free boxes, abuse locks,
  the start rate limit and billing blocks included; 1 when at least one lease failed for another reason; 125 when ibx
  itself failed (no key, API unreachable, missing dependencies). A billing block alone exits 0
  on purpose: the systemd unit below restarts a failed run after 60 s, which cannot help
  there; the next tick tries again.
- It needs a key with `machines:read` and `machines:write`. A timer does not see the variables
  of your shell, so keep the key in the default file,
  `${XDG_CONFIG_HOME:-~/.config}/instabox/api-key` (mode 600), or point `IBX_KEY_FILE` at it.
  A timer may not see `XDG_CONFIG_HOME` either. If you set it, use `IBX_KEY_FILE`. **Never
  write the key itself into a unit file, plist or crontab.**
- The timer only renews. On a paid box, `ibx claim` sets the same lease (1 hour) as soon as
  it holds the sandbox, so a fresh reservation is covered until the next run. On a free box
  claim sets none (`leaseUntil` is null in its JSON). `ibx release` deletes the lease either
  way, which is harmless when there is none, so a released sandbox pauses 30 idle minutes
  later.

## 6. Paid plans: reserved only, or --all

| | `ibx keepalive` (default) | `ibx keepalive --all` |
|---|---|---|
| Keeps awake | paid sandboxes an agent holds | every paid pool sandbox, except forced pauses |
| Forgotten reservations | stop being kept awake after `IBX_STALE_SECS` | kept awake |
| Leftover processes | frozen while paused | keep running |
| Cost | running time only while agents work | running time of the whole pool |

Prefer the default. Use `--all` only when pool sandboxes must keep serving something. A paid
4 vCPU/8 GiB box costs about $0.034 per running hour plus storage (about $0.0022 an hour for
20 GiB, also while paused); the Pro plan adds a $20 monthly fee that includes $20 of usage. A
paid box with the default unlimited max-run has no forced pauses. `doctor` shows the org plan,
usage and run budgets. The user decides whether to use `--all`.

On 2026-10-18, `--all` on the free plan led to an included-usage suspension of this account,
and since 2026-11-06 the terms forbid it there. `install.sh --keepalive` and
`--keepalive=all` still install the timer, because they make no network call and cannot tell
the plan, but they print a warning that the timer is for paid plans only and violates the free
plan's terms.

## 7. Install on Linux: systemd user timer

Use the absolute path of `ibx` (`command -v ibx`). The units below assume `~/.local/bin/ibx`
(`%h` is your home directory). The DNS wait replaces `network-online.target`, which a user
service cannot wait for. It works on any Linux with `getent`.

```bash
mkdir -p ~/.config/systemd/user

cat >~/.config/systemd/user/ibx-keepalive.service <<'EOF'
[Unit]
Description=ibx keepalive: renew activity leases on reserved instabox pool sandboxes
StartLimitIntervalSec=900
StartLimitBurst=3

[Service]
Type=oneshot
# Wait for DNS (after boot or resume); TimeoutStartSec bounds the wait and the run.
ExecStartPre=/bin/sh -c 'until getent hosts api.instabox.sh >/dev/null 2>&1; do sleep 5; done'
ExecStart=%h/.local/bin/ibx keepalive
TimeoutStartSec=300
Restart=on-failure
RestartSec=60
EOF

cat >~/.config/systemd/user/ibx-keepalive.timer <<'EOF'
[Unit]
Description=Run ibx keepalive every 15 minutes

[Timer]
OnCalendar=*:0/15
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now ibx-keepalive.timer
systemctl --user start ibx-keepalive.service    # one run now
```

- `Persistent=true` runs a missed run right after the computer wakes or boots.
- `Restart=on-failure` retries a failed run after 60 s, at most 3 starts per 15 minutes, so an
  expired key does not loop forever. Skips and billing blocks exit 0, so they never restart it.
- To keep the timer running while the user is logged out (a server, say), run
  `loginctl enable-linger "$USER"`. This also keeps sandboxes awake while nobody is logged in.
- For a key file elsewhere, add `Environment=IBX_KEY_FILE=%h/path/to/key` under `[Service]`.

## 8. Install on macOS: launchd agent

launchd needs absolute paths (no `~`). The `sed` below fills in your home directory. `PATH`
must include Homebrew so that launchd finds bash 4.4+ and jq (`brew install bash jq`). The
label has to contain `ibx-keepalive` for `ibx doctor` to find it.

```bash
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
sed "s#/Users/YOU#$HOME#g" >~/Library/LaunchAgents/local.ibx-keepalive.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.ibx-keepalive</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/YOU/.local/bin/ibx</string>
    <string>keepalive</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartInterval</key>
  <integer>900</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/Users/YOU/Library/Logs/ibx-keepalive.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/YOU/Library/Logs/ibx-keepalive.log</string>
</dict>
</plist>
EOF
plutil -lint ~/Library/LaunchAgents/local.ibx-keepalive.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.ibx-keepalive.plist
```

- If `ibx` is not in `~/.local/bin`, change the first `<string>` of `ProgramArguments`.
- `StartInterval` does not fire during sleep. launchd runs the job once after the Mac wakes.
- A failed run is simply retried at the next interval, and the 1-hour lease covers the gap.

## 9. Fallback: cron

Use cron when neither systemd nor launchd is available. cron's `PATH` is minimal, so set it on
the line. Leave the path to `ibx` unquoted so that `ibx doctor` can find `ibx keepalive` in the
crontab.

```bash
mkdir -p ~/.cache
( crontab -l 2>/dev/null
  echo '*/15 * * * * PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin $HOME/.local/bin/ibx keepalive >>$HOME/.cache/ibx-keepalive.log 2>&1'
) | crontab -
```

cron does not catch up after sleep. The first run comes at the next quarter hour.

## 10. Check that it works

```bash
ibx doctor                     # "ok keepalive timer active (systemd)" / "agent loaded (launchd)" / "in crontab"
ibx keepalive                  # run once by hand: one line per reserved sandbox
```

| System | Last runs | Run now |
|---|---|---|
| systemd | `journalctl --user -u ibx-keepalive -n 30 --no-pager`; `systemctl --user list-timers ibx-keepalive.timer` | `systemctl --user start ibx-keepalive.service` |
| launchd | `tail -n 30 ~/Library/Logs/ibx-keepalive.log`; `launchctl print "gui/$(id -u)/local.ibx-keepalive"` | `launchctl kickstart "gui/$(id -u)/local.ibx-keepalive"` |
| cron | `tail -n 30 ~/.cache/ibx-keepalive.log` | run `ibx keepalive` |

A healthy run prints `NAME: lease until ...` about one hour ahead for every reserved paid
sandbox. Free boxes, cooldowns, abuse locks, `max_run_disabled`, the start rate limit, the free
running-box limit and billing blocks print `skipped`, never `FAILED`. A billing
block prints `account blocked by billing` for each box it stops (section 5); the user has to
resolve it.
`FAILED` lines carry the API error code. `missing_scope` means the key lacks
`machines:write` (`insufficient_scope` on older servers), and `expired_key` or `revoked_key` means the user needs a new key (`api_key_expired` on older servers).
A key expiry date cannot be read by ibx; note it when creating the key. Expiry stops keepalive.

## 11. What to expect

- **Wakes are expected.** On a paid plan a lease wakes reserved sandboxes that were paused for
  idleness, for example when the computer wakes up in the morning. Sandboxes coming back on
  their own is not a fault.
- When the computer sleeps or goes offline, the last lease runs out about 1 hour after the last
  run, and the sandboxes pause about 30 idle minutes after that, so roughly 90 minutes after the
  last successful run.
- Sandboxes paused or stopped by hand stay that way. keepalive never starts or resumes them.
- Several computers running the timer for the same account renew the same `ibx-keepalive` lease,
  which is harmless. One timer per account is enough.
- A free box in the pool is skipped on every run, and `ibx doctor` fails while the timer is
  installed. If the whole pool is free, uninstall the timer (section 12).

## 12. Uninstall

```bash
# systemd
systemctl --user disable --now ibx-keepalive.timer
rm -f ~/.config/systemd/user/ibx-keepalive.service ~/.config/systemd/user/ibx-keepalive.timer
systemctl --user daemon-reload

# launchd
launchctl bootout "gui/$(id -u)/local.ibx-keepalive"
rm -f ~/Library/LaunchAgents/local.ibx-keepalive.plist

# cron
crontab -l | grep -v 'ibx keepalive' | crontab -
```

A timer that `install.sh --keepalive` installed also goes away with `./install.sh --uninstall`,
which removes everything else install.sh installed too.

Leases already granted expire within an hour, and the sandboxes then pause after 30 idle
minutes.
