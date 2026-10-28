#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
export LC_ALL=C
package='@vicary/pi-subagents'
[[ ${GITHUB_REF:-} =~ ^refs/tags/(v?[0-9]+\.[0-9]+\.[0-9]+)$ ]] || { echo 'A stable tag dispatch is required' >&2; exit 1; }
tag=${BASH_REMATCH[1]}
version=${tag#v}
[ "$(printf '%s\n' "$version" 0.83.1 | sort -V | head -1)" = 0.83.1 ] || { echo 'Historical tags are not fork releases' >&2; exit 1; }
commit=$(git rev-parse HEAD)
[ "$commit" = "${GITHUB_SHA:-}" ] || { echo 'Checkout does not match the provenance SHA' >&2; exit 1; }
ledger=$(mktemp)
trap 'rm -f "$ledger" "${registry:-}"' EXIT
# Fetch the authority from main independently; never trust a ledger in the tag.
git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main' "+refs/tags/$tag:refs/fork-tags/$tag"
git show 'refs/remotes/origin/main:.github/release-ledger' > "$ledger" || { echo 'Missing trusted release ledger on origin/main' >&2; exit 1; }
awk 'NF != 2 || $1 !~ /^v?[0-9]+\.[0-9]+\.[0-9]+$/ || $2 !~ /^[0-9a-f]+$/ || length($2) != 40 || seen[$1]++ { exit 1 }' "$ledger" || { echo 'Invalid release ledger' >&2; exit 1; }
recorded=$(awk -v tag="$tag" '$1 == tag { print $2 }' "$ledger")
[ -n "$recorded" ] && [ "$recorded" = "$commit" ] || { echo "Tag $tag is absent from or differs from the trusted release ledger" >&2; exit 1; }
git fetch --no-tags https://github.com/nicobailon/pi-subagents.git "+refs/tags/$tag:refs/upstream-tags/$tag"
[ "$(git rev-parse "refs/fork-tags/$tag^{commit}")" = "$commit" ] || { echo 'Tag moved since dispatch' >&2; exit 1; }
[ "$(git rev-parse "$commit^1")" = "$(git rev-parse "refs/upstream-tags/$tag^{commit}")" ] || { echo 'Tag is not based on the upstream release' >&2; exit 1; }
[ "$(git show "$commit:package.json" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).version')" = "$version" ] || { echo 'Tag and package version differ' >&2; exit 1; }
registry=$(mktemp)
status=$(curl --silent --show-error --location --output "$registry" --write-out '%{http_code}' 'https://registry.npmjs.org/%40vicary%2Fpi-subagents')
case "$status" in 200) ;; 404) printf '{"versions":{},"dist-tags":{}}' > "$registry" ;; *) echo "npm registry returned HTTP $status" >&2; exit 1 ;; esac
node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); if (!p.versions || !p["dist-tags"]) throw Error("Invalid registry metadata")' "$registry"
existing=$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); const v=p.versions[process.argv[2]]; if (v) { if (!v.gitHead) throw Error("Existing version lacks gitHead; cannot verify"); console.log(v.gitHead) }' "$registry" "$version")
if [ -n "$existing" ]; then
  [ "$existing" = "$commit" ] || { echo "$package@$version already exists with a different gitHead" >&2; exit 1; }
  echo "$package@$version already published at $commit"
  exit 0
fi
latest=$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1])); console.log(p["dist-tags"].latest || "")' "$registry")
disttag=latest
if [ -n "$latest" ]; then
  [[ $latest =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || { echo "Cannot safely compare latest version $latest" >&2; exit 1; }
  latestbase=${BASH_REMATCH[1]}
  # A stable version outranks a prerelease of the same base. Never move latest backwards.
  if [ "$latestbase" = "$version" ]; then
    [ "$latest" != "$version" ] || { echo 'latest points to missing version' >&2; exit 1; }
  elif [ "$(printf '%s\n' "$latestbase" "$version" | sort -V | tail -1)" = "$latestbase" ]; then
    disttag="fork-$version"
  fi
fi
# No npm token: npm obtains an OIDC credential and automatically generates provenance.
unset NODE_AUTH_TOKEN NPM_TOKEN
npm ci --ignore-scripts
node --experimental-strip-types --import ./test/support/isolated-temp-root.mjs --test --test-name-pattern='uses configured per-index roots without changing the persisted parent' test/unit/fork-context.test.ts
node --experimental-strip-types --import ./test/support/register-loader.mjs --test --test-name-pattern='keeps direct background forks under configured or per-call run roots|retains and resumes a terminal nested fork under the configured session root' test/integration/async-execution.part-1.test.ts test/integration/single-execution.part-2.test.ts
npm run build:pkg
# Shell variables in this JavaScript replacement string must remain literal.
# shellcheck disable=SC2016
node -e 'const fs=require("fs"), f="dist-pkg/README.md", s=fs.readFileSync(f,"utf8"), re=/^([ \t]*)pi install npm:pi-subagents([ \t]*\r?)$/gm; if (!re.test(s)) throw Error("Expected upstream install command absent from staged README"); fs.writeFileSync(f,s.replace(re,"$1pi install npm:@vicary/pi-subagents$2"))'
node -e 'const fs=require("fs"); const f="dist-pkg/package.json"; const p=JSON.parse(fs.readFileSync(f)); if (p.name !== "pi-subagents" || p.version !== process.argv[1] || p.private) throw Error("Unexpected package metadata"); p.name=process.argv[2]; p.gitHead=process.argv[3]; p.repository={type:"git",url:"git+https://github.com/vicary/pi-subagents.git"}; fs.writeFileSync(f,JSON.stringify(p,null,2)+"\n")' "$version" "$package" "$commit"
npm publish ./dist-pkg --access public --provenance --tag "$disttag"
