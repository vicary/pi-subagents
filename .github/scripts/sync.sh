#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
export LC_ALL=C
case ${1:-sync} in sync|verify) ;; *) echo 'Usage: sync.sh [sync|verify]' >&2; exit 2 ;; esac
upstream=https://github.com/nicobailon/pi-subagents.git
baseline=31208242
patch=$(mktemp)
index=$(mktemp)
ledger=$(mktemp)
rm -f "$index"
trap 'rm -f "$patch" "$index" "$ledger"' EXIT
git fetch --prune --no-tags origin '+refs/heads/main:refs/remotes/origin/main' '+refs/tags/*:refs/fork-tags/*'
git fetch --prune --no-tags "$upstream" '+refs/heads/main:refs/remotes/upstream/main' '+refs/tags/*:refs/upstream-tags/*'
old=$(git rev-parse refs/remotes/origin/main)
ledger_path=.github/release-ledger
if git cat-file -e "$old:$ledger_path" 2>/dev/null; then
  git show "$old:$ledger_path" > "$ledger"
else
  : > "$ledger"
fi
# The ledger is trusted only because it is committed on fork main, never from a tag.
awk 'NF != 2 || $1 !~ /^v?[0-9]+\.[0-9]+\.[0-9]+(-[1-9][0-9]*)?$/ || $2 !~ /^[0-9a-f]+$/ || length($2) != 40 || seen[$1]++ { exit 1 }' "$ledger" || { echo 'Invalid release ledger' >&2; exit 1; }
ledger_changed=false
while read -r recorded_tag recorded_commit; do
  base_tag=${recorded_tag%-*}
  git show-ref --verify --quiet "refs/upstream-tags/$base_tag" || { echo "Recorded upstream tag $base_tag is missing" >&2; exit 1; }
  git show-ref --verify --quiet "refs/fork-tags/$recorded_tag" || { echo "Recorded fork tag $recorded_tag is missing; refusing to recreate it" >&2; exit 1; }
  [ "$(git rev-parse "refs/fork-tags/$recorded_tag^{commit}")" = "$recorded_commit" ] || { echo "Recorded fork tag $recorded_tag moved" >&2; exit 1; }
  if [ "$base_tag" != "$recorded_tag" ]; then
    base_commit=$(awk -v tag="$base_tag" '$1 == tag { print $2 }' "$ledger")
    [ -n "$base_commit" ] && [ "$(git rev-parse "$recorded_commit^1")" = "$base_commit" ] || { echo "Revision tag $recorded_tag has an untrusted base" >&2; exit 1; }
  fi
done < "$ledger"
[ "$(git rev-parse 'refs/upstream-tags/v0.83.1^{commit}')" = "$(git rev-parse "$baseline^{commit}")" ] || { echo 'Upstream baseline tag changed' >&2; exit 1; }

# Integrate net changes once. Both histories remain ancestors of the result,
# so later syncs do not replay obsolete fork commits or their old conflicts.
upstream_commit=$(git rev-parse refs/remotes/upstream/main)
base=$(git merge-base "$old" "$upstream_commit")
git merge-base --is-ancestor "$baseline" "$base" || { echo 'Fork and upstream have an unsupported merge base; no refs pushed.' >&2; exit 1; }
new=$old
if ! git merge-base --is-ancestor "$upstream_commit" "$old"; then
  if ! merge_output=$(git merge-tree --write-tree "$old" "$upstream_commit"); then
    printf '%s\n' "$merge_output" >&2
    echo 'Upstream merge conflicts with current fork changes. Resolve once on main, then rerun; no refs pushed.' >&2
    exit 1
  fi
  tree=${merge_output%%$'\n'*}
  git cat-file -e "$tree^{tree}"
  new=$(printf 'chore(sync): merge upstream changes\n' | env GIT_AUTHOR_NAME='pi-subagents fork sync' GIT_AUTHOR_EMAIL='fork-sync@users.noreply.github.com' GIT_COMMITTER_NAME='pi-subagents fork sync' GIT_COMMITTER_EMAIL='fork-sync@users.noreply.github.com' git commit-tree "$tree" -p "$old" -p "$upstream_commit")
fi

# The replay patch is generated from the qualified application tree, not a
# historical commit stack. Automation and the release ledger own separate paths.
patch_path=.github/scripts/fork.patch
git diff --binary --full-index --no-ext-diff --no-textconv "$upstream_commit" "$new" -- . ':(exclude).github/scripts' ':(exclude).github/workflows/sync.yml' ':(exclude).github/workflows/release.yml' ':(exclude).github/release-ledger' > "$patch"
blob=$(git hash-object -w "$patch")
if [ "$(git rev-parse "$new:$patch_path")" != "$blob" ]; then
  rm -f "$index"
  GIT_INDEX_FILE="$index" git read-tree "$new"
  printf '100644 %s\t%s\n' "$blob" "$patch_path" | GIT_INDEX_FILE="$index" git update-index --index-info
  tree=$(GIT_INDEX_FILE="$index" git write-tree)
  new=$(printf 'chore(sync): refresh fork replay patch\n' | env GIT_AUTHOR_NAME='pi-subagents fork sync' GIT_AUTHOR_EMAIL='fork-sync@users.noreply.github.com' GIT_COMMITTER_NAME='pi-subagents fork sync' GIT_COMMITTER_EMAIL='fork-sync@users.noreply.github.com' git commit-tree "$tree" -p "$new")
fi

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
  git merge-base --is-ancestor "$base" "$upstream_commit" || { echo "$tag is not on upstream main" >&2; exit 1; }
  actual=$(git show "$base:package.json" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).version')
  [ "$actual" = "$version" ] || { echo "$tag has package version $actual" >&2; exit 1; }
  forkref=refs/fork-tags/$tag
  recorded=$(awk -v tag="$tag" '$1 == tag { print $2 }' "$ledger")
  if [ -n "$recorded" ]; then
    git show-ref --verify --quiet "$forkref" || { echo "Recorded tag $tag is missing; refusing to recreate it" >&2; exit 1; }
    existing=$(git rev-parse "$forkref^{commit}")
    [ "$existing" = "$recorded" ] || { echo "Fork tag $tag differs from the trusted release ledger" >&2; exit 1; }
    [ "$(git rev-parse "$existing^@")" = "$base" ] || { echo "Fork tag $tag has an unexpected upstream parent" >&2; exit 1; }
    continue
  fi
  rm -f "$index"
  GIT_INDEX_FILE="$index" git read-tree "$base"
  # An empty net patch is an identity application when upstream absorbs the fork.
  if [ -s "$patch" ]; then
    GIT_INDEX_FILE="$index" git apply --cached --3way "$patch" || { echo "HARD BLOCKER: fork patch cannot be replayed on upstream tag $tag ($base); historical port required; no refs pushed" >&2; exit 1; }
  fi
  # Before the ledger existed, releases had no automation overlay. Accept that
  # deterministic legacy tree, or the qualified candidate automation snapshot.
  legacy_tree=$(GIT_INDEX_FILE="$index" git write-tree)
  if git cat-file -e "$new:.github/scripts/sync.sh" 2>/dev/null; then
    git ls-tree -r "$new" -- .github/scripts .github/workflows/sync.yml .github/workflows/release.yml | GIT_INDEX_FILE="$index" git update-index --index-info
  fi
  tree=$(GIT_INDEX_FILE="$index" git write-tree)
  make_commit() {
    printf 'Apply fork patch to %s\n' "$tag" | env GIT_AUTHOR_NAME='pi-subagents fork sync' GIT_AUTHOR_EMAIL='fork-sync@users.noreply.github.com' GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_NAME='pi-subagents fork sync' GIT_COMMITTER_EMAIL='fork-sync@users.noreply.github.com' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' git commit-tree "$1" -p "$base"
  }
  expected=$(make_commit "$tree")
  if git show-ref --verify --quiet "$forkref"; then
    existing=$(git rev-parse "$forkref^{commit}")
    legacy=$(make_commit "$legacy_tree")
    [ "$existing" = "$expected" ] || [ "$existing" = "$legacy" ] || { echo "Unrecorded fork tag $tag cannot be independently verified; manual review required" >&2; exit 1; }
    expected=$existing
  else
    refs+=("$expected:refs/tags/$tag")
  fi
  printf '%s %s\n' "$tag" "$expected" >> "$ledger"
  ledger_changed=true
done < <(git for-each-ref --format='%(refname)' refs/upstream-tags/)

if [ "$ledger_changed" = true ]; then
  # Commit the independent tag identities on main in the same atomic push as
  # newly created tags. Plumbing avoids touching the checkout or its index.
  rm -f "$index"
  GIT_INDEX_FILE="$index" git read-tree "$new"
  blob=$(git hash-object -w "$ledger")
  printf '100644 %s\t%s\n' "$blob" "$ledger_path" | GIT_INDEX_FILE="$index" git update-index --index-info
  tree=$(GIT_INDEX_FILE="$index" git write-tree)
  new=$(printf 'chore(sync): record verified fork release tags\n' | env GIT_AUTHOR_NAME='pi-subagents fork sync' GIT_AUTHOR_EMAIL='fork-sync@users.noreply.github.com' GIT_COMMITTER_NAME='pi-subagents fork sync' GIT_COMMITTER_EMAIL='fork-sync@users.noreply.github.com' git commit-tree "$tree" -p "$new")
fi
# A sync must never discard fork history or claim an unintegrated upstream.
git merge-base --is-ancestor "$old" "$new" && git merge-base --is-ancestor "$upstream_commit" "$new" || { echo 'Candidate does not preserve both fork and upstream history; no refs pushed.' >&2; exit 1; }
if [ "${1:-sync}" = verify ]; then
  [ ${#refs[@]} -eq 0 ] || { echo 'Fork tags are missing; rerun sync first' >&2; exit 1; }
  [ "$new" = "$old" ] || { echo 'Fork main needs synchronization; rerun sync first; no refs pushed.' >&2; exit 1; }
  echo 'Verified upstream integration, replay patch, and release tags; no push.'
  exit 0
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
