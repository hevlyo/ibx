# Security policy

## Supported versions

Only the latest commit on `main` is supported. ibx has no release branches: fixes land on
`main`, and [CHANGELOG.md](CHANGELOG.md) records them under the version that `ibx --version`
prints.

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting: open the **Security**
tab of [hevlyo/ibx](https://github.com/hevlyo/ibx) and choose **Report a vulnerability**. Do
not put the details in a public issue, pull request or discussion. If the button is missing,
open a public issue that asks for a private channel and says nothing about the problem itself.

A useful report says:

- what is affected (the helper, `install.sh`, a document) and the commit or `ibx --version`;
- how to reproduce it, ideally against the offline mock (`tests/offline.sh`,
  `tests/mock_api.py`) rather than a real account;
- what an attacker gains, and what they need first (an API key of the account, code running in
  a sandbox, a crafted API reply, a local user on the same computer).

**Never include secrets**: no API keys, SSH tokens, desktop links, public port URLs, sandbox
IDs or personal data, in the text, logs or screenshots. Use placeholders such as `ibk_...` and
`m_...`. If a key leaked while you investigated, revoke it on the instabox dashboard.

The fix is discussed in the private advisory and published once it is on `main`.

## Scope

In scope, this repository:

- **The helper**, `skills/ibx/scripts/ibx`. For example: the API key reaching argv, the
  environment of a child process, a file or the output; an SSH token that leaks or is not
  revoked; agent commands reaching a sandbox outside the pool without `IBX_ALLOW_ANY=1`;
  `ibx claim` handing out a sandbox that the Vault writes secrets into without
  `IBX_ALLOW_VAULT=1`; `ibx put` accepting a file that its credential rules should refuse;
  the key going to a host other than `api.instabox.sh` without `IBX_ALLOW_CUSTOM_API=1`;
  control characters from the API reaching the terminal; command injection through names,
  paths or API replies.
- **The installer**, `install.sh`: replacing or deleting files it did not create, or timer
  files that expose the key.
- **The documentation**, `skills/ibx/SKILL.md` and `skills/ibx/references/`, where its guidance
  would lead an agent to leak secrets or to follow instructions found inside a sandbox.

Out of scope, report these to instabox:

- The instabox API, sandboxes, SSH gateway, CLI, dashboard and official skills. Bugs go through
  `instabox feedback` (see [Reporting provider bugs](README.md#reporting-provider-bugs));
  vulnerabilities go through instabox's own private channels, never a public report.
- Properties of the platform that ibx documents but cannot change: the provider is root in
  every sandbox, an API key cannot be limited to some sandboxes, public URLs have no
  authentication, and reservations are advisory
  ([trust-model.md](skills/ibx/references/trust-model.md)).
