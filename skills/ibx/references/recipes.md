# Recipes

Concrete ways to get common jobs done in a pool sandbox. `BOX` is the name `ibx claim` printed.
Write it down, because shell variables do not survive between your tool calls. The facts behind
these recipes were checked through 2026-10-27 ([field-notes.md](field-notes.md)). The API is in
beta and changes fast, so prefer what you observe.

Two forms run code in the sandbox. Exec can also opt into SSE:

- `ibx exec BOX [-t SECS] [-i] -- 'script'` needs no ssh client, runs for at most 600 s, and its output
  arrives when the command ends. A **single** argument is a bash script, so `~`, `$VAR`, pipes
  and `&&` are evaluated in the sandbox. `-i` sends your stdin (text, up to 1 MiB). Add
  `--stream` before `--` for incremental, uncapped SSE output; disconnect kills the command.
  This keeps the 600-second limit and never retries a started stream error.
- `ibx ssh BOX 'bash -s' <<'EOF' ... EOF` streams output. It lasts as long as your tool call
  (at most 10 minutes in Claude Code), and the connection closes if the sandbox pauses. Use it for
  multi-line work and big transfers.

Give every call a tool timeout of at least `-t` + 120 s (the default `-t 300` needs 420000 ms),
and `ibx claim` and `ibx ssh` 600000 ms. Where a tool call stops at 10 minutes, as in Claude
Code, keep `-t` at 480 or less; work that takes more than ~8 minutes goes detached (recipe 5).
That budget covers the command, not what comes before it: ibx can first wait up to 600 s for
a free request slot (32 per user) or a max-run cooldown, and up to 10 more minutes for a paused
box to start. An ibx interrupted during those waits says `interrupted by SIG... before anything
started in the sandbox`; only then is running the same command again known to be safe. `ibx ls`
shows a cooldown.

Commands start in HOME (`/data/home`). The guest user has passwordless sudo; its name varies, so
use `$(id -un)` and `$HOME`.

## Contents

1. [Screenshot a web page with headless Chromium](#1-screenshot-a-web-page-with-headless-chromium)
2. [Auditing an untrusted npm or pip package](#2-auditing-an-untrusted-npm-or-pip-package)
3. [Running a local script](#3-running-a-local-script)
4. [Moving big files](#4-moving-big-files)
5. [Long jobs, detached](#5-long-jobs-detached)
6. [Docker and compose](#6-docker-and-compose)
7. [Large public datasets](#7-large-public-datasets)
8. [Safe process killing](#8-safe-process-killing)
9. [Publishing a port (only when asked)](#9-private-previews-and-public-ports)
10. [Cleaning up](#10-cleaning-up)

## 1. Screenshot a web page with headless Chromium

Chromium 154 is preinstalled, and headless mode needs no display.

```bash
ibx exec BOX -t 120 -- 'mkdir -p shots && timeout 90 chromium --headless --disable-gpu \
  --hide-scrollbars --no-first-run --user-data-dir="$(mktemp -d)" \
  --window-size=1280,800 --virtual-time-budget=5000 \
  --screenshot="$HOME/shots/page.png" "https://example.com/" && ls -l shots/page.png'
ibx get BOX shots/page.png ./page.png        # bounded by IBX_GET_MAX, default 2G
ibx ssh BOX 'cat shots/page.png' >page.png   # any size
```

Then open `page.png` with your own image-reading tool.

- `--window-size=W,H` is the viewport. For more of a long page, raise H (for example
  `1280,3000`). For a phone, use `390,844`.
- `--virtual-time-budget=MS` lets scripts and timers run before the capture.
- `--user-data-dir="$(mktemp -d)"` gives a fresh profile, with no cookies from earlier runs.
- For other outputs, use `--print-to-pdf=FILE --no-pdf-header-footer` for a PDF, `--dump-dom` for the
  rendered HTML on stdout.
- Keep Chromium's sandbox. Add `--no-sandbox` only if Chromium refuses to start with a sandbox
  error, and then only for pages you trust.
- Use an absolute `--screenshot` path; a relative one lands in Chromium's working directory.

## 2. Auditing an untrusted npm or pip package

Treat the sandbox as compromised from step 4 on. The guest user has sudo, and outbound
internet is open. Claim a sandbox for this alone (`ibx claim "audit PKG@VERSION (untrusted)"`)
and **check that it holds nothing of value first**. `ibx claim` already skips sandboxes the
Vault writes secrets into, but an item can arrive later
([trust-model.md](trust-model.md#5-vault-and-org-secrets)):

```bash
ibx exec BOX -- 'env | cut -d= -f1 | sort; test -s /run/instabox/secrets/env && echo ORG-SECRETS-PRESENT; env | grep -c "=ibsec_"'   # names only
ibx exec BOX -- 'ls -A ~'
```

If credential-looking names appear (`*_TOKEN`, `*_KEY`, `*_SECRET`, `AWS_*`, files such as
`.env` or `.config/gh`), stop and tell the user.

**1. Tools** (strace, tcpdump and inotify-tools are not preinstalled):

```bash
ibx exec BOX -t 480 -- 'sudo apt-get update -qq &&
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq strace tcpdump inotify-tools >/dev/null &&
  echo tools ok'
```

**2. Look before running anything.** For npm, `npm pack` downloads without running scripts:

```bash
ibx ssh BOX 'bash -s' <<'EOF'
mkdir -p ~/audit/pack && cd ~/audit/pack
npm pack PKG@VERSION --silent && tar xzf ./*.tgz
node -p 'JSON.stringify(require("./package/package.json").scripts || {}, null, 2)'   # preinstall/install/postinstall run code
find package -type f | head -100
EOF
```

For pip, `pip download` runs a source distribution's build code. Fetch the files straight from
PyPI instead:
`curl -sSf https://pypi.org/pypi/PKG/VERSION/json | python3 -c 'import json,sys; [print(u["packagetype"], u["url"]) for u in json.load(sys.stdin)["urls"]]'`,
then `curl -O` the file, and list it with `unzip -l` (wheel) or `tar tzf` (sdist).

**3. Start capturing**, detached so the capture outlives the exec. The filter drops only our
own control channel (SSH from the gateway, 172.16.0.1), not every port-22 connection:

```bash
ibx ssh BOX 'bash -s' <<'EOF'
mkdir -p ~/audit && cd ~/audit && touch start.marker
sudo setsid -f tcpdump -i any -nn -U -Z "$(id -un)" -w "$HOME/audit/net.pcap" \
  'not (host 172.16.0.1 and port 22)' </dev/null >tcpdump.log 2>&1
sudo setsid -f inotifywait -m -r -q --exclude '/audit/' -e create,modify,delete,moved_to,attrib \
  --timefmt %T --format '%T %e %w%f' "$HOME" /tmp /etc </dev/null >inotify.log 2>&1
sleep 2; cat tcpdump.log; echo capture started
EOF
```

**4. Install and load it under strace** (`-f` follows every child process):

```bash
# npm
ibx ssh BOX 'bash -s' <<'EOF'
mkdir -p ~/audit/npm && cd ~/audit/npm && npm init -y >/dev/null
strace -f -tt -s 256 -o ~/audit/install.strace -e trace=execve,connect,openat \
  npm install --no-audit --no-fund PKG@VERSION; echo "install exit $?"
strace -f -tt -s 256 -o ~/audit/load.strace -e trace=execve,connect \
  node -e 'import("PKG").then(() => console.log("loaded"))'; echo "load exit $?"
EOF

# pip (uv is preinstalled; python3 -m venv may need the python3-venv package)
ibx ssh BOX 'bash -s' <<'EOF'
cd ~/audit && uv venv -q venv
strace -f -tt -s 256 -o ~/audit/install.strace -e trace=execve,connect,openat \
  uv pip install --no-cache --python venv/bin/python PKG==VERSION; echo "install exit $?"
strace -f -tt -s 256 -o ~/audit/load.strace -e trace=execve,connect \
  venv/bin/python -c 'import MODULE'; echo "load exit $?"
EOF
```

**5. Stop capturing** in a separate exec, with bracket patterns (see recipe 8). SIGINT makes
tcpdump flush the file:

```bash
ibx exec BOX -- "sudo pkill -INT -f '[t]cpdump -i any'; sudo pkill -f '[i]notifywait -m'; sleep 1; ls -la ~/audit"
```

**6. Read the evidence.**

```bash
ibx ssh BOX 'bash -s' <<'EOF'
cd ~/audit
echo '== programs started'
grep -h 'execve(' ./*.strace | grep -v ENOENT | grep -oE 'execve\("[^"]+"' | sort | uniq -c | sort -rn | head -40
echo '== outbound connections (strace)'
grep -h 'connect(' ./*.strace | grep -v AF_UNIX |
  grep -oE 'htons\([0-9]+\)|inet_addr\("[^"]+"\)|inet_pton\(AF_INET6, "[^"]+"' |
  paste -d' ' - - | sort | uniq -c | sort -rn | head -40
echo '== DNS names looked up'
tcpdump -nn -r net.pcap 'udp port 53' 2>/dev/null | grep -oE ' A{1,4}\? [^ ]+' | sort | uniq -c | sort -rn | head -40
echo '== new outbound TCP connections (IPv4)'
tcpdump -nn -r net.pcap 'tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn' 2>/dev/null |
  awk '{for (i = 1; i < NF; i++) if ($i == ">") { d = $(i+1); sub(/:$/, "", d); print d; break }}' |
  sort | uniq -c | sort -rn | head -40
echo '== files changed outside ~/audit and the package caches'
sudo find / /data /tmp /dev/shm -xdev -newer start.marker -type f ! -path "$HOME/audit/*" \
  ! -path "$HOME/.npm/*" ! -path "$HOME/.cache/*" ! -path '/var/log/journal/*' 2>/dev/null | sort -u | head -100
echo '== inotify'; tail -n 60 inotify.log
echo '== still running, listening, scheduled'
ps -eo pid,user,etime,cmd --sort=start_time | tail -n 15
sudo ss -ltnup; crontab -l 2>/dev/null; ls ~/.config/systemd/user 2>/dev/null
EOF
```

Report what the package ran, contacted and changed. Quote the evidence; do not judge intent
beyond it.

**7. Clean up and hand back.** Copy back the evidence if the user wants it
(`ibx ssh BOX 'tar czf - -C ~ audit' >audit.tgz`), stop whatever the package left running
(recipe 8), then `ibx exec BOX -- 'rm -rf ~/audit'`. **Tell the user** that BOX ran untrusted
code with sudo available, and that it should be recreated before anyone trusts it again. That
is the user's job, not yours ([trust-model.md](trust-model.md#10-recreating-a-sandbox-for-the-user)).
Then `ibx release BOX`. Use the literal name printed by claim in every call. If you lost it,
`ibx ls --mine` lists your live pool reservations and shows your identity/source on stderr.
`ibx release --mine` releases all your live reservations, continuing after individual errors;
a partial failure exits 125. Bulk release requires a session ID or explicit `IBX_AGENT_NAME`,
since the per-host fallback may belong to several agents. With `--json`, inspect `released`
(names) and `failed` (name/error objects) before retrying.

## 3. Running a local script

```bash
ibx ssh BOX 'bash -s' <script.sh                  # streams output; lasts as long as the tool call
ibx ssh BOX 'bash -s -- --flag value' <script.sh  # with arguments ($1, $2, ...)
ibx exec BOX -t 480 -i -- 'bash -s' <script.sh    # no ssh client; script up to 1 MiB, output at the end
```

- Start the script with `set -euo pipefail`.
- With `bash -s` the script **is** stdin. Any command in it that reads stdin (`read`, `ssh`,
  `docker run -i`, some installers) swallows the rest of the script, so give those commands
  `</dev/null`.
- The exit status is the script's. ibx uses 255 for "ssh could not connect" and 125 for "ibx
  failed", so avoid those two in your scripts.
- With several arguments instead of one, ibx quotes each argument and your *local* shell
  expands `~` and `$VAR` first. `ibx ssh BOX ls ~/x` lists your local home path. Pass the remote
  command as one quoted argument.

## 4. Moving big files

`ibx put` streams files up to 5 GiB and checks SHA-256. `ibx get` defaults to a 2G cap
(`IBX_GET_MAX`). Older servers fall back to exec with a 750 KB limit and a warning. Use SSH
for directories:

```bash
git archive HEAD | ibx ssh BOX 'mkdir -p src && tar xf - -C src'          # a repo: versioned files only
tar czf - -C ./data . | ibx ssh BOX 'mkdir -p data && tar xzf - -C data'  # any directory in
mkdir -p ./out && ibx ssh BOX 'tar czf - -C out .' | tar xzf - -C ./out   # a directory out
ibx put BOX big.bin big.bin                                       # one file in
ibx get BOX results.parquet results.parquet                        # one file out
sha256sum big.bin; ibx exec BOX -- 'sha256sum big.bin'                    # verify (macOS: shasum -a 256)
```

- Remote paths for `ibx put` and `ibx get` are relative to HOME or absolute, so write
  `dir/file`. A quoted leading `'~/'` is stripped (`'~/dir/file'` means `dir/file`), but an
  unquoted `~` is expanded by your **local** shell to your local home path, which then names
  the wrong place in the sandbox.
- Never send secrets along with code. `ibx put` refuses files that look like credentials;
  never use `--force` for one that really is. `git archive` copies every versioned file, so run
  `git ls-files | grep -Ei '(^|/)\.env|\.(pem|key|p12|pfx)$|id_rsa|id_ed25519|credential|secret'`
  first and stop if anything matches, or archive only selected paths
  (`git archive HEAD -- src tests`). Without git, use
  `tar --exclude=.git --exclude='.env*' ...`. See [trust-model.md](trust-model.md#8-rules-for-agents).
- If the data is public, download it in the sandbox (about 3.3 Gbit/s in). That is usually much
  faster than pushing it from your machine.
- Compress what you bring back. The sandbox sends at about 0.75 Gbit/s, and your own link is
  probably slower.

## 5. Long jobs, detached

Anything that may take more than ~8 minutes goes here. `ibx run` starts it in its own session
and `ibx job` polls or stops it. exec stops at 600 s and kills the process group, and your tool
call may stop sooner.

```bash
ibx run BOX build -- 'cd src && make -j4'
ibx job BOX build --wait 300 --tail 20
ibx job BOX build --kill
```

The same shape, written out, is what those commands run:

```bash
# start: returns at once
ibx exec BOX -- 'mkdir -p jobs/build && cd jobs/build && rm -f rc pid &&
  setsid -f bash -c "echo \$\$ >pid; make -C ~/src -j4 >log 2>&1; echo \$? >rc.tmp; mv rc.tmp rc" </dev/null >/dev/null 2>&1
  echo started'

# poll: one quick exec per check, every few minutes
ibx exec BOX -- 'cd jobs/build; if [ -f rc ]; then echo "finished: exit $(cat rc)";
  elif kill -0 "$(cat pid)" 2>/dev/null; then echo running; else echo "gone without an exit code"; fi
  tail -n 20 log'

# stop it: the whole process group
ibx exec BOX -- 'kill -TERM -- -"$(cat jobs/build/pid)"'
```

- Poll with separate `ibx exec` calls like the one above, doing other work in between, or run
  a poll loop as a background task if your harness has them. Do not hold a tool call open with
  a long foreground `sleep` loop. Some harnesses forbid foreground sleeps, and the call can hit
  its timeout.
- `setsid -f` puts the job in a new session, so the exec ending (or timing out) does not take
  it down. `$$` in the inner bash is the process group ID, so `kill -- -PGID` stops the job
  together with its children.
- The idle pause (30 minutes) ignores light CPU. Over 30 minutes, the user's keepalive timer
  ([keepalive.md](keepalive.md)) keeps a reserved sandbox up. Polling with an exec at least
  every 25 minutes also counts as activity, according to the spec. An idle pause usually preserves
  the job. Free boxes also pause at 480 continuous minutes, regardless of leases; all wake
  paths refuse until cooldownUntil. A refused poll is not a dead job. Checkpoint near 8 hours
  and check the PID and runtime.processesPreserved in ibx ls --json after waking.
- "gone without an exit code" usually means the sandbox booted fresh or the OOM killer struck
  (`sudo dmesg | grep -i 'killed process'`). ibx warns about a fresh boot only when it started,
  resumed or woke the sandbox itself (`claim`, `ssh`, or an exec that found it not running).
  When the server wakes an idle-paused sandbox for an exec, ibx cannot tell, so this poll is
  how you find out. Make long jobs restartable.
- For jobs past 24 h, run `ibx renew BOX` so your reservation does not count as abandoned.
- For an interactive session that survives disconnects, install tmux
  (`sudo apt-get install -y tmux`).

## 6. Docker and compose

The guest user is in the `docker` group, so no sudo is needed.

```bash
ibx exec BOX -- 'docker version --format "{{.Server.Version}}"; docker info -f "{{.DockerRootDir}}"; df -h / /data'
ibx exec BOX -t 480 -- 'cd src && docker compose up -d --build && docker compose ps'
ibx exec BOX -- 'cd src && docker compose logs --tail 100'
ibx exec BOX -- 'curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/'
ibx exec BOX -t 480 -- 'cd src && docker compose down -v --rmi local'
```

- A build that may take more than ~8 minutes goes detached (recipe 5), with
  `docker compose build` as the job.
- Check where Docker keeps its data (`DockerRootDir`) and how much space there is. The system
  disk is 16 GiB, shared with the OS. Watch `docker system df`.
- The kernel cannot load modules and there is no `/dev/kvm`, so containers that need extra
  kernel modules or nested virtualization will not work. Images are amd64.
- Egress goes through a shared IPv4 address, so anonymous registry pulls can hit rate limits
  sooner than expected. Do not `docker login` with the user's account in a pool sandbox.
- Remove only what you created (`down -v --rmi local`). `docker system prune` would also delete
  other holders' images; run it only if the user asks.

## 7. Large public datasets

The budget is 7.8 GiB of RAM with **no swap** (running out means the OOM killer and exit 137),
20 GiB on `/data`, and 16 GiB on the system disk. Downloads run at about 3.3 Gbit/s.

- Download, decompress and filter in one pipeline. Never keep both the compressed
  file and its decompressed copy.
- Put temporary files on `/data`. Use `mkdir -p ~/tmp` and pass `-T ~/tmp`, `TMPDIR=~/tmp` or the
  tool's own setting. Check `df -h /tmp /data` and `free -m` first; a tmpfs `/tmp` would use
  RAM.
- Bound memory explicitly. Use `sort -S 2G`, DuckDB `memory_limit`, pandas `chunksize=`, polars
  lazy `scan_*`.
- Use `set -o pipefail` so a failed download fails the command. Write results to a file
  instead of piping into `head`, which would make the pipeline end with SIGPIPE.
- Anything that may take more than ~8 minutes goes detached (recipe 5). Keep results small,
  bring them back, and delete the inputs.
- Install missing tools with `sudo apt-get install -y jq zstd pigz`.

```bash
# Rows per value of column 3 in a gzipped CSV, never stored on disk
ibx exec BOX -t 480 -- 'set -o pipefail; mkdir -p tmp out &&
  curl -sSfL "https://example.org/big.csv.gz" | gzip -dc | tail -n +2 | cut -d, -f3 |
  LC_ALL=C sort -S 2G -T tmp | uniq -c | sort -rn >out/counts.txt && head -20 out/counts.txt'

# JSON lines: keep only what you need
ibx exec BOX -t 480 -- 'set -o pipefail; mkdir -p out &&
  curl -sSfL "https://example.org/events.jsonl.gz" | gzip -dc |
  jq -c "select(.type == \"push\") | {repo: .repo.name}" >out/pushes.jsonl && wc -l out/pushes.jsonl'
```

For Parquet, DuckDB reads only the columns and row groups it needs over HTTP (its `httpfs`
extension installs itself on first use):

```bash
cat >query.py <<'EOF'
import os, duckdb
con = duckdb.connect()
con.execute("SET memory_limit = '4GB'")
con.execute(f"SET temp_directory = '{os.path.expanduser('~/tmp')}'")
print(con.sql("""
    SELECT col, count(*) AS n
    FROM read_parquet('https://example.org/data/part-0.parquet')
    GROUP BY col ORDER BY n DESC LIMIT 20
"""))
EOF
ibx put BOX query.py query.py
ibx exec BOX -t 480 -- 'mkdir -p tmp && uv run -q --with duckdb python query.py'
```

To keep a large file, use a resumable download in a detached job:
`curl -fL -C - -o data/file.bin URL`.

## 8. Safe process killing

The old exec self-match was not reproduced on 2026-10-27; SSH remains unverified.
A broad `pkill -f` pattern can kill unrelated processes. Prefer recorded PIDs. If you need a
pattern, look first and use brackets, especially with SSH. `'[m]y-server'` matches "my-server"
but not its own text.

```bash
ibx exec BOX -- "pgrep -af '[m]y-server' || echo none"          # look
ibx exec BOX -- "sudo ss -ltnp 'sport = :3000'"                  # who listens on a port
ibx exec BOX -- 'kill -TERM -- -"$(cat jobs/build/pid)"'         # best: a process group you recorded (recipe 5)
ibx exec BOX -- "pkill -TERM -f '[m]y-server' || true"           # by pattern, in its own exec
ibx exec BOX -- "sleep 3; if pgrep -f '[m]y-server' >/dev/null; then pkill -KILL -f '[m]y-server'; echo killed; else echo gone; fi"
```

- Exit 143 means TERM; inspect the returned signal rather than assuming a self-match. Redo it as above.
- `pkill -x NAME` matches only the exact process name, so it cannot hit the exec's bash, but it
  stops *every* process of that name.
- Stop containers with `docker compose stop` or `docker stop`, not by PID.
- Never kill `instabox-guest-agent`, `sshd`, `Xvnc`, `instabox-computer-use`, `dockerd` or
  `containerd`. Leave processes you did not start alone; ask the user about leftovers from
  earlier holders.

## 9. Private previews and public ports

For a preview on the user's computer, keep `ibx forward BOX 18080:8000` running in the
foreground and visit `http://127.0.0.1:18080`. It binds only to localhost, revokes its 1-hour
SSH token on exit, and relies on the claim's lease. Whether an open tunnel outlives token
expiry remains unverified. Max-run pauses still interrupt access.

A public URL has **no authentication**, and anyone with it reaches the service. Publish only
when the user asks, tell them that, and unpublish as soon as they are done.

```bash
# serve a dedicated directory (never HOME), detached, then check it from inside
ibx exec BOX -- 'mkdir -p site jobs/web && cd jobs/web &&
  setsid -f bash -c "echo \$\$ >pid; exec python3 -m http.server 8000 --bind 0.0.0.0 --directory ~/site >log 2>&1" </dev/null >/dev/null 2>&1
  sleep 1; curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/'
ibx port BOX 8000 site     # prints the URL (and a warning) for the user
curl -sS -o /dev/null -w '%{http_code}\n' 'URL'   # from outside: 200 while the box runs
ibx unport BOX 8000        # when the user is done
```

- Ports are 1024-65535, with 5901 and 6768 reserved, and at most 16 per sandbox. Publishing the
  same port again keeps its URL.
- The prose docs say URL visits wake an idle-paused box and wait; the spec still says 503.
  This has not been verified here. Manual pauses and stops still answer 503.
  For a demo that must stay up past 30 idle minutes, the user needs the keepalive timer
  ([keepalive.md](keepalive.md)).
- If `curl` inside works but the public URL does not, bind to `0.0.0.0` instead of
  `127.0.0.1`.
- instabox has no access control for these URLs. If the user wants protection, it has to live
  in the application itself.
- Release removes ibx ports and every port created during the reservation, including guest
  port-agent ports. Older non-ibx ports remain with a warning. Stop your server before release;
  a process left running can publish another port later.
- `ibx unport` of a port that is not published does nothing and succeeds, so it is safe to
  repeat.

## 10. Cleaning up

Before `ibx release`, leave the sandbox as you would want to find it:

```bash
ibx ssh BOX 'tar czf - -C ~ out' | tar xzf -                       # 1. copy back what matters
ibx exec BOX -- 'for p in jobs/*/pid; do [ -f "$p" ] && kill -TERM -- -"$(cat "$p")" 2>/dev/null; done; true'
ibx exec BOX -t 480 -- 'if [ -d src ]; then cd src && docker compose down -v --rmi local; fi; true'
ibx exec BOX -- 'rm -rf jobs src out tmp shots site data'          # 2. only what you created
ibx release BOX                                                     # 3. ports, lease, reservation
ibx ls                                                              # 4. BOX shows as free
```

- Delete only files and directories you created, and leave everything else alone.
- If `ibx release` says URLs are **STILL PUBLIC**, run `ibx unport BOX PORT` and release again.
- If the sandbox ran untrusted code, tell the user before releasing it (recipe 2, step 7).
- Never keep the only copy of anything in a sandbox ([trust-model.md](trust-model.md#8-rules-for-agents)).
