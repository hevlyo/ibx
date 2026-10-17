#!/usr/bin/env bash
# shellcheck disable=SC2329 # actions are called indirectly through do_
# install.sh: install ibx from a clone of https://github.com/hevlyo/ibx. It links (or copies)
# skills/ibx into each agent's skills directory, links the ibx command into a bin directory, and
# can install the keepalive timer. No sudo, no network, safe to run again. ./install.sh --help
#
# Written for the bash 3.2 that macOS ships (the ibx helper itself needs bash 4.4+).
# Test hook: IBX_INSTALL_OS=Linux|Darwin overrides `uname -s`, e.g. to preview the launchd plist
# with --dry-run on Linux.
set -eu

usage() {
	cat <<'EOF'
Usage: ./install.sh [options]

Installs ibx for your coding agents:
  - links skills/ibx into each agent's skills directory as ibx/ (or copies it, with --copy)
  - links scripts/ibx into a bin directory as the ibx command
  - with --keepalive, installs a timer that runs `ibx keepalive` every 15 minutes

Options
  --agents LIST      comma-separated skills roots (default: claude,agents)
                       claude    $CLAUDE_CONFIG_DIR/skills
                                 (default ~/.claude/skills; Claude Code)
                       agents    ~/.agents/skills    Codex and other agents that read it
                       codex     $CODEX_HOME/skills  (default ~/.codex/skills; only for a Codex
                                                     that does not read ~/.agents/skills)
                       opencode  ~/.config/opencode/skills
                       all, none
  --copy             copy the skill instead of linking it (the clone can then be deleted;
                     run ./install.sh --copy again after a git pull)
  --bin DIR          where the ibx command goes (default: ~/.local/bin)
  --no-bin           do not install the ibx command
  --keepalive        install the keepalive timer for reserved pool sandboxes
  --keepalive=all    same, but for every pool sandbox (ibx keepalive --all)
                       Linux: systemd user units ibx-keepalive.service and .timer
                       macOS: ~/Library/LaunchAgents/local.ibx-keepalive.plist
  --uninstall        remove what this script installed (with no --agents: from every root)
  -n, --dry-run      print what would change, including the timer files, and change nothing
  -h, --help         this help

It replaces copies and timer files it created, and symlinks to an ibx skill or helper, including
recognized dangling links. If anything else is in the way, it stops before changing anything
and says which. It does not touch your API key, your sandboxes or the pool.

CLAUDE_CONFIG_DIR, CODEX_HOME and XDG_CONFIG_HOME must be absolute paths. A leading ~ or ~/
is expanded to HOME; trailing slashes are removed.

Exit status: 0 done; 1 something is in the way or a step failed; 2 bad usage.
See README.md (Install, Setup) and skills/ibx/references/keepalive.md.
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'install.sh: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
usage_err() { warn "$*"; warn "see ./install.sh --help"; exit 2; }

case ${HOME:-} in /*) ;; *) die "HOME must be an absolute path" ;; esac

normalize_config() { # value label -> NORMALIZED; shared rules with install.sh
	local path=$1 label=$2
	# shellcheck disable=SC2088 # expand only a literal leading ~ or ~/
	case $path in
	"~") path=${HOME:-} ;;
	"~/"*) [ -n "${HOME:-}" ] || die "$label needs HOME to expand ~"; path=$HOME/${path#"~/"} ;;
	esac
	case $path in /*) ;; *) die "$label must be an absolute path (a leading ~ or ~/ is allowed)" ;; esac
	while [ "$path" != / ] && [ "${path%/}" != "$path" ]; do path=${path%/}; done
	NORMALIZED=$path
}
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
	normalize_config "$CLAUDE_CONFIG_DIR" CLAUDE_CONFIG_DIR; CLAUDE_CONFIG_DIR=$NORMALIZED
fi
if [ -n "${CODEX_HOME:-}" ]; then
	normalize_config "$CODEX_HOME" CODEX_HOME; CODEX_HOME=$NORMALIZED
fi
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
	normalize_config "$XDG_CONFIG_HOME" XDG_CONFIG_HOME; XDG_CONFIG_HOME=$NORMALIZED
fi
SRC=$(cd -P "$(dirname "$0")" && pwd -P)
SKILL_SRC=$SRC/skills/ibx
HELPER_SRC=$SKILL_SRC/scripts/ibx
if [ ! -f "$SKILL_SRC/SKILL.md" ] || [ ! -f "$HELPER_SRC" ]; then
	die "run install.sh from a clone of the ibx repository ($SKILL_SRC/SKILL.md not found)"
fi

MARK=.ibx-install                     # marker file inside the copies this script makes
FILE_MARK='Installed by ibx install.sh' # marker line in the timer files this script writes
HOMEPAGE=https://github.com/hevlyo/ibx
LABEL=local.ibx-keepalive # launchd label: it must contain "ibx-keepalive" for ibx doctor
OS=${IBX_INSTALL_OS:-$(uname -s)}
ALL_AGENTS="claude agents codex opencode"

# ---- options -------------------------------------------------------------------------------
agents=claude,agents agents_given='' mode=link bin=$HOME/.local/bin keepalive='' action=install dry=
while [ $# -gt 0 ]; do
	case $1 in
	--agents) [ $# -ge 2 ] || usage_err "--agents needs a list"; agents=$2; agents_given=1; shift 2 ;;
	--agents=*) agents=${1#*=}; agents_given=1; shift ;;
	--copy) mode=copy; shift ;;
	--bin) [ $# -ge 2 ] || usage_err "--bin needs a directory"; bin=$2; shift 2 ;;
	--bin=*) bin=${1#*=}; shift ;;
	--no-bin) bin=; shift ;;
	--keepalive) keepalive=reserved; shift ;;
	--keepalive=all) keepalive=all; shift ;;
	--uninstall) action=uninstall; shift ;;
	-n | --dry-run) dry=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage_err "unknown option: $1" ;;
	esac
done

list=
old_ifs=$IFS
IFS=', '
set -f
for a in $agents; do
	case $a in
	claude | agents | codex | opencode) add=$a ;;
	all) add=$ALL_AGENTS ;;
	none) add='' ;;
	*) usage_err "unknown agent '$a' (claude, agents, codex, opencode, all, none)" ;;
	esac
	for x in $add; do
		case " $list " in *" $x "*) ;; *) list="$list $x" ;; esac
	done
done
set +f
IFS=$old_ifs
[ "$action" = uninstall ] && [ -z "$agents_given" ] && list=$ALL_AGENTS

if [ -n "$bin" ]; then
	# shellcheck disable=SC2088 # a literal "~" from --bin=~/dir, expanded here
	case $bin in
	"~") bin=$HOME ;;
	"~/"*) bin=$HOME/${bin#"~/"} ;;
	/*) ;;
	*) bin=$PWD/$bin ;;
	esac
	bin=${bin%/}
	[ -n "$bin" ] || bin=/
fi

root_of() {
	case $1 in
	claude-default) printf '%s/.claude/skills' "$HOME" ;;
	claude) printf '%s/skills' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
	agents) printf '%s/.agents/skills' "$HOME" ;;
	codex) printf '%s/skills' "${CODEX_HOME:-$HOME/.codex}" ;;
	opencode) printf '%s/opencode/skills' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
	esac
}

# ---- helpers -------------------------------------------------------------------------------
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ibx-install.XXXXXX")
staged= # a temporary file or directory next to its destination, until it is moved into place
trap 'rm -rf "$tmp" ${staged:+"$staged"}' EXIT

# tilde PATH: PATH with $HOME shown as ~, for messages only.
# shellcheck disable=SC2088
tilde() { case $1 in "$HOME") printf '~' ;; "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

# do_ VERB WHAT CMD...: runs CMD and prints "VERBed WHAT", or with --dry-run only "would VERB WHAT".
do_() {
	local verb=$1 what=$2 past
	shift 2
	if [ -n "$dry" ]; then
		printf 'would %-8s %s\n' "$verb" "$what"
		did=1
		return 0
	fi
	"$@"
	did=1
	case $verb in
	link) past=linked ;; copy) past=copied ;; replace) past=replaced ;; remove) past=removed ;;
	write) past=wrote ;; run) past=ran ;; make) past=made ;; *) past=$verb ;;
	esac
	printf '%-14s %s\n' "$past" "$what"
}
note() { printf '%-14s %s\n' "$1" "$2"; }

link_text() { readlink "$1"; }
phys_dir() { (cd -P "$1" 2>/dev/null && pwd -P); }
is_ibx_skill() { [ -f "$1/SKILL.md" ] && grep -q '^name: ibx$' "$1/SKILL.md" && grep -q 'github.com/hevlyo/ibx' "$1/SKILL.md"; }
is_ibx_helper() { [ -f "$1" ] && head -n 5 "$1" | grep -q 'github.com/hevlyo/ibx'; }
is_ours_file() { [ -f "$1" ] && grep -q "$FILE_MARK" "$1"; }
# safe_path PATH: an absolute path with only characters that need no quoting in a unit or plist.
safe_path() { case $1 in /*) ;; *) return 1 ;; esac; case $1 in *[!A-Za-z0-9._/+@-]*) return 1 ;; esac; }

# classify_skill DEST: sets STATE to absent | linked (to this clone) | ourlink (another ibx link,
# or a dangling one) | copy (made by this script) | source (the clone itself) | conflict (WHY).
classify_skill() {
	local d=$1 t
	WHY=
	if [ -L "$d" ]; then
		t=$(link_text "$d")
		if [ "$(phys_dir "$d" || true)" = "$SKILL_SRC" ]; then STATE=linked; return 0; fi
		if [ -e "$d" ]; then
			if is_ibx_skill "$d"; then STATE=ourlink; return 0; fi
		else
			case $t in */skills/ibx | */skills/ibx/) STATE=ourlink; return 0 ;; esac
		fi
		STATE=conflict WHY="it is a symlink to $t, which is not an ibx skill"
	elif [ -d "$d" ]; then
		if [ "$(phys_dir "$d" || true)" = "$SKILL_SRC" ]; then STATE=source
		elif [ -f "$d/$MARK" ]; then STATE=copy
		else STATE=conflict WHY="it is a directory install.sh did not create (another install method?)"
		fi
	elif [ -e "$d" ]; then
		STATE=conflict WHY="it is a file install.sh did not create"
	else
		STATE=absent
	fi
	return 0
}

# classify_bin DEST WANT: absent | linked (to WANT) | ourlink | conflict (WHY).
classify_bin() {
	local d=$1 want=$2 t
	WHY=
	if [ -L "$d" ]; then
		t=$(link_text "$d")
		if [ "$t" = "$want" ]; then STATE=linked; return 0; fi
		if [ -e "$d" ]; then
			if is_ibx_helper "$d"; then STATE=ourlink; return 0; fi
		else
			case $t in */scripts/ibx) STATE=ourlink; return 0 ;; esac
		fi
		STATE=conflict WHY="it is a symlink to $t, which is not the ibx helper"
	elif [ -e "$d" ]; then
		STATE=conflict WHY="it is a file install.sh did not create"
	else
		STATE=absent
	fi
	return 0
}

# classify_file FILE: absent | ours | conflict, for the timer files.
classify_file() {
	WHY=
	if is_ours_file "$1"; then STATE=ours
	elif [ -e "$1" ] || [ -L "$1" ]; then STATE=conflict WHY="it exists and install.sh did not write it"
	else STATE=absent
	fi
	return 0
}

# ---- keepalive file contents ----------------------------------------------------------------
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
SERVICE=$UNIT_DIR/ibx-keepalive.service
TIMER=$UNIT_DIR/ibx-keepalive.timer
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
LOGFILE=$HOME/Library/Logs/ibx-keepalive.log
DEFAULT_KEYFILE=$HOME/.config/instabox/api-key
KEYFILE=${IBX_KEY_FILE:-${INSTABOX_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/instabox/api-key}}

# Directories of bash, curl and jq when they are not in the standard places, so that the timer,
# which does not see your shell's PATH, finds the same tools.
extra_path() {
	local tool p d out=
	for tool in bash curl jq; do
		p=$(command -v "$tool" 2>/dev/null) || continue
		d=$(dirname "$p")
		case ":/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$out:" in *":$d:"*) continue ;; esac
		safe_path "$d" || continue # never a relative PATH entry such as bin or .
		[ -d "$d" ] || continue
		out=${out:+$out:}$d
	done
	printf '%s' "$out"
}

gen_service() { # EXE ARGS
	local what="reserved instabox pool sandboxes" xp
	[ "$keepalive" = all ] && what="every instabox pool sandbox"
	xp=$(extra_path)
	cat <<EOF
# $FILE_MARK ($HOMEPAGE). ./install.sh --uninstall removes it.
[Unit]
Description=ibx keepalive: renew activity leases on $what
StartLimitIntervalSec=900
StartLimitBurst=3

[Service]
Type=oneshot
# Wait for DNS (after boot or resume); TimeoutStartSec bounds the wait and the run.
ExecStartPre=/bin/sh -c 'until getent hosts api.instabox.sh >/dev/null 2>&1; do sleep 5; done'
ExecStart=$1 keepalive$2
EOF
	[ -z "$xp" ] || printf 'Environment=PATH=%s:/usr/local/bin:/usr/bin:/bin\n' "$xp"
	[ "$KEYFILE" = "$DEFAULT_KEYFILE" ] || printf 'Environment=IBX_KEY_FILE=%s\n' "$KEYFILE"
	cat <<'EOF'
TimeoutStartSec=300
Restart=on-failure
RestartSec=60
EOF
}

gen_timer() {
	cat <<EOF
# $FILE_MARK ($HOMEPAGE). ./install.sh --uninstall removes it.
[Unit]
Description=Run ibx keepalive every 15 minutes

[Timer]
OnCalendar=*:0/15
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
}

gen_plist() { # EXE ARGS
	local xp path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
	xp=$(extra_path)
	[ -z "$xp" ] || path=$xp:$path
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- $FILE_MARK ($HOMEPAGE) -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$1</string>
    <string>keepalive</string>
EOF
	[ -z "$2" ] || printf '    <string>%s</string>\n' "${2# }"
	cat <<EOF
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$path</string>
EOF
	[ "$KEYFILE" = "$DEFAULT_KEYFILE" ] ||
		printf '    <key>IBX_KEY_FILE</key>\n    <string>%s</string>\n' "$KEYFILE"
	cat <<EOF
  </dict>
  <key>StartInterval</key>
  <integer>900</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOGFILE</string>
  <key>StandardErrorPath</key>
  <string>$LOGFILE</string>
</dict>
</plist>
EOF
}

# put_file NEW DEST: installs NEW at DEST if it differs. Sets CHANGED=1 when it wrote.
put_file() {
	CHANGED=
	if [ -f "$2" ] && cmp -s "$1" "$2"; then
		note "up to date" "$(tilde "$2")"
		return 0
	fi
	CHANGED=1
	if [ -n "$dry" ]; then
		printf 'would %-8s %s:\n' write "$(tilde "$2")"
		sed 's/^/    | /' "$1"
		return 0
	fi
	mkdir -p "$(dirname "$2")"
	# A new file from mktemp, next to DEST: nothing already there (a symlink left at a fixed name)
	# is followed or chmod-ed. A name that does not end in .service, .timer or .plist is never
	# loaded by systemd or launchd.
	staged=$(mktemp "$(dirname "$2")/.$(basename "$2").ibx-new.XXXXXX")
	cat "$1" >"$staged"
	chmod 644 "$staged"
	mv -f "$staged" "$2"
	staged=
	note wrote "$(tilde "$2")"
}

# The steps below run through do_, so that --dry-run only prints them.
# shellcheck disable=SC2317
stop_timer() {
	systemctl --user disable --now ibx-keepalive.timer >/dev/null 2>&1 || true
	systemctl --user stop ibx-keepalive.service >/dev/null 2>&1 || true
}
# shellcheck disable=SC2317
reload_units() { systemctl --user daemon-reload >/dev/null 2>&1 || true; }
# shellcheck disable=SC2317
unload_agent() { launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true; }
# shellcheck disable=SC2317
copy_skill() { # DEST: copy into a new private directory next to DEST, then swap it in
	local d=$1
	staged=$(mktemp -d "$(dirname "$d")/.ibx-install.XXXXXX")
	cp -Rp "$SKILL_SRC" "$staged/ibx"
	rm -f "$staged/ibx/$MARK"
	printf 'installed-by: ibx install.sh\nsource: %s\n' "$SRC" >"$staged/ibx/$MARK"
	if [ -L "$d" ]; then rm "$d"; elif [ -d "$d" ]; then rm -rf "$d"; fi
	mv "$staged/ibx" "$d"
	rmdir "$staged"
	staged=
}
# shellcheck disable=SC2317
relink() { # TARGET LINK
	if [ -L "$2" ]; then rm "$2"; elif [ -d "$2" ]; then rm -rf "$2"; fi
	ln -s "$1" "$2"
}

# Resolve existing ancestors without creating anything, including during --dry-run.
physical_root() {
	local path=$1 suffix='' part
	while [ ! -d "$path" ]; do
		part=$(basename "$path")
		suffix=/$part$suffix
		path=$(dirname "$path")
	done
	printf '%s%s\n' "$(cd -P "$path" && pwd -P)" "$suffix"
}
if [ "$action" = uninstall ] && [ -z "$agents_given" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
	list="$list claude-default"
fi
roots=() root_keys=() nroots=0
for a in $list; do
	root=$(root_of "$a")
	key=$(physical_root "$root")
	duplicate=
	for ((i=0; i<nroots; i++)); do
		[ "${root_keys[i]}" != "$key" ] || duplicate=1
	done
	[ -z "$duplicate" ] || continue
	roots[nroots]=$root root_keys[nroots]=$key
	nroots=$((nroots + 1))
done

# ---- uninstall -----------------------------------------------------------------------------
did=
if [ "$action" = uninstall ]; then
	rc=0
	[ -z "$dry" ] || say "Dry run: nothing is changed."
	for ((i=0; i<nroots; i++)); do
		d=${roots[i]}/ibx
		classify_skill "$d"
		case $STATE in
		linked | ourlink) do_ remove "$(tilde "$d") (symlink)" rm "$d" ;;
		copy) do_ remove "$(tilde "$d") (copy)" rm -rf "$d" ;;
		source) note "left alone" "$(tilde "$d"): it is the clone itself" ;;
		conflict) note "left alone" "$(tilde "$d"): $WHY" ;;
		esac
	done
	if [ -n "$bin" ]; then
		classify_bin "$bin/ibx" "$HELPER_SRC"
		case $STATE in
		linked | ourlink) do_ remove "$(tilde "$bin/ibx")" rm "$bin/ibx" ;;
		conflict) note "left alone" "$(tilde "$bin/ibx"): $WHY" ;;
		esac
	fi
	case $OS in
	Linux)
		classify_file "$TIMER"; ts=$STATE
		classify_file "$SERVICE"; ss=$STATE
		if [ "$ts" = ours ] || [ "$ss" = ours ]; then
			if command -v systemctl >/dev/null 2>&1 || [ -n "$dry" ]; then
				do_ run "systemctl --user disable --now ibx-keepalive.timer" stop_timer
			fi
			[ "$ts" != ours ] || do_ remove "$(tilde "$TIMER")" rm -f "$TIMER"
			[ "$ss" != ours ] || do_ remove "$(tilde "$SERVICE")" rm -f "$SERVICE"
			if command -v systemctl >/dev/null 2>&1 || [ -n "$dry" ]; then
				do_ run "systemctl --user daemon-reload" reload_units
			fi
		fi
		[ "$ts" != conflict ] || note "left alone" "$(tilde "$TIMER"): it exists and install.sh did not write it"
		[ "$ss" != conflict ] || note "left alone" "$(tilde "$SERVICE"): it exists and install.sh did not write it"
		;;
	Darwin)
		classify_file "$PLIST"
		case $STATE in
		ours)
			do_ run "launchctl bootout gui/<uid>/$LABEL" unload_agent
			do_ remove "$(tilde "$PLIST")" rm -f "$PLIST"
			;;
		conflict) note "left alone" "$(tilde "$PLIST"): $WHY" ;;
		esac
		;;
	esac
	[ -n "$did" ] || say "Nothing to remove: install.sh has not installed ibx in these places."
	say "Not touched: your API key file, and the pool metadata on your sandboxes (ibx pool rm <box>)."
	exit "$rc"
fi

# ---- install: check everything first ---------------------------------------------------------
conflicts=
conflict() { conflicts="$conflicts
  $(tilde "$1"): $2"; }

for ((i=0; i<nroots; i++)); do
	d=${roots[i]}/ibx
	classify_skill "$d"
	[ "$STATE" != conflict ] || conflict "$d" "$WHY"
done

# The ibx command and the timer run the helper from this clone, or with --copy from the first copy.
first=
[ "$nroots" = 0 ] || first=${roots[0]}/ibx
if [ "$mode" = copy ] && [ -n "$first" ]; then target=$first/scripts/ibx; else target=$HELPER_SRC; fi
if [ -n "$bin" ]; then
	classify_bin "$bin/ibx" "$target"
	[ "$STATE" != conflict ] || conflict "$bin/ibx" "$WHY"
	exe=$bin/ibx
else
	exe=$target
fi

if [ -n "$keepalive" ]; then
	args=
	[ "$keepalive" = all ] && args=" --all"
	safe_path "$exe" || conflict "$exe" "the timer needs a path with only letters, digits and ._/+@- (use --bin DIR)"
	case $OS in
	Linux)
		classify_file "$SERVICE"; [ "$STATE" != conflict ] || conflict "$SERVICE" "$WHY"
		classify_file "$TIMER"; [ "$STATE" != conflict ] || conflict "$TIMER" "$WHY"
		[ -n "$dry" ] || command -v systemctl >/dev/null 2>&1 ||
			conflict "keepalive" "systemctl not found: use the cron line in skills/ibx/references/keepalive.md (section 7)"
		;;
	Darwin)
		safe_path "$HOME" || conflict "$HOME" "launchd needs a home path with only letters, digits and ._/+@-"
		classify_file "$PLIST"; [ "$STATE" != conflict ] || conflict "$PLIST" "$WHY"
		[ -n "$dry" ] || command -v launchctl >/dev/null 2>&1 || conflict "keepalive" "launchctl not found"
		;;
	*) conflict "keepalive" "no timer support for $OS: see skills/ibx/references/keepalive.md (cron)" ;;
	esac
	if [ "$KEYFILE" != "$DEFAULT_KEYFILE" ]; then
		safe_path "$KEYFILE" ||
			conflict "$KEYFILE" "the timer needs an absolute key file path with only letters, digits and ._/+@-"
	fi
fi

if [ -n "$conflicts" ]; then
	warn "nothing was changed, because these are in the way:$conflicts"
	warn "move or remove them yourself (install.sh never replaces what it did not create), then run it again."
	exit 1
fi

# ---- install: apply --------------------------------------------------------------------------
[ -z "$dry" ] || say "Dry run: nothing is changed."
say "ibx from $(tilde "$SRC"): ${mode}ing the skill into:${list:- (no agents)}; command: $(tilde "${bin:-(none)}")${keepalive:+; keepalive: $keepalive}"
if [ ! -x "$HELPER_SRC" ]; then
	do_ make "$(tilde "$HELPER_SRC") executable" chmod +x "$HELPER_SRC"
fi

for ((i=0; i<nroots; i++)); do
	root=${roots[i]}
	d=$root/ibx
	classify_skill "$d"
	if [ ! -d "$root" ]; then do_ make "$(tilde "$root")/" mkdir -p "$root"; fi
	if [ "$mode" = link ]; then
		case $STATE in
		absent) do_ link "$(tilde "$d") -> $SKILL_SRC" ln -s "$SKILL_SRC" "$d" ;;
		linked) note "up to date" "$(tilde "$d") -> $SKILL_SRC" ;;
		ourlink | copy) do_ replace "$(tilde "$d") with a link to $SKILL_SRC" relink "$SKILL_SRC" "$d" ;;
		source) note "up to date" "$(tilde "$d") is the clone itself" ;;
		esac
	else
		case $STATE in
		absent) do_ copy "$SKILL_SRC -> $(tilde "$d")" copy_skill "$d" ;;
		copy)
			if diff -rq -x "$MARK" "$SKILL_SRC" "$d" >/dev/null 2>&1; then
				note "up to date" "$(tilde "$d") (copy)"
			else
				do_ replace "$(tilde "$d") with a fresh copy" copy_skill "$d"
			fi
			;;
		linked | ourlink) do_ replace "$(tilde "$d") (a link) with a copy" copy_skill "$d" ;;
		source) note "up to date" "$(tilde "$d") is the clone itself" ;;
		esac
	fi
done

if [ -n "$bin" ]; then
	classify_bin "$bin/ibx" "$target"
	if [ ! -d "$bin" ]; then do_ make "$(tilde "$bin")/" mkdir -p "$bin"; fi
	case $STATE in
	absent) do_ link "$(tilde "$bin/ibx") -> $(tilde "$target")" ln -s "$target" "$bin/ibx" ;;
	linked) note "up to date" "$(tilde "$bin/ibx") -> $(tilde "$target")" ;;
	ourlink) do_ replace "$(tilde "$bin/ibx") with a link to $(tilde "$target")" relink "$target" "$bin/ibx" ;;
	esac
fi

rc=0
if [ -n "$keepalive" ]; then
	case $OS in
	Linux)
		gen_service "$exe" "$args" >"$tmp/service"
		gen_timer >"$tmp/timer"
		put_file "$tmp/service" "$SERVICE"; c1=$CHANGED
		put_file "$tmp/timer" "$TIMER"; c2=$CHANGED
		if [ -n "$dry" ]; then
			say "would run      systemctl --user daemon-reload"
			say "would run      systemctl --user enable --now ibx-keepalive.timer"
		else
			ok=1
			if [ -n "$c1$c2" ]; then systemctl --user daemon-reload || ok=; fi
			if [ -n "$ok" ] && systemctl --user enable --now ibx-keepalive.timer >/dev/null 2>&1; then
				note enabled "ibx-keepalive.timer (every 15 minutes; first run at the next quarter hour)"
				say "               run one now: systemctl --user start ibx-keepalive.service"
			else
				warn "could not reach the systemd user manager. The unit files are in place; try:"
				warn "  systemctl --user daemon-reload && systemctl --user enable --now ibx-keepalive.timer"
				warn "or use the cron line in skills/ibx/references/keepalive.md (section 7)."
				rc=1
			fi
		fi
		;;
	Darwin)
		gen_plist "$exe" "$args" >"$tmp/plist"
		if command -v plutil >/dev/null 2>&1 && ! plutil -lint -s "$tmp/plist"; then
			die "the generated plist does not pass plutil -lint (please report this)"
		fi
		put_file "$tmp/plist" "$PLIST"
		if [ -n "$dry" ]; then
			[ -d "$(dirname "$LOGFILE")" ] || say "would make     $(tilde "$(dirname "$LOGFILE")")/"
			say "would run      launchctl bootstrap gui/<uid> $(tilde "$PLIST")"
		else
			mkdir -p "$(dirname "$LOGFILE")"
			uid=$(id -u)
			loaded=''
			if launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1; then loaded=1; fi
			if [ -n "$loaded" ] && [ -z "$CHANGED" ]; then
				note "up to date" "launchd agent $LABEL is loaded"
			else
				[ -z "$loaded" ] || launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
				ok=
				for _ in 1 2 3 4 5; do
					if launchctl bootstrap "gui/$uid" "$PLIST" 2>"$tmp/lc"; then ok=1; break; fi
					sleep 1
				done
				if [ -n "$ok" ]; then
					note loaded "launchd agent $LABEL (every 15 minutes; log: $(tilde "$LOGFILE"))"
				else
					warn "launchctl bootstrap failed: $(cat "$tmp/lc")"
					rc=1
				fi
			fi
		fi
		;;
	esac
	if [ ! -e "$KEYFILE" ]; then
		warn "the timer reads the API key from $(tilde "$KEYFILE"), which does not exist yet (README, Setup)."
	fi
fi

# ---- what next -------------------------------------------------------------------------------
if [ -n "$bin" ]; then
	case ":$PATH:" in
	*":$bin:"*)
		found=$(command -v ibx 2>/dev/null || true)
		if [ -n "$found" ] && [ "$found" != "$bin/ibx" ]; then
			warn "another ibx comes first on PATH: $found"
		fi
		;;
	*) warn "$(tilde "$bin") is not on your PATH: add it, or run $(tilde "$bin")/ibx" ;;
	esac
fi
if [ -z "$dry" ] && [ "$rc" = 0 ]; then
	say ""
	say "Next:"
	if [ ! -e "$KEYFILE" ] && [ -z "${INSTABOX_API_KEY:-}" ]; then
		say "  - save an instabox API key with only machines:write in $(tilde "$KEYFILE") (README, Setup)"
	fi
	say "  - ibx pool add <box>...   put sandboxes in the pool agents may claim"
	say "  - ibx doctor              check that everything works"
	[ -n "$keepalive" ] || say "  - optional: ./install.sh --keepalive   keep reserved sandboxes awake"
fi
exit "$rc"
