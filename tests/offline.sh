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
export IBX_KEY_FILE=$S/no-key-file IBX_AGENT_NAME=tester IBX_CLAIM_SETTLE='0.2 0.1'
unset INSTABOX_KEY_FILE IBX_STALE_SECS IBX_MAXTIME IBX_EXEC_MAXTIME IBX_REEXEC CURL_HOME \
	IBX_ALLOW_ANY IBX_ALLOW_VAULT IBX_ALLOW_CUSTOM_API CODEX_HOME

# The key reaches the mock through its environment, so no process has it in its arguments.
TMPDIR=$S/mock MOCK_API_KEY=$KEY python3 "$MOCK" --port 0 --exec "$EXEC_MODE" >"$S/mock.port" 2>"$S/mock.log" &
MOCK_PID=$!
for _ in $(seq 100); do [ -s "$S/mock.port" ] && break; sleep 0.1; done
PORT=$(head -n 1 "$S/mock.port")
[ -n "$PORT" ] || { echo "offline.sh: the mock did not start:" >&2; cat "$S/mock.log" >&2; exit 2; }
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
	local envs=(env) pid wd in=/dev/null
	while [ $# -gt 0 ]; do
		case "$1" in
		-u) envs+=(-u "$2"); shift 2 ;;
		-s) in=$2; shift 2 ;;
		[A-Za-z_]*=*) envs+=("$1"); shift ;;
		*) break ;;
		esac
	done
	rm -f "$S/timedout"
	RUN_LIMIT=$LIMIT
	"${envs[@]}" "$IBX" "$@" >"$S/out" 2>"$S/err" <"$in" &
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

want() { [ -z "${ONLY:-}" ] || [[ $1 == *$ONLY* ]]; }

# ---- tests -----------------------------------------------------------------------------------
t_cli() {
	group "CLI without the API"
	run -u INSTABOX_API_KEY --help
	rc_is "--help works without a key" 0
	out_has "--help prints the usage" '^ibx - borrow'
	run -u INSTABOX_API_KEY
	rc_is "no arguments prints the usage" 0
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
	err_has "a wrong key: the API error is shown" unauthenticated
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
	run INSTABOX_API_KEY=$OTHER_KEY doctor
	rc_is "doctor fails with a wrong key" 125
	out_has "doctor shows the API error" '^FAIL +API call failed: .*unauthenticated'
	run -u INSTABOX_API_KEY doctor
	rc_is "doctor fails without a key" 125
	out_has "doctor says the key is missing" '^FAIL +no API key'
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
		[ "$(claim_keys box-1)" = 4 ] && break
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
	err_has "renew of a free sandbox says so" 'has no reservation to renew'
	run renew
	rc_is "renew without a sandbox is a usage error" 125
}

t_release() {
	group release
	local setup
	setup='"set":{"box-1":{"mergeMetadata":{"owner.note":"keep me"},"leases":["ibx-keepalive","other-task"],
		"ports":[{"port":8080,"name":"ibx:web"},{"port":8081,"name":"dashboard"},{"port":8082,"name":"ibx:port"}]}}'
	reset "$setup"
	hold box-1 60
	run release box-1
	rc_is "release" 0
	out_has "release unpublishes ibx ports" '^unpublished port 8080 of box-1$'
	out_has "release unpublishes every ibx port" '^unpublished port 8082 of box-1$'
	out_has "release says what was released" '^released box-1 \(was: earlier job \(someone@elsewhere, since 20'
	err_has "release leaves other ports alone, and says so" 'left port 8081 alone'
	is "only the port ibx did not publish is left" "$(box box-1 '[.ports[].port]')" '[8081]'
	is "release deletes only the ibx lease" "$(box box-1 '[.leases[].id]')" '["other-task"]'
	is "release clears ibx.claim.* and keeps the rest" "$(box box-1 .metadata)" '{"ibx.pool":"1","owner.note":"keep me"}'
	run release box-2
	rc_is "release of a free sandbox" 0
	out_has "release of a free sandbox says there was no reservation" 'was: no reservation'

	reset "$setup,\"faults\":[{\"kind\":\"error\",\"method\":\"DELETE\",\"match\":\"/ports/\",\"count\":9,\"status\":403,\"code\":\"permission_denied\",\"message\":\"no\"}]"
	hold box-1 60
	run release box-1
	rc_is "release fails when a port cannot be unpublished" 125
	err_has "it names the URLs that are still public" 'STILL PUBLIC: https://'
	is "the reservation is kept" "$(claim_keys box-1)" 4
	is "the lease is kept" "$(box box-1 '[.leases[].id]')" '["ibx-keepalive","other-task"]'

	reset "$setup,\"faults\":[{\"kind\":\"error\",\"method\":\"GET\",\"match\":\"/ports$\",\"status\":403,\"code\":\"permission_denied\",\"message\":\"no\"}]"
	hold box-1 60
	run release box-1
	rc_is "release fails when the ports cannot be listed" 125
	err_has "it says nothing was released" 'nothing released'
	is "nothing was changed" "$(count DELETE .):$(count PATCH .)" 0:0

	# A DELETE that is retried after the first one went through gets 404: already unpublished.
	reset "$setup,\"faults\":[{\"kind\":\"error\",\"method\":\"DELETE\",\"match\":\"/ports/8080$\",\"status\":404,\"code\":\"not_found\",\"message\":\"port 8080 is not public\"}]"
	hold box-1 60
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
		run exec box-1 -- 'echo out; echo err >&2; exit 3'
		rc_is "one argument is a script" 3
		is "stdout goes to stdout" "$(OUT)" out
		is "stderr goes to stderr" "$(ERR)" err
	fi
	run exec box-1 -t 1 -- 'sleep 5'
	rc_is "a timed-out exec exits 124" 124
	err_has "a timeout suggests running detached" 'timed out after 1s'

	ctl '{"execResults":[{"stdout":"partial","truncated":true},{"exitCode":143}]}'
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
	is "an idle-paused sandbox is woken once" "$(count POST '/wake$')" 1

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
	run exec box-1 -- 'exit 2'
	rc_is "host_unavailable (retryable) is retried" 2
	is "and then the command ran" "$(count POST '/exec$')" 2
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
	local code
	for code in api_key_expired api_key_revoked; do
		reset "\"faults\":[{\"kind\":\"error\",\"method\":\"POST\",\"match\":\"/exec\$\",\"status\":401,\"code\":\"$code\",\"message\":\"no\"}]"
		run exec box-1 -- true
		rc_is "$code: exec fails with 125" 125
		err_has "$code: it says the command did not run" 'exec rejected \(the command did not run\)'
		is "$code: and does not retry" "$(count POST '/exec$')" 1
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
		'^ibx: interrupted by SIGTERM: a remote command it started may still be running$'
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
	ctl '{"resetCalls":true}'
	run put box-1 "$S/over.bin" over.bin
	rc_is "put of 750001 bytes is refused" 125
	err_has "it suggests tar over ssh" 'over 750 KB: tar c FILES \| ibx ssh box-1'
	is "and makes no request" "$(ncalls)" 0
	head -c 750001 /dev/zero >"$home/big.bin"
	run get box-1 big.bin "$S/big.out"
	rc_is "get of 750001 bytes is refused" 125
	err_has "it suggests ssh" '750001 bytes is over 750 KB'
	yes_ "and writes nothing" [ ! -e "$S/big.out" ]
	run get box-1 sub/dir/f.bin "$S/no-such-dir/f.bin"
	rc_is "get into a missing local directory fails with 125" 125
	run get box-1 no-such-file "$S/x"
	rc_is "get of a missing file fails" 125
	err_has "it says why" 'not a regular file'
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
	yes_ "the leading ~/ is dropped (HOME is where relative paths go)" \
		eval 'last_exec .cmd | grep -q "tl/plain.txt" && ! last_exec .cmd | grep -q "~"'
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
	out_lacks "nothing about sandboxes without the Vault or outside the pool" 'box-[34]'
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
	run release "$id"
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
		(cd "$ih" && env -u XDG_CONFIG_HOME -u IBX_KEY_FILE -u INSTABOX_KEY_FILE -u CODEX_HOME \
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
}

t_cleanup() {
	group cleanup
	is "ibx removed its temporary directories" "$(find "$TMPDIR" -maxdepth 1 -name 'ibx.*' | wc -l | tr -d ' ')" 0
}

start=$(date +%s)
echo "ibx offline tests: $IBX against $BASE (exec: $EXEC_MODE)"
for t in cli doctor pool ls claim claim_states renew release port keepalive exec exec_stdin sigterm retry files \
	put_guard poolonly vault hostile secrets ssh install cleanup; do
	want "$t" && "t_$t"
done
printf '\n%d passed, %d failed in %ds\n' "$passed" "$failed" $(($(date +%s) - start))
[ "$failed" = 0 ]
