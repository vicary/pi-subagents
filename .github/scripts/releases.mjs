// Reconcile public upstream release metadata only after patched fork tags exist.
// Upstream binary assets cannot safely be represented as fork-patched builds.
import { execFileSync } from 'node:child_process';

const fork = process.env.GITHUB_REPOSITORY;
if (!fork) throw Error('GITHUB_REPOSITORY is required');
const upstream = 'nicobailon/pi-subagents';
function gh(args, input) {
  return execFileSync('gh', args, { encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'inherit'] });
}
function list(repo) {
  return JSON.parse(gh(['api', '--paginate', '--slurp', `repos/${repo}/releases?per_page=100`])).flat();
}
execFileSync('git', ['fetch', '--no-tags', 'origin', '+refs/tags/*:refs/fork-tags/*'], { stdio: 'inherit' });
const source = list(upstream);
const destination = list(fork);
const byTag = new Map(destination.map(r => [r.tag_name, r]));
const plans = [];
for (const release of source) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(release.tag_name);
  if (!match) throw Error(`Unsupported upstream release tag ${release.tag_name}`);
  const [major, minor, patch] = match.slice(1).map(Number);
  const historical = major === 0 && (minor < 83 || (minor === 83 && patch < 1));
  try { execFileSync('git', ['rev-parse', '--verify', `refs/fork-tags/${release.tag_name}^{commit}`], { stdio: 'ignore' }); }
  catch { throw Error(`Fork tag missing for upstream release ${release.tag_name}`); }
  const existing = byTag.get(release.tag_name);
  if (existing?.assets.length) throw Error(`Fork release ${release.tag_name} has assets; refusing to alter it automatically`);
  const notice = historical
    ? '> **Upstream history: unpatched.** This historical tag is mirrored unchanged from upstream.'
    : '> **Fork release: patched.** Upstream binary assets are not redistributed; npm builds have no provenance attestation.';
  const data = { tag_name: release.tag_name, name: release.name, body: `${notice}\n\n${release.body ?? ''}`, draft: release.draft, prerelease: release.prerelease };
  if (!existing || Object.keys(data).some(key => (existing[key] ?? null) !== (data[key] ?? null))) plans.push({ existing, data });
}
for (const { existing, data } of plans) {
  const path = existing ? `repos/${fork}/releases/${existing.id}` : `repos/${fork}/releases`;
  gh(['api', '--method', existing ? 'PATCH' : 'POST', path, '--input', '-'], JSON.stringify({ ...data, make_latest: 'false' }));
  console.log(`${existing ? 'Updated' : 'Created'} release ${data.tag_name}`);
}
console.log(`Reconciled ${source.length} upstream releases; ${plans.length} changed.`);
