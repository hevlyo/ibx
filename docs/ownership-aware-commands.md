# Ownership-aware commands (0.3.0, round 2 B1)

The holder gate runs in resolve against the already-loaded machine list. Pool membership is
checked first. Another agent's non-stale reservation refuses access, including an unreadable
reservation timestamp (the existing fail-closed convention). The same agent's unreadable
timestamp is still a live hold: work and renew proceed, and release still releases it.
Missing and abandoned reservations allow work with a claim-first warning; renew requires a
live owned reservation. Release remains idempotent. `release` and `renew` fetch the machine
again and apply this rule before any port delete or metadata write. The user-only
IBX_ALLOW_ANY override bypasses both pool membership and holder checks.
The gate includes run and job for B2; those commands are not implemented in B1, so the offline
regression suite supplies minimal dispatches to exercise resolve under their future names.

Bulk release rejects the shared per-host fallback, even with the override. Session identities
and explicit names are accepted. It selects only live pool reservations, then uses the normal
release body, including another resolve check before each box. Released entries are box names;
failed entries retain the individual error object. A partial failure returns the aggregate
result with exit 125, and does not stop remaining boxes. A signal does stop the rest, after
the box already in flight, and the interrupt names any box that release finished. Both empty
mine operations succeed.

Each individual bulk release runs in a background shell subshell with its own temporary
error/result files and EXIT cleanup, so the parent's signal trap runs at `wait` instead of
after the release has already returned. Re-executing ibx was rejected because the key is intentionally removed
from the environment before child executables run; passing it back through the environment
would weaken that guard. A shell subshell inherits the private shell variables without exporting
them. The existing per-box cleanup and warnings are reused, with warnings included in the
aggregate JSON response. The parent captures its exit status outside a conditional function
call, while the child explicitly enables errexit and keeps its cleanup state in subshell
variables (function locals would unwind before the EXIT trap on failure): a refused resolve or malformed machine
response must stop before any later request or mutation. Bulk iteration uses raw holder/age
metadata and machine IDs; cleaned display names must never determine which boxes to release.

The metadata checks are advisory. They do not add server-side access control or compare-and-swap.
`release` and `renew` re-check the fresh machine, and a concurrent writer can still change it
after that read. The check is not a lock.

Validation uses only tests/mock_api.py and the server-ts offline runner; no live account/API
access or credential files are involved. New regressions are also run against the pre-B1 script
to verify they detect the missing behavior. Full-suite summaries are reported with the commit.

Validation for B1 (2026-10-28), server-ts label b1-impl:

- Plain full suite: 1236 passed, 0 failed in 938s; exit 0.
- MOCK_EXEC=real full suite: 1290 passed, 0 failed in 1000s; exit 0.
- Targeted ownership group: 96 passed in each mode. The initial 82-check subset against the
  pre-B1 script produced 56 failures, confirming the regressions detect the missing behavior.
- ShellCheck 0.11.0, Bash syntax checks and git diff --check pass.
- Clean-context diff review converged with no remaining findings. The final corrections cover
  cleaned-name selection, Bash conditional errexit, and EXIT cleanup state after an error.
