#!/usr/bin/env bash
# Cuts a lockstep release. Stamps <version> into every published package (its own
# version, the inter-package `^` constraints, and the example), prepends a
# CHANGELOG entry to each, commits, and tags `v<version>`.
#
# pub.dev takes the version from pubspec.yaml, not the git tag (automated
# publishing even checks the tag matches the pubspec version) — this just stamps
# all five for you so you never hand-edit pubspecs.
#
#   tool/release.sh 0.2.0
#   git show --stat v0.2.0        # review
#   git push --follow-tags <remote>   # triggers publish.yml -> pub.dev
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$ ]]; then
  echo "usage: tool/release.sh <version>   e.g. tool/release.sh 0.2.0" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty — commit or stash before releasing" >&2
  exit 1
fi

published=(bluebird bluebird_platform_interface bluebird_android bluebird_darwin bluebird_web)

# 1. each published package's own version + a CHANGELOG entry
for pkg in "${published[@]}"; do
  perl -i -pe "s/^version:.*/version: $version/" "packages/$pkg/pubspec.yaml"
  cl="packages/$pkg/CHANGELOG.md"
  printf '### %s\n  * \n\n%s' "$version" "$(cat "$cl")" > "$cl"
done

# 2. inter-package dependency constraints wherever they appear (incl. the example)
for f in packages/*/pubspec.yaml packages/bluebird/example/pubspec.yaml; do
  perl -i -pe "s/^(\s+bluebird(?:_platform_interface|_android|_darwin|_web)?):\s*\^?[0-9][^\s]*/\$1: ^$version/" "$f"
done

# 3. confirm it still resolves, then commit + tag
flutter pub get >/dev/null
git add packages/*/pubspec.yaml packages/*/CHANGELOG.md packages/bluebird/example/pubspec.yaml
git commit -q -m "chore: release v$version"
git tag "v$version"

echo "Tagged v$version. Review with:  git show --stat v$version"
echo "Publish with:                    git push --follow-tags <remote>"
