#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
export LC_ALL=C
package='@vicary/pi-subagents'
registry=$(mktemp)
work=$(mktemp -d)
cleanup() { git worktree remove --force "$work" >/dev/null 2>&1 || true; rm -rf "$work"; rm -f "$registry"; }
trap cleanup EXIT
# A 404 is an absent package; every other registry error must stop reconciliation.
status=$(curl --silent --show-error --location --output "$registry" --write-out '%{http_code}' 'https://registry.npmjs.org/%40vicary%2Fpi-subagents')
case "$status" in 200) ;; 404) printf '{"versions":{},"dist-tags":{}}' > "$registry" ;; *) echo "npm registry returned HTTP $status" >&2; exit 1 ;; esac
node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); if (!p.versions || !p["dist-tags"]) throw Error("Invalid registry metadata")' "$registry"
while IFS= read -r tag; do
  version=${tag#v}
  if [ "$(printf '%s\n' "$version" 0.83.1 | sort -V | head -1)" != 0.83.1 ]; then continue; fi
  git show-ref --verify --quiet "refs/upstream-tags/$tag" || { echo "Fork tag $tag has no upstream counterpart" >&2; exit 1; }
  commit=$(git rev-parse "refs/fork-tags/$tag^{commit}")
  existing=$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); const v=p.versions[process.argv[2]]; if (v) { if (!v.gitHead) throw Error("Existing version lacks gitHead; cannot verify"); console.log(v.gitHead) }' "$registry" "$version")
  if [ -n "$existing" ]; then
    [ "$existing" = "$commit" ] || { echo "$package@$version already exists with a different gitHead" >&2; exit 1; }
    continue
  fi
  # Token authentication only, without OIDC or provenance: workflow SHA is not
  # the synthetic tag commit. gitHead is metadata, not a provenance attestation.
  [ -n "${NODE_AUTH_TOKEN:-}" ] || { echo 'NPM_TOKEN is required; no package published' >&2; exit 1; }
  latest=$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); console.log(p["dist-tags"].latest || "")' "$registry")
  if [ -n "$latest" ] && [[ ! $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "Cannot safely compare latest version $latest" >&2; exit 1; fi
  disttag=latest
  if [ -n "$latest" ] && [ "$(printf '%s\n' "$latest" "$version" | sort -V | tail -1)" = "$latest" ]; then disttag=fork-sync; fi
  git worktree add --detach "$work" "$commit"
  (
    cd "$work"
    npm ci --ignore-scripts
    npm run test:all
    npm run build:pkg
    # Rewrite only the staged README; fail rather than publish stale install instructions.
    node -e 'const fs=require("fs"), f="dist-pkg/README.md", s=fs.readFileSync(f,"utf8"), re=/^([ \t]*)pi install npm:pi-subagents([ \t]*\r?)$/gm; if (!re.test(s)) throw Error("Expected upstream install command absent from staged README"); fs.writeFileSync(f,s.replace(re,"$1pi install npm:@vicary/pi-subagents$2"))'
    node -e 'const fs=require("fs"); const f="dist-pkg/package.json"; const p=JSON.parse(fs.readFileSync(f)); if (p.name !== "pi-subagents" || p.version !== process.argv[1] || p.private) throw Error("Unexpected package metadata"); p.name=process.argv[2]; p.gitHead=process.argv[3]; p.repository={type:"git",url:"git+https://github.com/vicary/pi-subagents.git"}; fs.writeFileSync(f,JSON.stringify(p,null,2)+"\n")' "$version" "$package" "$commit"
    npm publish ./dist-pkg --access public --provenance=false --tag "$disttag"
  )
  git worktree remove --force "$work"
  # Track versions published in this run without relying on registry cache propagation.
  node -e 'const fs=require("fs"),f=process.argv[1],p=JSON.parse(fs.readFileSync(f)); p.versions[process.argv[2]]={gitHead:process.argv[3]}; if(process.argv[4]==="latest") p["dist-tags"].latest=process.argv[2]; fs.writeFileSync(f,JSON.stringify(p))' "$registry" "$version" "$commit" "$disttag"
done < <(git for-each-ref --format='%(refname:strip=2)' refs/fork-tags/ | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)
