# API notes: the instabox routes ibx and agents use

This is a compact reference, checked against `GET https://api.instabox.sh/v1/openapi.json` on
2026-10-15. The API is in beta and changes fast. When in doubt, read the live spec (public, no
key) and prefer what you observe; [field-notes.md](field-notes.md) lists where the two differ.
**Agents should prefer `ibx`**: it handles the key, retries, idempotency and waiting. Call the
API directly only for something ibx does not do.

Read a route from the spec with
`jq '.paths["/v1/machines/{id}/exec"].post | {description, parameters}' openapi.json`.

## Contents

1. [Basics](#1-basics)
2. [Routes](#2-routes)
3. [Idempotency](#3-idempotency)
4. [Errors that matter](#4-errors-that-matter)
5. [Operations and long-poll](#5-operations-and-long-poll)
6. [Listing sandboxes](#6-listing-sandboxes)
7. [Limits](#7-limits)
8. [Scopes](#8-scopes)
9. [curl patterns that survive TLS drops](#9-curl-patterns-that-survive-tls-drops)

## 1. Basics

- Base URL: `https://api.instabox.sh`. JSON uses camelCase, and times are RFC 3339 UTC.
- Auth: `Authorization: Bearer ibk_...` or `X-API-Key: ibk_...`. If you send both, they must
  carry the same key (spec: info.description, "API keys").
- Every non-2xx reply has the envelope
  `{"error": {"code", "message", "requestId", "retryable", "operationId"}}`.
- Lifecycle changes are asynchronous: `202` plus an Operation. Accepted does not mean ready
  (section 5).
- IDs: sandbox `m_` + 26 base32 characters, snapshot `sn_` (older ones `im_`), SSH grant `cn_`,
  key `key_`. Most routes take only the sandbox ID. `GET /v1/machines/{id}`, exec and the
  machine vault routes also accept the sandbox name (spec: parameters.MachineRef).
- "machine" in paths is a sandbox, and `suspend`/`resume` are pause and resume.

## 2. Routes

Key: **Idem** = the `Idempotency-Key` header per the route's own parameters (`req` = required).
**Retry** = whether repeating the request is safe.

| Route | Scope (API key) | Idem | Retry | Notes |
|---|---|---|---|---|
| `GET /v1/openapi.json` | none (public) | - | yes | the spec |
| `GET /v1/me` | any key | - | yes | who the key belongs to |
| `GET /v1/usage` | machines:read or images:read | - | yes | counts and `limits` |
| `GET /v1/templates` | machines:read or images:read | - | yes | template versions, capabilities |
| `GET /v1/machines` | machines:read | - | yes | paginated (section 6) |
| `POST /v1/machines` | machines:write | req | same key | create; leave size fields out |
| `GET /v1/machines/{id}` | machines:read | - | yes | ID or name |
| `PATCH /v1/machines/{id}` | machines:write | req | same key | synchronous; `metadata` **replaces** the whole map |
| `DELETE /v1/machines/{id}` | machines:delete | req | same key | deletes system files and storage |
| `POST .../{id}/start`, `/stop`, `/suspend`, `/resume` | machines:write | req | same key | returns an Operation |
| `POST .../{id}/wake` | machines:write | none | yes | wakes an idle-paused sandbox; waits up to 45 s |
| `GET /v1/operations/{id}?wait=25s` | machines:read or images:read | - | yes | long-poll, 30 s at most |
| `POST .../{id}/exec` | machines:write | none | **no** | runs again on every retry |
| `GET .../{id}/files?path=/abs` | **machines:write** | - | yes | reads as root; counts toward the exec limit |
| `PUT .../{id}/activity-leases/{leaseID}` | machines:write | none | yes | `{"ttlSeconds": 30-3600}` |
| `DELETE .../{id}/activity-leases/{leaseID}` | machines:write | none | yes | 204 |
| `GET .../{id}/ports` | machines:read | - | yes | `{enabled, ports[]}` |
| `POST .../{id}/ports` | machines:write | none | yes | 201 new, 200 already public (same URL) |
| `DELETE .../{id}/ports/{port}` | machines:write | none | yes | 204; 404 if not public |
| `GET /v1/ports` | machines:read | - | yes | every sandbox's public ports |
| `GET .../{id}/connection-info` | machines:read | - | yes | host, port, `hostTrust.publicKey` |
| `POST .../{id}/ssh-tokens` | machines:write | none | **no** | a retry makes a second live token |
| `GET .../{id}/ssh-tokens` | machines:read | - | yes | metadata, including `revokedAt` |
| `DELETE .../{id}/ssh-tokens/{tokenID}` | machines:write | none | yes | 204; verify `revokedAt` |
| `DELETE .../{id}/ssh-tokens` | machines:write | none | yes | revokes every token of the sandbox |
| `POST .../{id}/connections` | machines:write | req | same key | SSH certificate, 1 h by default |
| `POST .../{id}/snapshots` | images:write | req | same key | copies HOME, credentials included |
| `GET /v1/snapshots/{id}` | images:read | - | yes | poll `status` |
| `DELETE /v1/snapshots/{id}` | images:delete | req | same key | |
| `POST .../{id}/desktop` | machines:write | none | yes | `{"action": "status"}` and others |
| `POST`/`DELETE .../{id}/desktop/stream` | machines:write | none | POST: no | desktop links (no sign-in needed to open one) |
| `GET .../{id}/metrics` | machines:read | - | yes | CPU/memory every 30 s |
| `GET .../{id}/vault` | machines:read | - | yes | `{enabled, items[], applied}`: item names, never values; 404 on a server without a Vault |
| `POST .../{id}/vault` | machines:write | none | yes | writes the current items into a running sandbox now (`vault push`) |
| `/v1/keys`, `/v1/vault`, `/v1/sessions` | sign-in only | | | an API key never works here |

`...` stands for `/v1/machines`. Sources: the per-route `description` and `parameters` in the
spec.

## 3. Idempotency

- The prose says mutating POST and DELETE need the header. The per-route parameters are what
  matter, and they differ (table above). Exec, SSH-token creation, ports, leases, wake,
  desktop and vault push take no key, while `PATCH /v1/machines/{id}` requires one
  (spec: parameters.IdempotencyKey; [field-notes.md](field-notes.md#12-spec-drift)).
- The key is 1-200 printable ASCII characters, scoped to the user. The same key with the same
  method, path and body replays the original response. The same key with a different request
  gets `409 idempotency_conflict`. Records last 7 days.
- Generate a fresh random key for each action and **save it before sending**, so a retry after a
  timeout or crash reuses it. curl's `--retry` resends the same headers, so the key stays the
  same within one curl run.
- A missing required key gets `400 bad_request`.

## 4. Errors that matter

| Code | HTTP | Meaning | What to do |
|---|---|---|---|
| `unauthenticated` | 401 | missing or unknown key | run `ibx doctor`; ask the user |
| `api_key_expired` / `api_key_revoked` | 401 | the key expired or was revoked | ask the user for a new key; never look for another |
| `insufficient_scope` | 403 | the key lacks the route's scope | tell the user which scope (ibx needs machines:read + machines:write) |
| `permission_denied` | 403 | not the owner, an admin-only route, or a key on a sign-in-only route | stop |
| `invite_required` | 403 | the account has not redeemed an invite | the user must activate it |
| `not_found` | 404 | no such sandbox (deleted ones too), or someone else's | list again |
| `bad_request` | 400 | invalid input, or a missing Idempotency-Key | fix the request |
| `spec_not_allowed` | 400 | a size field was set | leave `vcpus`, `memMiB`, disk sizes out |
| `quota_exceeded` | 429 | a limit: sandboxes, storage, snapshots, keys, execs, terminals, ports, Vault | execs: wait and retry (retryable); otherwise free something or ask the user |
| `machine_not_running` | 409 | the sandbox is not running | start, resume or wake it, then retry |
| `operation_conflict` | 409 | another operation is active (`operationId`), or the transition is not allowed | wait on `operationId`, then retry |
| `idempotency_conflict` | 409 | a key was reused for a different request | use a fresh key |
| `host_unavailable` | 503 | the sandbox cannot be reached | if `retryable`, retry in a few seconds; for exec with `retryable: false` the command **may have run** |
| `no_capacity` | 503 or a failed operation | no host has room | retry later; a create from a template that fails before it gets a host deletes itself and does not count toward the limit |
| `internal` | 500 | server error | retry only calls that are safe to repeat |

The HTTP status for each code is fixed (spec: schemas.Error, components.responses).

## 5. Operations and long-poll

- Start, stop, suspend, resume, create and delete return `202` with `{"id", "state", ...}`.
  Loop on `GET /v1/operations/{id}?wait=25s` until `state` is `succeeded` or `failed`.
- `wait` is capped at 30 s. The reply comes as soon as the state or `phase` changes, so loop
  on it rather than sleeping between calls (spec: GET /v1/operations/{id}).
- `trigger` tells you instabox started the operation itself: `idle`, `request` (wake on use),
  `timeout`, `archive`, `drain`, `user_delete`, `admin_delete`.
- One operation runs at a time per sandbox. Repeating the same change returns the running
  operation, and a change that is already in effect returns an operation that has already
  succeeded.
- ibx gives up waiting after 8 minutes per operation and 10 minutes per start.

## 6. Listing sandboxes

`GET /v1/machines` returns `{"machines": [...], "nextCursor": string|null}`.

- `limit` sets the page size. `cursor` takes the previous `nextCursor` (opaque: URL-encode
  it). The last page has `nextCursor: null`.
- `metadata=key:value` filters on an exact metadata value (split at the first `:`). It can be
  repeated, and every term must match. For example `metadata=ibx.pool:1` lists pool sandboxes.
- Deleted sandboxes are not listed.
- ibx metadata keys: `ibx.pool` (`"1"` = in the pool), `ibx.claim.by`, `ibx.claim.at`
  (RFC 3339), `ibx.claim.purpose`, `ibx.claim.token`. A reservation older than
  `IBX_STALE_SECS` (default 86400) counts as abandoned. Metadata has no compare-and-swap, and
  the last PATCH wins.

## 7. Limits

| What | Limit | Source |
|---|---|---|
| exec timeout | 1-600 s, default 60 (ibx: 300) | schemas.ExecRequest |
| Concurrent execs | 4 per user, `GET /files` included | POST .../exec |
| exec `cmd` / `stdin` / output | 64 KiB / 1 MiB / 1 MiB per stream | schemas.ExecRequest, ExecResult |
| exec `envs` | 256 variables | schemas.ExecRequest |
| `GET /files` | path up to 4096 bytes; text up to 256 KiB; binary gives empty `content`; up to 5000 directory entries | GET .../files |
| `ibx put` / `ibx get` | 750,000 bytes (the base64 has to fit in 1 MiB) | the ibx helper |
| Metadata | 32 keys of 1-64 chars `[A-Za-z0-9_.-]`, values up to 512 chars, 8 KiB as JSON | schemas.Metadata |
| Vault | 100 items and 256 KiB of values per user (server defaults); one value up to 64 KiB | schemas.VaultLimits, PutVaultItemRequest |
| SSH token TTL | default 7 days, max 30 days | schemas.CreateSSHTokenRequest |
| SSH certificate TTL | default 1 h, max 24 h | schemas.CreateConnectionRequest |
| Desktop link TTL | default 1 h, 60 s to 24 h | schemas.DesktopStreamRequest |
| Activity lease | 30-3600 s (0 or absent: 300); 128 active per sandbox | PUT .../activity-leases/{leaseID} |
| Sandbox timeout | `timeoutSeconds` 60-86400 | schemas.TimeoutSeconds |
| Idle pause | documented 120-86400 or 0; **ignored, stays 1800** (observed) | schemas.AutoSuspendAfterSeconds |
| Public ports | 16 per sandbox; ports 1024-65535; 5901 and 6768 reserved | POST .../ports, PublishPortRequest |
| Sandboxes | 5 in any state | GET /v1/usage |
| Snapshots / stored data | 10 / 200 GB (observed `limits`) | GET /v1/usage |
| API keys | 20 active; expiry 1-365 days or never | info.description, CreateAPIKeyRequest |
| Terminals | 8 open per user | GET .../terminal |
| Long-poll `wait` | 30 s at most | GET /v1/operations/{id} |
| Idempotency-Key | 1-200 printable ASCII; kept 7 days | parameters.IdempotencyKey |

## 8. Scopes

Scopes are `machines:read|write|delete` and `images:read|write|delete` (images means
snapshots). A `:write` or `:delete` scope includes `:read` of the same resource
(spec: info.description, "API keys"; schemas.APIKeyScope).

| Scope | Allows |
|---|---|
| `machines:read` | list and read sandboxes, connection info, metrics, ports, token metadata, operations, templates, usage |
| `machines:write` | create, PATCH (metadata), start/stop/pause/resume/wake, **exec and `GET /files` as root on every sandbox of the account**, SSH tokens and certificates, ports, leases, desktop |
| `machines:delete` | delete sandboxes |
| `images:read` / `write` / `delete` | read, create, delete snapshots |

- A key cannot be limited to one sandbox.
- No key can use `/v1/keys`, `/v1/sessions`, `/v1/vault` (the Vault items themselves),
  `/v1/admin/*` or `/metrics`.
- ibx needs `machines:read` and `machines:write` only. See [trust-model.md](trust-model.md).
- Older keys may still carry the legacy `machines:ssh` and `machines:exec` scopes.

## 9. curl patterns that survive TLS drops

The API sometimes drops TLS mid-reply (curl 55/56). These patterns do what ibx does: the key
stays in an unexported shell variable and reaches curl through a pipe (`-H @-`), so it is in
no argv, no child's environment and no file; `-q` makes curl ignore `~/.curlrc`; only safe
calls are retried; and the body goes to a file, so a retry replaces a partial body instead of
adding to it. They need curl 7.71+ and jq 1.6+.

```bash
umask 077
API=https://api.instabox.sh
# Unexported: child processes never see it. Never echo it.
IBK=$(tr -d '[:space:]' <"${XDG_CONFIG_HOME:-$HOME/.config}/instabox/api-key")

# call METHOD PATH [curl args...]: prints the body; returns 1 on a non-2xx reply or transport error.
# printf is a shell builtin, so the key never appears in a process's argv. stdin carries the
# header, so send request bodies from a file (--data-binary @FILE) or as an argument.
call() {
  local m=$1 p=$2 out code; shift 2
  out=$(mktemp)
  code=$(printf 'Authorization: Bearer %s\n' "$IBK" |
    curl -q -sS -o "$out" -w '%{http_code}' -m 120 --retry 3 --retry-delay 2 --retry-all-errors \
      -H @- -H 'Content-Type: application/json' -X "$m" "$@" "$API$p") ||
    { rm -f "$out"; return 1; }
  cat "$out"; rm -f "$out"
  case $code in 2??) return 0 ;; *) return 1 ;; esac
}

# Reads: retried freely.
call GET "/v1/machines/$ID" | jq '{name, state, guestUser}'

# Pagination with an opaque cursor.
cursor=
while :; do
  r=$(call GET /v1/machines -G --data-urlencode limit=100 ${cursor:+--data-urlencode "cursor=$cursor"}) || break
  jq -c '.machines[] | {id, name, state}' <<<"$r"
  cursor=$(jq -r '.nextCursor // empty' <<<"$r"); [ -n "$cursor" ] || break
done

# A mutation that takes an Idempotency-Key: make the key once and keep it for every retry.
ik=ibx-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
if op=$(call POST "/v1/machines/$ID/resume" -H "Idempotency-Key: $ik" --data '{}'); then
  # Long-poll the operation, for 8 minutes at most (as ibx does).
  oid=$(jq -r .id <<<"$op") end=$((SECONDS + 480))
  while [ "$SECONDS" -lt "$end" ]; do
    if ! r=$(call GET "/v1/operations/$oid?wait=25s"); then
      [ "$(jq -r '.error.code // empty' <<<"$r")" = not_found ] && break
      sleep 3; continue   # a dropped connection: ask again
    fi
    case $(jq -r .state <<<"$r") in succeeded) break ;; failed) jq .error <<<"$r"; break ;; esac
  done
else
  jq .error <<<"$op"   # operation_conflict: wait on .error.operationId, then try again
fi

# exec: never with --retry. Keep the client timeout above timeoutSeconds (ibx: + 90 s).
jq -n --arg c 'make test' '{cmd: $c, timeoutSeconds: 300}' >req.json
printf 'Authorization: Bearer %s\n' "$IBK" |
  curl -q -sS -o res.json -w '%{http_code}\n' -m 390 -H @- -H 'Content-Type: application/json' \
    -X POST --data-binary @req.json "$API/v1/machines/$ID/exec"
jq '{exitCode, timedOut, truncated}' res.json
# On curl 28/55/56 the command may or may not have run: check its effect before running it again.

# Revoke an SSH token, then verify it (a DELETE lost to a TLS drop once left the token live).
call DELETE "/v1/machines/$ID/ssh-tokens/$TOKEN_ID" >/dev/null
call GET "/v1/machines/$ID/ssh-tokens" | jq -r --arg t "$TOKEN_ID" '.tokens[] | select(.id == $t) | .revokedAt // "NOT REVOKED"'

unset IBK
```

Notes:
- `--retry` on its own already retries timeouts and HTTP 408/429/500/502/503/504.
  `--retry-all-errors` adds connection resets and TLS drops. For other 4xx codes, curl
  returns the reply, and `call` returns 1. `--retry-max-time N` caps the retries too (ibx
  uses 8 s while it claims a sandbox).
- Use `-o FILE`, not stdout. curl cannot take back bytes it already printed before a drop.
- Never write the key into a header file, a script or a command line; never `export` it.
