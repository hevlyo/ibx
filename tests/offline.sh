#!/usr/bin/env bash
# Offline tests for ibx: runs the helper against tests/mock_api.py, a local fake of the instabox
# API, and install.sh in a scratch HOME (with a fake systemctl). No account and no network.
# Prints PASS/FAIL lines and exits 1 if any check failed.
#
#   tests/offline.sh                    exec answers are canned (any OS); put/get are skipped
#   MOCK_EXEC=real tests/offline.sh     the mock runs the commands too, and put/get are tested
#                                       (the sandbox side of put/get needs GNU coreutils: Linux)
#   IBX=/path/to/ibx tests/offline.sh   test another copy of the helper
#   ONLY=claim tests/offline.sh         run only the test groups whose name matches
# shellcheck disable=SC2016,SC2317,SC2329 # checks given to eval expand when they run; yes_ calls helpers
set -u

here=$(cd -- "$(dirname -- "$0")" && pwd)
IBX=${IBX:-$(cd -- "$here/.." && pwd)/skills/ibx/scripts/ibx}
MOCK=$here/mock_api.py
REAL='' EXEC_MODE=canned
[ "${MOCK_EXEC:-}" = real ] && REAL=1 EXEC_MODE=real

for dep in python3 curl jq; do
	command -v "$dep" >/dev/null || { echo "offline.sh: $dep is needed" >&2; exit 2; }
done

S=$(mktemp -d "${TMPDIR:-/tmp}/ibx-offline.XXXXXX")
S=$(cd "$S" && pwd -P)
mkdir -p "$S/tmp" "$S/home" "$S/mock"
KEY=ibk_fakefakefakefakefakefakefakefakefakefakefakefakefake # 52 base32 characters, not a real key
OTHER_KEY=ibk_wrongwrongwrongwrongwrongwrongwrongwrongwrongwrong

# ibx sees only the mock, a scratch HOME and TMPDIR, and no key file.
export HOME=$S/home XDG_CONFIG_HOME=$S/home/.config TMPDIR=$S/tmp
export IBX_STATE_DIR=$S/state XDG_STATE_HOME=$S/home/.local/state
export IBX_KEY_FILE=$S/no-key-file IBX_AGENT_NAME=tester IBX_CLAIM_SETTLE='0.2 0.1'
unset INSTABOX_KEY_FILE IBX_STALE_SECS IBX_MAXTIME IBX_EXEC_MAXTIME IBX_REEXEC CURL_HOME \
	IBX_ALLOW_ANY IBX_ALLOW_VAULT IBX_ALLOW_SECRETS IBX_GET_MAX IBX_ALLOW_CUSTOM_API CODEX_HOME IBX_MAX_CLAIMS CLAUDE_CONFIG_DIR \
	CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID IBX_TEST_CLAIM_LOCK_SECS

# The key reaches the mock through its environment, so no process has it in its arguments.
TMPDIR=$S/mock MOCK_API_KEY=$KEY python3 "$MOCK" --port 0 --exec "$EXEC_MODE" >"$S/mock.port" 2>"$S/mock.log" &
MOCK_PID=$!
# A cold python3 can take several seconds on a CI runner: wait up to 60 s.
for _ in $(seq 600); do [ -s "$S/mock.port" ] && break; sleep 0.1; done
PORT=$(head -n 1 "$S/mock.port")
if [ -z "$PORT" ]; then
	echo "offline.sh: the mock did not start:" >&2
	cat "$S/mock.log" >&2
	if kill -0 "$MOCK_PID" 2>/dev/null; then echo "(still running after 60 s)" >&2; else wait "$MOCK_PID"; echo "(exited with $?)" >&2; fi
	echo "python3: $(command -v python3) $(python3 -V 2>&1)" >&2
	exit 2
fi
BASE=http://127.0.0.1:$PORT
export INSTABOX_API_URL=$BASE INSTABOX_API_KEY=$KEY

# A curl that logs each run, then runs the real one: run PATH="$SPY:$PATH" ... Each line: 1 if an
# API key is in its environment (else 0); what its stdin is (pipe, file, or - where /proc is
# missing); its arguments.
SPY=$S/spy
mkdir -p "$SPY"
cat >"$SPY/curl" <<EOF
#!/bin/sh
case "\$(env)" in *ibk_*) e=1 ;; *) e=0 ;; esac
i=\$(readlink "/proc/\$\$/fd/0" 2>/dev/null)
case "\$i" in pipe:*) i=pipe ;; '') i=- ;; *) i=file ;; esac
printf '%s %s %s\\n' "\$e" "\$i" "\$*" >>"$S/spy.args"
exec '$(command -v curl)' "\$@"
EOF
chmod +x "$SPY/curl"

finish() {
	kill "$MOCK_PID" 2>/dev/null
	wait "$MOCK_PID" 2>/dev/null
	rm -rf "$S"
}
trap finish EXIT

passed=0 failed=0
ok() { passed=$((passed + 1)); printf 'PASS %s\n' "$*"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$*"; }
skip() { printf 'SKIP %s\n' "$*"; }
group() { printf '\n## %s\n' "$*"; }
detail() { # the last run's output, for a failed check
	[ -s "$S/out" ] && head -n 15 "$S/out" | sed 's/^/    stdout| /'
	[ -s "$S/err" ] && head -n 15 "$S/err" | sed 's/^/    stderr| /'
	return 0
}

LIMIT=40 # seconds before a run counts as hung
# run [-u NAME]... [-s FILE] [NAME=value]... ARGS...: runs ibx with ARGS (stdin: FILE, else
# /dev/null). Sets RC; stdout and stderr are in $S/out and $S/err. A run still going after $LIMIT
# seconds gets SIGTERM (TIMEDOUT=1).
run() {
	local envs=(env) pid wd in=/dev/null closed=
	while [ $# -gt 0 ]; do
		case "$1" in
		--closed-stderr) closed=1; shift ;;
		-u) envs+=(-u "$2"); shift 2 ;;
		-s) in=$2; shift 2 ;;
		[A-Za-z_]*=*) envs+=("$1"); shift ;;
		*) break ;;
		esac
	done
	rm -f "$S/timedout"
	RUN_LIMIT=$LIMIT
	if [ -n "$closed" ]; then
		: >"$S/err"
		"${envs[@]}" "$IBX" "$@" >"$S/out" 2>&- <"$in" &
	else
		"${envs[@]}" "$IBX" "$@" >"$S/out" 2>"$S/err" <"$in" &
	fi
	pid=$!
	(
		sp=
		trap 'kill "$sp" 2>/dev/null; exit 0' TERM
		sleep "$LIMIT" &
		sp=$!
		wait "$sp" || exit 0
		: >"$S/timedout"
		pkill -TERM -P "$pid" 2>/dev/null
		kill -TERM "$pid" 2>/dev/null
	) &
	wd=$!
	wait "$pid"
	RC=$?
	kill -TERM "$wd" 2>/dev/null
	wait "$wd" 2>/dev/null
	TIMEDOUT=
	[ -e "$S/timedout" ] && TIMEDOUT=1
	return 0
}
OUT() { cat "$S/out"; }
ERR() { cat "$S/err"; }

rc_is() { # description expected-rc: checks the last run
	if [ "$RC" = "$2" ] && [ -z "$TIMEDOUT" ]; then
		ok "$1"
	else
		bad "$1 (rc $RC, expected $2${TIMEDOUT:+; hung: killed after ${RUN_LIMIT}s})"
		detail
	fi
}
is() { # description got expected
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got $(printf %q "$2"), expected $(printf %q "$3"))"; fi
}
out_has() { if grep -Eq -- "$2" "$S/out"; then ok "$1"; else bad "$1 (stdout lacks /$2/)"; detail; fi; }
err_has() { if grep -Eq -- "$2" "$S/err"; then ok "$1"; else bad "$1 (stderr lacks /$2/)"; detail; fi; }
err_lacks() { if grep -Eq -- "$2" "$S/err"; then bad "$1 (stderr has /$2/)"; detail; else ok "$1"; fi; }
out_lacks() { if grep -Eq -- "$2" "$S/out"; then bad "$1 (stdout has /$2/)"; detail; else ok "$1"; fi; }
yes_() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

has_ctl() { LC_ALL=C grep -q "$(printf '[\001-\010\013-\037\177]')" "$@"; } # control chars but tab/newline
sha() { python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

# ---- the mock ------------------------------------------------------------------------------
# curl -q: a ~/.curlrc that a test plants must not change what these see.
ctl() { # JSON for POST /_control
	curl -q -fsS -m 10 -X POST --data-binary "$1" "$BASE/_control" >/dev/null || bad "mock control: $1"
}
reset() { ctl "{\"reset\":true${1:+,$1}}"; } # optional extra control keys, e.g. '"seed":{...}'
calls() { curl -q -fsS -m 10 "$BASE/_calls"; }
state() { curl -q -fsS -m 10 "$BASE/_state"; }
count() { # METHOD path-regex -> number of such /v1 requests since the last reset
	calls | jq --arg m "$1" --arg r "$2" '[.calls[] | select(.method == $m and (.path | test($r)))] | length'
}
ncalls() { calls | jq '.calls | length'; }
last_exec() { # jq filter on the body of the last exec request
	calls | jq -r "[.calls[] | select(.path | test(\"/exec\$\"))] | last | .body | $1"
}
box() { # name jq-filter -> value from the mock's state of that sandbox (objects: sorted keys)
	state | jq -rcS --arg n "$1" ".machines[] | select(.name == \$n) | $2"
}
wait_exec() { # N: waits (up to 10 s) until the mock has seen N exec requests since the last reset
	for _ in $(seq 100); do
		[ "$(count POST '/exec$')" -ge "$1" ] && return 0
		sleep 0.1
	done
	return 1
}
ago() { jq -nr --argjson s "$1" 'now - $s | floor | todate'; } # ISO time N seconds ago
TOKEN=0123456789abcdef01234567
claim_md() { # at [by]: the metadata of a reservation, as ibx writes it
	jq -cn --arg at "$1" --arg by "${2:-someone@elsewhere}" --arg t "$TOKEN" \
		'{"ibx.claim.by": $by, "ibx.claim.at": $at, "ibx.claim.purpose": "earlier job", "ibx.claim.token": $t}'
}
hold() { # name [age-seconds] [by]: give the sandbox a reservation
	ctl "{\"set\":{\"$1\":{\"mergeMetadata\":$(claim_md "$(ago "${2:-0}")" "${3:-}")}}}"
}
claim_keys() { box "$1" '[.metadata | keys[] | select(startswith("ibx.claim."))] | length'; }
fail_next() { # the last run printed FAIL lines, each followed by an indented next step
	awk '/^FAIL /{f++; if ((getline n) <= 0 || n !~ /^      next: [^ ]/) bad++} END {exit !(f > 0 && bad == 0)}' "$S/out"
}

want() { [ -z "${ONLY:-}" ] || [[ $1 == *$ONLY* ]]; }

# ---- tests -----------------------------------------------------------------------------------
t_cli() {
	group "CLI without the API"
	run -u INSTABOX_API_KEY --help
	rc_is "--help works without a key" 0
	out_has "--help prints the usage" '^ibx - borrow'
	run -u INSTABOX_API_KEY
	rc_is "no arguments prints the usage" 0
	local help_args
	for help_args in 'claim --help' 'claim -h' 'release --help' 'exec --help' 'exec --stream --help' 'exec box-1 --stream --help' 'exec box-1 --help' 'exec box-1 -t 30 --help' 'pool add --help' 'ssh --help' 'ssh -h' 'put box-1 --help'; do
		reset
		# These fixed test arguments deliberately split into words.
		# shellcheck disable=SC2086
		run -u INSTABOX_API_KEY $help_args
		rc_is "$help_args exits successfully without a key" 0
		is "$help_args makes no API call" "$(ncalls)" 0
		out_has "$help_args prints usage" '^ibx - borrow'
	done
	reset
	run claim --frobnicate
	rc_is "an unknown claim option fails" 125
	err_has "unknown claim options explain the quoted purpose" 'unknown option --frobnicate; the purpose is one quoted argument'
	is "an unknown claim option makes no API call" "$(ncalls)" 0
	reset
	run exec box-1 -- printf %s --help
	rc_is "--help after exec's separator is a remote argument" 0
	yes_ "the remote command retains --help" eval 'last_exec .cmd | grep -q -- --help'
	reset
	run exec box-1 printf %s --help
	rc_is "--help after an implicit remote command stays remote" 0
	yes_ "an implicit remote command retains --help" eval 'last_exec .cmd | grep -q -- --help'
	local ver
	ver=$(sed -n 's/^IBX_VERSION=//p' "$IBX")
	run -u INSTABOX_API_KEY --version
	rc_is "--version works without a key" 0
	is "--version output" "$(OUT)" "ibx $ver"

	reset
	run -u INSTABOX_API_KEY ls
	rc_is "no key: ls fails" 125
	err_has "no key: says how to set one" 'no API key: set INSTABOX_API_KEY'
	run INSTABOX_API_KEY=sk-not-an-instabox-key ls
	rc_is "malformed key is refused" 125
	run INSTABOX_API_URL=http://example.com ls
	rc_is "plain http to a remote host is refused" 125
	err_has "bad URL: says why" 'must be https://host'
	run INSTABOX_API_URL=https://api.example.com/v1 ls
	rc_is "an API URL with a path is refused" 125
	run IBX_STALE_SECS=1d ls
	rc_is "IBX_STALE_SECS must be a number" 125
	run frobnicate
	rc_is "an unknown command fails" 125
	rm -f "$S/spy.args"
	run PATH="$SPY:$PATH" INSTABOX_API_URL=https://evil.example.com ls
	rc_is "an API host other than api.instabox.sh is refused" 125
	err_has "it names the host and how to allow it" 'points at evil\.example\.com, not api\.instabox\.sh: set IBX_ALLOW_CUSTOM_API=1'
	yes_ "before any request (curl never ran)" [ ! -e "$S/spy.args" ]
	run INSTABOX_API_URL=https://api.instabox.sh.evil.example.com ls
	rc_is "a look-alike of api.instabox.sh is refused" 125
	run INSTABOX_API_URL=https://key@api.instabox.sh ls
	rc_is "an API URL with a user part is refused" 125
	run INSTABOX_API_URL="http://127.0.0.1.evil.example.com:$PORT" ls
	rc_is "plain http to a look-alike of 127.0.0.1 is refused" 125
	run IBX_ALLOW_CUSTOM_API=1 INSTABOX_API_URL=https://evil.example.com frobnicate
	yes_ "IBX_ALLOW_CUSTOM_API=1 lets another https host through the check" \
		eval '[ "$RC" = 125 ] && ! grep -q "points at" "$S/err" && grep -q "^ibx - borrow" "$S/err"'
	is "none of these reached the API" "$(ncalls)" 0
	run INSTABOX_API_URL="http://localhost:$PORT" ls
	rc_is "plain http to localhost is allowed (tests)" 0

	printf '%s\n' "$KEY" >"$S/key"
	chmod 600 "$S/key"
	run -u INSTABOX_API_KEY IBX_KEY_FILE="$S/key" ls
	rc_is "the key can come from IBX_KEY_FILE" 0
	if grep -q 'readable by other users' "$S/err"; then bad "a 0600 key file gets no warning"; else ok "a 0600 key file gets no warning"; fi
	chmod 644 "$S/key"
	run -u INSTABOX_API_KEY IBX_KEY_FILE="$S/key" ls
	err_has "a world-readable key file is warned about" 'readable by other users'
	run INSTABOX_API_KEY=$OTHER_KEY ls
	rc_is "a wrong key fails" 125
	err_has "a wrong key: the API error is shown" invalid_key
}

t_doctor() {
	group doctor
	reset
	run doctor
	rc_is "doctor passes" 0
	out_has "doctor reaches the API" "^ok +API reachable at $BASE as mock-user"
	out_has "doctor counts the pool" '^ok +pool: 3 of 3 sandboxes'
	out_has "doctor shows the limits" '^ok +limits: .*maxMachines'
	reset '"seed":{"count":2,"pool":[0,0]}'
	run doctor
	rc_is "doctor fails on an empty pool" 125
	out_has "doctor explains the empty pool" '^FAIL +the pool is empty \(2 sandboxes'
	out_has "and how to fill it" '^      next: .*ibx pool add BOX'
	run INSTABOX_API_KEY=$OTHER_KEY doctor
	rc_is "doctor fails with a wrong key" 125
	out_has "doctor shows the API error" '^FAIL +API call failed: .*invalid_key'
	out_has "a refused key is the user's to fix" '^      next: the user fixes or replaces this key'
	run -u INSTABOX_API_KEY doctor
	rc_is "doctor fails without a key" 125
	out_has "doctor says the key is missing" '^FAIL +no API key'
	yes_ "its FAIL line has a next step" fail_next
	reset
	local config=$S/claude-doctor
	run CLAUDE_CONFIG_DIR="$config" doctor
	rc_is "a missing Claude skill is a warning, not a doctor failure" 0
	out_has "doctor explains how to install for CLAUDE_CONFIG_DIR" '^warn +Claude Code with CLAUDE_CONFIG_DIR=.*cannot see the ibx skill; run CLAUDE_CONFIG_DIR=.* ./install.sh --agents claude --no-bin'
	mkdir -p "$config/skills"
	ln -s "$here/../skills/ibx" "$config/skills/ibx"
	run CLAUDE_CONFIG_DIR="$config" doctor
	out_lacks "doctor recognizes a skill linked into the custom config" 'cannot see the ibx skill'
	rm "$config/skills/ibx"
	mkdir -p "$config/plugins"
	printf '%s\n' '{"version":2,"plugins":{"not-ibx@ibx":[{"installPath":"/plugins/ibx"}],"ibx@ibx":[]}}' >"$config/plugins/installed_plugins.json"
	run CLAUDE_CONFIG_DIR="$config" doctor
	out_has "doctor does not mistake an unrelated plugin or empty install list for ibx" 'cannot see the ibx skill'
	printf '%s\n' '{"version":2,"plugins":{"ibx@ibx":[{"scope":"user","installPath":"/plugins/ibx"}]}}' >"$config/plugins/installed_plugins.json"
	run CLAUDE_CONFIG_DIR="$config" doctor
	out_lacks "doctor recognizes the recorded ibx plugin by its exact name" 'cannot see the ibx skill'
	printf 'invalid JSON\n' >"$config/plugins/installed_plugins.json"
	run CLAUDE_CONFIG_DIR="$config" doctor
	out_has "unreadable plugin records do not hide the missing skill warning" 'cannot see the ibx skill'

	mkdir -p "$HOME/.claude-normalized/skills"
	ln -s "$here/../skills/ibx" "$HOME/.claude-normalized/skills/ibx"
	run CLAUDE_CONFIG_DIR='~/.claude-normalized///' doctor
	rc_is "doctor expands a literal tilde and strips config trailing slashes" 0
	out_lacks "doctor finds the normalized Claude skill" 'cannot see the ibx skill'
	local var
	for var in CLAUDE_CONFIG_DIR CODEX_HOME XDG_CONFIG_HOME; do
		reset
		run "$var=relative-config" doctor
		rc_is "doctor rejects relative $var" 125
		err_has "doctor explains the $var path rule" "$var must be an absolute path"
		is "invalid $var is rejected before API access" "$(ncalls)" 0
	done
}

t_pool() {
	group "pool add/rm/ls"
	reset '"seed":{"count":3,"pool":[1,1,0]},"set":{"box-3":{"mergeMetadata":{"owner.note":"keep me"}}}'
	run pool ls
	rc_is "pool ls" 0
	yes_ "pool ls lists pool sandboxes only" eval 'grep -q "^box-1" "$S/out" && grep -q "^box-2" "$S/out" && ! grep -q "^box-3" "$S/out"'
	run pool add box-3
	rc_is "pool add" 0
	out_has "pool add reports" '^added box-3 to the pool$'
	is "pool add keeps other metadata" "$(box box-3 .metadata)" '{"ibx.pool":"1","owner.note":"keep me"}'
	is "every PATCH carries an Idempotency-Key" \
		"$(calls | jq '[.calls[] | select(.method == "PATCH" and ((.idempotencyKey // "") | startswith("ibx-") | not))] | length')" 0
	run pool rm box-3
	rc_is "pool rm" 0
	is "pool rm removes only ibx.pool" "$(box box-3 .metadata)" '{"owner.note":"keep me"}'
	run pool add "$(box box-2 .id)"
	rc_is "pool add takes a sandbox ID too" 0
	reset
	run pool add nosuch
	rc_is "pool add of an unknown sandbox fails" 125
	err_has "unknown sandbox: says so" 'no sandbox named nosuch'
	run pool add
	rc_is "pool add without a sandbox is a usage error" 125
	run pool frob box-1
	rc_is "an unknown pool subcommand fails" 125
	is "usage errors make no PATCH" "$(count PATCH .)" 0
}

t_ls() {
	group ls
	reset '"seed":{"count":5,"pool":[1,1,1,0,1]}'
	hold box-1 60 agent-x
	hold box-2 $((3 * 86400))
	hold box-4 60
	ctl "{\"set\":{\"box-5\":{\"mergeMetadata\":$(claim_md not-a-date)}}}"
	run ls --json
	rc_is "ls --json" 0
	is "ls --json lists the pool" "$(jq -c 'map(.name)' "$S/out")" '["box-1","box-2","box-3","box-5"]'
	is "ls --json tells held, abandoned, free and unreadable apart" \
		"$(jq -c 'map({(.name): .reservation}) | add' "$S/out")" \
		'{"box-1":"held","box-2":"abandoned","box-3":"free","box-5":"invalid"}'
	is "ls --json shows who holds it and why" "$(jq -c '.[0] | [.by, .purpose, .pool, .state]' "$S/out")" \
		'["agent-x","earlier job",true,"running"]'
	run ls --all --json
	rc_is "ls --all --json" 0
	is "ls --all includes sandboxes outside the pool" "$(jq -c 'map(select(.pool | not) | .name)' "$S/out")" '["box-4"]'
	run ls
	rc_is "ls" 0
	out_has "ls shows a held sandbox" '^box-1 +running +held by agent-x since .*: earlier job'
	out_has "ls shows an abandoned reservation as free" '^box-2 .*free \(abandoned reservation by someone@elsewhere\)'
	out_has "ls flags an unreadable reservation date" '^box-5 .*held\? reservation date unreadable'
	run ls --all
	out_has "ls --all marks sandboxes outside the pool" '^box-4 .*not in pool'
	run pool ls
	rc_is "pool ls is ls" 0
	run ls --bogus
	rc_is "ls rejects unknown flags" 125
	is "ls only reads" "$(calls | jq '[.calls[] | select(.method != "GET")] | length')" 0
	reset '"seed":{"count":2,"pool":[0,0]}'
	run ls
	rc_is "ls of an empty pool succeeds" 0
	err_has "ls of an empty pool says how to fill it" 'the pool is empty.*ibx pool add'
	run ls --json
	is "ls --json of an empty pool is []" "$(OUT)" '[]'
}

t_ownership() {
	group "ownership-aware commands"
	local command age id original=$IBX
	printf 'public fixture\n' >"$S/public.txt"
	for command in exec put get ssh forward port unport renew release; do
		reset
		hold box-1 60 other-agent
		hold box-2 60 tester
		case $command in
		exec) run exec box-1 -- true ;;
		put) run put box-1 "$S/public.txt" public.txt ;;
		get) run get box-1 public.txt "$S/download" ;;
		ssh) run ssh box-1 true ;;
		forward) run forward box-1 18080:8080 ;;
		port | unport) run "$command" box-1 8080 ;;
		*) run "$command" --json box-1 ;;
		esac
		rc_is "$command refuses another agent's live reservation" 125
		err_has "$command identifies holder, time, purpose and own boxes" 'held by other-agent since .*: earlier job; you hold: box-2'
		if [ "$command" = renew ] || [ "$command" = release ]; then
			is "$command JSON has held_by_other and own reservations" "$(jq -c '[.error.code, [.error.held[].name]]' "$S/out")" '["held_by_other",["box-2"]]'
		fi
		is "$command refuses before any box request or mutation" "$(ncalls)" 1
	done
	# run/job arrive in B2; exercise the shared resolve gate under those command names now.
	python3 - "$IBX" "$S/future-commands" <<'PYCODE'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
source = source.replace('case "$cmd" in\nls)', 'case "$cmd" in\nrun | job) resolve --pool "$1" ;;\nls)')
Path(sys.argv[2]).write_text(source)
PYCODE
	chmod +x "$S/future-commands"
	for command in run job; do
		reset
		hold box-1 60 other-agent
		IBX=$S/future-commands run "$command" box-1
		rc_is "$command resolve gate refuses another holder" 125
		err_has "$command resolve gate names the holder" 'held by other-agent'
	done
	IBX=$original
	for age in free 90000; do
		reset
		[ "$age" = free ] || hold box-1 "$age" other-agent
		run exec box-1 -- true
		rc_is "$age box work proceeds" 0
		err_has "$age box work warns" 'not reserved by you; ibx claim first or another agent may take it'
		run renew --json box-1
		rc_is "$age box renew refuses" 125
		is "$age box renew has not_held" "$(jq -r .error.code "$S/out")" not_held
		run release --json box-1
		rc_is "$age box release succeeds" 0
		err_lacks "$age release has no claim-first warning" 'not reserved by you'
		run release --json box-1
		rc_is "$age release remains idempotent" 0
	done
	reset
	ctl "{\"set\":{\"box-1\":{\"mergeMetadata\":$(claim_md not-a-date other-agent)}}}"
	run exec box-1 -- true
	rc_is "another agent's unreadable date is still refused" 125
	err_has "and names that holder" 'held by other-agent'
	is "before any mutation" "$(ncalls)" 1
	reset
	ctl "{\"set\":{\"box-1\":{\"mergeMetadata\":$(claim_md not-a-date tester)}}}"
	run exec box-1 -- true
	rc_is "your own unreadable date still runs" 0
	err_lacks "and is not described as unowned" 'not reserved by you'
	run renew --json box-1
	rc_is "your own unreadable date can be renewed" 0
	is "renew replaced the unreadable date" "$(jq -r .since "$S/out" | grep -c '^[0-9]\{4\}-')" 1
	reset
	ctl "{\"set\":{\"box-1\":{\"mergeMetadata\":$(claim_md not-a-date tester)}}}"
	run release --json box-1
	rc_is "your own unreadable date can be released" 0
	err_lacks "release does not call it unowned" 'not reserved by you'
	is "and clears it" "$(claim_keys box-1)" 0
	reset
	hold box-1 60 other-agent
	run IBX_ALLOW_ANY=1 exec box-1 -- true
	rc_is "user override permits work on another holder's box" 0
	err_lacks "override has no ownership warning" 'not reserved by you'
	run IBX_ALLOW_ANY=1 renew --json box-1
	rc_is "user override permits renew of another holder's box" 0
	run IBX_ALLOW_ANY=1 release --json box-1
	rc_is "user override permits release of another holder's box" 0
	hold box-1 60 other-agent
	run keepalive
	rc_is "keepalive still renews another holder's box" 0
	out_has "keepalive reports the other holder's lease" '^box-1: lease until'
	run ls --json
	rc_is "ls remains unaffected by other holders" 0
	run doctor
	rc_is "doctor remains unaffected by other holders" 0
	reset '"seed":{"count":5,"pool":[1,1,1,0,1]}'
	hold box-1 60 tester
	hold box-2 90000 tester
	hold box-3 60 other-agent
	hold box-4 60 tester
	ctl "{\"set\":{\"box-5\":{\"mergeMetadata\":$(claim_md not-a-date tester)}}}"
	run ls --mine
	rc_is "ls --mine succeeds" 0
	err_has "ls --mine identifies agent and source on stderr" '^you are tester \(IBX_AGENT_NAME\)$'
	out_has "ls --mine shows the held pool box" '^box-1 '
	out_lacks "ls --mine omits stale, foreign, non-pool and invalid reservations" 'box-[2345]'
	run ls --json
	jq '[.[] | select(.name == "box-1")]' "$S/out" >"$S/expected-rows"
	run ls --mine --json
	is "ls --mine JSON contains identity and normal ls rows" "$(jq -c '[.agent,.agentSource,.boxes]' "$S/out")" "$(jq -c '["tester","IBX_AGENT_NAME",.]' "$S/expected-rows")"
	run IBX_AGENT_NAME=no-holdings ls --mine --json
	rc_is "ls --mine none held succeeds" 0
	is "ls --mine none held JSON is an empty box list" "$(jq -c .boxes "$S/out")" '[]'
	err_has "ls --mine none held says so" 'you hold no sandboxes'
	run IBX_AGENT_NAME=no-holdings ls --mine
	is "ls --mine none held stdout is empty" "$(OUT)" ''
	err_has "plain none held still identifies agent" '^you are no-holdings \(IBX_AGENT_NAME\)$'
	run ls --mine --all
	rc_is "ls rejects conflicting filters" 125
	reset
	hold box-1 60 tester
	hold box-2 60 tester
	hold box-3 60 other-agent
	run release --mine --json
	rc_is "release --mine releases all owned boxes" 0
	is "release --mine result names released boxes" "$(jq -c '[.released,.failed]' "$S/out")" '[["box-1","box-2"],[]]'
	is "release --mine keeps other agent's reservation" "$(claim_keys box-1):$(claim_keys box-2):$(claim_keys box-3)" 0:0:4
	run release --mine --json
	rc_is "release --mine none held succeeds" 0
	is "release --mine none held result is empty" "$(jq -c '[.released,.failed]' "$S/out")" '[[],[]]'
	reset
	hold box-1 60 tester
	hold box-2 60 tester
	hold box-3 90000 tester
	ctl '{"faults":[{"kind":"error","method":"GET","match":"/ports$","status":403,"code":"permission_denied","message":"test refusal"}]}'
	run release --mine --json
	rc_is "release --mine partial failure exits 125" 125
	is "partial failure reports error and continues with the next box" "$(jq -c '[.released,[.failed[] | [.name,.error.code]]]' "$S/out")" '[["box-2"],[["box-1","failed"]]]'
	is "partial failure preserves failed and stale reservations" "$(claim_keys box-1):$(claim_keys box-2):$(claim_keys box-3)" 4:0:4
	reset '"seed":{"count":1},"faults":[{"kind":"delay","method":"GET","match":"^/v1/machines$","skip":1,"seconds":2}]'
	hold box-1 60 tester
	"$IBX" release --mine --json >"$S/out" 2>"$S/err" &
	local releasing=$!
	for _ in $(seq 100); do
		[ "$(count GET '^/v1/machines$')" -ge 2 ] && break
		sleep 0.05
	done
	hold box-1 60 other-agent
	wait "$releasing"; RC=$?; TIMEDOUT=
	rc_is "bulk release refuses a holder change before its per-box recheck" 125
	is "bulk recheck reports held_by_other" "$(jq -r '.failed[0].error.code' "$S/out")" held_by_other
	is "a refused recheck stops immediately without further requests" "$(ncalls)" 2
	is "a raced foreign reservation survives" "$(box box-1 '.metadata["ibx.claim.by"]')" other-agent
	reset '"seed":{"count":1},"faults":[{"kind":"delay","method":"GET","match":"^/v1/machines/m_","seconds":2}]'
	hold box-1 60 tester
	"$IBX" release --json box-1 >"$S/out" 2>"$S/err" &
	releasing=$!
	for _ in $(seq 100); do
		[ "$(count GET '^/v1/machines/m_')" -ge 1 ] && break
		sleep 0.05
	done
	hold box-1 60 other-agent
	wait "$releasing"; RC=$?; TIMEDOUT=
	rc_is "release refuses a holder seen only on the fresh read" 125
	is "that refusal is held_by_other" "$(jq -r .error.code "$S/out")" held_by_other
	is "and does not clear the new reservation" "$(box box-1 '.metadata["ibx.claim.by"]')" other-agent
	is "nor delete or patch after the fresh refusal" "$(count DELETE .):$(count PATCH .)" 0:0
	reset '"seed":{"count":1},"faults":[{"kind":"delay","method":"GET","match":"^/v1/machines/m_","seconds":2}]'
	hold box-1 60 tester
	"$IBX" renew --json box-1 >"$S/out" 2>"$S/err" &
	releasing=$!
	for _ in $(seq 100); do
		[ "$(count GET '^/v1/machines/m_')" -ge 1 ] && break
		sleep 0.05
	done
	hold box-1 60 other-agent
	after=$(box box-1 '.metadata["ibx.claim.at"]')
	wait "$releasing"; RC=$?; TIMEDOUT=
	rc_is "renew refuses a holder seen only on the fresh read" 125
	is "renew refusal is held_by_other" "$(jq -r .error.code "$S/out")" held_by_other
	is "and leaves the new holder's timestamp" "$(box box-1 '.metadata["ibx.claim.at"]')" "$after"
	reset '"seed":{"count":2},"faults":[{"kind":"delay","method":"GET","match":"/ports$","seconds":2}]'
	hold box-1 60 tester
	hold box-2 60 tester
	"$IBX" release --mine --json >"$S/out" 2>"$S/err" &
	releasing=$!
	for _ in $(seq 100); do
		[ "$(count GET '/ports$')" -ge 1 ] && break
		sleep 0.05
	done
	kill -TERM "$releasing"
	wait "$releasing"; RC=$?; TIMEDOUT=
	rc_is "a signal during release --mine exits 143" 143
	is "and names the box already released" "$(jq -r .error.message "$S/out")" \
		'interrupted by SIGTERM: released box-1; no further boxes were released'
	is "the in-flight release still cleared its reservation" "$(claim_keys box-1)" 0
	is "and the next box was not released" "$(claim_keys box-2)" 4
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"GET","match":"^/v1/machines/m_[a-z2-7]+$","status":200,"body":"{\"metadata\":[]}"}]'
	hold box-1 60 tester
	run release --mine --json
	rc_is "bulk release stops on malformed per-box data" 125
	is "malformed data is an individual failure" "$(jq -c '[.released,[.failed[].name]]' "$S/out")" '[[],["box-1"]]'
	is "malformed data causes no mutations" "$(count DELETE .):$(count PATCH .)" 0:0
	reset
	hold box-1 60 tester
	ctl '{"set":{"box-1":{"name":"odd\u001b[2Jbox","ports":[{"port":8081,"name":"manual"}]}}}'
	run release --mine --json
	rc_is "bulk release handles hostile names by machine id" 0
	is "bulk release cleans names and aggregates warnings" "$(jq -c '[.released,(.warnings | length)]' "$S/out")" '[["odd [2Jbox"],1]'
	yes_ "bulk release JSON and stderr have no terminal controls" eval '! has_ctl "$S/out" "$S/err"'
	reset
	hold box-1 60 tester
	run release --mine
	rc_is "bulk release plain output succeeds" 0
	out_has "bulk release plain output names each box" '^released box-1$'
	reset
	hold box-1 60 tester
	ctl '{"set":{"box-1":{"name":"odd\u001b[2Jbox"}}}'
	run release --mine
	rc_is "plain bulk release handles hostile names" 0
	yes_ "plain bulk release cleans terminal controls" eval '! has_ctl "$S/out" "$S/err"'
	reset
	run -u IBX_AGENT_NAME release --mine --json
	rc_is "release --mine refuses the per-host fallback" 125
	is "fallback refusal has ambiguous_identity" "$(jq -r .error.code "$S/out")" ambiguous_identity
	is "fallback refusal makes no API calls" "$(ncalls)" 0
	run -u IBX_AGENT_NAME IBX_ALLOW_ANY=1 release --mine --json
	rc_is "pool/holder override cannot make bulk identity unambiguous" 125
	run -u IBX_AGENT_NAME CODEX_THREAD_ID=b1-test release --mine --json
	rc_is "release --mine accepts session identity" 0
	reset '"seed":{"count":1}'
	run claim ownership-test
	rc_is "claim human output succeeds" 0
	is "claim stdout stays the bare name" "$(OUT)" box-1
	err_has "claim stderr teaches literal name, release and rediscovery" 'literal name box-1.*ibx release box-1.*ibx ls --mine'
}

t_claim() {
	group claim
	reset
	local a b c ra rb
	IBX_CLAIM_SETTLE='0.5 0.2' IBX_AGENT_NAME=agent-a "$IBX" claim "job a" >"$S/a" 2>"$S/a.err" </dev/null &
	a=$!
	IBX_CLAIM_SETTLE='0.5 0.2' IBX_AGENT_NAME=agent-b "$IBX" claim "job b" >"$S/b" 2>"$S/b.err" </dev/null &
	b=$!
	wait "$a"
	ra=$?
	wait "$b"
	rb=$?
	a=$(cat "$S/a") b=$(cat "$S/b")
	is "concurrent claim A succeeds" "$ra" 0
	is "concurrent claim B succeeds" "$rb" 0
	if [[ $a == box-[123] && $b == box-[123] && $a != "$b" ]]; then
		ok "concurrent claims got different sandboxes ($a, $b)"
	else
		bad "concurrent claims: A=$a B=$b"
		sed 's/^/    A| /' "$S/a.err"
		sed 's/^/    B| /' "$S/b.err"
	fi
	if [ -n "$a" ] && [ -n "$b" ]; then
		is "A's reservation" "$(box "$a" '.metadata | [.["ibx.claim.by"], .["ibx.claim.purpose"], .["ibx.pool"]]')" '["agent-a","job a","1"]'
		is "B's reservation" "$(box "$b" '.metadata | [.["ibx.claim.by"], .["ibx.claim.purpose"]]')" '["agent-b","job b"]'
		yes_ "the reservation has a random token" eval '[[ $(box "$a" ".metadata[\"ibx.claim.token\"]") =~ ^[0-9a-f]{24}$ ]]'
		yes_ "the reservation time is now" eval '[ $(( $(date +%s) - $(box "$a" ".metadata[\"ibx.claim.at\"] | fromdate") )) -lt 60 ]'
		is "both claims set the ibx-keepalive lease" "$(box "$a" '[.leases[].id]') $(box "$b" '[.leases[].id]')" \
			'["ibx-keepalive"] ["ibx-keepalive"]'
		is "for an hour" "$(calls | jq -c '[.calls[] | select(.method == "PUT" and (.path | endswith("/activity-leases/ibx-keepalive"))) | .body.ttlSeconds]')" \
			'[3600,3600]'
	fi
	run claim $'two\tlines\nhere'
	rc_is "a third claim gets the last free sandbox" 0
	c=$(OUT)
	yes_ "the third sandbox is the remaining one" eval '[[ $c == box-[123] && $c != "$a" && $c != "$b" ]]'
	is "tabs and newlines in the purpose become spaces" "$(box "$c" '.metadata["ibx.claim.purpose"]')" 'two lines here'
	ctl '{"resetCalls":true}'
	run claim "one too many"
	rc_is "claim with no free sandbox exits 75" 75
	err_has "no free sandbox: says so" 'no free sandbox in the pool'
	is "a claim that finds nothing writes nothing" "$(count PATCH .)" 0

	reset '"seed":{"count":3,"pool":[1,0,0]}'
	hold box-1 60
	run claim x
	rc_is "sandboxes outside the pool are never claimed" 75
	reset '"seed":{"count":2,"pool":[0,0]}'
	run claim x
	rc_is "claim on an empty pool fails" 125
	err_has "empty pool: says how to fill it" 'the pool is empty: ask the user'
	run claim
	rc_is "claim needs a purpose" 125
	reset
	run claim "$(printf 'p%.0s' $(seq 600))"
	rc_is "claim with a long purpose" 0
	is "the purpose is cut to 500 characters" "$(box "$(OUT)" '.metadata["ibx.claim.purpose"] | length')" 500
	c=$(OUT)
	run release "$c"
	rc_is "release after claim" 0
	is "release removes the lease that claim set" "$(box "$c" '[.leases[].id]')" '[]'

	reset
	run claim $'esc\e[31mred\a bell\x7f'
	is "control characters are dropped from the purpose" "$(box "$(OUT)" '.metadata["ibx.claim.purpose"]')" 'esc[31mred bell'
	reset
	run -u IBX_AGENT_NAME claim "default name"
	local by
	by=$(box "$(OUT)" '.metadata["ibx.claim.by"]')
	yes_ "the default agent name is agent-<number>" eval '[[ $by =~ ^agent-[0-9]+$ ]]'
	is "a checksum of user@host, which it does not show" "$by" \
		"agent-$(printf '%s@%s' "${USER:-}" "$(uname -n)" | cksum | cut -d' ' -f1)"
	reset
	run IBX_AGENT_NAME=$'me & you <a@b>;$(id)\n' claim "odd name"
	is "characters outside [A-Za-z0-9@._:-] in IBX_AGENT_NAME become _" \
		"$(box "$(OUT)" '.metadata["ibx.claim.by"]')" 'me___you__a@b____id__'
	reset
	run IBX_AGENT_NAME="$(printf 'n%.0s' $(seq 100))" claim "long name"
	is "IBX_AGENT_NAME is cut to 64 characters" "$(box "$(OUT)" '.metadata["ibx.claim.by"] | length')" 64

	# The reservation is made with short API calls: 8 s at most, curl's retries included.
	reset '"faults":[{"kind":"delay","method":"GET","match":"^/v1/machines/m_[a-z2-7]{26}$","seconds":15,"count":3}]'
	hold box-2 0
	hold box-3 0
	local t0=$SECONDS
	run claim "hanging API"
	rc_is "claim gives up on a sandbox whose API calls hang" 125
	err_has "it says the API failed" 'could not claim a sandbox: API errors'
	yes_ "after about 8 s, not the 15 s the call hangs ($((SECONDS - t0)) s)" [ $((SECONDS - t0)) -le 12 ]
	is "nothing was reserved" "$(count PATCH .)" 0
}

# Batch outputs stay separate so every process's exit status and JSON can be checked.
claim_batch() { # count identity(shared/distinct) lock(shared/separate) cap settle
	local n=$1 identity=$2 lock=$3 cap=$4 settle=$5 i pid
	local pids=()
	rm -rf "$S/batch"
	mkdir -p "$S/batch"
	if [ "${6:-}" = dead ]; then
		mkdir -p "$S/batch/state/claim.lock"
		lock_owner 99999999 >"$S/batch/state/claim.lock/pid"
	fi
	for ((i=1; i<=n; i++)); do
		local agent=batch-$i dir=$S/batch/state
		[ "$identity" != shared ] || agent=batch-agent
		[ "$lock" != separate ] || dir=$S/batch/state-$i
		IBX_AGENT_NAME=$agent IBX_STATE_DIR=$dir IBX_MAX_CLAIMS=$cap \
			IBX_CLAIM_SETTLE=$settle \
			"$IBX" claim --json "parallel $i" >"$S/batch/$i.json" 2>"$S/batch/$i.err" </dev/null &
		pids+=("$!")
	done
	i=0
	for pid in "${pids[@]}"; do
		i=$((i + 1))
		wait "$pid"
		printf '%s\n' "$?" >"$S/batch/$i.rc"
	done
	is "no claim.lock remains after the batch" "$(find "$S/batch" -name claim.lock | wc -l | tr -d ' ')" 0
}
batch_json() { jq -s "$1" "$S/batch/"*.json; }
batch_rcs() { cat "$S/batch/"*.rc | sort -n | tr '\n' ' '; }

t_claim_parallel() {
	group "claim: local lock and cross-computer settle checks"
	reset '"seed":{"count":6},"faults":[{"kind":"delay","method":"PATCH","seconds":0.12,"count":100}]'
	claim_batch 8 distinct shared 3 '0.05 0'
	is "8 parallel claims: six succeed, two exit 75" "$(batch_rcs)" '0 0 0 0 0 0 75 75 '
	is "all six winners are distinct" "$(batch_json '[.[] | select(.name) | .name] | unique | length')" 6
	is "both refusals are no_free_sandbox" "$(batch_json '[.[] | select(.error.code == "no_free_sandbox")] | length')" 2
	yes_ "each stdout is exactly one JSON object" \
		jq -se 'length == 8 and all(.[]; type == "object")' "$S/batch/"*.json
	reset '"seed":{"count":6},"faults":[{"kind":"delay","method":"PATCH","seconds":0.2,"count":100}]'
	claim_batch 8 distinct separate 3 '1 0.5'
	is "separate state dirs: every run succeeds or exits 75" "$(cat "$S/batch/"*.rc | grep -vcE '^(0|75)$')" 0
	yes_ "separate state dirs: at least one claim succeeds" [ "$(batch_json '[.[] | select(.name)] | length')" -gt 0 ]
	is "separate state dirs: no two winners have the same sandbox" \
		"$(batch_json '[.[] | select(.name) | .name] | length == (unique | length)')" true
	local wins
	wins=$(batch_json '[.[] | select(.name) | {name,by}]')
	is "separate state dirs: winners match final reservations" \
		"$(state | jq --argjson wins "$wins" '[.machines[] as $m | $wins[] | select(.name == $m.name and .by != $m.metadata["ibx.claim.by"])] | length')" 0
}

t_claim_cap() {
	group "claim: per-agent cap"
	reset '"seed":{"count":6}'
	claim_batch 10 shared shared 1 '0.05 0' dead
	is "dead lock recovery: ten claims under cap=1 have exactly one winner" "$(batch_rcs)" '0 75 75 75 75 75 75 75 75 75 '
	is "dead lock recovery: nine claim_limit errors" "$(batch_json '[.[] | select(.error.code == "claim_limit")] | length')" 9
	reset '"seed":{"count":6}'
	claim_batch 4 shared shared 2 '0.05 0'
	is "cap=2: two succeed, two exit 75" "$(batch_rcs)" '0 0 75 75 '
	is "two structured claim_limit errors" "$(batch_json '[.[] | select(.error.code == "claim_limit")] | length')" 2
	is "limit errors list both held sandboxes" \
		"$(batch_json '[.[] | select(.error) | .error.held | length] | all(. == 2)')" true
	run IBX_STATE_DIR="$S/batch/state" IBX_MAX_CLAIMS=0 claim --json x
	rc_is "another claim can acquire the lock after claim_limit" 0
	yes_ "no claim.lock remains after claim_limit" [ ! -e "$S/batch/state/claim.lock" ]
	reset '"seed":{"count":6}'
	claim_batch 4 shared shared 0 '0.05 0'
	is "cap=0 permits all four claims" "$(batch_rcs)" '0 0 0 0 '
	reset
	run IBX_MAX_CLAIMS=bad claim --json x
	rc_is "a nonnumeric cap fails" 125
	is "invalid cap gets a single failed JSON error" "$(jq -sc 'length == 1 and .[0].error.code == "failed"' "$S/out")" true
	run IBX_MAX_CLAIMS=-1 claim --json x
	rc_is "a negative cap fails" 125
	reset
	hold box-1 90000 tester
	ctl "{\"set\":{\"box-2\":{\"mergeMetadata\":$(claim_md invalid tester)}}}"
	run IBX_MAX_CLAIMS=1 claim --json x
	rc_is "abandoned and invalid reservations by this agent do not count" 0
	reset
	hold box-1 0 tester
	ctl '{"set":{"box-1":{"deleteMetadata":["ibx.pool"]}}}'
	run IBX_MAX_CLAIMS=1 claim --json x
	rc_is "reservations outside the pool do not count" 0
	reset
	hold box-1 0 tester
	run IBX_MAX_CLAIMS=1 claim --json x
	rc_is "initial cap check refuses an extra claim" 75
	is "initial cap check writes nothing" "$(count PATCH .)" 0
	yes_ "initial cap refusal leaves no lock" [ ! -e "$IBX_STATE_DIR/claim.lock" ]
	err_has "cap message explains how to free capacity" 'tester already holds 1 sandboxes.*box-1.*Release one'
	reset '"seed":{"count":2},"faults":[{"kind":"error","method":"GET","match":"^/v1/machines/m_[a-z2-7]{26}$","skip":2,"count":4,"status":503,"code":"unavailable"}]'
	run IBX_MAX_CLAIMS=1 claim --json x
	rc_is "a failed settle read does not count this run's in-flight reservation against its cap" 0
	is "the failed candidate is cleared and only the winner remains reserved" \
		"$(state | jq '[.machines[] | select(.metadata["ibx.claim.by"] == "tester")] | length')" 1
	yes_ "the recovered claim releases the lock" [ ! -e "$IBX_STATE_DIR/claim.lock" ]
}

t_claim_lock_busy() {
	group "claim: a busy usable lock never falls back to an unlocked write"
	local dir=$S/queued-state i pid by busy=0 wrote=0 pids=()
	rm -rf "$dir" "$S/queued"
	mkdir "$S/queued"
	reset '"seed":{"count":20},"faults":[{"kind":"delay","method":"GET","match":"^/v1/machines$","seconds":1,"count":100}]'
	for i in $(seq 16); do
		by=queue-agent-$((i % 4))
		IBX_AGENT_NAME=$by IBX_STATE_DIR=$dir IBX_MAX_CLAIMS=2 IBX_TEST_CLAIM_LOCK_SECS=2 \
			IBX_CLAIM_SETTLE='0.05 0' "$IBX" claim --json "queued $i" \
			>"$S/queued/$i.json" 2>"$S/queued/$i.err" </dev/null &
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do wait "$pid"; printf '%s\n' "$?" >>"$S/queued/rcs"; done
	is "the queued claims all succeed or exit 75" "$(grep -vcE '^(0|75)$' "$S/queued/rcs")" 0
	yes_ "the shortened lock deadline rejects overflow with lock_busy" \
		jq -se 'any(.[]; .error.code == "lock_busy")' "$S/queued/"*.json
	yes_ "every queued claim emits exactly one object" \
		jq -se 'length == 16 and all(.[]; type == "object")' "$S/queued/"*.json
	yes_ "no agent exceeds the cap while list calls are slow" \
		jq -e '[.machines[] | .metadata["ibx.claim.by"] | select(. != null)] | group_by(.) | all(.[]; length <= 2)' < <(state)
	for i in $(seq 16); do
		if jq -e '.error.code == "lock_busy"' "$S/queued/$i.json" >/dev/null; then
			busy=$((busy + 1))
			wrote=$((wrote + $(calls | jq --arg p "queued $i" '[.calls[] | select(.method == "PATCH" and .body.metadata["ibx.claim.purpose"] == $p)] | length')))
		fi
	done
	is "all $busy lock_busy refusals write no reservation" "$wrote" 0
	yes_ "the slow batch releases the lock and guard" eval '[ ! -e "$dir/claim.lock" ] && [ ! -e "$dir/claim.reap" ]'
	yes_ "a usable busy lock never warns about continuing unlocked" \
		eval '! grep -q "continuing with settle checks" "$S/queued/"*.err'
}

t_claim_mkdir_signals() {
	group "claim: signals after mkdir and before the owner write"
	local dir=$S/mkdir-state bin=$S/mkdir-bin kind real_mkdir
	mkdir "$bin"
	real_mkdir=$(command -v mkdir)
	cat >"$bin/mkdir" <<EOF
#!/bin/sh
if [ "\$1" = "\$IBX_SIGNAL_MKDIR" ] && [ ! -e "$S/mkdir-signaled" ]; then
	'$real_mkdir' "\$@" || exit
	: >"$S/mkdir-signaled"
	kill -TERM "\$PPID"
	exit 0
fi
exec '$real_mkdir' "\$@"
EOF
	chmod +x "$bin/mkdir"
	for kind in claim.lock claim.reap; do
		rm -rf "$dir" "$S/mkdir-signaled"
		reset '"seed":{"count":1}'
		run IBX_STATE_DIR="$dir" PATH="$bin:$PATH" IBX_SIGNAL_MKDIR="$dir/$kind" claim --json x
		rc_is "TERM during mkdir $kind returns 143" 143
		is "TERM during mkdir $kind emits one interrupted JSON error" \
			"$(jq -sc 'length == 1 and .[0].error.code == "interrupted"' "$S/out")" true
		yes_ "TERM during mkdir $kind leaves neither empty directory" eval '[ ! -e "$dir/claim.lock" ] && [ ! -e "$dir/claim.reap" ]'
		is "TERM during mkdir $kind writes nothing" "$(count PATCH .)" 0
		run IBX_STATE_DIR="$dir" claim --json x
		rc_is "the next claim after TERM during mkdir $kind acquires immediately" 0
	done
}

t_closed_stderr() {
	group "diagnostics: a closed stderr preserves JSON, status and reservations"
	reset
	run --closed-stderr release --json nosuchbox
	rc_is "die in resolve with stderr closed retains exit 125" 125
	is "die in resolve with stderr closed emits its failed JSON error" \
		"$(jq -sc 'length == 1 and .[0].error.code == "failed" and (.[0].error.message | contains("nosuchbox"))' "$S/out")" true
	hold box-1 0 tester
	run --closed-stderr IBX_MAX_CLAIMS=1 claim --json x
	rc_is "claim_limit with stderr closed retains exit 75" 75
	is "claim_limit with stderr closed retains its JSON code" "$(jq -r .error.code "$S/out")" claim_limit
	is "the cap refusal leaves the existing reservation alone" "$(claim_keys box-1)" 4
	hold box-2 0 other
	hold box-3 0 other
	run --closed-stderr claim --json x
	rc_is "no_free_sandbox with stderr closed retains exit 75" 75
	is "the holder listing cannot replace the no-free JSON error" \
		"$(jq -sc 'length == 1 and .[0].error.code == "no_free_sandbox" and (.[0].error.held | length == 3)' "$S/out")" true
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"PUT","match":"/activity-leases/","status":403,"code":"permission_denied"}]'
	run --closed-stderr claim --json x
	rc_is "a warning after keeping a claim with stderr closed still succeeds" 0
	is "the caller learns the held box and its warning with stderr closed" \
		"$(jq -sc 'length == 1 and .[0].name == "box-1" and (.[0].warnings | length == 1)' "$S/out")" true
	is "the successful warned claim is still held" "$(claim_keys box-1)" 5
}

t_claim_names() {
	group "claim: session agent names"
	local a b c var
	for var in CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID; do
		reset
		run -u IBX_AGENT_NAME "$var=session-a" claim --json x
		a=$(jq -r .by "$S/out")
		run -u IBX_AGENT_NAME "$var=session-b" claim --json x
		b=$(jq -r .by "$S/out")
		run -u IBX_AGENT_NAME "$var=session-a" claim --json x
		c=$(jq -r .by "$S/out")
		yes_ "$var: different sessions get different names" [ "$a" != "$b" ]
		is "$var: the same session keeps its name" "$a" "$c"
		reset
		run "$var=session-a" claim --json x
		is "$var: IBX_AGENT_NAME overrides the session" "$(jq -r .by "$S/out")" tester
	done
	run -u IBX_AGENT_NAME CLAUDE_CODE_SESSION_ID=session-a CODEX_THREAD_ID=session-b doctor
	out_has "doctor identifies the Claude session source" '^ok +agent: agent-[0-9]+ \(CLAUDE_CODE_SESSION_ID\); IBX_MAX_CLAIMS=3'
	run -u IBX_AGENT_NAME CODEX_THREAD_ID=session-b doctor
	out_has "doctor identifies the Codex thread source" '^ok +agent: agent-[0-9]+ \(CODEX_THREAD_ID\); IBX_MAX_CLAIMS=3'
	run -u IBX_AGENT_NAME doctor
	out_has "doctor identifies the host fallback" '^ok +agent: agent-[0-9]+ \(per host\); IBX_MAX_CLAIMS=3'
	run IBX_MAX_CLAIMS=2 doctor
	out_has "doctor identifies the explicit name and cap" '^ok +agent: tester \(IBX_AGENT_NAME\); IBX_MAX_CLAIMS=2'
}

lock_owner() { printf '%s\t%s\t%s\n' "$1" "$(uname -n)" "$(readlink /proc/self/ns/pid 2>/dev/null || true)"; }

t_claim_lock() {
	group "claim: mkdir lock recovery and state directory safety"
	local dir=$S/lock-test kind t0 dead
	sleep 0 & dead=$!; wait "$dead"
	for kind in old-layout dead-owner empty old-file symlink old-live stale-reap dead-reap; do
		rm -rf "$dir"
		mkdir -p "$dir"
		case "$kind" in
		old-layout)
			mkdir -p "$dir/claim.lock/reap"; printf '99999999\n' >"$dir/claim.lock/pid"
			touch -t 200001010000 "$dir/claim.lock"
			;;
		dead-owner) mkdir "$dir/claim.lock"; lock_owner "$dead" >"$dir/claim.lock/pid" ;;
		empty)
			mkdir "$dir/claim.lock"
			TZ=UTC touch -t "$(jq -nr 'now - 150 | strftime("%Y%m%d%H%M.%S")')" "$dir/claim.lock"
			;;
		dead-reap) mkdir "$dir/claim.reap"; lock_owner "$dead" >"$dir/claim.reap/pid" ;;
		stale-reap)
			mkdir "$dir/claim.reap"
			lock_owner 99999999 >"$dir/claim.reap/pid"
			TZ=UTC touch -t "$(jq -nr 'now - 150 | strftime("%Y%m%d%H%M.%S")')" "$dir/claim.reap"
			;;
		old-file) printf 'old flock file\n' >"$dir/claim.lock" ;;
		symlink) ln -s "$S/lock-target" "$dir/claim.lock" ;;
		old-live)
			mkdir "$dir/claim.lock"; lock_owner "$$" >"$dir/claim.lock/pid"
			touch -t 200001010000 "$dir/claim.lock"
			;;
		esac
		reset '"seed":{"count":1}'
		t0=$SECONDS
		run IBX_STATE_DIR="$dir" claim --json x
		rc_is "$kind: recovers the lock and claims" 0
		yes_ "$kind: recovers quickly ($((SECONDS - t0)) s)" [ $((SECONDS - t0)) -lt 30 ]
		yes_ "$kind: no claim.reap remains" [ ! -e "$dir/claim.reap" ]
		err_lacks "$kind: no lock warning" 'local claim lock'
		yes_ "$kind: no claim.lock remains" eval '[ ! -e "$dir/claim.lock" ] && [ ! -L "$dir/claim.lock" ]'
	done
	mkdir -p "$dir/claim.stale.old"
	touch -t 200001010000 "$dir/claim.stale.old"
	reset
	run IBX_STATE_DIR="$dir" claim --json x
	yes_ "old claim.stale directories are removed" [ ! -e "$dir/claim.stale.old" ]
	reset
	run -u IBX_STATE_DIR claim --json x
	rc_is "claim uses XDG_STATE_HOME when IBX_STATE_DIR is unset" 0
	yes_ "the default state directory is created" [ -d "$XDG_STATE_HOME/ibx" ]
	printf 'file\n' >"$S/no-state"
	reset
	run IBX_STATE_DIR="$S/no-state/state" claim --json x
	rc_is "an unavailable state directory still permits a claim" 0
	is "the lock failure warns exactly once" "$(grep -c 'local claim lock' "$S/err")" 1
	is "lock warning is included in JSON" "$(jq '.warnings | length' "$S/out")" 1
	run IBX_STATE_DIR="$S/no-state/state" doctor
	out_has "doctor warns when the state directory is not writable" '^warn +state directory is not writable'
	for kind in symlink group-writable world-writable; do
		rm -rf "$dir"
		case "$kind" in
		symlink) mkdir -p "$S/state-target"; ln -s "$S/state-target" "$dir" ;;
		group-writable) mkdir "$dir"; chmod 770 "$dir" ;;
		world-writable) mkdir "$dir"; chmod 707 "$dir" ;;
		esac
		reset
		run IBX_STATE_DIR="$dir" claim --json x
		rc_is "$kind state directory: claim still succeeds" 0
		is "$kind state directory: one lock warning" "$(grep -c 'local claim lock' "$S/err")" 1
		yes_ "$kind state directory: no lock created" [ ! -e "$dir/claim.lock" ]
	done
	rm -rf "$dir"
	reset
	run -u HOME -u IBX_STATE_DIR -u XDG_STATE_HOME claim --json x
	rc_is "unset HOME does not abort claim" 0
	err_has "no state directory can be derived: lock is disabled with a warning" 'local claim lock.*unknown state directory'
	reset
	run -u HOME ls
	rc_is "unset HOME does not abort other commands" 0
}

t_claim_reaper() {
	group "claim: reapers preserve mutual exclusion and foreign owners"
	local dir=$S/reaper-state bin=$S/reaper-bin worker=$S/lock-worker funcs=$S/lock-functions a b rc
	mkdir -p "$dir" "$bin"
	# Exercise the actual lock functions without API latency masking the interleaving.
	python3 - "$IBX" "$funcs" <<'PYCODE'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text('state_dir_ok() {' + source.split('state_dir_ok() {', 1)[1].split('\nheld_claims() {', 1)[0])
PYCODE
	cat >"$worker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
umask 077
STATE_DIR=$1
LOCK_HOST=$(uname -n)
LOCK_NS=$(readlink /proc/self/ns/pid 2>/dev/null) || LOCK_NS=
LOCK_OWNER=$(printf '%s\t%s\t%s' "$$" "$LOCK_HOST" "$LOCK_NS")
claim_lock_kind= claim_lock_disabled= reap_lock_held=
sleep_for() { sleep "$1" & wait $!; }
warn() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC1090
source "$2"
trap 'claim_unlock; reap_unlock' EXIT
trap 'exit 143' TERM
if [ "$3" = stale ]; then lock_stale "$STATE_DIR/claim.lock"; exit; fi
if [ "$3" = reap ]; then reap_claim_lock; exit; fi
claim_lock
if ! mkdir "$STATE_DIR/critical"; then touch "$STATE_DIR/violation"; exit 1; fi
touch "$STATE_DIR/entered.$3"
sleep 0.3 & wait $!
rmdir "$STATE_DIR/critical"
SH
	cat >"$bin/mv" <<EOF
#!/bin/sh
if [ "\${DELAY_REAP:-}" = 1 ] && [ "\$1" = "$dir/claim.lock" ]; then
	: >"$dir/ready"
	while [ ! -e "$dir/go" ]; do sleep 0.05; done
fi
exec '$(command -v mv)' "\$@"
EOF
	chmod +x "$worker" "$bin/mv"
	mkdir "$dir/claim.lock"
	lock_owner 99999999 >"$dir/claim.lock/pid"
	DELAY_REAP=1 PATH="$bin:$PATH" "$worker" "$dir" "$funcs" a >"$S/reaper-a.out" 2>"$S/reaper-a.err" & a=$!
	for _ in $(seq 100); do [ -e "$dir/ready" ] && break; sleep 0.05; done
	yes_ "the first reaper pauses before its rename" [ -e "$dir/ready" ]
	"$worker" "$dir" "$funcs" b >"$S/reaper-b.out" 2>"$S/reaper-b.err" & b=$!
	sleep 0.3
	yes_ "another process cannot reap or enter while the first reaper is delayed" [ ! -e "$dir/entered.b" ]
	: >"$dir/go"
	wait "$a"; rc=$?
	is "the delayed reaper eventually acquires" "$rc" 0
	wait "$b"; rc=$?
	is "the other process eventually acquires" "$rc" 0
	yes_ "the delayed rename preserves mutual exclusion" [ ! -e "$dir/violation" ]
	yes_ "both lock and reaper guard are released" eval '[ ! -e "$dir/claim.lock" ] && [ ! -e "$dir/claim.reap" ]'

	# A client outside the guard can replace the lock; a mismatched live owner must survive.
	rm -f "$dir/ready" "$dir/go"
	mkdir "$dir/claim.lock"
	lock_owner 99999999 >"$dir/claim.lock/pid"
	DELAY_REAP=1 PATH="$bin:$PATH" "$worker" "$dir" "$funcs" reap >"$S/reaper-a.out" 2>"$S/reaper-a.err" & a=$!
	for _ in $(seq 100); do [ -e "$dir/ready" ] && break; sleep 0.05; done
	rm -rf "$dir/claim.lock"
	mkdir "$dir/claim.lock"
	lock_owner "$$" >"$dir/claim.lock/pid"
	: >"$dir/go"
	wait "$a"
	is "a moved lock with a different live owner is restored" "$(cat "$dir/claim.lock/pid")" "$(lock_owner "$$")"
	yes_ "mismatch recovery releases the guard" [ ! -e "$dir/claim.reap" ]
	printf '99999999\t%s\tforeign-namespace\n' "$(uname -n)" >"$dir/claim.lock/pid"
	"$worker" "$dir" "$funcs" stale; rc=$?
	is "a foreign namespace's dead-looking pid does not make a fresh lock stale" "$rc" 1
	printf '99999999\tforeign-host\t%s\n' "$(readlink /proc/self/ns/pid 2>/dev/null || true)" >"$dir/claim.lock/pid"
	"$worker" "$dir" "$funcs" stale; rc=$?
	is "a foreign host's dead-looking pid does not make a fresh lock stale" "$rc" 1
	rm -rf "$dir/claim.lock"
}

signal_claim() { # arguments for ibx claim; reset SIGINT, which bash ignores in background jobs
	python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT,signal.SIG_DFL); os.execv(sys.argv[1],sys.argv[1:])' \
		"$IBX" claim "$@" >"$S/out" 2>"$S/err" </dev/null &
	SIGNAL_PID=$!
}
t_claim_signals() {
	group "claim: interruption JSON and lock release"
	local sig expected phase dir=$S/signal-state t0 sleepbin=$S/signal-sleep
	mkdir "$sleepbin"
	# Stretch short waits so scheduler jitter cannot look like a deferred signal.
	cat >"$sleepbin/sleep" <<EOF
#!/bin/sh
if [ "\${IBX_SLEEP_EXPECT:-}" = "\$1" ]; then
	: >"\$IBX_SLEEP_MARKER"
	exec '$(command -v sleep)' 20
fi
exec '$(command -v sleep)' "\$@"
EOF
	chmod +x "$sleepbin/sleep"
	for sig in TERM INT; do
		expected=143
		[ "$sig" != INT ] || expected=130
		for phase in waiting patch settle relook notready opwait kept; do
			rm -rf "$dir"
			reset '"seed":{"count":1}'
			case "$phase" in
			waiting) mkdir -p "$dir/claim.lock"; lock_owner "$$" >"$dir/claim.lock/pid" ;;
			relook) ctl '{"opDelay":120,"set":{"box-1":{"state":"creating"}}}' ;;
			notready) ctl '{"set":{"box-1":{"ready":false}}}' ;;
			opwait) ctl '{"set":{"box-1":{"state":"suspended"}},"faults":[{"kind":"error","method":"GET","match":"/v1/operations/","status":403,"code":"permission_denied","count":100}]}' ;;
			patch) ctl '{"faults":[{"kind":"delay","method":"PATCH","seconds":2}]}' ;;
			kept) ctl '{"faults":[{"kind":"delay","method":"PUT","match":"/activity-leases/","seconds":2}]}' ;;
			esac
			rm -f "$S/sleep-ready"
			local expect=
			case $phase in settle | relook) expect=20 ;; notready | opwait) expect=3 ;; esac
			IBX_STATE_DIR=$dir PATH="$sleepbin:$PATH" IBX_SLEEP_EXPECT=$expect IBX_SLEEP_MARKER=$S/sleep-ready \
				IBX_CLAIM_SETTLE="$(if [ "$phase" = settle ]; then echo '20 5'; else echo '0.2 0.1'; fi)" signal_claim --json x
			for _ in $(seq 600); do
				case "$phase" in
				waiting) [ "$(count GET '^/v1/machines/m_[a-z2-7]{26}$')" -gt 0 ] && break ;;
				settle | relook | notready | opwait) [ -e "$S/sleep-ready" ] && break ;;
				patch) [ "$(count PATCH .)" -gt 0 ] && break ;;
				kept) [ "$(count PUT '/activity-leases/')" -gt 0 ] && break ;;
				esac
				sleep 0.05
			done
			sleep 0.15
			t0=$SECONDS
			kill -"$sig" "$SIGNAL_PID"
			wait "$SIGNAL_PID"
			RC=$? TIMEDOUT=
			rc_is "$sig during $phase: usual exit status" "$expected"
			is "$sig during $phase: exactly one interrupted JSON object" \
				"$(jq -sc 'length == 1 and .[0].error.code == "interrupted"' "$S/out")" true
			if [ "$phase" = settle ] || [ "$phase" = relook ] || [ "$phase" = notready ] || [ "$phase" = opwait ]; then
				yes_ "$sig during $phase: entered the intended sleep" [ -e "$S/sleep-ready" ]
				yes_ "$sig during $phase: interrupts a 20-second sleep promptly ($((SECONDS - t0)) s)" [ $((SECONDS - t0)) -lt 10 ]
			fi
			if [ "$phase" = waiting ]; then
				yes_ "$sig while waiting: responds at once" [ $((SECONDS - t0)) -lt 3 ]
				is "$sig while waiting: the other owner remains" "$(cat "$dir/claim.lock/pid")" "$(lock_owner "$$")"
				rm -rf "$dir/claim.lock"
			else
				yes_ "$sig during $phase: no claim.lock remains" [ ! -e "$dir/claim.lock" ]
			fi
			if [ "$phase" = kept ]; then
				is "$sig after keep: the caller learns the reserved box" "$(jq -c '.error.held | map({name,id})' "$S/out")" \
					"$(state | jq -c '[.machines[] | {name,id}]')"
				is "$sig after keep: the reservation is still held" "$(claim_keys box-1)" 5
			else
				is "$sig during $phase: no reservation remains" "$(claim_keys box-1)" 0
			fi
		done
	done
	reset '"seed":{"count":1},"faults":[{"kind":"delay","method":"PUT","match":"/activity-leases/","seconds":2}]'
	IBX_STATE_DIR=$dir signal_claim x
	for _ in $(seq 600); do [ "$(count PUT '/activity-leases/')" -gt 0 ] && break; sleep 0.05; done
	yes_ "plain claim reaches the keep stage before interruption" [ "$(count PUT '/activity-leases/')" -gt 0 ]
	kill -TERM "$SIGNAL_PID"
	wait "$SIGNAL_PID"
	RC=$? TIMEDOUT=
	rc_is "plain claim interrupted after keep: exit 143" 143
	err_has "plain interruption names the sandbox to release" 'sandbox still reserved: box-1'
	yes_ "plain interruption leaves no claim.lock" [ ! -e "$dir/claim.lock" ]
	local failbin=$S/fail-jq real_jq
	mkdir -p "$failbin"
	real_jq=$(command -v jq)
	cat >"$failbin/jq" <<EOF
#!/bin/sh
case "\$*" in *'.expiresAt | clean'*) exit 17 ;; esac
exec '$real_jq' "\$@"
EOF
	chmod +x "$failbin/jq"
	reset '"seed":{"count":1}'
	run PATH="$failbin:$PATH" claim --json x
	rc_is "an unhandled command failure keeps its status" 17
	is "cleanup backstop emits exactly one failed JSON object" \
		"$(jq -sc 'length == 1 and .[0].error.code == "failed" and .[0].error.message == "exit 17"' "$S/out")" true
	is "a failed backstop with a kept claim tells the caller which box to release" \
		"$(jq -c '.error.held | map(.name)' "$S/out")" '["box-1"]'
	yes_ "the cleanup backstop leaves no claim.lock" [ ! -e "$IBX_STATE_DIR/claim.lock" ]

}

t_claim_signal_commit() {
	group "claim: atomic keep and JSON emission during interruption"
	local copy=$S/commit-ibx marker=$S/commit-ready original=$IBX pid rc bin=$S/json-write-bin real_jq
	# Pause immediately after the keep assignment, before the claimed_ids update.
	python3 - "$IBX" "$copy" <<'PYCODE'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
source = source.replace('\t\t\tclaimed_ids=("${claimed_ids[@]/$id/}")', '\t\t\t: >"$IBX_COMMIT_MARKER"\n\t\t\tsleep_for 20\n\t\t\tclaimed_ids=("${claimed_ids[@]/$id/}")', 1)
Path(sys.argv[2]).write_text(source)
PYCODE
	chmod +x "$copy"
	reset '"seed":{"count":1}'
	IBX=$copy IBX_COMMIT_MARKER=$marker signal_claim --json x
	# Up to 20 s: the claim makes several API writes before it gets there, and a loaded CI
	# host can take more than 5 s for them.
	for _ in $(seq 400); do [ -e "$marker" ] && break; sleep 0.05; done
	yes_ "the claim pauses at its keep commit point" [ -e "$marker" ]
	kill -TERM "$SIGNAL_PID"
	wait "$SIGNAL_PID"; RC=$? TIMEDOUT=
	rc_is "interruption at the keep commit point exits 143" 143
	is "interruption at the keep commit point reports one held box" "$(jq -sc 'length == 1 and .[0].error.code == "interrupted" and .[0].error.held[0].name == "box-1"' "$S/out")" true
	is "cleanup preserves the box reported as kept" "$(claim_keys box-1)" 5
	yes_ "the commit-point interruption leaves no lock" [ ! -e "$IBX_STATE_DIR/claim.lock" ]

	reset '"seed":{"count":1}'
	python3 - "$original" "$BASE" "$S/out" "$S/err" <<'PYCODE'
import json, os, signal, subprocess, sys, time, urllib.request
proc = subprocess.Popen([sys.argv[1], 'claim', '--json', 'pipe interruption'],
                        env=dict(os.environ, IBX_CLAIM_SETTLE='20 5'),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    for _ in range(200):
        with urllib.request.urlopen(sys.argv[2] + '/_calls') as reply:
            calls = json.load(reply)['calls']
        if any(call['method'] == 'PATCH' for call in calls):
            break
        time.sleep(0.05)
    time.sleep(0.15)
    proc.send_signal(signal.SIGTERM)
    out, err = proc.communicate(timeout=3)
    status = 0 if proc.returncode == 143 else 1
except subprocess.TimeoutExpired:
    proc.kill()
    out, err = proc.communicate(timeout=25)
    status = 1
finally:
    from pathlib import Path
    Path(sys.argv[3]).write_bytes(out)
    Path(sys.argv[4]).write_bytes(err)
sys.exit(status)
PYCODE
	RC=$? TIMEDOUT=
	rc_is "interrupted settle closes stdout pipes promptly, including the sleep child's copy" 0
	is "pipe interruption returns one JSON error" "$(jq -sc 'length == 1 and .[0].error.code == "interrupted"' "$S/out")" true
	is "pipe interruption releases the reservation" "$(claim_keys box-1)" 0

	# Interrupt while a failed error object is only partially written to its candidate file.
	mkdir "$bin"
	real_jq=$(command -v jq)
	cat >"$bin/jq" <<EOF
#!/bin/sh
case "\$*" in *'--arg c failed'*)
	printf '{'
	: >"$S/json-write-ready"
	sleep 0.5
	exit 17
	;;
esac
exec '$real_jq' "\$@"
EOF
	chmod +x "$bin/jq"
	PATH="$bin:$PATH" "$original" claim --json --unknown >"$S/out" 2>"$S/err" </dev/null & pid=$!
	for _ in $(seq 100); do [ -e "$S/json-write-ready" ] && break; sleep 0.05; done
	kill -TERM "$pid"
	wait "$pid"; RC=$? TIMEDOUT=
	rc_is "interruption while writing a JSON error exits 143" 143
	is "a partial candidate never suppresses the interrupted JSON object" "$(jq -sc 'length == 1 and .[0].error.code == "interrupted"' "$S/out")" true
	# A cleanup serialization failure must preserve the original status and still remove tmp.
	cat >"$bin/jq" <<EOF
#!/bin/sh
case "\$*" in *'. + {warnings:'*) exit 19 ;; esac
exec '$real_jq' "\$@"
EOF
	run PATH="$bin:$PATH" release --json nosuchbox
	rc_is "cleanup serialization failure preserves the original exit status" 125
	is "cleanup serialization failure returns one fixed error object" "$(jq -sc 'length == 1 and .[0].error.code == "failed"' "$S/out")" true
	is "cleanup removes temporary directories even after a failing command" "$(find "$TMPDIR" -maxdepth 1 -name 'ibx.*' | wc -l | tr -d ' ')" 0
	# No API-backed command should run under the altered test copy after this group.
	IBX=$original
}

t_claim_fresh() {
	group "claim: recheck the GET used for the metadata write"
	reset '"seed":{"count":1},"faults":[{"kind":"delay","method":"GET","match":"^/v1/machines/m_[a-z2-7]{26}$","skip":1,"seconds":2}]'
	local pid
	"$IBX" claim --json x >"$S/out" 2>"$S/err" </dev/null &
	pid=$!
	for _ in $(seq 100); do
		[ "$(count GET '^/v1/machines/m_[a-z2-7]{26}$')" -ge 2 ] && break
		sleep 0.05
	done
	hold box-1 0 another-computer
	wait "$pid"
	RC=$? TIMEDOUT=
	rc_is "claim skips a candidate reserved during its final GET" 75
	is "the other computer's reservation is kept" "$(box box-1 '.metadata["ibx.claim.by"]')" another-computer
	is "the final GET guard prevents the PATCH" "$(count PATCH .)" 0
}

t_claim_json() {
	group "claim, renew and release JSON"
	reset '"seed":{"count":1},"set":{"box-1":{"ports":[{"port":8080,"name":"ibx:old"},{"port":8081,"name":"manual"}]}}'
	run claim x --json
	rc_is "claim accepts --json after the purpose" 0
	is "claim JSON keys" "$(jq -c 'keys' "$S/out")" '["by","cooldownUntil","id","leaseUntil","name","pausesAt","publicPorts","purpose","since","warnings"]'
	is "claim JSON includes public ports" "$(jq -c '[.publicPorts[].port]' "$S/out")" '[8080,8081]'
	yes_ "claim JSON includes lease expiry and warnings" jq -e '.leaseUntil | type == "string"' "$S/out"
	is "claim JSON collects each port warning" "$(jq '.warnings | length' "$S/out")" 3
	run renew --json box-1
	rc_is "renew --json succeeds" 0
	is "renew JSON keys" "$(jq -c 'keys' "$S/out")" '["abandonedAfter","by","id","name","since","warnings"]'
	is "renew JSON since matches the written timestamp" "$(jq -r .since "$S/out")" "$(box box-1 '.metadata["ibx.claim.at"]')"
	is "renew has no warnings" "$(jq -c .warnings "$S/out")" '[]'
	run release box-1 --json
	rc_is "release accepts --json after the box" 0
	is "release JSON keys" "$(jq -c 'keys' "$S/out")" '["id","leftAlone","name","unpublishReasons","unpublished","warnings","was"]'
	is "release JSON lists unpublished and untouched ports" "$(jq -c '[.unpublished, [.leftAlone[].port], .was.by]' "$S/out")" '[[8080],[8081],"tester"]'
	is "release JSON collects its warning" "$(jq '.warnings | length' "$S/out")" 1
	run release --json box-1
	is "release JSON was is null without a reservation" "$(jq -c .was "$S/out")" null
	run release --json nosuchbox
	rc_is "a die inside resolve exits 125" 125
	is "a die inside resolve emits exactly one JSON object to original stdout" \
		"$(jq -sc 'length == 1 and .[0].error.code == "failed" and (.[0].warnings == [])' "$S/out")" true
	err_has "a die inside resolve keeps the usual stderr" 'no sandbox named nosuchbox'
	reset
	hold box-1 10 someone
	hold box-2 10 someone-else
	hold box-3 10 third
	run claim --json x
	rc_is "no free sandbox JSON exits 75" 75
	is "no free sandbox JSON has one object and holders" \
		"$(jq -sc 'length == 1 and .[0].error.code == "no_free_sandbox" and (.[0].error.held | length == 3)' "$S/out")" true
	err_has "no free sandbox stderr lists holders and purpose" 'box-1: held by someone since .*: earlier job'
	reset '"faults":[{"kind":"error","method":"PUT","match":"/activity-leases/","status":403,"code":"permission_denied"}]'
	run claim --json x
	rc_is "a failed lease still returns a successful claim" 0
	is "a failed lease has a null expiry" "$(jq -c .leaseUntil "$S/out")" null
	is "the lease warning is included" "$(jq '.warnings | length' "$S/out")" 1
	ctl "$(jq -cn --arg at "$(ago 10)" '{reset:true,seed:{count:1},set:{"box-1":{
		name:"evil\u001b[2Jbox",mergeMetadata:{"ibx.claim.by":"other\u0007", "ibx.claim.at":$at,
		"ibx.claim.purpose":"job\u001b[31m", "ibx.claim.token":"other-token"},
		ports:[{port:8081,name:"manual\u0007",url:"https://a.mock.invalid/\u001b[2J"}]}}}')"
	local id
	id=$(state | jq -r '.machines[0].id')
	run claim --json x
	rc_is "hostile holder strings still give exit 75" 75
	is "JSON holders are cleaned" "$(jq -c '.error.held[0] | [.name,.by,.purpose]' "$S/out")" '["evil [2Jbox","other ","job [31m"]'
	yes_ "the holder message has no terminal controls" eval '! has_ctl "$S/out" "$S/err"'
	run IBX_ALLOW_ANY=1 renew "$id" --json
	is "renew JSON cleans API strings" "$(jq -c '[.name,.by]' "$S/out")" '["evil [2Jbox","other "]'
	run IBX_ALLOW_ANY=1 release --json "$id"
	is "release JSON cleans previous holder and public ports" \
		"$(jq -c '[.name,.was.by,.leftAlone[0].name,.leftAlone[0].url]' "$S/out")" \
		'["evil [2Jbox","other ","manual ","https://a.mock.invalid/ [2J"]'
	run claim --json x
	is "claim JSON cleans the API name and public port fields" \
		"$(jq -c '[.name,.publicPorts[0].name,.publicPorts[0].url]' "$S/out")" \
		'["evil [2Jbox","manual ","https://a.mock.invalid/ [2J"]'

	reset
	printf '%s\n' "$KEY" >"$S/json-key"
	chmod 644 "$S/json-key"
	run -u INSTABOX_API_KEY IBX_KEY_FILE="$S/json-key" release --json nosuchbox
	is "warnings before a resolve error survive subshells" "$(jq '.warnings | length' "$S/out")" 1
}

t_claim_errors() {
	group "claim: dependency errors, final listing and malformed ports"
	local nojq=$S/nojq dep spy=$S/fd-spy real_curl
	mkdir -p "$nojq"
	for dep in bash uname readlink cksum cut mktemp sed grep curl awk rm ln cat; do
		ln -s "$(command -v "$dep")" "$nojq/$dep"
	done
	run PATH="$nojq" claim --json x
	rc_is "missing jq preserves die's exit 125 in JSON mode" 125
	err_has "missing jq reports the dependency" 'jq is missing'
	err_lacks "missing jq does not try to emit JSON through a missing program" 'jq: command not found'
	is "missing jq still emits one fixed JSON error" "$(jq -sc 'length == 1 and .[0].error.code == "failed" and .[0].error.message == "jq is missing"' "$S/out")" true
	local failtmp=$S/fail-mktemp
	mkdir "$failtmp"
	printf '#!/bin/sh\nexit 1\n' >"$failtmp/mktemp"
	chmod +x "$failtmp/mktemp"
	run PATH="$failtmp:$PATH" claim --json x
	rc_is "mktemp failure exits 125" 125
	is "mktemp failure still emits exactly one JSON error" "$(jq -sc 'length == 1 and .[0].error.code == "failed"' "$S/out")" true
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"GET","match":"/ports$","status":403,"code":"permission_denied"}]'
	run claim --json x
	rc_is "a failed public ports listing still returns the claim" 0
	is "failed public ports listing is explicit in JSON" "$(jq -c '.publicPorts' "$S/out")" null
	yes_ "failed public ports listing includes the recovery warning" jq -e '.warnings | any(test("could not list the public ports of box-1; check with ibx release"))' "$S/out"
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"GET","match":"^/v1/machines$","skip":1,"count":4,"status":503,"code":"unavailable"}]'
	hold box-1 0 someone
	run claim --json x
	rc_is "no free sandbox does not depend on a redundant final listing" 75
	is "no free sandbox uses its existing listing" "$(count GET '^/v1/machines$')" 1
	is "no free sandbox still emits one structured refusal" \
		"$(jq -sc 'length == 1 and .[0].error.code == "no_free_sandbox"' "$S/out")" true
	reset '"seed":{"count":1},"set":{"box-1":{"rawPorts":[{"port":"8080","name":"ibx:string","url":"bad-string"},{"port":"bad\u001b[2J","name":"ibx:escape","url":"bad-escape"},{"port":-5,"name":"ibx:negative","url":"bad-negative"},{"port":8080.5,"name":"ibx:fraction","url":"bad-fraction"},{"port":8081,"name":"manual","url":"https://valid.mock.invalid"}]}}'
	run claim --json x
	rc_is "claim ignores malformed public port numbers" 0
	is "only the numeric integer public port is reported" "$(jq -c '[.publicPorts[].port]' "$S/out")" '[8081]'
	err_lacks "malformed public ports are not printed" 'bad-string|bad-escape|bad-negative|bad-fraction'
	run release --json box-1
	rc_is "release ignores malformed public port numbers" 0
	is "release reports only the valid manual port" "$(jq -c '[.leftAlone[].port]' "$S/out")" '[8081]'
	is "no malformed port reaches an API path" "$(count DELETE '/ports/')" 0
	run claim one two
	rc_is "an unquoted multiword purpose is rejected" 125
	err_has "claim explains that its purpose is ONE quoted argument" 'purpose must be ONE quoted argument'
	if [ -d /proc/self/fd ]; then
		mkdir -p "$spy"
		real_curl=$(command -v curl)
		cat >"$spy/curl" <<EOF
#!/bin/sh
for fd in /proc/\$\$/fd/*; do
	[ "\$(readlink "\$fd" 2>/dev/null)" != "$S/out" ] || printf '%s\n' "\$fd" >>"$S/extra-stdout"
done
exec '$real_curl' "\$@"
EOF
		chmod +x "$spy/curl"
		reset
		: >"$S/extra-stdout"
		run PATH="$spy:$PATH" ls
		yes_ "plain commands do not leak a copy of stdout to curl" [ ! -s "$S/extra-stdout" ]
		run PATH="$spy:$PATH" release --json nosuchbox
		yes_ "JSON commands retain the original stdout for subshell errors" [ -s "$S/extra-stdout" ]
	fi
}

t_claim_states() {
	group "claim: abandoned reservations and sandbox states"
	reset
	hold box-1 10
	hold box-2 10
	hold box-3 10
	run IBX_STALE_SECS=5 claim "take over"
	rc_is "an abandoned reservation can be claimed" 0
	local got
	got=$(OUT)
	is "the new reservation replaces the old one" "$(box "$got" '.metadata["ibx.claim.by"]')" tester
	run claim "not abandoned yet"
	rc_is "reservations younger than IBX_STALE_SECS are respected" 75

	reset
	ctl "{\"set\":{\"box-1\":{\"mergeMetadata\":$(claim_md garbage)},\"box-2\":{\"mergeMetadata\":$(claim_md "$(ago -3600)")}}}"
	hold box-3 0
	run IBX_STALE_SECS=5 claim x
	rc_is "unreadable or future reservation dates are never taken over" 75

	reset '"set":{"box-1":{"state":"suspended"}}'
	hold box-2 0
	hold box-3 0
	run claim "paused one"
	rc_is "claim resumes a paused sandbox" 0
	is "claim returned the paused sandbox" "$(OUT)" box-1
	is "it was resumed once" "$(count POST '/resume$')" 1
	is "it runs now" "$(box box-1 .state)" running

	reset '"set":{"box-1":{"state":"suspended"}},"conflictResumes":1'
	hold box-2 0
	hold box-3 0
	run claim "conflict"
	rc_is "claim waits out an operation_conflict on resume" 0
	is "the conflicting resume was not repeated" "$(count POST '/resume$')" 1
	is "it runs after the other operation" "$(box box-1 .state)" running

	reset '"set":{"box-1":{"state":"stopped"}}'
	hold box-2 0
	hold box-3 0
	run claim "stopped one"
	rc_is "claim starts a stopped sandbox" 0
	is "a stopped sandbox is started" "$(count POST '/start$')" 1

	reset '"set":{"box-1":{"state":"idle"}}'
	hold box-2 0
	hold box-3 0
	LIMIT=20 run claim "idle one"
	rc_is "claim wakes a sandbox paused when idle" 0
	is "an idle-paused sandbox is woken, not resumed" "$(count POST '/wake$'):$(count POST '/resume$')" 1:0
	is "the woken sandbox runs" "$(box box-1 .state)" running

	reset '"set":{"box-1":{"state":"suspended","freshBoot":true}}'
	hold box-2 0
	hold box-3 0
	run claim "fresh"
	rc_is "claim of a sandbox that boots fresh" 0
	err_has "a fresh boot is warned about" 'came back with a fresh boot'

	reset '"set":{"box-1":{"state":"suspended"}},"failOps":1'
	hold box-2 0
	hold box-3 0
	run claim "broken"
	rc_is "a sandbox that will not start is skipped" 75
	err_has "it says the sandbox would not start" 'box-1 would not start; trying another'
	is "its reservation is cleared again" "$(claim_keys box-1)" 0

	reset '"set":{"box-1":{"state":"suspended"}}'
	hold box-2 0
	run claim "prefer running"
	is "running sandboxes are claimed before paused ones" "$(OUT):$(count POST '/resume$')" box-3:0

	reset '"set":{"box-1":{"ports":[{"port":8080,"name":"ibx:old"}]}}'
	hold box-2 0
	hold box-3 0
	run claim "left ports"
	rc_is "claim of a sandbox with public ports" 0
	err_has "leftover public ports are warned about" 'still has public ports from before'
	err_has "the warning lists the URL" '8080 ibx:old https://'

	reset
	hold box-2 0
	hold box-3 0
	IBX_CLAIM_SETTLE='2 1' "$IBX" claim "interrupted" >"$S/out" 2>"$S/err" </dev/null &
	local pid=$!
	for _ in $(seq 50); do
		[ "$(claim_keys box-1)" = 5 ] && break
		sleep 0.1
	done
	kill -TERM "$pid"
	wait "$pid"
	RC=$? TIMEDOUT=
	rc_is "an interrupted claim exits 143" 143
	err_has "it says it got SIGTERM" '^ibx: interrupted by SIGTERM'
	is "an interrupted claim clears its reservation" "$(claim_keys box-1)" 0
}

t_renew() {
	group renew
	reset '"set":{"box-1":{"mergeMetadata":{"owner.note":"keep me"}}}'
	hold box-1 7200 tester
	run renew box-1
	rc_is "renew" 0
	out_has "renew says when it counts as abandoned" '^renewed box-1; it counts as abandoned after 20'
	yes_ "renew moves the reservation time to now" eval '[ $(( $(date +%s) - $(box box-1 ".metadata[\"ibx.claim.at\"] | fromdate") )) -lt 60 ]'
	is "renew keeps everything else" "$(box box-1 '.metadata | del(.["ibx.claim.at"])')" \
		"$(claim_md x tester | jq -cS '. + {"ibx.pool":"1","owner.note":"keep me"} | del(.["ibx.claim.at"])')"
	run renew box-2
	rc_is "renew of a free sandbox fails" 125
	err_has "renew of a free sandbox says so" 'no live reservation to renew'
	run renew
	rc_is "renew without a sandbox is a usage error" 125
}

t_release() {
	group release
	local setup
	setup='"set":{"box-1":{"mergeMetadata":{"owner.note":"keep me"},"leases":["ibx-keepalive","other-task"],
		"ports":[{"port":8080,"name":"ibx:web"},{"port":8081,"name":"dashboard"},{"port":8082,"name":"ibx:port"}]}}'
	reset "$setup"
	hold box-1 60 tester
	run release box-1
	rc_is "release" 0
	out_has "release unpublishes ibx ports" '^unpublished port 8080 of box-1$'
	out_has "release unpublishes every ibx port" '^unpublished port 8082 of box-1$'
	out_has "release says what was released" '^released box-1 \(was: earlier job \(tester, since 20'
	err_has "release leaves other ports alone, and says so" 'left port 8081 alone'
	is "only the port ibx did not publish is left" "$(box box-1 '[.ports[].port]')" '[8081]'
	is "release deletes only the ibx lease" "$(box box-1 '[.leases[].id]')" '["other-task"]'
	is "release clears ibx.claim.* and keeps the rest" "$(box box-1 .metadata)" '{"ibx.pool":"1","owner.note":"keep me"}'
	run release box-2
	rc_is "release of a free sandbox" 0
	out_has "release of a free sandbox says there was no reservation" 'was: no reservation'

	reset "$setup,\"faults\":[{\"kind\":\"error\",\"method\":\"DELETE\",\"match\":\"/ports/\",\"count\":9,\"status\":403,\"code\":\"permission_denied\",\"message\":\"no\"}]"
	hold box-1 60 tester
	run release box-1
	rc_is "release fails when a port cannot be unpublished" 125
	err_has "it names the URLs that are still public" 'STILL PUBLIC: https://'
	is "the reservation is kept" "$(claim_keys box-1)" 4
	is "the lease is kept" "$(box box-1 '[.leases[].id]')" '["ibx-keepalive","other-task"]'

	reset "$setup,\"faults\":[{\"kind\":\"error\",\"method\":\"GET\",\"match\":\"/ports$\",\"status\":403,\"code\":\"permission_denied\",\"message\":\"no\"}]"
	hold box-1 60 tester
	run release box-1
	rc_is "release fails when the ports cannot be listed" 125
	err_has "it says nothing was released" 'nothing released'
	is "nothing was changed" "$(count DELETE .):$(count PATCH .)" 0:0

	# A DELETE that is retried after the first one went through gets 404: already unpublished.
	reset "$setup,\"faults\":[{\"kind\":\"error\",\"method\":\"DELETE\",\"match\":\"/ports/8080$\",\"status\":404,\"code\":\"not_found\",\"message\":\"port 8080 is not public\"}]"
	hold box-1 60 tester
	run release box-1
	rc_is "release when a port DELETE answers 404" 0
	out_has "that port counts as unpublished" '^unpublished port 8080 of box-1$'
	is "and the reservation is cleared" "$(claim_keys box-1)" 0
}

t_port() {
	group "port/unport"
	reset
	local bad_args
	for bad_args in "port box-1 abc" "port box-1 8080;x" "port box-1 -1" "unport box-1 ../../x" \
		"unport box-1 8080/../../v1" "unport box-1 80%2f.." "port box-1" "unport box-1" "unport box-1 8080 9090"; do
		# shellcheck disable=SC2086 # split on purpose
		run $bad_args
		rc_is "rejected before any request: ibx $bad_args" 125
	done
	is "the mock saw no request for them" "$(ncalls)" 0
	run port box-1 8080 web
	rc_is "port" 0
	local url
	url=$(OUT)
	yes_ "port prints the public URL" eval '[[ $url =~ ^https://[^[:space:]]+$ ]]'
	err_has "port warns that the URL has no authentication" 'NO authentication'
	is "the port is published under an ibx: name" "$(box box-1 '.ports[] | select(.port == 8080) | .name')" ibx:web
	run port box-1 08081
	rc_is "port with a leading zero" 0
	is "08081 is port 8081, named ibx:port" "$(box box-1 '.ports[] | select(.port == 8081) | .name')" ibx:port
	run port box-1 8080 renamed
	rc_is "port again" 0
	is "publishing again keeps the URL" "$(OUT)" "$url"
	run port box-1 80
	rc_is "a port the API refuses" 125
	err_has "the API's reason is shown" 'port must be 1024-65535'
	run unport box-1 8080
	rc_is "unport" 0
	is "unport removed it" "$(box box-1 '[.ports[].port]')" '[8081]'
	run unport box-1 9999
	rc_is "unport of a port that is not public is a no-op (a retried DELETE gets 404)" 0
}

t_keepalive() {
	group keepalive
	# box-1 held+running, box-2 free, box-3 held+idle-paused, box-4 held+paused by hand,
	# box-5 held but not in the pool, box-6 abandoned
	local setup='"seed":{"count":6,"pool":[1,1,1,1,0,1]},"set":{"box-3":{"state":"idle"},"box-4":{"state":"suspended"}}'
	reset "$setup"
	hold box-1 60
	hold box-3 60
	hold box-4 60
	hold box-5 60
	hold box-6 $((3 * 86400))
	run keepalive
	rc_is "keepalive" 0
	is "keepalive leases only reserved pool sandboxes that run or idle" \
		"$(state | jq -c '[.machines[] | select(.leases | map(.id) == ["ibx-keepalive"]) | .name]')" '["box-1","box-3"]'
	out_has "keepalive reports the lease" '^box-1: lease until 20'
	out_has "keepalive skips a sandbox paused by hand" '^box-4: suspended, skipped$'
	is "keepalive does not mention free or outside sandboxes" "$(grep -cE '^box-(2|5|6):' "$S/out")" 0
	is "keepalive wakes a sandbox paused when idle" "$(box box-3 '[.state, .autoSuspendedAt]')" '["running",null]'
	is "a paused-by-hand sandbox stays paused" "$(box box-4 .state)" suspended

	reset "$setup"
	hold box-1 60
	hold box-4 60
	run keepalive --all
	rc_is "keepalive --all" 0
	is "keepalive --all leases every running or idle pool sandbox" \
		"$(state | jq -c '[.machines[] | select(.leases | length > 0) | .name]')" '["box-1","box-2","box-3","box-6"]'

	reset "$setup,\"faults\":[{\"kind\":\"error\",\"method\":\"PUT\",\"count\":9,\"status\":409,\"code\":\"operation_conflict\",\"message\":\"busy\"}]"
	hold box-1 60
	run keepalive
	rc_is "keepalive fails when a lease cannot be set" 1
	out_has "it says which one failed" '^box-1: FAILED .*operation_conflict'
}

t_exec() {
	group exec
	reset
	run exec box-1 -- 'exit 7'
	rc_is "exec passes the exit code through" 7
	run exec box-1 -t 08 -- 'exit 4'
	rc_is "exec -t 08 (base 10)" 4
	is "-t 08 is sent as 8 seconds" "$(last_exec .timeoutSeconds)" 8
	run exec box-1 -- true
	is "the default timeout is 300 s" "$(last_exec .timeoutSeconds)" 300
	run exec box-1 -t 600 -- true
	rc_is "-t 600 is allowed" 0
	is "exec sends no Idempotency-Key (a retry would run it again)" \
		"$(calls | jq '[.calls[] | select((.path | test("/exec$")) and .idempotencyKey != null)] | length')" 0

	ctl '{"resetCalls":true}'
	local t
	for t in 0 601 abc -5 '' 1.5 99999999999999999999999; do
		run exec box-1 -t "$t" -- true
		rc_is "exec -t '$t' is rejected" 125
	done
	run exec box-1 -t
	rc_is "exec -t without a value is rejected" 125
	run exec box-1
	rc_is "exec without a command is a usage error" 125
	run exec box-1 --
	rc_is "exec with an empty command is a usage error" 125
	is "the mock saw no request for them" "$(ncalls)" 0

	run exec box-1 -- printf '<%s>' 'a b' 'x;y'
	rc_is "exec with several arguments" 0
	is "several arguments are sent as one quoted command" "$(last_exec .cmd)" "$(printf '%q ' printf '<%s>' 'a b' 'x;y')"
	if [ -n "$REAL" ]; then
		is "several arguments keep their boundaries" "$(OUT)" '<a b><x;y>'
		hold box-1 60 tester
		run exec box-1 -- 'echo out; echo err >&2; exit 3'
		rc_is "one argument is a script" 3
		is "stdout goes to stdout" "$(OUT)" out
		is "stderr goes to stderr" "$(ERR)" err
	fi
	run exec box-1 -t 1 -- 'sleep 5'
	rc_is "a timed-out exec exits 124" 124
	err_has "a timeout suggests running detached" 'timed out after 1s'
	err_has "with stdin redirected too" 'setsid -f CMD </dev/null >LOG 2>&1'

	ctl '{"execResults":[{"stdout":"partial","truncated":true},{"exitCode":143,"signal":"TERM"}]}'
	run exec box-1 -- 'cat huge'
	is "truncated output is passed on" "$(OUT)" partial
	err_has "truncated output is warned about" 'output truncated'
	run exec box-1 -- 'pkill -f x'
	rc_is "exit code 143 is passed on" 143
	err_has "exit code 143 is explained" 'killed by SIGTERM'

	reset '"quotaExecs":1'
	run exec box-1 -- 'exit 0'
	rc_is "exec retries after 429 quota_exceeded" 0
	is "429, then the command ran" "$(calls | jq -c '[.calls[] | select(.path | test("/exec$")) | .status]')" '[429,200]'

	reset '"set":{"box-1":{"state":"suspended"}}'
	run exec box-1 -- 'exit 5'
	rc_is "exec on a paused sandbox resumes it, then runs" 5
	is "409 machine_not_running, resume, run" \
		"$(calls | jq -c '[.calls[] | select(.method == "POST") | [(.path | split("/") | last), .status]]')" \
		'[["exec",409],["resume",202],["exec",200]]'

	reset '"set":{"box-1":{"state":"idle"}}'
	LIMIT=20 run exec box-1 -- 'exit 6'
	rc_is "exec on an idle-paused sandbox wakes it, then runs" 6
	is "409 machine_not_running, one wake, run" \
		"$(calls | jq -c '[.calls[] | select(.method == "POST") | [(.path | split("/") | last), .status]]')" \
		'[["exec",409],["wake",200],["exec",200]]'
	is "the woken box is running" "$(box box-1 .state)" running

	reset '"dropExecs":1'
	run exec box-1 -- 'echo ran >>ran.txt'
	rc_is "a dropped exec reply fails with 125" 125
	err_has "it says the command may have run" 'may or may not have run'
	is "a dropped exec is never retried" "$(count POST '/exec$')" 1
	if [ -n "$REAL" ]; then
		is "the command ran exactly once" "$(wc -l <"$(box box-1 .home)/ran.txt" | tr -d ' ')" 1
	fi

	reset '"faults":[{"kind":"error","method":"POST","match":"/exec$","status":400,"code":"bad_request","message":"cmd too long"}]'
	run exec box-1 -- true
	rc_is "a rejected exec fails with 125" 125
	err_has "it says the command did not run" 'exec rejected \(the command did not run\)'
	reset '"faults":[{"kind":"error","method":"POST","match":"/exec$","status":503,"code":"host_unavailable","retryable":false}]'
	run exec box-1 -- true
	rc_is "host_unavailable (not retryable) fails with 125" 125
	is "and is not retried" "$(count POST '/exec$')" 1
	reset '"faults":[{"kind":"error","method":"POST","match":"/exec$","status":503,"code":"host_unavailable","retryable":true}]'
	run EXEC_SAFE=1 exec box-1 -- 'exit 2'
	rc_is "host_unavailable never repeats a user command" 125
	is "the potentially partly-run command is not retried" "$(count POST '/exec$')" 1
	run exec nosuch -- true
	rc_is "exec on an unknown sandbox fails" 125

	local mnr='{"kind":"error","method":"POST","match":"/exec$","status":409,"code":"machine_not_running","message":"stopped"'
	reset "\"faults\":[$mnr,\"count\":3}]"
	run exec box-1 -- 'exit 4'
	rc_is "machine_not_running is handled up to 3 times" 4
	is "three 409s, then it ran" "$(calls | jq -c '[.calls[] | select(.path | test("/exec$")) | .status]')" '[409,409,409,200]'
	reset "\"faults\":[$mnr,\"count\":4}]"
	run exec box-1 -- 'exit 4'
	rc_is "a fourth machine_not_running gives up" 125
	err_has "it says the command did not run" 'exec did not run: .* keeps stopping'
	is "after four tries" "$(count POST '/exec$')" 4
	local code status
	for code in api_key_expired api_key_revoked unauthenticated missing_key malformed_key invalid_key expired_key revoked_key session_expired missing_scope insufficient_scope; do
		case $code in missing_scope | insufficient_scope) status=403 ;; *) status=401 ;; esac # as the API sends them
		reset "\"faults\":[{\"kind\":\"error\",\"method\":\"POST\",\"match\":\"/exec\$\",\"status\":$status,\"code\":\"$code\",\"message\":\"no\"}]"
		run exec box-1 -- true
		rc_is "$code: exec fails with 125" 125
		err_has "$code: it says the command did not run" 'exec rejected \(the command did not run\)'
		is "$code: and does not retry" "$(count POST '/exec$')" 1
	done
}

t_exec_wait_signals() {
	group "exec: interrupted retry sleeps close stdout pipes"
	local bin=$S/exec-sleep kind marker=$S/exec-sleep-ready real_sleep
	mkdir "$bin"
	real_sleep=$(command -v sleep)
	cat >"$bin/sleep" <<EOF
#!/bin/sh
printf '%s\\n' "\$\$" >"\$IBX_EXEC_SLEEP_MARKER"
exec '$real_sleep' 20
EOF
	chmod +x "$bin/sleep"
	printf 'safe retry fixture\n' >"$S/retry-safe.txt"
	for kind in quota host; do
		rm -f "$marker"
		case $kind in
		quota) reset '"quotaExecs":100' ;;
		host) reset '"faults":[{"kind":"error","method":"PUT","match":"/files$","status":503,"code":"host_unavailable","retryable":true,"count":100}]' ;;
		esac
		PATH="$bin:$PATH" IBX_EXEC_SLEEP_MARKER=$marker python3 - "$IBX" "$marker" "$S/out" "$S/err" "$kind" "$S/retry-safe.txt" <<'PYCODE'
from pathlib import Path
import os, signal, subprocess, sys, time
args = ['exec', 'box-1', '--', 'true'] if sys.argv[5] == 'quota' else ['put', 'box-1', sys.argv[6], 'retry-safe']
proc = subprocess.Popen([sys.argv[1], *args],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
for _ in range(600):
    if Path(sys.argv[2]).exists():
        break
    time.sleep(0.05)
ready = Path(sys.argv[2]).exists()
proc.send_signal(signal.SIGTERM)
try:
    out, err = proc.communicate(timeout=10)
    status = 0 if ready and proc.returncode == 143 else 1
except subprocess.TimeoutExpired:
    proc.kill()
    out, err = proc.communicate(timeout=25)
    status = 1
Path(sys.argv[3]).write_bytes(out)
Path(sys.argv[4]).write_bytes(err)
if ready:
    try:
        os.kill(int(Path(sys.argv[2]).read_text()), 0)
        status = 1
    except ProcessLookupError:
        pass
sys.exit(status)
PYCODE
		RC=$? TIMEDOUT=
		rc_is "$kind: interrupt closes the pipes and reaps the sleep promptly" 0
		err_has "$kind: the caller sees the interruption warning" 'interrupted by SIGTERM'
		if [ "$kind" = quota ]; then
			is "quota: no exec is retried after interruption" "$(count POST '/exec$')" 1
			err_has "quota: an interrupted slot wait says nothing started" 'interrupted by SIGTERM before anything started in the sandbox'
			err_lacks "quota: and does not claim the command may have run" 'may have run partly'
		else
			err_has "interrupted uploads report remote outcome uncertainty" 'remote file may have been replaced'
			is "safe host retry: no upload is retried after interruption" "$(count PUT '/files$')" 1
		fi
	done
}

t_exec_stdin() {
	group "exec -i (stdin)"
	reset
	printf 'hello\nworld\n' >"$S/in"
	run -s "$S/in" exec box-1 -i -- cat
	rc_is "exec -i" 0
	is "-i sends the local stdin with the exec" "$(last_exec '[.stdinLength, .stdinSha256] | join(" ")')" "12 $(sha <"$S/in")"
	[ -z "$REAL" ] || is "and the command reads it" "$(OUT)" "$(printf 'hello\nworld')"
	run -s "$S/in" exec box-1 -- cat
	is "without -i no stdin is sent" "$(last_exec 'has("stdin")')" false
	run -s "$S/in" exec box-1 -i -t 7 -- cat
	is "-i -t 7" "$(last_exec '[.timeoutSeconds, .stdinLength] | join(" ")')" '7 12'
	run -s "$S/in" exec box-1 -t 7 -i -- cat
	is "-t 7 -i" "$(last_exec '[.timeoutSeconds, .stdinLength] | join(" ")')" '7 12'
	run exec box-1 -i -- cat
	rc_is "-i with an empty stdin" 0
	is "sends an empty stdin" "$(last_exec .stdinLength)" 0
	head -c 1048576 /dev/zero | LC_ALL=C tr '\000' a >"$S/in1m"
	run -s "$S/in1m" exec box-1 -i -- 'wc -c'
	rc_is "exactly 1 MiB of stdin" 0
	is "all of it is sent" "$(last_exec .stdinLength)" 1048576
	[ -z "$REAL" ] || is "and read" "$(OUT | tr -d ' ')" 1048576
	printf a >>"$S/in1m"
	ctl '{"resetCalls":true}'
	run -s "$S/in1m" exec box-1 -i -- 'wc -c'
	rc_is "1 MiB + 1 byte of stdin is refused" 125
	err_has "it suggests ibx ssh" 'stdin is over 1 MiB: use ibx ssh'
	is "and no exec is sent" "$(count POST '/exec$')" 0
}

t_sigterm() {
	group "SIGTERM to ibx"
	reset
	local pid t0
	ctl '{"execResults":[{"stdout":"late\n","delay":2}]}'
	"$IBX" exec box-1 -- 'long job' >"$S/out" 2>"$S/err" </dev/null &
	pid=$!
	wait_exec 1 || bad "the slow exec did not start"
	kill -TERM "$pid"
	wait "$pid"
	RC=$? TIMEDOUT=
	rc_is "SIGTERM to a running ibx exec: exit 143" 143
	err_has "it warns that the remote command may still run" \
		'^ibx: interrupted by SIGTERM: the remote command was killed when the connection closed'
	is "and prints no result as if it had finished" "$(OUT)" ''

	# As agent harnesses do it: SIGTERM to the whole process group, curl included.
	reset '"execResults":[{"stdout":"late\n","delay":10}]'
	t0=$SECONDS
	python3 -c 'import os, sys; os.setpgid(0, 0); os.execv(sys.argv[1], sys.argv[1:])' \
		"$IBX" exec box-1 -- 'long job' >"$S/out" 2>"$S/err" </dev/null &
	pid=$!
	wait_exec 1 || bad "the slow exec did not start"
	kill -TERM -- "-$pid"
	wait "$pid"
	RC=$? TIMEDOUT=
	rc_is "SIGTERM to its process group: exit 143" 143
	err_has "with the same warning" '^ibx: interrupted by SIGTERM'
	yes_ "at once, without waiting for the reply ($((SECONDS - t0)) s)" [ $((SECONDS - t0)) -lt 8 ]
}

t_retry() {
	group "retries of reads"
	reset '"dropGets":1'
	run ls --json
	rc_is "a GET whose reply was cut off is retried" 0
	is "cut off once, then answered" "$(calls | jq -c '[.calls[] | select(.path == "/v1/machines") | .dropped]')" '[true,false]'
	reset '"dropGets":4'
	run ls
	rc_is "a GET that keeps failing gives up" 125
	is "after 3 retries" "$(count GET '^/v1/machines$')" 4
}

t_files() {
	group "put/get"
	if [ -z "$REAL" ]; then
		skip "put/get need MOCK_EXEC=real (GNU coreutils in the fake sandbox)"
		return 0
	fi
	reset
	local home f
	home=$(box box-1 .home)
	head -c 1000 /dev/urandom >"$S/f.bin"
	run put box-1 "$S/f.bin" sub/dir/f.bin
	rc_is "put" 0
	yes_ "put wrote the file under HOME, unchanged" cmp -s "$S/f.bin" "$home/sub/dir/f.bin"
	is "put leaves no partial file" "$(find "$home" -name '*.ibx-part' | wc -l | tr -d ' ')" 0
	mkdir -p "$home/adir" "$S/dl" "$S/cwd"
	run put box-1 "$S/f.bin" adir
	rc_is "put onto a directory is refused" 125
	err_has "it says to give the file name" 'destination is a directory'
	run get box-1 sub/dir/f.bin "$S/dl"
	rc_is "get into a local directory" 0
	yes_ "get into a directory writes DIR/NAME" cmp -s "$S/f.bin" "$S/dl/f.bin"
	run get box-1 sub/dir/f.bin "$S/copy.bin"
	yes_ "get to a file name" cmp -s "$S/f.bin" "$S/copy.bin"
	(cd "$S/cwd" && run get box-1 sub/dir/f.bin && [ "$RC" = 0 ] && cmp -s "$S/f.bin" "$S/cwd/f.bin")
	yes_ "get without a destination writes ./NAME" [ $? = 0 ]
	f="it's a \"file\" (1).bin"
	run put box-1 "$S/f.bin" "$f"
	rc_is "put to a name with quotes and spaces" 0
	run get box-1 "$f" "$S/odd.bin"
	yes_ "and back" cmp -s "$S/f.bin" "$S/odd.bin"
	: >"$S/empty"
	run put box-1 "$S/empty" empty
	rc_is "put of an empty file" 0
	run get box-1 empty "$S/empty.out"
	yes_ "get of an empty file" eval '[ "$RC" = 0 ] && [ -f "$S/empty.out" ] && [ ! -s "$S/empty.out" ]'

	head -c 750000 /dev/urandom >"$S/max.bin"
	run put box-1 "$S/max.bin" max.bin
	rc_is "put of exactly 750000 bytes" 0
	run get box-1 max.bin "$S/max.out"
	rc_is "get of exactly 750000 bytes" 0
	yes_ "750000 bytes round-trip unchanged" cmp -s "$S/max.bin" "$S/max.out"
	head -c 750001 /dev/zero >"$S/over.bin"
	run put box-1 "$S/over.bin" over.bin
	rc_is "put above the old 750 KB limit succeeds" 0
	run get box-1 over.bin "$S/big.out"
	rc_is "get above the old 750 KB limit succeeds" 0
	yes_ "large files round-trip unchanged" cmp -s "$S/over.bin" "$S/big.out"
	run IBX_GET_MAX=750000 get box-1 over.bin "$S/capped.out"
	rc_is "get honors IBX_GET_MAX" 125
	yes_ "an oversized download leaves no destination" [ ! -e "$S/capped.out" ]
	run get box-1 sub/dir/f.bin "$S/no-such-dir/f.bin"
	rc_is "get into a missing local directory fails with 125" 125
	run get box-1 no-such-file "$S/x"
	rc_is "get of a missing file fails" 125
	err_has "it says why" 'file not found'
	run put box-1 "$S/no-such-file" x
	rc_is "put of a missing local file fails" 125
	run put box-1 "$S/f.bin"
	rc_is "put needs a destination" 125
}

t_put_guard() {
	group "put refuses files that look like credentials"
	reset
	local d=$S/creds n missed='' passed_through=''
	mkdir -p "$d/.ssh" "$d/.aws" "$d/.gnupg" "$d/.kube" "$d/.docker" "$d/gcloud" "$d/.claude" "$d/.codex" "$d/instabox"
	for n in .env .env.local prod.env .ENV server.pem tls.key cert.p12 cert.pfx store.jks vault.kdbx app.keystore \
		terraform.tfstate prod.tfvars id_rsa id_rsa.pub id_dsa id_ecdsa id_ed25519 ID_ED25519 .netrc .npmrc .pypirc \
		.pgpass .git-credentials credentials credentials.json client_secret.json gh-token.txt api-key office.ovpn \
		.ssh/config .aws/config .gnupg/pubring.kbx .kube/config .docker/config.json gcloud/adc.json \
		.claude/settings.json .codex/auth.json instabox/notes; do
		printf 'not a real secret\n' >"$d/$n"
		run put box-1 "$d/$n" "x/$(basename "$n")"
		[ "$RC" = 125 ] && grep -q 'looks like a credential' "$S/err" || missed+=" $n"
	done
	is "every credential-like name or place is refused" "$missed" ''
	is "and none of them reached the API" "$(ncalls)" 0
	for n in notes.txt envoy.yaml key.txt monkey.py environment.md .docker/daemon.json; do
		printf 'plain\n' >"$d/$n"
		run put box-1 "$d/$n" "x/$(basename "$n")"
		[ "$RC" = 0 ] || passed_through+=" $n"
	done
	is "ordinary names are copied" "$passed_through" ''

	ctl '{"resetCalls":true}'
	run put box-1 "$d/.env" .env
	rc_is "put .env is refused" 125
	err_has "it says why, and how to override" 'looks like a credential; credentials never go to a sandbox \(--force'
	run put box-1 "$d/id_ed25519" id_ed25519
	rc_is "put id_ed25519 is refused" 125
	run put box-1 "$d/.ssh/config" config
	rc_is "put of a file under .ssh/ is refused" 125
	is "no exec was sent for them" "$(count POST '/exec$')" 0
	run put --force box-1 "$d/.env" .env
	rc_is "put --force copies it anyway" 0
	[ -z "$REAL" ] || yes_ "and it arrives" cmp -s "$d/.env" "$(box box-1 .home)/.env"
	run put box-1 --force "$d/.env" .env
	rc_is "--force goes before the sandbox name" 125

	printf 'tilde\n' >"$S/plain.txt"
	# shellcheck disable=SC2088 # a literal ~/ that ibx strips
	run put box-1 "$S/plain.txt" '~/tl/plain.txt'
	rc_is "put to ~/PATH" 0
	yes_ "the leading ~/ becomes an absolute path under remote HOME" jq -e \
		'.calls | map(select(.method == "PUT" and (.path | endswith("/files")))) | last.query | contains("path=%2Fdata%2Fhome%2Ftl%2Fplain.txt")' < <(calls)
	out_has "and the message shows the path under HOME" "-> box-1:tl/plain.txt$"
	if [ -n "$REAL" ]; then
		yes_ "the file is at HOME/tl/plain.txt" cmp -s "$S/plain.txt" "$(box box-1 .home)/tl/plain.txt"
		# shellcheck disable=SC2088
		run get box-1 '~/tl/plain.txt' "$S/back.txt"
		rc_is "get from ~/PATH" 0
		yes_ "gets that file" cmp -s "$S/plain.txt" "$S/back.txt"
	fi
}

t_poolonly() {
	group "agent commands use pool sandboxes only"
	reset '"seed":{"count":3,"pool":[1,1,0]}'
	printf 'hello\n' >"$S/plain.txt"
	local id3
	id3=$(box box-3 .id)
	refused() { # ibx ARGS...: refused because the sandbox is outside the pool
		run "$@"
		rc_is "outside the pool, refused: ibx $*" 125
		grep -q 'is not in the pool: agents only use pool sandboxes' "$S/err" || { bad "ibx $*: no 'not in the pool' message"; detail; }
	}
	refused exec box-3 -- true
	refused exec "$id3" -- true
	refused put box-3 "$S/plain.txt" plain.txt
	refused get box-3 plain.txt "$S/got.txt"
	refused ssh box-3 true
	refused port box-3 8080
	refused unport box-3 8080
	refused renew box-3
	refused release box-3
	refused IBX_ALLOW_ANY=yes exec box-3 -- true
	is "none of them did more than list the sandboxes" \
		"$(calls | jq -c '[.calls[] | select(.path != "/v1/machines") | .method + " " + .path] | unique')" '[]'
	run IBX_ALLOW_ANY=1 exec box-3 -- 'exit 3'
	rc_is "IBX_ALLOW_ANY=1: exec outside the pool" 3
	run IBX_ALLOW_ANY=1 port box-3 8080
	rc_is "IBX_ALLOW_ANY=1: port" 0
	run IBX_ALLOW_ANY=1 unport box-3 8080
	rc_is "IBX_ALLOW_ANY=1: unport" 0
	hold box-3 60 tester
	run IBX_ALLOW_ANY=1 renew box-3
	rc_is "IBX_ALLOW_ANY=1: renew" 0
	run IBX_ALLOW_ANY=1 release box-3
	rc_is "IBX_ALLOW_ANY=1: release" 0
	if [ -n "$REAL" ]; then
		run IBX_ALLOW_ANY=1 put box-3 "$S/plain.txt" plain.txt
		rc_is "IBX_ALLOW_ANY=1: put" 0
		run IBX_ALLOW_ANY=1 get box-3 plain.txt "$S/got.txt"
		yes_ "IBX_ALLOW_ANY=1: get" eval '[ "$RC" = 0 ] && cmp -s "$S/plain.txt" "$S/got.txt"'
	fi
	is "IBX_ALLOW_ANY=1 does not put it in the pool" "$(box box-3 '.metadata["ibx.pool"]')" null
}

t_vault() {
	group "Vault"
	reset '"seed":{"count":3,"vault":{"box-1":2,"box-2":0}}'
	run ls --json
	is "ls --json has a boolean vault field" "$(jq -c 'map(.vault)' "$S/out")" '[true,true,false]'
	hold box-2 0
	hold box-3 0
	run claim "vault"
	rc_is "claim skips a sandbox the Vault writes secrets into" 75
	err_has "and says why" 'skipping box-1: the Vault writes 2 secret\(s\) into it'
	is "it was not reserved" "$(count PATCH .)" 0
	ctl '{"resetCalls":true}'
	run IBX_ALLOW_VAULT=1 claim "vault accepted"
	rc_is "IBX_ALLOW_VAULT=1 claims it anyway" 0
	is "that sandbox" "$(OUT)" box-1
	is "without reading its Vault" "$(count GET '/vault$')" 0

	reset '"seed":{"count":3,"vault":{"box-1":0}}'
	hold box-2 0
	hold box-3 0
	run claim "empty vault"
	rc_is "a sandbox with the Vault on but empty is claimed" 0
	is "that sandbox" "$(OUT)" box-1
	err_lacks "without a warning" skipping

	reset '"set":{"box-1":{"vault":null}}'
	hold box-2 0
	hold box-3 0
	run ls --json
	is "a Machine without the vault field counts as Vault on" "$(jq -c '.[0].vault' "$S/out")" true
	run claim "no vault route"
	rc_is "a 404 on the Vault route counts as no Vault items (a server without Vault)" 0
	is "that sandbox" "$(OUT)" box-1
	is "after asking once" "$(count GET '/vault$')" 1

	reset '"seed":{"count":3,"vault":{"box-1":1}},"faults":[{"kind":"error","method":"GET","match":"/vault$","status":403,"code":"permission_denied","message":"no","count":9}]'
	hold box-2 0
	hold box-3 0
	run claim "vault unreadable"
	rc_is "a Vault that cannot be read fails the claim" 125
	err_has "as an API error" 'could not claim a sandbox: API errors'
	is "and reserves nothing" "$(count PATCH .)" 0

	reset '"seed":{"count":3,"pool":[0,0,0],"vault":{"box-1":3,"box-2":0}}'
	run pool add box-1
	rc_is "pool add refuses a sandbox the Vault writes secrets into" 125
	err_has "it says why and how to accept it" 'box-1 receives 3 Vault secret\(s\) at every boot.*--allow-vault box-1'
	is "and changes nothing" "$(count PATCH .):$(box box-1 '.metadata["ibx.pool"]')" 0:null
	run pool add --allow-vault box-1
	rc_is "pool add --allow-vault accepts it" 0
	out_has "and adds it" '^added box-1 to the pool$'
	err_has "with a note" 'note: box-1 has the Vault on \(3 item\(s\) now\)'
	run pool add box-2
	rc_is "pool add of a sandbox with the Vault on but empty" 0
	err_has "warns that later Vault items reach it" 'note: box-2 has the Vault on \(0 item\(s\) now\). Secrets you add to the Vault later reach it'
	run pool add box-3
	rc_is "pool add of a sandbox without the Vault" 0
	err_lacks "says nothing about the Vault" Vault

	reset '"seed":{"count":4,"pool":[1,1,1,0],"vault":{"box-1":3,"box-2":0,"box-4":5}}'
	run doctor
	rc_is "doctor fails when the Vault writes secrets into a pool sandbox" 125
	out_has "FAIL names it" '^FAIL +box-1 receives 3 Vault secret\(s\): claim skips it unless IBX_ALLOW_VAULT=1'
	out_has "warn for the Vault on but empty" '^warn +box-2 has the Vault on \(empty now\)'
	out_lacks "no Vault warnings for a clean disabled Vault or a box outside the pool" '^(warn|FAIL).*box-[34].*Vault'
	reset '"seed":{"count":2,"vault":{"box-1":0}}'
	run doctor
	rc_is "doctor passes with only an empty Vault" 0
	out_has "and warns about it" '^warn +box-1 has the Vault on \(empty now\)'
}

t_hostile() {
	group "what the API sends back is not trusted blindly"
	local id
	ctl "$(jq -cn --arg at "$(ago 60)" '{reset: true, seed: {count: 1}, set: {"box-1": {
		name: "evil\u001b[2Jbox",
		metadata: {"ibx.pool": "1", "ibx.claim.by": "x\u001b]0;pwned\u0007", "ibx.claim.at": $at,
			"ibx.claim.purpose": "p\u001b[31mq\r", "ibx.claim.token": "0123"},
		ports: [{port: 8080, name: "ibx:\u001b[1mweb", url: "https://a.mock.invalid/\u001b[2J"},
			{port: 8081, name: "other\u0007", url: "https://b.mock.invalid/\u001b[5m"}]}}}')"
	id=$(state | jq -r '.machines[0].id')
	run ls --all
	rc_is "ls" 0
	yes_ "ls prints no control characters" eval '! has_ctl "$S/out" "$S/err"'
	out_has "but still the text around them" 'evil.\[2Jbox'
	run keepalive
	yes_ "keepalive prints none" eval '[ "$RC" = 0 ] && ! has_ctl "$S/out" "$S/err"'
	run IBX_ALLOW_ANY=1 release "$id"
	rc_is "release" 0
	yes_ "release prints none" eval '! has_ctl "$S/out" "$S/err"'
	err_has "it shows the URL it left alone, cleaned" 'left port 8081 alone \(https://b\.mock\.invalid/.\[5m\)'
	run claim x
	rc_is "claim" 0
	yes_ "claim prints none (the name, the leftover port)" eval '! has_ctl "$S/out" "$S/err"'
	is "the name it prints" "$(OUT)" 'evil [2Jbox'

	reset '"set":{"box-1":{"id":"m_../../v1/me"}}'
	run exec box-1 -- true
	rc_is "a sandbox ID that is not m_ + 26 base32 characters is refused" 125
	err_has "it says so" 'unexpected sandbox id from the API'
	hold box-2 0
	hold box-3 0
	run claim x
	rc_is "claim skips a sandbox with such an ID" 75
	is "no request used that ID" "$(calls | jq '[.calls[] | select(.path | contains("..")) ] | length'):$(count PATCH .)" 0:0
}

t_secrets() {
	group "the API key stays out of files, arguments, the environment and output"
	reset
	local pid f
	rm -f "$S/spy.args"
	run ENV_KEY=exported AUTH=exported key=exported PATH="$SPY:$PATH" exec box-1 -- true
	rc_is "inherited export attributes do not change key handling" 0
	is "internal key variables stay out of child environments even when those names were exported" \
		"$(grep -c '^1 .* -H @- ' "$S/spy.args")" 0

	rm -f "$S/spy.args"
	ctl '{"execResults":[{"stdout":"slow\n","delay":3}]}'
	env PATH="$SPY:$PATH" "$IBX" exec box-1 -- 'slow job' >"$S/out" 2>"$S/err" </dev/null &
	pid=$!
	wait_exec 1 || bad "the slow exec did not start"
	yes_ "(ibx has its temporary files while the exec is in flight)" eval '[ -n "$(find "$TMPDIR" -type f -path "*/ibx.*/*")" ]'
	yes_ "the key is in no file under TMPDIR meanwhile" eval '! grep -rqF -- "$KEY" "$TMPDIR"'
	yes_ "and those files are private (umask 077)" eval '[ -z "$(find "$TMPDIR" -mindepth 1 \( -perm -040 -o -perm -004 \))" ]'
	wait "$pid"
	RC=$? TIMEDOUT=
	rc_is "the slow exec finished" 0
	is "with its output" "$(OUT)" slow
	yes_ "(curl sent the requests through the spy)" grep -q '^0 .* -H @- ' "$S/spy.args"
	yes_ "the key is never in curl's arguments" eval '! grep -q ibk_ "$S/spy.args"'
	# Only the runs that send a request: the helper's own `curl -V` (deps_ok) runs before it drops
	# INSTABOX_API_KEY from its environment (reported; the fix moves the unset to the top).
	is "nor in the environment of a curl that sends a request" "$(grep -c '^1 .* -H @- ' "$S/spy.args")" 0
	if [ -e /proc/self/fd/0 ]; then
		# bash 4.4 and 5.0 put a here-string in a temporary file (bash 5.1+: a pipe).
		is "it reaches curl through a pipe, never a temporary file" "$(grep -c '^[01] file .* -H @- ' "$S/spy.args")" 0
	fi

	# curl -q: a ~/.curlrc that turns on verbose output and tracing must not print the key.
	for f in "$HOME/.curlrc" "$XDG_CONFIG_HOME/.curlrc"; do
		mkdir -p "$(dirname "$f")"
		printf 'verbose\ntrace-ascii -\n' >"$f"
	done
	curl -sS -o /dev/null -H "Authorization: Bearer $KEY" "$BASE/_health" >"$S/out" 2>"$S/err"
	yes_ "(this ~/.curlrc makes a plain curl print the key)" grep -q 'Authorization: Bearer ibk_' "$S/out" "$S/err"
	clean() { # KEY: not in the last run's output, not even a part of it (traces wrap lines)
		! grep -qF -e "${1:0:16}" -e "${1:16:16}" "$S/out" "$S/err" && ! grep -qi 'authorization' "$S/out" "$S/err"
	}
	run ls
	rc_is "ls with that ~/.curlrc" 0
	yes_ "prints no key and no request headers" clean "$KEY"
	run exec box-1 -- 'exit 3'
	rc_is "exec with that ~/.curlrc" 3
	yes_ "prints neither" clean "$KEY"
	run INSTABOX_API_KEY=$OTHER_KEY ls
	rc_is "a rejected key with that ~/.curlrc" 125
	yes_ "is not printed either" clean "$OTHER_KEY"
	run doctor
	yes_ "nor by doctor" eval '[ "$RC" = 0 ] && clean "$KEY"'
	rm -f "$HOME/.curlrc" "$XDG_CONFIG_HOME/.curlrc"
}

t_ssh() {
	group "ssh (the mock's SSH port is closed)"
	if ! command -v ssh >/dev/null; then
		skip "ssh is not installed"
		return 0
	fi
	local fake=$S/fake-ssh
	mkdir "$fake"
	cat >"$fake/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$SSH_ARGS_FILE"
case "$*" in *cat-stdin*) cat ;; esac
SH
	chmod +x "$fake/ssh"
	local remote
	for remote in '-- grep --help' 'grep --help' 'grep -h'; do
		reset
		# shellcheck disable=SC2086 # fixed arguments deliberately split into words
		run PATH="$fake:$PATH" SSH_ARGS_FILE="$S/ssh-args" ssh box-1 $remote
		rc_is "ssh box-1 $remote reaches ssh successfully" 0
		yes_ "ssh preserves the remote flag in $remote" grep -Eq -- '^grep (--help|-h) ?$' "$S/ssh-args"
		is "ssh $remote creates a token" "$(count POST '/ssh-tokens$')" 1
		is "ssh $remote revokes its token" "$(box box-1 '[.tokens[] | .revoked]')" '[true]'
	done
	printf 'ssh stdin preserved\n' >"$S/ssh-in"
	run -s "$S/ssh-in" PATH="$fake:$PATH" SSH_ARGS_FILE="$S/ssh-args" ssh box-1 cat-stdin
	rc_is "main-shell SSH wait preserves caller stdin" 0
	is "SSH receives the exact caller input" "$(OUT)" 'ssh stdin preserved'
	reset '"set":{"box-2":{"state":"suspended"}}'
	run ssh box-1 'echo hi'
	rc_is "ssh that cannot connect exits 255" 255
	is "one SSH token was made" "$(count POST '/ssh-tokens$')" 1
	is "and revoked on exit" "$(box box-1 '[.tokens[] | .revoked]')" '[true]'
	yes_ "the token is not shown" eval '! grep -Eq "ibssh_[a-z2-7]" "$S/out" "$S/err"'
	run ssh box-2 true
	is "ssh resumes a paused sandbox first" "$(count POST '/resume$')" 1
	run ssh
	rc_is "ssh without a sandbox is a usage error" 125
}

# shellcheck disable=SC2088 # literal tildes exercise installer expansion
t_install() {
	group "install.sh (a scratch HOME and a fake systemctl; never the real ones)"
	local ih=$S/ihome fb=$S/fakebin ab=$S/absbin sh=bash repo unit timer skills
	repo=$(cd -- "$here/.." && pwd -P)
	[ -x /bin/bash ] && sh=/bin/bash # on macOS the bash 3.2 that install.sh is written for
	rm -rf "$ih" "$fb" "$ab"
	mkdir -p "$ih/relbin" "$fb" "$ab"
	printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/systemctl.log"\n' "$S" >"$fb/systemctl"
	printf '#!/bin/sh\nexit 0\n' >"$ih/relbin/jq"
	chmod +x "$fb/systemctl" "$ih/relbin/jq"
	ln -s "$(command -v bash)" "$ab/bash" # an absolute PATH directory outside the standard ones
	unit=$ih/.config/systemd/user/ibx-keepalive.service
	timer=$ih/.config/systemd/user/ibx-keepalive.timer
	skills=$ih/.claude/skills
	inst() { # install.sh ARGS, in the scratch HOME and from it, with a relative PATH entry first
		local envs=(env -u XDG_CONFIG_HOME -u IBX_KEY_FILE -u INSTABOX_KEY_FILE -u CODEX_HOME)
		[ -z "${INSTALL_CODEX_HOME:-}" ] || envs+=("CODEX_HOME=$INSTALL_CODEX_HOME")
		[ -z "${INSTALL_XDG_CONFIG_HOME:-}" ] || envs+=("XDG_CONFIG_HOME=$INSTALL_XDG_CONFIG_HOME")
		(cd "$ih" && "${envs[@]}" \
			HOME="$ih" PATH="relbin:$ab:$fb:$PATH" IBX_INSTALL_OS="${INST_OS:-Linux}" "$sh" "$repo/install.sh" "$@") \
			>"$S/out" 2>"$S/err" </dev/null
		RC=$? TIMEDOUT=
	}
	abs_only() { # FILE: every directory on the PATH line of a generated unit or plist is absolute
		local p
		p=$(sed -n -e 's/^.*Environment=PATH=//p' -e 's/^.*<string>\(.*:\/usr\/bin:\/bin\)<\/string>$/\1/p' "$1")
		[ -n "$p" ] && ! printf '%s\n' "$p" | tr ':' '\n' | grep -qv '^/'
	}
	if [ "$(PATH="relbin:$ab:$fb:$PATH" command -v systemctl)" != "$fb/systemctl" ]; then
		bad "install.sh: the fake systemctl is not first on PATH; skipping the install.sh tests"
		return 0
	fi

	inst --dry-run --keepalive --no-bin --agents none
	rc_is "--dry-run --keepalive" 0
	out_has "it shows the unit" "^    [|] ExecStart=$repo/skills/ibx/scripts/ibx keepalive$"
	yes_ "a relative PATH entry (relbin, where jq is found) never reaches the unit" abs_only "$S/out"
	out_has "an absolute directory does" "^    [|] Environment=PATH=$ab:/usr/local/bin:/usr/bin:/bin$"
	yes_ "a dry run changes nothing" eval '[ ! -e "$ih/.config" ] && [ ! -e "$S/systemctl.log" ]'
	INST_OS=Darwin inst --dry-run --keepalive --no-bin --agents none
	rc_is "--dry-run --keepalive for launchd" 0
	out_has "the plist gets the absolute directory" "^    [|]     <string>$ab:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>$"
	yes_ "and no relative one" abs_only "$S/out"

	# Symlinks left at the old fixed temporary names must not be written through or chmod-ed.
	mkdir -p "$(dirname "$unit")"
	printf 'precious\n' >"$S/precious"
	chmod 600 "$S/precious"
	ln -s "$S/precious" "$unit.ibx-new"
	ln -s "$S/precious" "$timer.ibx-new"
	inst --keepalive --no-bin --agents none
	rc_is "--keepalive" 0
	is "the file the planted symlinks point at is untouched" "$(cat "$S/precious")" precious
	yes_ "and keeps its mode 600" [ -n "$(find "$S/precious" -perm 600)" ]
	yes_ "the unit and timer are regular files, mode 644" eval \
		'[ ! -L "$unit" ] && [ ! -L "$timer" ] && [ "$(find "$unit" "$timer" -type f -perm 644 | wc -l | tr -d " ")" = 2 ]'
	yes_ "written by install.sh" grep -q 'Installed by ibx install.sh' "$unit" "$timer"
	yes_ "the unit has no relative PATH entry" eval 'abs_only "$unit" && grep -qx "Environment=PATH=$ab:/usr/local/bin:/usr/bin:/bin" "$unit"'
	is "no temporary file is left" "$(find "$(dirname "$unit")" -name '*.ibx-new.*' | wc -l | tr -d ' ')" 0
	yes_ "the fake systemctl was asked to reload and enable" eval \
		'grep -qx -- "--user daemon-reload" "$S/systemctl.log" && grep -qx -- "--user enable --now ibx-keepalive.timer" "$S/systemctl.log"'
	inst --keepalive --no-bin --agents none
	out_has "a second run finds them up to date" '^up to date +~/\.config/systemd/user/ibx-keepalive\.service$'

	inst --copy --agents claude --no-bin
	rc_is "--copy" 0
	yes_ "the copy is a directory with the install marker" eval '[ -d "$skills/ibx" ] && [ ! -L "$skills/ibx" ] && [ -f "$skills/ibx/.ibx-install" ]'
	yes_ "identical to the skill" diff -rq -x .ibx-install "$repo/skills/ibx" "$skills/ibx"
	is "no staging directory is left" "$(find "$skills" -maxdepth 1 -name '.ibx-install.*' | wc -l | tr -d ' ')" 0
	inst --copy --agents claude --no-bin
	out_has "a second --copy finds it up to date" '^up to date +~/\.claude/skills/ibx \(copy\)$'
	inst --agents claude --bin "$ih/bin"
	rc_is "link install (replacing the copy) with --bin" 0
	is "the skill is a link to the clone" "$(readlink "$skills/ibx")" "$repo/skills/ibx"
	is "the command is a link to the helper" "$(readlink "$ih/bin/ibx")" "$repo/skills/ibx/scripts/ibx"
	inst --uninstall --bin "$ih/bin"
	rc_is "--uninstall" 0
	yes_ "removes what it installed" eval '[ ! -e "$skills/ibx" ] && [ ! -L "$ih/bin/ibx" ] && [ ! -e "$unit" ] && [ ! -e "$timer" ]'
	yes_ "and leaves the planted symlinks alone" eval '[ -L "$unit.ibx-new" ] && [ "$(cat "$S/precious")" = precious ]'
	yes_ "(the fake systemctl disabled the timer)" grep -qx -- '--user disable --now ibx-keepalive.timer' "$S/systemctl.log"
	local config=$ih/.claude-proxy
	CLAUDE_CONFIG_DIR=$config inst --dry-run --agents claude --no-bin
	rc_is "custom Claude config dry run" 0
	out_has "dry run targets CLAUDE_CONFIG_DIR" 'would link +~/.claude-proxy/skills/ibx'
	yes_ "custom Claude dry run changes nothing" [ ! -e "$config" ]
	mkdir -p "$config/skills"
	ln -s "$repo/skills/ibx" "$config/skills/ibx"
	CLAUDE_CONFIG_DIR=$config inst --agents claude --no-bin
	rc_is "a hand-made symlink in CLAUDE_CONFIG_DIR is accepted" 0
	out_has "the existing custom-config link is already installed" '^up to date +~/.claude-proxy/skills/ibx'
	CLAUDE_CONFIG_DIR=$config inst --uninstall --dry-run --agents claude --no-bin
	rc_is "custom Claude uninstall dry run" 0
	out_has "uninstall dry run targets CLAUDE_CONFIG_DIR" 'would remove +~/.claude-proxy/skills/ibx'
	yes_ "uninstall dry run preserves the hand-made symlink" [ -L "$config/skills/ibx" ]
	CLAUDE_CONFIG_DIR=$config inst --uninstall --agents claude --no-bin
	rc_is "custom Claude uninstall accepts the hand-made symlink" 0
	yes_ "custom Claude uninstall removes its link" [ ! -L "$config/skills/ibx" ]
	CLAUDE_CONFIG_DIR=$config inst --agents claude --no-bin
	rc_is "install creates a custom Claude skill link" 0
	is "the custom Claude link targets this clone" "$(readlink "$config/skills/ibx")" "$repo/skills/ibx"
	yes_ "custom Claude install does not create a default Claude link" [ ! -L "$skills/ibx" ]
	ln -s "$repo/skills/ibx" "$skills/ibx"
	CLAUDE_CONFIG_DIR=$config inst --uninstall --no-bin
	rc_is "uninstall without an explicit agent list follows CLAUDE_CONFIG_DIR" 0
	yes_ "uninstall without an agent list removes the custom link" [ ! -L "$config/skills/ibx" ]
	yes_ "uninstall with a custom config also removes the default Claude link" [ ! -L "$skills/ibx" ]
	CLAUDE_CONFIG_DIR='~/.claude-copy///' inst --copy --agents claude --bin "$ih/bin" --keepalive
	rc_is "copy install expands a literal tilde in CLAUDE_CONFIG_DIR" 0
	is "the command points at an absolute copied helper" "$(readlink "$ih/bin/ibx")" "$ih/.claude-copy/skills/ibx/scripts/ibx"
	yes_ "the copied command target exists" [ -x "$ih/bin/ibx" ]
	yes_ "the timer uses the command whose target is absolute" grep -qx "ExecStart=$ih/bin/ibx keepalive" "$unit"
	CLAUDE_CONFIG_DIR='~/.claude-copy/' inst --copy --agents claude --bin "$ih/bin" --keepalive
	rc_is "rerunning the normalized copy install succeeds" 0
	yes_ "the copied command still resolves after rerunning" [ -x "$ih/bin/ibx" ]
	CLAUDE_CONFIG_DIR='~/.claude-copy/' inst --copy --agents claude --no-bin --keepalive
	rc_is "copy install without a bin link uses the normalized helper directly" 0
	yes_ "without a bin link the timer uses the absolute copied helper" grep -qx "ExecStart=$ih/.claude-copy/skills/ibx/scripts/ibx keepalive" "$unit"
	CLAUDE_CONFIG_DIR='~/.claude-copy' inst --uninstall --bin "$ih/bin"
	INSTALL_CODEX_HOME='~/.codex-copy///' INSTALL_XDG_CONFIG_HOME='~/.config-copy///' inst --copy --agents codex,opencode --no-bin
	rc_is "Codex and XDG config roots also expand a literal tilde" 0
	yes_ "both normalized config roots contain the copied skill" eval '[ -f "$ih/.codex-copy/skills/ibx/SKILL.md" ] && [ -f "$ih/.config-copy/opencode/skills/ibx/SKILL.md" ]'
	INSTALL_CODEX_HOME='~/.codex-copy' INSTALL_XDG_CONFIG_HOME='~/.config-copy' inst --uninstall --no-bin
	local var
	for var in CLAUDE_CONFIG_DIR INSTALL_CODEX_HOME INSTALL_XDG_CONFIG_HOME; do
		case $var in
		CLAUDE_CONFIG_DIR) CLAUDE_CONFIG_DIR=relative-config inst --copy --agents all --no-bin ;;
		INSTALL_CODEX_HOME) INSTALL_CODEX_HOME=relative-config inst --copy --agents all --no-bin ;;
		INSTALL_XDG_CONFIG_HOME) INSTALL_XDG_CONFIG_HOME=relative-config inst --copy --agents all --no-bin ;;
		esac
		rc_is "installer rejects relative $var" 1
		err_has "relative $var explains the absolute path rule" 'must be an absolute path'
		yes_ "relative $var creates no dangling destination" [ ! -e "$ih/relative-config" ]
	done
	mkdir -p "$ih/.shared-config/skills"
	ln -s "$ih/.shared-config" "$ih/.alias-config"
	CLAUDE_CONFIG_DIR="$ih/.shared-config" INSTALL_CODEX_HOME="$ih/.alias-config" inst --dry-run --agents claude,codex --no-bin
	rc_is "dry run accepts config roots that resolve to the same place" 0
	is "dry run lists a shared skill link exactly once" "$(grep -c '^would link ' "$S/out")" 1
	CLAUDE_CONFIG_DIR="$ih/.shared-config" INSTALL_CODEX_HOME="$ih/.alias-config" inst --copy --agents claude,codex --no-bin
	rc_is "copy install deduplicates physically identical roots" 0
	is "the shared skill is copied exactly once" "$(grep -c '^copied ' "$S/out")" 1
	CLAUDE_CONFIG_DIR="$ih/.shared-config" INSTALL_CODEX_HOME="$ih/.alias-config" inst --uninstall --dry-run --agents claude,codex --no-bin
	is "uninstall dry run lists the shared copy exactly once" "$(grep -c '^would remove ' "$S/out")" 1
	CLAUDE_CONFIG_DIR="$ih/.shared-config" INSTALL_CODEX_HOME="$ih/.alias-config" inst --uninstall --agents claude,codex --no-bin
	rc_is "uninstall removes a shared root once" 0
	yes_ "the shared copy is removed" [ ! -e "$ih/.shared-config/skills/ibx" ]
	inst --help
	out_has "installer help documents CLAUDE_CONFIG_DIR" 'CLAUDE_CONFIG_DIR/skills'

}

t_cleanup() {
	group cleanup
	is "ibx removed its temporary directories" "$(find "$TMPDIR" -maxdepth 1 -name 'ibx.*' | wc -l | tr -d ' ')" 0
}

start=$(date +%s)
echo "ibx offline tests: $IBX against $BASE (exec: $EXEC_MODE)"
t_stream030() {
	group "0.3.0 opt-in exec streams"
	reset '"execResults":[{"stdout":"buffered\n"}]'
	run STREAM=1 exec box-1 -- true
	rc_is "buffered exec remains the default even with an unrelated STREAM environment variable" 0
	is "buffered exec does not request SSE" "$(calls | jq -c '[.calls[] | select(.path | endswith("/exec")) | .accept]')" '["*/*"]'
	reset '"execResults":[{"stdout":"hello é\n","stderr":"remote warning\n","exitCode":7}]'
	hold box-1 60 tester
	run exec box-1 --stream -- true
	rc_is "streamed exec preserves the remote exit status" 7
	is "stream stdout survives UTF-8 and ignores ping comments" "$(OUT)" 'hello é'
	is "stream stderr stays on stderr" "$(ERR)" 'remote warning'
	is "stream explicitly requests SSE" "$(calls | jq -c '[.calls[] | select(.path | endswith("/exec")) | .accept]')" '["text/event-stream"]'
	reset '"execResults":[{"stdout":"leading flag\n"}]'
	run exec --stream box-1 -- true
	rc_is "--stream can precede the box" 0
	is "the leading option still streams the command" "$(OUT)" 'leading flag'
	printf 'stdin030\n' >"$S/stream-in"
	reset '"execResults":[{"stdout":"stdin accepted\n"}]'
	run -s "$S/stream-in" exec box-1 -i --stream -t 30 -- cat
	rc_is "streaming accepts stdin and timeout options" 0
	is "streaming sends exactly the requested stdin" "$(last_exec .stdinLength)" 9
	head -c 1048576 /dev/zero | LC_ALL=C tr '\000' a >"$S/stream-big-in"
	reset '"execResults":[{"stdout":"big stdin accepted\n"}]'
	run -s "$S/stream-big-in" exec box-1 --stream -i -- cat
	rc_is "stream header parsing handles a one-MiB request and interim responses" 0
	is "the full streamed stdin reaches the mock" "$(last_exec .stdinLength)" 1048576

	reset '"quotaExecs":1,"execResults":[{"stdout":"after quota\n"}]'
	run exec box-1 --stream -- true
	rc_is "a pre-start JSON quota refusal can retry safely into an SSE response" 0
	is "the quota refusal is followed by exactly one started command" "$(count POST '/exec$')" 2
	is "the successful retry emits output once" "$(OUT)" 'after quota'
	reset '"faults":[{"kind":"error","method":"POST","match":"/exec$","status":403,"code":"missing_scope","requiredScopes":["machines:write"],"hint":"ask the user"}]'
	run exec box-1 --stream -- true
	rc_is "pre-start JSON auth errors do not retry" 125
	err_has "stream auth refusals keep their safe hint" 'missing_scope.*ask the user'
	is "a streamed auth refusal sends one request" "$(count POST '/exec$')" 1
	reset '"faults":[{"kind":"error","method":"POST","match":"/exec$","status":503,"code":"host_unavailable","retryable":true}]'
	run EXEC_SAFE=1 exec box-1 --stream -- true
	rc_is "a pre-start host_unavailable response stays conservative even if retryable" 125
	is "a host refusal before stream establishment never repeats a user command" "$(count POST '/exec$')" 1

	reset '"execResults":[{"stdout":"partial output\n","streamError":true}]'
	run exec box-1 --stream -- true
	rc_is "a started stream error is terminal" 125
	is "partial output survives the stream error" "$(OUT)" 'partial output'
	err_has "stream error explains partly-run work" 'failed after starting.*killed.*partly.*check before retrying'
	is "retryable host_unavailable inside a stream never retries" "$(count POST '/exec$')" 1
	reset '"execResults":[{"stdout":"before drop\n","streamDrop":true}]'
	run exec box-1 --stream -- true
	rc_is "a stream without an exit event fails" 125
	is "output before a dropped stream survives" "$(OUT)" 'before drop'
	is "a dropped stream is never retried" "$(count POST '/exec$')" 1
	reset '"execResults":[{"timedOut":true,"exitCode":124}]'
	run exec box-1 --stream -t 1 -- true
	rc_is "stream timeout remains exit 124" 124
	err_has "stream timeout includes the slow-start caveat" 'may never have started'
	reset '"execResults":[{"invalidUtf8":true,"exitCode":255,"signal":"USR1","diskWarning":{"message":"stream disk warning"}}]'
	run exec box-1 --stream -- true
	rc_is "stream exit diagnostics preserve code 255" 255
	err_has "stream exit reports invalid UTF-8" 'not UTF-8'
	err_has "stream exit names the actual signal" 'SIGUSR1'
	err_has "stream exit reports disk warnings" 'stream disk warning'
	python3 - "$S/stream-control" <<'PYCODE'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'reset': True, 'execResults': [{'stdout': 'é' * 786432}]}))
PYCODE
	curl -q -fsS --data-binary @"$S/stream-control" "$BASE/_control" >/dev/null
	run exec box-1 --stream -- true
	rc_is "stream output can exceed one MiB" 0
	is "all 1.5 MiB of multibyte output arrives" "$(wc -c <"$S/out" | tr -d ' ')" 1572864
	reset '"execResults":[{"stdout":"early output\n","streamDelay":20}]'
	python3 - "$IBX" "$S/out" "$S/err" <<'PYCODE'
from pathlib import Path
import os, selectors, signal, subprocess, sys
proc = subprocess.Popen([sys.argv[1], 'exec', 'box-1', '--stream', '--', 'true'],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
selector = selectors.DefaultSelector()
selector.register(proc.stdout, selectors.EVENT_READ)
first = proc.stdout.readline() if selector.select(timeout=10) else b''
early = first == b'early output\n' and proc.poll() is None
proc.send_signal(signal.SIGTERM)
try:
    out, err = proc.communicate(timeout=10)
    status = 0 if early and proc.returncode == 143 else 1
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    out, err = proc.communicate(timeout=25)
    status = 1
Path(sys.argv[2]).write_bytes(first + out)
Path(sys.argv[3]).write_bytes(err)
sys.exit(status)
PYCODE
	RC=$? TIMEDOUT=
	rc_is "SSE emits output before exit and a parent-only TERM promptly closes it" 0
	is "partial output is retained on interruption" "$(OUT)" 'early output'
	err_has "a stream interruption says the process group was killed" 'remote command was killed when the connection closed'
	is "interrupted streaming sends no retry" "$(count POST '/exec$')" 1
	if [ -n "$REAL" ]; then
		reset
		run exec box-1 --stream -- 'head -c 1572864 /dev/zero | tr "\\000" x'
		rc_is "real mock commands also stream above the buffered cap" 0
		is "real streamed output is uncapped" "$(wc -c <"$S/out" | tr -d ' ')" 1572864
		run exec box-1 --stream -- "printf '\\377'"
		rc_is "real streamed invalid UTF-8 retains the command's successful status" 0
		err_has "real streamed invalid UTF-8 is reported" 'not UTF-8'
		run exec box-1 --stream -- 'kill -TERM $$'
		rc_is "real streamed signal exits preserve 128 plus signal" 143
		err_has "real streamed signals use API names without a duplicate prefix" 'killed by SIGTERM$'
		run -s "$S/stream-big-in" exec box-1 --stream -i -- 'wc -c'
		rc_is "real SSE concurrently drains output while feeding large stdin" 0
		is "real SSE stdin is complete" "$(OUT | tr -d ' ')" 1048576
		run exec box-1 --stream -t 1 -- 'sleep 5'
		rc_is "real SSE enforces the command deadline" 124
		reset
		local stream_home
		stream_home=$(box box-1 .home)
		python3 - "$IBX" "$stream_home" "$S/out" "$S/err" <<'PYCODE'
from pathlib import Path
import os, selectors, signal, subprocess, sys, time
home = Path(sys.argv[2])
command = "echo $$ >stream.pid; (sleep 10; touch stream-after) & printf 'ready\\n'; wait"
proc = subprocess.Popen([sys.argv[1], 'exec', 'box-1', '--stream', '-t', '20', '--', command],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
selector = selectors.DefaultSelector()
selector.register(proc.stdout, selectors.EVENT_READ)
first = proc.stdout.readline() if selector.select(timeout=8) else b''
remote_pid = int((home / 'stream.pid').read_text()) if (home / 'stream.pid').exists() else None
def running():
    if remote_pid is None:
        return False
    try:
        os.kill(remote_pid, 0)
        return True
    except ProcessLookupError:
        return False
early = first == b'ready\n' and running() and not (home / 'stream-after').exists()
proc.send_signal(signal.SIGTERM)
try:
    out, err = proc.communicate(timeout=10)
    status = 0 if early and proc.returncode == 143 else 1
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    out, err = proc.communicate(timeout=25)
    status = 1
deadline = time.monotonic() + 5
while running() and time.monotonic() < deadline:
    time.sleep(0.05)
if running():
    status = 1
time.sleep(11)
if (home / 'stream-after').exists():
    status = 1
Path(sys.argv[3]).write_bytes(first + out)
Path(sys.argv[4]).write_bytes(err)
sys.exit(status)
PYCODE
		RC=$? TIMEDOUT=
		rc_is "real SSE delivers early output and disconnect kills the process group before a delayed side effect" 0

	fi
}

t_stream_backpressure030() {
	group "0.3.0 streamed command deadlines with stalled readers"
	if [ -z "$REAL" ]; then skip "process-group backpressure requires real mock commands"; return; fi
	reset '"seed":{"count":1}'
	local id home
	id=$(box box-1 .id)
	home=$(box box-1 .home)
	python3 - "$BASE" "$id" "$home" <<'PYCODE'
from pathlib import Path
from urllib.parse import urlsplit
import http.client, json, os, socket, sys, time
url = urlsplit(sys.argv[1])
home = Path(sys.argv[3])
conn = http.client.HTTPConnection(url.hostname, url.port, timeout=10)
conn.connect()
conn.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
body = json.dumps({'cmd': 'echo $$ >stalled.pid; (sleep 4; touch stalled-after) & head -c 67108864 /dev/zero; wait', 'timeoutSeconds': 1})
# The key is synthetic, supplied by the offline harness; no real account is used.
conn.request('POST', '/v1/machines/' + sys.argv[2] + '/exec', body=body,
             headers={'Authorization': 'Bearer ' + os.environ['INSTABOX_API_KEY'],
                      'Accept': 'text/event-stream', 'Content-Type': 'application/json'})
reply = conn.getresponse()
status = 0 if reply.status == 200 else 1
try:
    deadline = time.monotonic() + 3
    while not (home / 'stalled.pid').exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    pid = int((home / 'stalled.pid').read_text())
    def running():
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
    while running() and time.monotonic() < deadline:
        time.sleep(0.05)
    if running():
        status = 1
    time.sleep(5)
    if (home / 'stalled-after').exists():
        status = 1
finally:
    # Intentionally never read the verbose response body.
    reply.close()
    conn.close()
sys.exit(status)
PYCODE
	RC=$? TIMEDOUT=
	rc_is "a stalled SSE reader cannot defer timeout or allow a delayed side effect" 0
}

t_files030() {
	group "0.3.0 official file routes and older-server fallback"
	local home fake=$S/file-shims real_curl
	reset
	home=$(box box-1 .home)
	python3 - "$S/sparse030.bin" <<'PYCODE'
import sys
with open(sys.argv[1], 'wb') as stream:
    stream.truncate(5 * 1024**3 + 1)
PYCODE
	run put box-1 "$S/sparse030.bin" too-large
	rc_is "put refuses above five GiB before making a request" 125
	is "over-limit upload sends no API request" "$(ncalls)" 0
	rm "$S/sparse030.bin"

	head -c 5000000 /dev/urandom >"$S/file030.bin"
	hold box-1 60 tester
	run put box-1 "$S/file030.bin" 'sub/file with spaces..bin'
	rc_is "official PUT streams five MB with spaces and dots in the path" 0
	is "file upload uses no exec" "$(count POST '/exec$')" 0
	run get box-1 'sub/file with spaces..bin' "$S/file030.out"
	rc_is "official content GET downloads five MB" 0
	is "a successful first GET has no stderr diagnostics" "$(ERR)" ''
	yes_ "the five MB binary file round-trips unchanged" cmp -s "$S/file030.bin" "$S/file030.out"
	printf 'keep original\n' >"$S/limited.out"
	run IBX_GET_MAX=1M get box-1 'sub/file with spaces..bin' "$S/limited.out"
	rc_is "a bounded GET refuses excess bytes" 125
	is "a refused download preserves existing local content" "$(cat "$S/limited.out")" 'keep original'
	mkdir -p "$home/dir030"
	run put box-1 "$S/file030.bin" dir030
	rc_is "the file route refuses a directory destination" 125
	err_has "directory failure is actionable" 'destination is a directory'
	for code in no_space too_large; do
		ctl "$(jq -cn --arg c "$code" '{faults:[{kind:"error",method:"PUT",match:"/files$",status:507,code:$c}]}')"
		run put box-1 "$S/file030.bin" x
		rc_is "$code file errors exit 125" 125
	done
	ctl '{"faults":[{"kind":"error","method":"PUT","match":"/files$","status":409,"code":"machine_not_running","count":100}]}'
	run put box-1 "$S/file030.bin" repeated-refusal
	rc_is "persistent not-running file refusals are bounded" 125
	is "the file route stops after four not-running refusals" "$(calls | jq '[.calls[] | select(.method == "PUT" and .status == 409 and (.query | contains("repeated-refusal")))] | length')" 4
	ctl '{"clearFaults":true,"faults":[{"kind":"drop","method":"PUT","match":"/files$"}]}'
	run put box-1 "$S/file030.bin" committed-before-drop
	rc_is "a dropped committed upload response reports failure" 125
	err_has "a dropped upload does not claim the remote destination is untouched" 'remote file may have been replaced'
	yes_ "the mock confirms upload committed before the reply dropped" cmp -s "$S/file030.bin" "$home/committed-before-drop"
	ctl '{"fileBadHash":true}'
	run put box-1 "$S/file030.bin" bad-hash
	rc_is "an uploaded SHA-256 mismatch fails" 125
	err_has "checksum mismatch is explained" 'SHA-256 does not match'
	ctl '{"fileBadHash":false,"faults":[{"kind":"error","method":"PUT","match":"/files$","status":429,"code":"quota_exceeded"}]}'
	run put box-1 "$S/file030.bin" retry-quota
	rc_is "atomic upload retries a quota refusal" 0
	ctl '{"faults":[{"kind":"drop","method":"GET","match":"/files/content$"}]}'
	run get box-1 'sub/file with spaces..bin' "$S/short030.out"
	rc_is "a short file response fails" 125
	yes_ "a short response creates no local output" [ ! -e "$S/short030.out" ]
	ctl '{"faults":[{"kind":"error","method":"GET","match":"/files/content$","status":404,"code":"not_found","message":"file not found"}]}'
	run get box-1 absent "$S/absent030.out"
	rc_is "a real missing file never falls back to exec" 125
	is "missing file uses no exec" "$(count POST '/exec$')" 0
	ctl '{"filesEnabled":false}'
	run put box-1 "$S/file030.bin" old-large
	rc_is "older-server fallback keeps the 750 KB cap" 125
	err_has "older-server fallback is disclosed" 'falling back to exec.*750 KB'
	if [ -n "$REAL" ]; then
		printf 'old server\n' >"$S/old030.txt"
		run put box-1 "$S/old030.txt" old-small
		rc_is "older-server fallback writes a small file" 0
		run get box-1 old-small "$S/old030.out"
		rc_is "older-server fallback reads a small file" 0
		yes_ "older-server fallback round-trips unchanged" cmp -s "$S/old030.txt" "$S/old030.out"
		ctl '{"faults":[{"kind":"error","method":"POST","match":"/exec$","status":503,"code":"host_unavailable","retryable":true}]}'
		run put box-1 "$S/old030.txt" retry-safe
		rc_is "repeat-safe legacy upload may retry host_unavailable" 0
	fi
	reset
	ctl '{"set":{"box-1":{"tokens":[{"id":"cn_test","name":"TEST-LONG","createdAt":"2026-01-01T00:00:00Z"}]}}}'
	run doctor
	out_has "doctor audits non-expiring SSH tokens" 'long-lived SSH token: TEST-LONG'
	out_has "doctor reads concrete org usage" 'freeSandboxHoursUsed.*12'
	reset '"faults":[{"kind":"drop","method":"DELETE","match":"/ssh-tokens/","before":true,"count":12}]'
	mkdir "$fake"
	real_curl=$(command -v curl)
	printf '#!/bin/sh\nexit 0\n' >"$fake/ssh"
	# Only suppress the revoke backoff; all API and token verification calls still run.
	printf '#!/bin/sh\nexit 0\n' >"$fake/sleep"
	chmod +x "$fake/ssh" "$fake/sleep"
	run PATH="$fake:$PATH" ssh box-1 true
	rc_is "an SSH command can succeed while token cleanup fails" 0
	err_has "dropped token DELETEs remain visibly unconfirmed" 'may NOT be revoked'
	is "the failed revocation leaves one live token in the mock" "$(box box-1 '[.tokens[] | select(.revoked == false)] | length')" 1
	: "$real_curl"
}

t_platform030() {
	group "0.3.0 lifecycle, Secrets, ports and transfers"
	local future id selected fixture code fake=$S/forward030
	python3 - "$here/live.sh" "$S/live-budget-functions" <<'PYCODE'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
functions = []
for name in ('live_budget_rows', 'live_claim_budget'):
    start = source.index(name + '() {')
    end = source.index('\n}\n', start) + 3
    functions.append(source[start:end])
Path(sys.argv[2]).write_text('\n'.join(functions))
PYCODE
	jq -cn --arg short "$(ago -600)" --arg long "$(ago -2400)" \
		'[{name:"short",pool:true,reservation:"free",pausesAt:$short},{name:"long-a",pool:true,reservation:"free",pausesAt:$long},{name:"long-b",pool:true,reservation:"free",pausesAt:$long}]' >"$S/live-budget-rows"
	# shellcheck disable=SC1090,SC1091 # only the pure budget functions are extracted; no live suite runs
	source "$S/live-budget-functions"
	is "live preflight sees two eligible candidates" "$(live_budget_rows <"$S/live-budget-rows" | jq length)" 2
	live_claim_budget short long-a <"$S/live-budget-rows"
	is "live guard rejects an actually claimed nearly-spent box" "$?" 1
	yes_ "live guard accepts the two actual healthy claims" live_claim_budget long-a long-b <"$S/live-budget-rows"

	future=$(ago -300)
	reset
	hold box-1 0
	ctl "$(jq -cn --arg c "$future" '{set:{"box-1":{cooldownUntil:$c}}}')"
	run keepalive
	rc_is "cooldown skips are successful keepalive ticks" 0
	out_has "keepalive prints the cooldown deadline" 'box-1: max-run cooldown until .*skipped'
	is "cooldown skip sends no PUT" "$(count PUT .)" 0
	reset '"faults":[{"kind":"error","method":"PUT","match":"/activity-leases/","status":409,"code":"machine_cooldown","retryAfterSeconds":2}]'
	run keepalive --all
	rc_is "a cooldown raced with keepalive does not fail the pool tick" 0
	out_has "it says when to retry, without a cooldownUntil to print" '^box-1: max-run cooldown, retry after 2 s, skipped$'
	is "the other boxes still get leases" "$(count PUT .)" 3
	reset
	ctl "$(jq -cn --arg old "$(ago 25000)" '{set:{"box-1":{runStartedAt:$old},"box-2":{maxRunMinutes:0},"box-3":{maxRunMinutes:-1}}}')"
	run claim --json x
	rc_is "claim chooses a box with run budget" 0
	is "claim prefers unlimited over nearly spent and disabled boxes" "$(jq -r .name "$S/out")" box-3
	yes_ "claim JSON has pause and cooldown fields" jq -e 'has("pausesAt") and has("cooldownUntil")' "$S/out"
	reset '"seed":{"count":1}'
	ctl "$(jq -cn --arg c "$future" '{set:{"box-1":{cooldownUntil:$c}}}')"
	run claim --json x
	rc_is "claim skips boxes in cooldown" 75
	is "cooldown candidates receive no metadata write" "$(count PATCH .)" 0
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"POST","match":"/exec$","status":409,"code":"machine_cooldown","retryAfterSeconds":1}]'
	run exec box-1 -- true
	rc_is "exec waits out a short cooldown refusal before starting" 0
	is "one refused request and one actual exec" "$(count POST '/exec$')" 2
	reset '"set":{"box-1":{"state":"suspended"}},"faults":[{"kind":"error","method":"POST","match":"/resume$","status":409,"code":"machine_cooldown","retryAfterSeconds":1}]'
	run exec box-1 -- true
	rc_is "ensure_running waits out a short lifecycle cooldown" 0
	reset '"seed":{"count":2,"states":["suspended","suspended"]},"faults":[{"kind":"error","method":"POST","match":"/resume$","status":402,"code":"credit_exhausted","message":"wait until next UTC month"}]'
	run claim --json x
	rc_is "account blocks stop claim with exit 125" 125
	is "account blocks have a distinct JSON code" "$(jq -r .error.code "$S/out")" account_blocked
	is "account block stops after the first candidate" "$(count POST '/resume$')" 1
	is "account block cleanup leaves no reservation" "$(state | jq '[.machines[] | select(.metadata["ibx.claim.token"])] | length')" 0
	reset '"faults":[{"kind":"error","method":"GET","match":"^/v1/machines$","status":401,"code":"expired_key","hint":"ask the user","requiredScopes":["machines:write"]}]'
	run claim --json x
	rc_is "an expired key is an auth failure" 125
	yes_ "auth JSON keeps the code and safe server hint" jq -e '.error.code == "auth" and (.error.message | contains("expired_key") and contains("ask the user") and contains("machines:write"))' "$S/out"
	for fixture in '"all"' '["TEST_PROXY"]' '[]'; do
		reset '"seed":{"count":1}'
		selected=$(jq -cn --argjson p "$fixture" '{secrets:$p,envSecrets:[],items:[],version:0}')
		[ "$fixture" != '[]' ] || selected='{"secrets":[],"envSecrets":["TEST_ENV"],"items":[],"version":0}'
		ctl "$(jq -cn --argjson s "$selected" '{set:{"box-1":{secrets:$s}}}')"
		run claim --json x
		rc_is "unsafe Org Secret selection $fixture fails closed" 75
		is "unsafe Secret selections receive no reservation PATCH" "$(count PATCH .)" 0
		run IBX_ALLOW_SECRETS=1 claim --json x
		case $fixture in
		'[]') rc_is "env Secrets cannot be overridden" 75 ;;
		'"all"') rc_is "all proxy Secrets cannot be overridden" 75 ;;
		*) rc_is "the user can explicitly allow named proxy selections" 0 ;;
		esac
		if [ "$fixture" = '"all"' ]; then
			run IBX_ALLOW_SECRETS=1 ls --json
			is "ls still reports proxy selection risk when override is set" "$(jq -r '.[0].secrets' "$S/out")" true
			run IBX_ALLOW_SECRETS=1 doctor
			rc_is "doctor audits selected proxy Secrets even when override is set" 125
		fi
	done
	for fixture in '{"secrets":[],"envSecrets":[],"items":[],"version":0,"proxy":{"state":"pending"}}' '{"secrets":[],"envSecrets":[],"items":[],"version":0,"guest":{"items":[{"name":"RESIDUE"}]}}'; do
		reset '"seed":{"count":1}'
		ctl "$(jq -cn --argjson s "$fixture" '{set:{"box-1":{secrets:$s}}}')"
		run IBX_ALLOW_SECRETS=1 claim --json x
		rc_is "pending or guest Secret residue cannot be overridden" 75
	done
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"GET","match":"/secrets$","status":403,"code":"permission_denied"}]'
	run claim --json x
	rc_is "uninspectable Secrets are an API failure" 125
	reset '"seed":{"count":1},"orgSecretsEnabled":false'
	run claim --json x
	rc_is "older servers without Org Secrets are accepted only when usage disables them" 0
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"GET","match":"/machines/.*/secrets$","status":404,"code":"not_found","count":10}]'
	run claim --json x
	rc_is "ambiguous Secret 404 with orgSecrets enabled fails closed" 125
	reset '"seed":{"count":1,"pool":[0]},"set":{"box-1":{"secrets":{"secrets":"all","envSecrets":[],"items":[],"version":0}}}'
	run pool add box-1
	rc_is "pool add refuses Org Secret selections" 125
	err_has "pool add explains both selections must be cleared" 'secrets.*envSecrets.*--no-vault --secrets none'
	reset '"orgSecrets":[{"name":"TEST_ENV","delivery":"env","hosts":["*"]}]'
	run doctor
	rc_is "doctor fails for unsafe org-wide Secrets" 125
	out_has "doctor names the unsafe Secret without its value" 'FAIL.*unsafe Org Secret: TEST_ENV'
	reset '"seed":{"count":1},"set":{"box-1":{"ports":[{"port":8081,"name":"old"}]}}'
	run claim --json x
	id=$(jq -r .id "$S/out")
	selected=$(box box-1 '.metadata["ibx.claim.start"]')
	run renew box-1
	is "renew preserves the stable reservation start" "$(box box-1 '.metadata["ibx.claim.start"]')" "$selected"
	curl -q -fsS -H 'Authorization: Port mock-port' -H 'Content-Type: application/json' -d '{"port":8082,"name":"web"}' "$BASE/v1/machines/$id/ports" >/dev/null
	run release --json box-1
	rc_is "release removes a port created inside the sandbox during its reservation" 0
	yes_ "release gives the new port cleanup reason" jq -e '.unpublishReasons | any(.port == 8082 and .reason == "created during the reservation")' "$S/out"
	is "the older non-ibx port stays" "$(box box-1 '[.ports[].port]')" '[8081]'
	run doctor
	rc_is "doctor fails for a public port on an unreserved pool box" 125
	reset '"seed":{"count":1},"set":{"box-1":{"ports":[{"port":8081,"name":"older"},{"port":8082,"name":"newer"},{"port":8083,"name":"ibx:newer"}],"mergeMetadata":{"ibx.claim.start":"2026-10-27T10:00:00.150Z"},"rawPorts":[{"port":8081,"name":"older","url":"old","createdAt":"2026-10-27T10:00:00.100Z"},{"port":8082,"name":"newer","url":"new","createdAt":"2026-10-27T10:00:00.200Z"},{"port":8083,"name":"ibx:newer","url":"new-ibx","createdAt":"2026-10-27T10:00:00.200Z"}]}}'
	run release --json box-1
	rc_is "release distinguishes ports created within the same second" 0
	is "only the later same-second port is removed" "$(jq -c '[.unpublished,[.leftAlone[].port]]' "$S/out")" '[[8082,8083],[8081]]'
	yes_ "new ports get the reservation cleanup reason regardless of prefix" jq -e \
		'.unpublishReasons | all(.[]; .reason == "created during the reservation")' "$S/out"
	reset '"seed":{"count":1},"set":{"box-1":{"vault":0,"applied":{"env":[],"files":["leftover"],"kept":[]}}}'
	run claim --json x
	rc_is "Vault file residue is unsafe even with no selected items" 75
	reset '"seed":{"count":1},"set":{"box-1":{"vault":false,"applied":{"files":["leftover"],"kept":[]}}}'
	run claim --json x
	rc_is "disabling Vault does not hide persistent file residue" 75
	reset '"seed":{"count":1},"set":{"box-1":{"rawVault":{}}}'
	run claim --json x
	rc_is "a malformed Vault inspection fails closed" 125

	reset '"seed":{"count":1},"set":{"box-1":{"vault":0}},"faults":[{"kind":"error","method":"GET","match":"/vault$","status":403,"code":"permission_denied"}]'
	run claim --json x
	rc_is "uninspectable Vault fails closed" 125
	err_has "Vault 403 has actionable wording" 'cannot inspect the Vault.*--no-vault --secrets none'
	reset '"execResults":[{"stdout":"changed","invalidUtf8":true,"signal":"USR1","exitCode":255,"diskWarning":{"message":"disk is 95% full"}}]'
	run exec box-1 -- true
	rc_is "ExecResult warnings preserve the remote status" 255
	err_has "invalid UTF-8 is reported" 'output was not UTF-8'
	err_has "nonstandard signals are reported" 'SIGUSR1'
	err_has "disk warnings are reported" 'disk is 95% full'
	mkdir "$fake"
	printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"$FORWARD_ARGS"\n' >"$fake/ssh"
	chmod +x "$fake/ssh"
	reset
	run PATH="$fake:$PATH" FORWARD_ARGS="$S/forward-args" forward box-1 18080:8080 9000
	rc_is "forward uses the SSH setup" 0
	yes_ "forward binds both ends to loopback" grep -q '127.0.0.1:18080:127.0.0.1:8080' "$S/forward-args"
	yes_ "forward refuses failed listener setup" grep -q ExitOnForwardFailure=yes "$S/forward-args"
	is "forward revokes its token" "$(box box-1 '[.tokens[].revoked]')" '[true]'
	err_lacks "token revocation is confirmed" 'NOT be revoked'
	run PATH="$fake:$PATH" FORWARD_ARGS="$S/forward-args" forward box-1 0:8080
	rc_is "forward refuses invalid ports" 125
}

t_guards030() {
	group "0.3.0 guards: literal file names, RFC 3339 dates, Secret checks, keepalive refusals"
	local home cwd=$PWD code h fake=$S/guards-ssh future past start sel id f c args pid
	reset '"seed":{"count":1}'
	home=$(box box-1 .home)
	# curl reads -T - as stdin and expands {a,b} unless -g: the literal file must be what arrives.
	printf 'literal braces\n' >"$S/{x,.env}"
	printf 'decoy\n' >"$S/x"
	printf 'synthetic credential\n' >"$S/.env"
	run put box-1 "$S/{x,.env}" literal
	rc_is "put uploads a file whose name has braces" 0
	yes_ "the brace name is literal: no other file is uploaded in its place" cmp -s "$S/{x,.env}" "$home/literal"
	printf 'literal dash\n' >"$S/-"
	cd "$S" || return
	run put box-1 - dash
	cd "$cwd" || return
	rc_is "put uploads a local file named -" 0
	yes_ "a file named - is read, not stdin" cmp -s "$S/-" "$home/dash"
	mkdir "$fake"
	printf '#!/bin/sh\nexit 0\n' >"$fake/ssh"
	chmod +x "$fake/ssh"
	rm -f "$S/spy.args"
	run PATH="$SPY:$PATH" ls
	rc_is "(spied ls)" 0
	run PATH="$SPY:$PATH" exec box-1 -- true
	rc_is "(spied exec)" 0
	run PATH="$SPY:$PATH" exec box-1 --stream -- true
	rc_is "(spied exec --stream)" 0
	run PATH="$SPY:$PATH" put box-1 "$S/x" spy-put
	rc_is "(spied put)" 0
	run PATH="$SPY:$PATH" get box-1 spy-put "$S/spy-get"
	rc_is "(spied get)" 0
	run PATH="$fake:$SPY:$PATH" forward box-1 18080:8080
	rc_is "(spied forward)" 0
	# Each kind of curl call: api(), the stream, the upload, the download, the token revoke.
	for h in ' -X GET -H @- .*/v1/machines' ' -w %\{http_code\} -X POST -H @- .*/exec$' ' -N .* -H @- .*/exec$' \
		' -H @- -T ' ' -H @- --max-filesize ' ' -X DELETE -H @- .*/ssh-tokens/'; do
		yes_ "(the spy saw the curl call /$h/)" grep -Eq -- "$h" "$S/spy.args"
	done
	is "every curl that sends a request turns globbing off" "$(grep ' -H @- ' "$S/spy.args" | grep -cv -- ' -g ')" 0
	# /dev/stdin and the fd names are curl's own stdin (the drained key header) once curl opens
	# them: put refuses them, and hands curl the file's physical path, so no alias reaches it.
	printf 'orig\n' >"$home/f4"
	run -s "$S/x" put box-1 /dev/stdin f4
	rc_is "put refuses /dev/stdin" 125
	err_has "and says to name the file" 'put copies a named file'
	yes_ "and leaves the remote file alone" grep -qx orig "$home/f4"
	ln -s /dev/stdin "$S/stdin-link"
	run -s "$S/x" put box-1 "$S/stdin-link" f4
	yes_ "a link to /dev/stdin uploads the file it resolves to, or is refused; never an empty file (rc $RC)" \
		eval '{ [ "$RC" = 0 ] && cmp -s "$S/x" "$home/f4"; } || { [ "$RC" = 125 ] && grep -qx orig "$home/f4"; }'

	# Dates: valid RFC 3339 offsets are parsed; an unreadable one is null, never a vanished row.
	reset '"set":{"box-1":{"runStartedAt":"2026-10-27T10:00:00+05:30"},"box-2":{"runStartedAt":"2026-10-27t10:00:00.5-03:00"},"box-3":{"runStartedAt":"2026-10-27T10:00:00+0530"}}'
	run ls --json
	rc_is "ls with offset and unreadable run starts" 0
	is "no row is dropped for a date ibx cannot read" "$(jq -c 'map(.name)' "$S/out")" '["box-1","box-2","box-3"]'
	is "offsets move the pause to UTC" "$(jq -c 'map(.pausesAt)' "$S/out")" '["2026-10-27T12:30:00Z","2026-10-27T21:00:00Z",null]'
	reset '"seed":{"count":1},"set":{"box-1":{"runStartedAt":"2026-10-27T10:00:00+0530"}}'
	run claim --json x
	rc_is "claim takes a box whose run start it cannot read" 0
	yes_ "and reports its pause as null" jq -e '.name == "box-1" and .pausesAt == null' "$S/out"
	future=$(jq -nr 'now + 600 + 7200 | floor | strftime("%Y-%m-%dT%H:%M:%S+02:00")')
	past=$(jq -nr 'now - 600 - 14400 | floor | strftime("%Y-%m-%dT%H:%M:%S-04:00")')
	for code in "$future" soon; do
		reset '"seed":{"count":1}'
		ctl "$(jq -cn --arg c "$code" '{set:{"box-1":{cooldownUntil:$c}}}')"
		run claim --json x
		rc_is "claim skips a box with cooldownUntil $code" 75
		is "and writes no reservation to it" "$(count PATCH .)" 0
	done
	reset '"seed":{"count":1}'
	ctl "$(jq -cn --arg c "$past" '{set:{"box-1":{cooldownUntil:$c}}}')"
	run claim --json x
	rc_is "an offset cooldown that has ended allows the claim" 0
	reset '"seed":{"count":1}'
	hold box-1 0
	ctl "$(jq -cn --arg c "$future" '{set:{"box-1":{cooldownUntil:$c}}}')"
	run keepalive
	rc_is "keepalive with an offset cooldown" 0
	out_has "it reads the offset cooldown" '^box-1: max-run cooldown until .*\+02:00, skipped$'
	is "and sends no lease request" "$(count PUT .)" 0
	ctl '{"set":{"box-1":{"cooldownUntil":"soon"}}}'
	run keepalive
	rc_is "keepalive with an unreadable cooldown" 0
	is "leaves the decision to the server" "$(count PUT '/activity-leases/')" 1
	out_has "which refuses it as a cooldown skip" '^box-1: max-run cooldown until soon, skipped$'
	reset '"seed":{"count":1},"set":{"box-1":{"tokens":[{"id":"cn_odd","name":"ODD-EXPIRY","expiresAt":"not-a-date","revokedAt":null}]}}'
	run doctor
	out_has "doctor still reports a token whose expiry it cannot read" 'long-lived SSH token: ODD-EXPIRY'

	# Org Secrets: an inspection failure is an API error, unknown delivery fails closed, and
	# a proxy Secret without hosts means every host.
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"GET","match":"/machines/.*/secrets$","status":503,"code":"internal","count":20}]'
	run claim --json x
	rc_is "claim exits 125 when it cannot inspect Org Secrets" 125
	is "with an API failure, not no_free_sandbox" "$(jq -r .error.code "$S/out")" failed
	err_has "it says the Secrets could not be inspected" 'skipping box-1: could not inspect its Org Secrets'
	reset '"seed":{"count":1,"pool":[0]},"faults":[{"kind":"error","method":"GET","match":"/machines/.*/secrets$","status":503,"code":"internal","count":20}]'
	run pool add box-1
	rc_is "pool add refuses a box whose Secrets it cannot inspect" 125
	err_has "and says so instead of claiming Secrets are selected" 'could not inspect the Org Secrets of box-1'
	for h in '"secrets":[]' '"secrets":"all"'; do
		reset "\"seed\":{\"count\":1},\"set\":{\"box-1\":{\"secrets\":{$h,\"envSecrets\":[],\"items\":[{\"name\":\"NEW\",\"delivery\":\"future\"}],\"version\":0}}}"
		run IBX_ALLOW_SECRETS=1 claim --json x
		rc_is "the proxy override refuses unknown delivery ($h)" 75
	done
	# The override is for proxy Secrets scoped to named hosts: omitted or empty hosts mean every host.
	for h in '"hosts":["*"]' '"hosts":["api.example.com","*"]' '"hosts":[]' '"hosts":null' '"size":1'; do
		for sel in '"all"' '["WIDE"]'; do
			reset "\"seed\":{\"count\":1},\"set\":{\"box-1\":{\"secrets\":{\"secrets\":$sel,\"envSecrets\":[],\"items\":[{\"name\":\"WIDE\",\"delivery\":\"proxy\",$h}],\"version\":0}}}"
			run IBX_ALLOW_SECRETS=1 claim --json x
			rc_is "the proxy override refuses a wildcard proxy Secret ($sel, $h)" 75
			is "and reserves nothing" "$(count PATCH .)" 0
		done
		reset "\"seed\":{\"count\":1,\"pool\":[0]},\"set\":{\"box-1\":{\"secrets\":{\"secrets\":[\"WIDE\"],\"envSecrets\":[],\"items\":[{\"name\":\"WIDE\",\"delivery\":\"proxy\",$h}],\"version\":0}}}"
		run IBX_ALLOW_SECRETS=1 pool add box-1
		rc_is "pool add with the override refuses a wildcard proxy Secret ($h)" 125
		is "and leaves the box out of the pool" "$(box box-1 '.metadata["ibx.pool"] // "none"')" none
	done
	reset '"seed":{"count":1},"set":{"box-1":{"secrets":{"secrets":["SCOPED"],"envSecrets":[],"items":[{"name":"SCOPED","delivery":"proxy","hosts":["api.example.com"]}],"version":0}}}'
	run IBX_ALLOW_SECRETS=1 claim --json x
	rc_is "the proxy override still allows a proxy Secret for named hosts" 0
	for h in null '[]' '["*"]' '"*"'; do
		reset "\"orgSecrets\":[{\"name\":\"WIDE\",\"delivery\":\"proxy\",\"hosts\":$h}]"
		run doctor
		rc_is "doctor fails for a proxy Secret with hosts $h" 125
		out_has "and names it" '^FAIL +unsafe Org Secret: WIDE'
	done
	reset '"orgSecrets":[{"name":"NOHOSTS","delivery":"proxy"}]'
	run doctor
	rc_is "doctor fails for a proxy Secret that omits hosts" 125
	reset '"orgSecrets":[{"name":"LATER","delivery":"later","hosts":["api.example.com"]}]'
	run doctor
	rc_is "doctor fails for a Secret with an unknown delivery" 125
	reset '"orgSecrets":[{"name":"SCOPED","delivery":"proxy","hosts":["api.example.com"]}]'
	run doctor
	rc_is "a proxy Secret for named hosts is only a warning" 0
	out_has "and is listed" '^warn +Org Secret exists: SCOPED'
	reset '"orgSecretsEnabled":false'
	run doctor
	rc_is "doctor accepts a server without Org Secrets (404, usage says off)" 0
	out_has "and says so" '^ok +Org Secrets: none on this server'
	reset '"faults":[{"kind":"error","method":"GET","match":"^/v1/orgs/[^/]+/secrets$","status":404,"code":"not_found","count":10}]'
	run doctor
	rc_is "an Org Secrets 404 while usage says they exist still fails" 125
	out_has "as an audit failure" '^FAIL +could not audit Org Secrets'
	# Doctor shows the API's reason for a failed audit instead of guessing one.
	reset '"faults":[{"kind":"error","method":"GET","match":"^/v1/orgs/[^/]+/secrets$","status":403,"code":"permission_denied","message":"only org admins may list Secrets here","count":10}]'
	run doctor
	rc_is "doctor fails when the Org Secrets audit is refused" 125
	out_has "with the API's reason" '^FAIL +could not audit Org Secrets \(permission_denied: only org admins may list Secrets here\)$'
	out_lacks "without guessing a missing scope" 'machines:read'
	reset '"faults":[{"kind":"error","method":"GET","match":"^/v1/orgs/[^/]+/secrets$","status":403,"code":"missing_scope","message":"this key lacks a scope","requiredScopes":["machines:read"],"count":10}]'
	run doctor
	out_has "a missing scope is named as such" '^      next: .*machines:read'
	reset '"seed":{"count":1},"set":{"box-1":{"secrets":{"secrets":["X"],"envSecrets":[],"items":[],"version":0}}}'
	run doctor
	rc_is "doctor fails for a box with Org Secrets selected" 125
	out_has "and says they are selected" '^FAIL +box-1 has Org Secrets selected, pending or left behind$'
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"GET","match":"/machines/.*/secrets$","status":503,"code":"host_unavailable","message":"mock: secrets down","count":20}]'
	run doctor
	rc_is "doctor fails for a box whose Org Secrets it cannot inspect" 125
	out_has "and says why" '^FAIL +could not inspect the Org Secrets of box-1 \(host_unavailable: mock: secrets down\)$'
	out_lacks "without calling that a selection" 'has Org Secrets selected'
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"GET","match":"/vault$","status":403,"code":"permission_denied","message":"not the creator","count":20}]'
	run doctor
	rc_is "doctor fails for a box whose Vault it cannot read" 125
	out_has "and says why" '^FAIL +could not read the Vault of box-1 \(permission_denied: not the creator\)$'
	reset '"faults":[{"kind":"error","method":"GET","match":"^/v1/machines$","status":503,"code":"host_unavailable","message":"mock: list down","retryable":true,"count":10}]'
	run doctor
	rc_is "doctor fails when it cannot list the sandboxes" 125
	out_has "and says so, with the API's reason" '^FAIL +could not list sandboxes \(host_unavailable: mock: list down\)'
	out_lacks "never as an empty pool" 'pool is empty|pool add'
	is "and audits no ports against a list it does not have" "$(count GET '^/v1/ports$')" 0
	yes_ "with a next step" fail_next
	reset '"seed":{"count":2,"vault":{"box-1":2}},"set":{"box-2":{"ports":[{"port":8081,"name":"x"}]}},"orgSecrets":[{"name":"ENVV","delivery":"env","hosts":["*"]}]'
	run doctor
	rc_is "doctor with several failures" 125
	is "it reports each of them" "$(grep -c '^FAIL ' "$S/out")" 3
	yes_ "every FAIL line is followed by a next step" fail_next

	# keepalive: refusals that renewing cannot fix are skips; a billing block stops the tick.
	reset '"seed":{"count":1},"set":{"box-1":{"maxRunMinutes":0}}'
	run keepalive --all
	rc_is "keepalive skips a box whose max-run is disabled" 0
	out_has "and says why" '^box-1: max-run is disabled \(maxRunMinutes 0\), skipped$'
	# The lease route does not list 402, but it wakes an idle-paused box first, and wake does.
	# box-2 is paused for idleness; box-1 and box-3 run and need no wake.
	reset '"set":{"box-2":{"state":"idle"}}'
	id=$(box box-2 .id)
	ctl "{\"faults\":[{\"kind\":\"error\",\"method\":\"PUT\",\"match\":\"/$id/activity-leases/\",\"status\":402,\"code\":\"credit_exhausted\",\"message\":\"wait until next UTC month\"}]}"
	run keepalive --all
	rc_is "a billing block is a skip: exit 0, so the timer unit does not restart" 0
	out_has "it names the billing block" '^box-2: account blocked by billing: credit_exhausted; wait until next UTC month.*skipped'
	out_has "the running box after it still gets its lease" '^box-3: lease until '
	is "every box is asked once" "$(count PUT '/activity-leases/')" 3
	reset '"set":{"box-2":{"state":"idle"}}'
	ctl "$(jq -cn --arg a "$(box box-1 .id)" --arg b "$(box box-2 .id)" '{faults:[
		{kind:"error",method:"PUT",match:("/" + $a + "/activity-leases/"),status:409,code:"operation_conflict"},
		{kind:"error",method:"PUT",match:("/" + $b + "/activity-leases/"),status:402,code:"credit_exhausted"}]}')"
	run keepalive --all
	rc_is "a billing block does not hide another box's failed lease" 1
	out_has "which is reported" '^box-1: FAILED .*operation_conflict'
	out_has "and the box after them still gets its lease" '^box-3: lease until '
	reset '"seed":{"count":1}'
	hold box-1 0
	run INSTABOX_API_KEY=$OTHER_KEY keepalive
	rc_is "keepalive with a rejected key fails as ibx itself (125), not as a lease (1)" 125

	# Release compares the claim start with port times from the server's clock.
	reset '"seed":{"count":1},"clockSkew":-120'
	run claim --json x
	rc_is "claim against a server clock two minutes behind" 0
	start=$(box box-1 '.metadata["ibx.claim.start"]')
	yes_ "the reservation start is the server's time of the claim ($start)" \
		jq -en --arg s "$start" --arg u "$(box box-1 .updatedAt)" '($s | sub("\\.[0-9]+"; "") | fromdateiso8601) < now - 60 and $s <= $u'
	curl -q -fsS -H 'Authorization: Port mock-port' -H 'Content-Type: application/json' -d '{"port":8082,"name":"web"}' "$BASE/v1/machines/$(box box-1 .id)/ports" >/dev/null
	run release --json box-1
	rc_is "release with a skewed server clock" 0
	yes_ "a port the sandbox published during the reservation is removed" jq -e \
		'.unpublishReasons == [{"port":8082,"reason":"created during the reservation"}]' "$S/out"
	reset '"seed":{"count":1},"metadataKeepsUpdatedAt":true'
	run claim --json x
	rc_is "claim on a server whose metadata PATCH leaves updatedAt alone" 0
	is "then the start falls back to this computer's clock, never an old updatedAt" \
		"$(box box-1 '.metadata["ibx.claim.start"] != .updatedAt')" true

	# A stream answered with a 4xx error envelope never started the command.
	reset '"faults":[{"kind":"error","method":"POST","match":"/exec$","status":409,"code":"operation_conflict"}]'
	run exec box-1 --stream -- true
	rc_is "a plain JSON stream refusal fails with 125 (409)" 125
	err_has "and says the command did not run" 'exec did not run: the API'
	is "without a retry" "$(count POST '/exec$')" 1

	# Any other reply without a stream may come after the command started, including every
	# 503: retryable host_unavailable can also mean an API restart killed a running command.
	for f in '"kind":"error","status":500,"code":"internal"' '"kind":"error","status":503,"code":"host_unavailable","retryable":true' \
		'"kind":"error","status":503,"code":"host_unavailable","retryable":false' '"kind":"error","status":403,"body":"<html>Forbidden</html>"' \
		'"kind":"error","status":401,"body":"<html>Unauthorized</html>"' \
		'"kind":"error","status":502,"body":"<html><body>502 Bad Gateway</body></html>"' '"kind":"drop","plain":true'; do
		reset "\"execResults\":[{\"stdout\":\"hi\\n\"}],\"faults\":[{\"method\":\"POST\",\"match\":\"/exec\$\",$f}]"
		run exec box-1 --stream -- 'echo hi'
		rc_is "a stream answered without one ($f) fails with 125" 125
		err_has "and says the command may have run" 'may (or may not )?have run'
		err_lacks "never that it did not run" 'did not run'
		is "without a retry" "$(count POST '/exec$')" 1
	done

	# An interrupt says how far it got: nothing started before the SSH session, and an exec whose
	# result arrived has finished.
	for c in ssh forward; do
		reset '"seed":{"count":1},"faults":[{"kind":"delay","method":"GET","match":"/connection-info$","seconds":3}]'
		if [ "$c" = ssh ]; then args=(ssh box-1 -- true); else args=(forward box-1 18080:8080); fi
		PATH="$fake:$PATH" "$IBX" "${args[@]}" >"$S/out" 2>"$S/err" </dev/null &
		pid=$!
		for _ in $(seq 100); do [ "$(count GET '/connection-info$')" -ge 1 ] && break; sleep 0.1; done
		kill -TERM "$pid"
		wait "$pid"
		RC=$? TIMEDOUT=
		rc_is "$c interrupted while it reads the connection info exits 143" 143
		err_has "and says nothing started" '^ibx: interrupted by SIGTERM before anything started in the sandbox$'
		is "it created no SSH token" "$(count POST '/ssh-tokens$')" 0
	done
	reset '"seed":{"count":1}'
	jq -cn '{execResults:[{stdout:("x" * 300000)}]}' >"$S/big-result"
	curl -q -fsS -m 10 -X POST --data-binary @"$S/big-result" "$BASE/_control" >/dev/null || bad "mock control: big result"
	python3 - "$IBX" "$S/out" "$S/err" <<'PYCODE'
import os, select, signal, subprocess, sys
proc = subprocess.Popen([sys.argv[1], 'exec', 'box-1', '--', 'big'], stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
# Output means the result is in; ibx then blocks writing to the pipe nobody reads yet.
select.select([proc.stdout], [], [], 30)
os.killpg(proc.pid, signal.SIGTERM)
out, err = proc.communicate(timeout=20)
open(sys.argv[2], 'wb').write(out)
open(sys.argv[3], 'wb').write(err)
sys.exit(proc.returncode if proc.returncode >= 0 else 128 - proc.returncode)
PYCODE
	RC=$? TIMEDOUT=
	rc_is "exec interrupted while it prints the result exits 143" 143
	err_has "and says the command had finished" '^ibx: interrupted by SIGTERM after the remote command finished$'

	# ls --json shows the runtime, so agents can check processesPreserved after a wake.
	reset '"set":{"box-1":{"state":"idle","freshBoot":true}}'
	run exec box-1 -- true
	rc_is "exec wakes an idle box that comes back fresh" 0
	run ls --json
	is "ls --json reports runtime.processesPreserved" \
		"$(jq -c '.[] | select(.name == "box-1") | .runtime.processesPreserved' "$S/out")" false
}

t_review_a_r2() {
	group "part A round 2: physical paths, named Secrets and doctor failure reasons"
	local cwd=$PWD home selected items action route label pid source
	reset '"seed":{"count":1}'
	home=$(box box-1 .home)
	printf 'original\n' >"$S/notes"
	printf 'newline file\n' >"$S/notes"$'\n'
	printf 'keep remote\n' >"$home/newline"
	mkdir "$S/cdpath-src"
	cp "$S/notes" "$S/cdpath-src/notes"
	cd "$S" || return
	run CDPATH="$S" put box-1 cdpath-src/notes cdpath
	cd "$cwd" || return
	rc_is "put accepts relative paths with exported CDPATH" 0
	yes_ "CDPATH does not change the uploaded file" cmp -s "$S/notes" "$home/cdpath"
	run put box-1 "$S/notes"$'\n' newline
	rc_is "put refuses a physical path that lost a trailing newline" 125
	yes_ "a truncated source path cannot replace the remote file" grep -qx 'keep remote' "$home/newline"
	ln -s "$S/notes" "$S/regular-link"
	run put box-1 "$S/regular-link" regular-link
	rc_is "put still accepts a symlink to a regular file" 0
	yes_ "and uploads its target" cmp -s "$S/notes" "$home/regular-link"
	ln -s "$S/notes"$'\n' "$S/newline-link"
	run put box-1 "$S/newline-link" newline
	rc_is "put refuses a symlink whose target lost a trailing newline" 125
	yes_ "a truncated symlink target cannot replace the remote file" grep -qx 'keep remote' "$home/newline"
	cd "$(dirname "$here")/.." || return
	# A relative script path exercises install.sh's source-directory lookup.
	env CDPATH="$PWD" bash "$(basename "$(dirname "$here")")/install.sh" --agents none --no-bin --dry-run >"$S/out" 2>"$S/err"
	RC=$? TIMEDOUT=
	cd "$cwd" || return
	rc_is "install accepts a relative script path with exported CDPATH" 0

	if [ -f /proc/self/environ ]; then
		# This stable process contains only public, synthetic values. /proc/self is also checked
		# separately because phys resolves it through a short-lived command-substitution shell.
		env -i PATH="$PATH" IBX_TEST_VALUE=synthetic sleep 60 &
		pid=$!
		ln -s "/proc/$pid/environ" "$S/pseudo-link"
		for action in true false; do
			for source in /proc/self/environ "/proc/$pid/environ" "$S/pseudo-link"; do
				reset "\"seed\":{\"count\":1},\"filesEnabled\":$action"
				home=$(box box-1 .home)
				printf 'keep remote\n' >"$home/pseudo"
				# Only synthetic values reach this child, even when testing the unfixed helper.
				env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" IBX_STATE_DIR="$IBX_STATE_DIR" \
					IBX_KEY_FILE="$IBX_KEY_FILE" IBX_AGENT_NAME=tester INSTABOX_API_URL="$BASE" \
					INSTABOX_API_KEY="$KEY" "$IBX" put --force box-1 "$source" pseudo >"$S/out" 2>"$S/err" </dev/null
				RC=$? TIMEDOUT=
				rc_is "put refuses pseudo-files and aliases even with --force ($source, file routes $action)" 125
				err_has "and asks for a named file" 'put copies a named file'
				is "pseudo-files are refused before any API request" "$(ncalls)" 0
				yes_ "and preserve the remote file" grep -qx 'keep remote' "$home/pseudo"
			done
		done
		kill "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
	else skip "pseudo-file guard needs Linux /proc/self/environ"; fi

	for items in '[]' '[{"name":"SCOPED","delivery":"proxy","hosts":["api.example.com"]}]'; do
		for action in claim pool; do
			reset '"seed":{"count":1,"pool":[0]}'
			selected=$(jq -cn --argjson items "$items" '{secrets:"all",envSecrets:[],items:$items,version:0}')
			ctl "$(jq -cn --argjson s "$selected" '{set:{"box-1":{secrets:$s}}}')"
			if [ "$action" = claim ]; then
				ctl '{"set":{"box-1":{"mergeMetadata":{"ibx.pool":"1"}}}}'
				run IBX_ALLOW_SECRETS=1 claim --json x
				rc_is "claim refuses all future proxy Secrets even when current items are $items" 75
			else
				run IBX_ALLOW_SECRETS=1 pool add box-1
				rc_is "pool add refuses all future proxy Secrets even when current items are $items" 125
			fi
			is "all selection causes no metadata write" "$(count PATCH .)" 0
		done
	done
	reset '"seed":{"count":1,"pool":[0]},"set":{"box-1":{"secrets":{"secrets":["SCOPED"],"envSecrets":[],"items":[{"name":"SCOPED","delivery":"proxy","hosts":["api.example.com"]}],"version":0}}}'
	run IBX_ALLOW_SECRETS=1 pool add box-1
	rc_is "pool add accepts an explicitly named scoped proxy Secret with the override" 0
	is "and admits that box" "$(box box-1 '.metadata["ibx.pool"]')" 1
	reset '"seed":{"count":1},"set":{"box-1":{"secrets":{"secrets":[],"envSecrets":[],"items":[{"name":"WIDE","delivery":"proxy","hosts":["*"]}],"version":0}}}'
	run IBX_ALLOW_SECRETS=1 claim --json x
	rc_is "empty selections cannot hide an effective wildcard proxy Secret" 75
	is "and reserve nothing" "$(count PATCH .)" 0

	reset '"seed":{"count":1},"faults":[{"kind":"drop","method":"GET","match":"/machines/.*/secrets$","before":true,"count":20}]'
	run doctor
	rc_is "doctor fails for a dropped Secret inspection connection" 125
	out_has "and extracts the envelope after curl's own diagnostic lines" '^FAIL +could not inspect the Org Secrets of box-1 \(transport: curl exit 52 on GET /v1/machines/.*/secrets\)$'
	for route in '^/v1/orgs/[^/]+$' '/ssh-tokens$' '^/v1/ports$'; do
		case $route in
		'^/v1/orgs/[^/]+$') label='could not read the org plan' ;;
		'/ssh-tokens$') label='could not audit SSH tokens for box-1' ;;
		*) label='could not audit public ports' ;;
		esac
		reset "\"seed\":{\"count\":1},\"faults\":[{\"kind\":\"error\",\"method\":\"GET\",\"match\":\"$route\",\"status\":403,\"code\":\"missing_scope\",\"message\":\"mock: audit denied\",\"count\":10}]"
		run doctor
		rc_is "doctor fails for a refused audit ($route)" 125
		out_has "and includes that audit's API reason" "^FAIL +$label \\(missing_scope: mock: audit denied\\)$"
		yes_ "and supplies a next step" fail_next
	done
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"GET","match":"/machines/.*/secrets$","status":502,"body":"<html>Bad\u001bGateway</html>","count":10}]'
	run doctor
	rc_is "doctor fails for an HTML gateway error" 125
	out_has "and falls back to cleaned raw text" '^FAIL +could not inspect the Org Secrets of box-1 \(<html>BadGateway</html>\)$'
	yes_ "raw diagnostics print no control characters" eval '! has_ctl "$S/out"'
	reset '"faults":[{"kind":"error","method":"GET","match":"^/v1/machines$","status":403,"code":"missing_scope","message":"mock: machines:read required","count":10}]'
	run doctor
	rc_is "doctor fails when a key cannot read the sandbox list" 125
	out_has "and names the missing list scope" '^FAIL +could not list sandboxes \(missing_scope: mock: machines:read required\)'
	out_has "with the fatal key-replacement next step" '^      next: the user fixes or replaces this key'
	out_lacks "without reporting an empty pool" 'pool is empty|pool add'
	is "and skips the public-port audit" "$(count GET '^/v1/ports$')" 0
	reset '"seed":{"count":1},"faults":[{"kind":"error","method":"PUT","match":"/activity-leases/","status":403,"code":"missing_scope","message":"mock: machines:write required","count":10}]'
	run keepalive --all
	rc_is "a key that can list boxes but cannot write leases exits 1" 1
	out_has "and reports a failed lease" '^box-1: FAILED .*missing_scope'
}

for t in review_a_r2 ownership guards030 platform030 files030 stream030 stream_backpressure030 cli doctor pool ls claim claim_parallel claim_cap claim_lock_busy claim_mkdir_signals closed_stderr claim_names claim_lock claim_reaper claim_signals claim_signal_commit claim_fresh claim_json claim_errors claim_states renew release port keepalive exec exec_wait_signals exec_stdin sigterm retry files \
	put_guard poolonly vault hostile secrets ssh install cleanup; do
	want "$t" && "t_$t"
done
printf '\n%d passed, %d failed in %ds\n' "$passed" "$failed" $(($(date +%s) - start))
[ "$failed" = 0 ]
