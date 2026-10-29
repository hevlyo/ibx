#!/usr/bin/env bash
# IBX_VERSION, the skill, both plugin manifests and the changelog heading are one version.
# On a tag push, that version is the tag without its leading v.
set -eu
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
ver=$(sed -n 's/^IBX_VERSION=//p' "$root/skills/ibx/scripts/ibx")
skill=$(sed -n 's/^  version: "\(.*\)"/\1/p' "$root/skills/ibx/SKILL.md")
plugin=$(jq -r .version "$root/.claude-plugin/plugin.json")
market=$(jq -r '.plugins[] | select(.name == "ibx") | .version' "$root/.claude-plugin/marketplace.json")
clog=$(sed -n 's/^## \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$root/CHANGELOG.md" | head -n 1)
[ -n "$ver" ] || { echo "versions.sh: IBX_VERSION is empty" >&2; exit 1; }
for pair in "skill:$skill" "plugin:$plugin" "marketplace:$market" "changelog:$clog"; do
	name=${pair%%:*} got=${pair#*:}
	[ "$got" = "$ver" ] || { echo "versions.sh: $name is ${got:-empty}, IBX_VERSION is $ver" >&2; exit 1; }
done
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
	tag=${GITHUB_REF_NAME#v}
	[ "$tag" = "$ver" ] || { echo "versions.sh: tag $GITHUB_REF_NAME is not v$ver" >&2; exit 1; }
fi
echo "versions agree on $ver"
