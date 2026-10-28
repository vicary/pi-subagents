#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
registry=$(mktemp)
trap 'rm -f "$registry"' EXIT
status=$(curl --silent --show-error --location --output "$registry" --write-out '%{http_code}' 'https://registry.npmjs.org/%40vicary%2Fpi-subagents')
case "$status" in 200) ;; 404) printf '{"versions":{}}' > "$registry" ;; *) echo "npm registry returned HTTP $status" >&2; exit 1 ;; esac
node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); if (!p.versions || typeof p.versions !== "object") throw Error("Invalid registry metadata")' "$registry"
pending=false
while IFS= read -r ref; do
  tag=${ref#refs/fork-tags/}
  [[ $tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected fork tag $tag" >&2; exit 1; }
  version=${tag#v}
  if [ "$(printf '%s\n' "$version" 0.83.1 | sort -V | head -1)" != 0.83.1 ]; then continue; fi
  commit=$(git rev-parse "$ref^{commit}")
  existing=$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); const v=p.versions[process.argv[2]]; if (v) { if (!v.gitHead) throw Error("Existing version lacks gitHead"); console.log(v.gitHead) }' "$registry" "$version")
  if [ -z "$existing" ]; then pending=true; elif [ "$existing" != "$commit" ]; then echo "Existing npm version $version has a different gitHead" >&2; exit 1; fi
done < <(git for-each-ref --format='%(refname)' refs/fork-tags/)
echo "pending=$pending" >> "$GITHUB_OUTPUT"
