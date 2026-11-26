// Sanity checks on public/: internal links and assets resolve, every page has title,
// description, canonical, hreflang pairs and valid JSON-LD, and the sitemap lists real pages.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'public');
const SITE = 'https://om-photos.app';
const errors = [];
const files = [];
(function walk(d) { for (const f of readdirSync(d)) { const p = join(d, f); statSync(p).isDirectory() ? walk(p) : files.push(p); } })(out);
const htmls = files.filter((f) => f.endsWith('.html'));
const REDIRECTS = new Set(['/download/mac']); // handled by the worker

const resolve = (url) => {
  const path = url.split('#')[0].split('?')[0];
  if (!path || REDIRECTS.has(path)) return true;
  const f = join(out, decodeURIComponent(path));
  return existsSync(f) && statSync(f).isFile() || existsSync(join(f, 'index.html'));
};

for (const f of htmls) {
  const rel = f.slice(out.length);
  const h = readFileSync(f, 'utf8');
  const need = (re, what) => { if (!re.test(h)) errors.push(`${rel}: missing ${what}`); };
  need(/<title>[^<]{5,}<\/title>/, 'title');
  need(/<meta name="description" content="[^"]{20,}"/, 'description');
  if (!rel.endsWith('404.html')) {
    need(/<link rel="canonical" href="https:\/\/om-photos\.app\//, 'canonical');
    need(/hreflang="zh-Hant"/, 'hreflang zh');
    need(/hreflang="en"/, 'hreflang en');
    need(/hreflang="x-default"/, 'hreflang x-default');
  }
  for (const m of h.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)) {
    try { JSON.parse(m[1]); } catch (e) { errors.push(`${rel}: bad JSON-LD (${e.message})`); }
  }
  for (const m of h.matchAll(/(?:href|src)="([^"]+)"/g)) {
    let u = m[1];
    if (u.startsWith(SITE)) u = u.slice(SITE.length) || '/';
    if (!u.startsWith('/') || u.startsWith('//')) continue;
    if (!resolve(u)) errors.push(`${rel}: broken link ${m[1]}`);
  }
  for (const m of h.matchAll(/href="#([^"]+)"/g)) {
    if (!h.includes(`id="${m[1]}"`)) errors.push(`${rel}: missing anchor #${m[1]}`);
  }
}

const sm = readFileSync(join(out, 'sitemap.xml'), 'utf8');
const locs = [...sm.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
for (const l of locs) if (!resolve(l.slice(SITE.length))) errors.push(`sitemap: ${l} has no page`);
if (locs.length < 10) errors.push(`sitemap: only ${locs.length} urls`);

if (errors.length) { console.error(errors.join('\n')); console.error(`\n${errors.length} problem(s)`); process.exit(1); }
console.log(`check ok: ${htmls.length} html files, ${locs.length} sitemap urls`);
