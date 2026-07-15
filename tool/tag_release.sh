#!/usr/bin/env bash
# Creates git tags in this repo's publish format `<hyphenated-name>/v<version>`
# (what .github/workflows/publish.yml triggers on) from each package's current
# pubspec version. Melos can only emit `<name>-v<version>` tags, so tagging is
# done here instead.
#
# It does NOT push — review the tags, then push them IN ORDER, waiting for each
# to appear on pub.dev before the next (a package can't publish until the
# dependencies it needs are live). Typical flow:
#   melos version <pkg> <patch|minor|major> --no-git-tag-version   # bump + changelog
#   tool/tag_release.sh                                            # create tags
#   git push <remote> <tag>                                        # one at a time
set -euo pipefail
cd "$(dirname "$0")/.."

# dependency / publish order
packages=(bluebird_platform_interface bluebird_android bluebird_darwin bluebird_web bluebird)

created=()
for pkg in "${packages[@]}"; do
  version=$(grep -m1 '^version:' "packages/$pkg/pubspec.yaml" | awk '{print $2}')
  tag="${pkg//_/-}/v${version}"
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    echo "exists:  ${tag}  (skipping)"
  else
    git tag "${tag}"
    echo "created: ${tag}"
    created+=("${tag}")
  fi
done

if [ ${#created[@]} -gt 0 ]; then
  echo
  echo "Push in this order, waiting for each to publish before the next:"
  for t in "${created[@]}"; do
    echo "  git push <remote> ${t}"
  done
fi
