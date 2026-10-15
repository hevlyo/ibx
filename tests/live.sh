#!/usr/bin/env bash
# Live regression checks for ibx against a real instabox.sh account. Opt-in: IBX_LIVE=1.
#
# It claims two free pool sandboxes at once, runs commands in them, copies files, opens ssh
# sessions, publishes a port at a public URL for a few seconds, and releases both sandboxes at
# the end (also after a failure or Ctrl-C). It needs the usual API key (INSTABOX_API_KEY or
# ~/.config/instabox/api-key) and at least two free sandboxes in the pool (ibx pool add ...)
# that the Vault writes no secrets into (the Vault may be on, but empty: ibx doctor says so).
# It runs with ibx's default rules: IBX_ALLOW_ANY and IBX_ALLOW_VAULT are ignored.
# It also runs `ibx keepalive`, which renews the activity lease of every reserved pool sandbox,
# as the keepalive timer does. Takes a few minutes. Prints PASS/FAIL lines; exits 1 on a FAIL.
#
#   IBX_LIVE=1 tests/live.sh
#   IBX_LIVE=1 IBX=/path/to/ibx tests/live.sh
# shellcheck disable=SC2016,SC2088 # checks given to eval expand when they run; ~/ is for ibx
set -u

if [ "${IBX_LIVE:-}" != 1 ]; then
	echo "live.sh uses a real instabox.sh account and two of its pool sandboxes: run it with IBX_LIVE=1" >&2
	exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd)
IBX=${IBX:-$(cd -- "$here/.." && pwd)/skills/ibx/scripts/ibx}
for dep in curl jq cmp tar; do
	command -v "$dep" >/dev/null || { echo "live.sh: $dep is needed" >&2; exit 2; }
done

L=$(mktemp -d "${TMPDIR:-/tmp}/ibx-live.XXXXXX")
export IBX_AGENT_NAME=ibx-live-$$
unset IBX_ALLOW_ANY IBX_ALLOW_VAULT
W=ibx-live-$$ # work directory in the sandboxes, under HOME
A='' B='' URL=''

passed=0 failed=0
ok() { passed=$((passed + 1)); printf 'PASS %s\n' "$*"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$*"; }
check() { # description expected-rc actual-rc
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (rc $3, expected $2)"; fi
}
is() { # description got expected
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got $(printf %q "$2"), expected $(printf %q "$3"))"; fi
}
yes_() { if "${@:2}"; then ok "$1"; else bad "$1"; return 1; fi; } # description command...
show() { sed 's/^/    /' "$1"; }
ibx() { "$IBX" "$@"; }
mine() { # name -> 0 if this run still holds that sandbox
	[ -n "$1" ] && ibx ls --json 2>/dev/null |
		jq -e --arg n "$1" --arg by "$IBX_AGENT_NAME" 'any(.[]; .name == $n and .by == $by)' >/dev/null
}

tidy() { # name: stop the test server and remove the work directory (only while we hold it)
	ibx exec "$1" -- "pkill -f '[h]ttp.server 8098'; rm -rf ~/$W" >/dev/null 2>&1
}
cleanup() {
	trap '' INT TERM
	local b
	for b in "$A" "$B"; do
		mine "$b" || continue # released already (maybe someone else holds it now): hands off
		tidy "$b"
		ibx release "$b" >/dev/null 2>&1 || echo "live.sh: could not release $b: run  ibx release $b" >&2
	done
	rm -rf "$L"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "ibx live tests: $IBX as $IBX_AGENT_NAME"

# ---- before claiming -----------------------------------------------------------------------
env -u INSTABOX_API_KEY IBX_KEY_FILE="$L/no-key" "$IBX" --help >/dev/null 2>&1
check "--help works without a key" 0 $?
ibx doctor >"$L/doctor" 2>&1
rc=$?
check "doctor (it fails when the Vault writes secrets into a pool sandbox)" 0 "$rc"
[ "$rc" = 0 ] || show "$L/doctor"
yes_ "doctor reached the API" grep -q '^ok    API reachable' "$L/doctor" || show "$L/doctor"
ibx ls --all --json >"$L/ls-all"
yes_ "ls --json: every row has a boolean vault field" jq -e 'all(.[]; .vault | type == "boolean")' "$L/ls-all"
free=$(jq '[.[] | select(.pool and (.reservation == "free" or .reservation == "abandoned"))] | length' "$L/ls-all")
if [ "${free:-0}" -lt 2 ]; then
	bad "the pool needs two free sandboxes (it has ${free:-?}): ibx ls, ibx pool add <box>"
	exit 1
fi
outside=$(jq -r '[.[] | select(.pool | not) | .name][0] // empty' "$L/ls-all")
if [ -n "$outside" ]; then
	ibx exec "$outside" -- true 2>"$L/err"
	check "exec on a sandbox outside the pool is refused (nothing runs)" 125 $?
	yes_ "and says why" grep -q 'is not in the pool' "$L/err" || show "$L/err"
else
	echo "SKIP no sandbox outside the pool: the pool-only refusal is not checked"
fi

# ---- two claims at once --------------------------------------------------------------------
ibx claim "ibx live test A" >"$L/a" 2>"$L/a.err" &
pa=$!
ibx claim "ibx live test B" >"$L/b" 2>"$L/b.err" &
pb=$!
wait "$pa"
ra=$?
wait "$pb"
rb=$?
A=$(cat "$L/a") B=$(cat "$L/b")
check "claim A" 0 "$ra"
check "claim B" 0 "$rb"
if [ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ]; then
	ok "concurrent claims got different sandboxes ($A, $B)"
else
	bad "concurrent claims: A=$A B=$B"
	cat "$L/a.err" "$L/b.err" >&2
	exit 1
fi
ibx ls --json >"$L/ls"
is "ls shows both reservations (ibx.claim.*)" \
	"$(jq -c --arg a "$A" --arg b "$B" '[.[] | select(.name == $a or .name == $b) | [.reservation, .by, .purpose]] | sort' "$L/ls")" \
	"$(jq -cn --arg by "$IBX_AGENT_NAME" '[["held", $by, "ibx live test A"], ["held", $by, "ibx live test B"]]')"
if [ "$(jq '[.[] | select(.reservation == "free" or .reservation == "abandoned")] | length' "$L/ls")" = 0 ]; then
	ibx claim "ibx live test C" >"$L/c" 2>/dev/null
	rc=$?
	check "a third claim with no free sandbox exits 75" 75 "$rc"
	[ "$rc" != 0 ] || ibx release "$(cat "$L/c")" >/dev/null
fi

# ---- exec ----------------------------------------------------------------------------------
is "exec passes several arguments with their boundaries" "$(ibx exec "$A" -- printf '<%s>' "a b" 'x;y')" '<a b><x;y>'
ibx exec "$A" -t 08 -- 'exit 4'
check "exec -t 08 (base 10) and the exit code" 4 $?
ibx exec "$A" -t 2 -- 'sleep 4' 2>/dev/null
check "exec timeout exits 124" 124 $?
out=$(ibx exec "$B" -- 'echo out; echo err >&2; exit 3' 2>"$L/err")
check "exec in B: exit code" 3 $?
is "exec in B: stdout" "$out" out
is "exec in B: stderr" "$(cat "$L/err")" err
ibx exec "$A" -t 0 -- true 2>/dev/null
check "exec -t 0 is refused" 125 $?
is "exec -i sends this stdin" "$(printf 'from-stdin\n' | ibx exec "$A" -i -- cat)" from-stdin
is "exec -t 30 -i (either order)" "$(printf 'x\n' | ibx exec "$A" -t 30 -i -- 'cat; echo y')" "$(printf 'x\ny')"
is "exec -i -t 30" "$(printf 'x\n' | ibx exec "$A" -i -t 30 -- cat)" x
is "exec -i takes exactly 1 MiB" "$(head -c 1048576 /dev/zero | LC_ALL=C tr '\000' a | ibx exec "$A" -i -- 'wc -c')" 1048576
head -c 1048577 /dev/zero | ibx exec "$A" -i -- 'wc -c' >/dev/null 2>&1
check "exec -i refuses 1 MiB + 1 byte" 125 $?

# ---- put/get -------------------------------------------------------------------------------
head -c 1000 /dev/urandom >"$L/f.bin"
ibx exec "$A" -- "mkdir -p ~/$W/adir" >/dev/null
ibx put "$A" "$L/f.bin" "$W/adir" 2>/dev/null
check "put onto a directory is refused" 125 $?
ibx put "$A" "$L/f.bin" "$W/sub/f.bin" >/dev/null
check "put" 0 $?
mkdir -p "$L/dl"
ibx get "$A" "$W/sub/f.bin" "$L/dl" >/dev/null
check "get into a local directory" 0 $?
yes_ "get into a directory wrote DIR/f.bin, unchanged" cmp -s "$L/f.bin" "$L/dl/f.bin"
head -c 750000 /dev/urandom >"$L/max.bin"
ibx put "$A" "$L/max.bin" "$W/max.bin" >/dev/null && ibx get "$A" "$W/max.bin" "$L/max.out" >/dev/null
check "put and get of exactly 750000 bytes" 0 $?
yes_ "750000 bytes round-trip unchanged" cmp -s "$L/max.bin" "$L/max.out"
head -c 750001 /dev/zero >"$L/over.bin"
ibx put "$A" "$L/over.bin" "$W/over.bin" 2>/dev/null
check "put of 750001 bytes is refused" 125 $?
ibx exec "$A" -- "head -c 750001 /dev/zero >~/$W/big.bin" >/dev/null
ibx get "$A" "$W/big.bin" "$L/big.out" 2>/dev/null
check "get of 750001 bytes is refused" 125 $?
ibx put "$A" "$L/f.bin" "~/$W/tilde/f.bin" >/dev/null && ibx get "$A" "~/$W/tilde/f.bin" "$L/tilde.out" >/dev/null
check "put and get with a leading ~/" 0 $?
yes_ "~/ means HOME" cmp -s "$L/f.bin" "$L/tilde.out"
printf 'FAKE_TOKEN=not-a-real-secret\n' >"$L/.env"
ibx put "$A" "$L/.env" "$W/.env" 2>"$L/err"
check "put refuses a .env file" 125 $?
yes_ "and says why" grep -q 'looks like a credential' "$L/err" || show "$L/err"
is "nothing reached the sandbox" "$(ibx exec "$A" -- "test -e ~/$W/.env && echo there || echo absent")" absent
ibx put --force "$A" "$L/.env" "$W/.env" >/dev/null
check "put --force copies it (a fake one)" 0 $?
is "and it arrives" "$(ibx exec "$A" -- "cat ~/$W/.env")" 'FAKE_TOKEN=not-a-real-secret'

# ---- ssh -----------------------------------------------------------------------------------
out=$(ibx ssh "$A" 'echo out1; echo err1 >&2; echo out2' 2>&1)
check "ssh" 0 $?
is "ssh delivered stdout and stderr" "$(printf '%s\n' "$out" | sort | tr '\n' ' ')" 'err1 out1 out2 '
ibx ssh "$A" 'exit 6'
check "ssh passes the exit code through" 6 $?
is "ssh streams stdin (bash -s)" "$(printf 'echo from-stdin\n' | ibx ssh "$B" 'bash -s')" from-stdin
mkdir -p "$L/tree/d" "$L/back"
printf 'one\n' >"$L/tree/d/one.txt"
head -c 5000 /dev/urandom >"$L/tree/blob"
tar c -C "$L/tree" . | ibx ssh "$B" "mkdir -p ~/$W/tree && tar x -C ~/$W/tree"
check "tar into the sandbox over ssh" 0 $?
ibx ssh "$B" "tar c -C ~/$W/tree ." | tar x -C "$L/back"
check "tar out of the sandbox over ssh" "0 0" "${PIPESTATUS[*]}"
yes_ "the tree came back unchanged" diff -r "$L/tree" "$L/back"
ibx ssh "$B" true 2>"$L/err"
yes_ "SSH tokens are revoked on exit" eval '! grep -q "NOT revoked" "$L/err"' || show "$L/err"

# ---- ports, keepalive, renew, release ------------------------------------------------------
ibx port "$A" abc 2>/dev/null
check "port rejects a non-number" 125 $?
ibx unport "$A" ../../x 2>/dev/null
check "unport rejects a path" 125 $?
ibx exec "$A" -- "mkdir -p ~/$W/www && echo hi >~/$W/www/index.html && (setsid -f python3 -m http.server 8098 --directory ~/$W/www >/dev/null 2>&1); sleep 1" >/dev/null
URL=$(ibx port "$A" 8098 live-test 2>/dev/null)
check "port" 0 $?
body=''
for _ in 1 2 3 4 5; do
	body=$(curl -s -m 20 "$URL") && [ "$body" = hi ] && break
	sleep 2
done
is "the public URL serves the page" "$body" hi
ibx keepalive >"$L/keep" 2>&1
check "keepalive" 0 $?
yes_ "keepalive leased A" grep -q "^$A: lease until" "$L/keep" || show "$L/keep"
yes_ "keepalive leased B too" grep -q "^$B: lease until" "$L/keep"
before=$(ibx ls --json | jq -r --arg a "$A" '.[] | select(.name == $a) | .since')
sleep 1
ibx renew "$A" >/dev/null
check "renew" 0 $?
after=$(ibx ls --json | jq -r --arg a "$A" '.[] | select(.name == $a) | .since')
yes_ "renew moved the reservation time ($before -> $after)" eval '[ -n "$after" ] && [ "$after" != "$before" ]'

# Tidy up while A is still ours. With the server stopped, a URL that is still published answers
# 502/503; an unpublished one answers 404.
tidy "$A"
ibx release "$A" >"$L/rel" 2>&1
check "release A" 0 $?
yes_ "release unpublished the ibx: port" grep -q "^unpublished port 8098 of $A" "$L/rel" || show "$L/rel"
code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$URL")
is "the URL is gone after release" "$code" 404
is "A is free again" "$(ibx ls --json | jq -r --arg a "$A" '.[] | select(.name == $a) | .reservation')" free
tidy "$B"
ibx release "$B" >/dev/null
check "release B" 0 $?
is "B is free again" "$(ibx ls --json | jq -r --arg b "$B" '.[] | select(.name == $b) | .reservation')" free

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
