#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
registry=$(mktemp)
ledger=$(mktemp)
trap 'rm -f "$registry" "$ledger"' EXIT
# Neither the checked-out tree nor tag contents are the authority for releases.
git fetch --prune --no-tags origin '+refs/heads/main:refs/remotes/origin/main' '+refs/tags/*:refs/fork-tags/*'
git show 'refs/remotes/origin/main:.github/release-ledger' > "$ledger" || { echo 'Missing trusted release ledger on origin/main' >&2; exit 1; }
awk 'NF != 2 || $1 !~ /^v?[0-9]+\.[0-9]+\.[0-9]+$/ || $2 !~ /^[0-9a-f]+$/ || length($2) != 40 || seen[$1]++ { exit 1 }' "$ledger" || { echo 'Invalid release ledger' >&2; exit 1; }
status=$(curl --silent --show-error --location --output "$registry" --write-out '%{http_code}' 'https://registry.npmjs.org/%40vicary%2Fpi-subagents')
case "$status" in 200) ;; 404) printf '{"versions":{}}' > "$registry" ;; *) echo "npm registry returned HTTP $status" >&2; exit 1 ;; esac
node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); if (!p.versions || typeof p.versions !== "object") throw Error("Invalid registry metadata")' "$registry"
while IFS= read -r tag; do
  [[ $tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected fork tag $tag" >&2; exit 1; }
  version=${tag#v}
  if [ "$(printf '%s\n' "$version" 0.83.1 | sort -V | head -1)" != 0.83.1 ]; then continue; fi
  commit=$(git rev-parse "refs/fork-tags/$tag^{commit}")
  recorded=$(awk -v tag="$tag" '$1 == tag { print $2 }' "$ledger")
  [ -n "$recorded" ] && [ "$recorded" = "$commit" ] || { echo "Fork tag $tag is absent from or differs from the trusted release ledger" >&2; exit 1; }
  existing=$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); const v=p.versions[process.argv[2]]; if (v) { if (!v.gitHead) throw Error("Existing version lacks gitHead"); console.log(v.gitHead) }' "$registry" "$version")
  if [ -n "$existing" ]; then
    [ "$existing" = "$commit" ] || { echo "Existing npm version $version has a different gitHead" >&2; exit 1; }
    continue
  fi
  for file in .github/workflows/sync.yml .github/workflows/release.yml .github/scripts/publish.sh; do
    git cat-file -e "$commit:$file" 2>/dev/null || { echo "Pending immutable tag $tag lacks $file; cannot publish with truthful provenance" >&2; exit 1; }
  done
  echo "Dispatching $tag ($commit)"
  gh api --method POST "repos/$GITHUB_REPOSITORY/actions/workflows/sync.yml/dispatches" -f "ref=refs/tags/$tag"
  exit 0
done < <(git for-each-ref --format='%(refname:strip=2)' refs/fork-tags/ | sort -V)
echo 'No pending npm releases.'
