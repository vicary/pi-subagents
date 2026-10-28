#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
export LC_ALL=C
upstream=https://github.com/nicobailon/pi-subagents.git
baseline=31208242
patch=$(mktemp)
index=$(mktemp)
rm -f "$index"
trap 'rm -f "$patch" "$index"' EXIT
cp .github/scripts/fork.patch "$patch"
git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main' '+refs/tags/*:refs/fork-tags/*'
git fetch --no-tags "$upstream" '+refs/heads/main:refs/remotes/upstream/main' '+refs/tags/*:refs/upstream-tags/*'
old=$(git rev-parse refs/remotes/origin/main)
[ "$(git rev-parse 'refs/upstream-tags/v0.83.1^{commit}')" = "$(git rev-parse "$baseline^{commit}")" ] || { echo 'Upstream baseline tag changed' >&2; exit 1; }

# Recreate each release from its exact upstream commit, not from fork main.
refs=()
while IFS= read -r ref; do
  tag=${ref#refs/upstream-tags/}
  [[ $tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unsupported upstream tag $tag; refusing to omit it" >&2; exit 1; }
  version=${tag#v}
  base=$(git rev-parse "$ref^{commit}")
  # Earlier releases are explicitly unpatched upstream history, including tag objects.
  if [ "$(printf '%s\n' "$version" 0.83.1 | sort -V | head -1)" != 0.83.1 ]; then
    expected=$(git rev-parse "$ref")
    forkref=refs/fork-tags/$tag
    if git show-ref --verify --quiet "$forkref"; then
      [ "$(git rev-parse "$forkref")" = "$expected" ] || { echo "Historical tag $tag differs from upstream" >&2; exit 1; }
    else
      refs+=("$expected:refs/tags/$tag")
    fi
    continue
  fi
  git merge-base --is-ancestor "$base" refs/remotes/upstream/main || { echo "$tag is not on upstream main" >&2; exit 1; }
  actual=$(git show "$base:package.json" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).version')
  [ "$actual" = "$version" ] || { echo "$tag has package version $actual" >&2; exit 1; }
  rm -f "$index"
  GIT_INDEX_FILE="$index" git read-tree "$base"
  GIT_INDEX_FILE="$index" git apply --cached --3way "$patch" || { echo "HARD BLOCKER: fork patch cannot be replayed on upstream tag $tag ($base); historical port required; no refs pushed" >&2; exit 1; }
  tree=$(GIT_INDEX_FILE="$index" git write-tree)
  expected=$(printf 'Apply fork patch to %s\n' "$tag" | env GIT_AUTHOR_NAME='pi-subagents fork sync' GIT_AUTHOR_EMAIL='fork-sync@users.noreply.github.com' GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_NAME='pi-subagents fork sync' GIT_COMMITTER_EMAIL='fork-sync@users.noreply.github.com' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' git commit-tree "$tree" -p "$base")
  forkref=refs/fork-tags/$tag
  if git show-ref --verify --quiet "$forkref"; then
    existing=$(git rev-parse "$forkref^{commit}")
    [ "$existing" = "$expected" ] || { echo "Fork tag $tag does not match the expected patched commit" >&2; exit 1; }
  else
    refs+=("$expected:refs/tags/$tag")
  fi
done < <(git for-each-ref --format='%(refname)' refs/upstream-tags/)

if [ "${1:-sync}" = verify ]; then
  [ ${#refs[@]} -eq 0 ] || { echo 'Fork tags are missing; rerun sync first' >&2; exit 1; }
  exit 0
fi
[ "${1:-sync}" = sync ] || exit 2
new=$old
if ! git merge-base --is-ancestor refs/remotes/upstream/main "$old"; then
  base=$(git merge-base "$old" refs/remotes/upstream/main)
  git merge-base --is-ancestor "$baseline" "$base" || { echo 'Fork and upstream have an unsupported merge base' >&2; exit 1; }
  git checkout --detach "$old"
  if ! git -c user.name='pi-subagents fork sync' -c user.email='fork-sync@users.noreply.github.com' rebase --onto refs/remotes/upstream/main "$base"; then
    git rebase --abort || true
    echo 'Rebase failed; aborted locally. Resolve the fork patch against upstream and rerun; no refs pushed.' >&2
    exit 1
  fi
  new=$(git rev-parse HEAD)
fi
if [ "$new" = "$old" ] && [ ${#refs[@]} -eq 0 ]; then
  echo 'Already synchronized; no push.'
  exit 0
fi
# Always require the workflow-authorized credential before any push, including tags.
[ "${HAS_WORKFLOW_TOKEN:-false}" = true ] || { echo 'FORK_SYNC_TOKEN with Contents:write and Workflows:write required; no refs pushed.' >&2; exit 1; }
args=(--atomic "--force-with-lease=refs/heads/main:$old")
for spec in "${refs[@]}"; do args+=("--force-with-lease=${spec#*:}:"); done
if [ "$new" != "$old" ]; then refs+=("$new:refs/heads/main"); fi
if ! git push "${args[@]}" origin "${refs[@]}"; then
  echo 'Atomic push failed; no refs should have changed. Check branch protection, stale lease, and workflow-file token permissions; rerun after correction.' >&2
  exit 1
fi
