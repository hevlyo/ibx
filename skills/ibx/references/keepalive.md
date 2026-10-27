# Keepalive: keeping reserved sandboxes awake

The free plan fixes idle pause at 1800 seconds. Activity leases prevent idle pauses but do not
prevent the free plan's 480-minute max-run pause and cooldown. Facts checked on 2026-10-27.
`ibx keepalive` renews leases every timer tick; it never changes lifecycle settings.

**Agents.** installing a timer changes the user's computer. Do not do it yourself. If
sandboxes keep pausing under you, point the user to this file (`ibx doctor` reports whether a
timer is installed).

## Contents

1. [Why](#1-why)
2. [How activity leases work](#2-how-activity-leases-work)
3. [What ibx keepalive does](#3-what-ibx-keepalive-does)
4. [Reserved only, or --all](#4-reserved-only-or---all)
5. [Install on Linux: systemd user timer](#5-install-on-linux-systemd-user-timer)
6. [Install on macOS: launchd agent](#6-install-on-macos-launchd-agent)
7. [Fallback: cron](#7-fallback-cron)
8. [Check that it works](#8-check-that-it-works)
9. [What to expect](#9-what-to-expect)
10. [Uninstall](#10-uninstall)

## 1. Why

- Free sandboxes reject `autoSuspendAfterSeconds` other than 1800 with 403. Paid plans allow
  300-1800 in steps of 300, or 0 when always-on is allowed. Only admin-granted manual lifecycle
  accounts use the 120-86400 range. See [field-notes.md](field-notes.md#1-idle-pause-and-plan-rules).
- Detached work can outlive idle activity. Renewed leases prevent those idle pauses.
- Free boxes still pause every 480 continuous minutes. Wakes are refused until `cooldownUntil`.
  Observed cooldowns were 5-17 minutes; the spec default is 10. Checkpoint long jobs.
- The prose docs say public URL visits wake an idle-paused box; the spec still says 503. This
  remains unverified here. Manual pauses and stops still answer 503.

## 2. How activity leases work

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

ibx uses one lease ID, `ibx-keepalive`, with a 1-hour TTL. With renewals every 15 minutes, the
lease survives up to three missed runs.

## 3. What ibx keepalive does

```
ibx keepalive          # pool sandboxes that are reserved (held, not abandoned)
ibx keepalive --all    # every pool sandbox
```

- It considers only pool sandboxes (`ibx.pool` = `1`). A reservation older than
  `IBX_STALE_SECS` (default 24 h) counts as abandoned and is skipped unless you pass `--all`.
  Agents running jobs past 24 h use `ibx renew BOX`.
- **Running** sandboxes get the lease, and so do sandboxes **paused for idleness** (which wakes
  them). Sandboxes paused or stopped by hand, or in the middle of an operation, are skipped.
- Output is one line per sandbox: `NAME: lease until TIME`, `NAME: suspended, skipped`, or
  `NAME: FAILED {code, message, retryAfterSeconds}`. A max-run pause prints
  `NAME: max-run cooldown until TIME, skipped`; it sends no lease request if known in advance.
  A raced `409 machine_cooldown` is also a successful skip, so other boxes still get leases.
- Exit status: 0 when every eligible lease was renewed or a cooldown was skipped, 1 when at least one failed, 125 when ibx itself
  failed (no key, API unreachable, missing dependencies).
- It needs a key with `machines:read` and `machines:write`. A timer does not see the variables
  of your shell, so keep the key in the default file,
  `${XDG_CONFIG_HOME:-~/.config}/instabox/api-key` (mode 600), or point `IBX_KEY_FILE` at it.
  A timer may not see `XDG_CONFIG_HOME` either. If you set it, use `IBX_KEY_FILE`. **Never
  write the key itself into a unit file, plist or crontab.**
- The timer only renews. `ibx claim` sets the same lease (1 hour) as soon as it holds a
  sandbox, so a fresh reservation is covered until the next run. `ibx release` deletes the
  lease, so a released sandbox pauses 30 idle minutes later.

## 4. Reserved only, or --all

| | `ibx keepalive` (default) | `ibx keepalive --all` |
|---|---|---|
| Keeps awake | sandboxes an agent holds | every pool sandbox, except forced pauses |
| Free sandboxes | pause after 30 idle minutes; `ibx claim` resumes them (about 1 s) | cycle through max-run pauses |
| Forgotten reservations | stop being kept awake after `IBX_STALE_SECS` | renewed between max-run pauses |
| Leftover processes on free sandboxes | frozen while paused | run between forced pauses |
| Cost | running time only while agents work | running time of the whole pool between forced pauses |

Prefer the default. Use `--all` only when free pool sandboxes must keep serving something.
Free running hours count toward the org's included-usage limit when one is enforced; limit 0
means no cap. An included-usage suspension was observed on 2026-10-18. With `--all`, free boxes
cycle through 8 hours running, cooldown, then up to 15 minutes until the next timer tick.
Paid 4 vCPU/8 GiB boxes cost about $0.034/hour, roughly $124/month for five running all month.
`doctor` shows the org plan, usage and run budgets. The user decides whether to use `--all`.

## 5. Install on Linux: systemd user timer

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
  expired key does not loop forever.
- To keep the timer running while the user is logged out (a server, say), run
  `loginctl enable-linger "$USER"`. This also keeps sandboxes awake while nobody is logged in.
- For a key file elsewhere, add `Environment=IBX_KEY_FILE=%h/path/to/key` under `[Service]`.

## 6. Install on macOS: launchd agent

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

## 7. Fallback: cron

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

## 8. Check that it works

```bash
ibx doctor                     # "ok keepalive timer active (systemd)" / "agent loaded (launchd)" / "in crontab"
ibx keepalive                  # run once by hand: one line per reserved sandbox
```

| System | Last runs | Run now |
|---|---|---|
| systemd | `journalctl --user -u ibx-keepalive -n 30 --no-pager`; `systemctl --user list-timers ibx-keepalive.timer` | `systemctl --user start ibx-keepalive.service` |
| launchd | `tail -n 30 ~/Library/Logs/ibx-keepalive.log`; `launchctl print "gui/$(id -u)/local.ibx-keepalive"` | `launchctl kickstart "gui/$(id -u)/local.ibx-keepalive"` |
| cron | `tail -n 30 ~/.cache/ibx-keepalive.log` | run `ibx keepalive` |

A healthy run prints `NAME: lease until ...` about one hour ahead for every reserved sandbox.
`FAILED` lines carry the API error code. `missing_scope` means the key lacks
`machines:write` (`insufficient_scope` on older servers), and `expired_key` or `revoked_key` means the user needs a new key (`api_key_expired` on older servers). `machine_cooldown` is expected.
A key expiry date cannot be read by ibx; note it when creating the key. Expiry stops keepalive.

## 9. What to expect

- **Wakes are expected.** A lease wakes reserved sandboxes that were paused for idleness, for
  example when the computer wakes up in the morning. Sandboxes coming back on their own is not
  a fault.
- When the computer sleeps or goes offline, the last lease runs out about 1 hour after the last
  run, and the sandboxes pause about 30 idle minutes after that, so roughly 90 minutes after the
  last successful run.
- Sandboxes paused or stopped by hand stay that way. keepalive never starts or resumes them.
- Several computers running the timer for the same account renew the same `ibx-keepalive` lease,
  which is harmless. One timer per account is enough.

## 10. Uninstall

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

Leases already granted expire within an hour, and the sandboxes then pause after 30 idle
minutes.
