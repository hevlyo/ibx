# Security policy

## Supported versions

Only the latest commit on `main` is supported. ibx has no release branches. Fixes land on
`main`, and [CHANGELOG.md](CHANGELOG.md) records them under the version that `ibx --version`
prints.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting. Open the **Security**
tab of [hevlyo/ibx](https://github.com/hevlyo/ibx) and choose **Report a vulnerability**. Do
not put the details in a public issue, pull request or discussion. If the button is missing,
open a public issue that asks for a private channel and says nothing about the problem itself.

A useful report says:

- what is affected (the helper, `install.sh`, a document) and the commit or `ibx --version`;
- how to reproduce it, ideally against the offline mock (`tests/offline.sh`,
  `tests/mock_api.py`) rather than a real account;
- what an attacker gains, and what they need first (an API key of the account, code running in
  a sandbox, a crafted API reply, a local user on the same computer).

Keep API keys, SSH tokens, desktop links, public port URLs, sandbox IDs and personal data
out of the text, logs and screenshots. Use placeholders such as `ibk_...` and
`m_...`. If a key leaked while you investigated, revoke it on the instabox dashboard.

The fix is discussed in the private advisory and published once it is on `main`.

## Scope

In scope, this repository:

- The helper, `skills/ibx/scripts/ibx`. Examples include the API key reaching argv, the
  environment of a child process, a file or the output; an SSH token that leaks or is not
  revoked; agent commands reaching a sandbox outside the pool or another agent's live
  reservation without the user-only `IBX_ALLOW_ANY=1`; bulk release accepting only the shared
  per-host identity instead of requiring a session ID or explicit agent name;
  `ibx claim` handing out a sandbox that the Vault writes secrets into without
  `IBX_ALLOW_VAULT=1`; accepting selected, pending or residual Org Secrets without an explicit
  user proxy-only override, or accepting env Secrets, an unknown delivery or a proxy Secret for
  every host with that override;
  `ibx put` accepting a file that its credential rules should refuse, or uploading another
  file than the one named (curl globbing, `-` or `/dev/stdin` read as curl's stdin);
  the key going to a host other than `api.instabox.sh` without `IBX_ALLOW_CUSTOM_API=1`;
  control characters from the API reaching the terminal; command injection through names,
  paths or API replies.
- The installer, `install.sh`, replacing or deleting files it did not create, or timer
  files that expose the key.
- **The documentation**, `skills/ibx/SKILL.md` and `skills/ibx/references/`, where its guidance
  would lead an agent to leak secrets or to follow instructions found inside a sandbox.

Out of scope, report these to instabox:

- The instabox API, sandboxes, SSH gateway, CLI, dashboard and official skills. Bugs go to the
  instabox team with `instabox feedback`
  (see [Reporting provider bugs](skills/ibx/references/field-notes.md#15-reporting-provider-bugs));
  vulnerabilities go through instabox's own private channels, never a public report.
- Platform properties that ibx documents but cannot change. The provider is root in
  every sandbox, an API key cannot be limited to some sandboxes, public URLs have no
  authentication, and reservations are advisory
  ([trust-model.md](skills/ibx/references/trust-model.md)).
