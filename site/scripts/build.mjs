// Builds om-photos.app into public/ in two languages: Traditional Chinese at /, English at /en/.
//   node scripts/build.mjs
// Guides: content/guide/*.md (zh) and content/en/guide/*.md (en), same slug = same page.
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'public');
const cfg = JSON.parse(readFileSync(join(root, 'site.config.json'), 'utf8'));
const SITE = `https://${cfg.domain}`;
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const today = new Date().toISOString().slice(0, 10);

mkdirSync(out, { recursive: true });
for (const f of readdirSync(out)) rmSync(join(out, f), { recursive: true, force: true });
cpSync(join(root, 'static'), out, { recursive: true });

const LANGS = {
  zh: { html: 'zh-Hant-TW', hreflang: 'zh-Hant', og: 'zh_TW', prefix: '', dir: '' },
  en: { html: 'en', hreflang: 'en', og: 'en_US', prefix: '/en', dir: 'en' },
};
const p = (lang, path) => (LANGS[lang].prefix + path).replace(/\/\/+/g, '/');
const both = (path) => ({ zh: p('zh', path), en: p('en', path) });

// ------------------------------------------------------------------ guides
function frontmatter(raw, file) {
  const m = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (!m) throw new Error(`${file}: missing front matter`);
  const data = {};
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^([A-Za-z][\w-]*):\s*(.*)$/);
    if (kv) data[kv[1]] = kv[2].trim();
  }
  return { data, body: m[2] };
}
const guides = {};
for (const lang of Object.keys(LANGS)) {
  const d = join(root, 'content', LANGS[lang].dir, 'guide');
  guides[lang] = readdirSync(d).filter((f) => f.endsWith('.md')).map((f) => {
    const { data, body } = frontmatter(readFileSync(join(d, f), 'utf8'), f);
    for (const k of ['title', 'description', 'group', 'order']) if (!data[k]) throw new Error(`${lang}/${f}: missing ${k}`);
    return { slug: f.replace(/\.md$/, ''), ...data, order: Number(data.order), body };
  }).sort((a, b) => a.order - b.order);
}
for (const g of guides.zh) if (!guides.en.some((e) => e.slug === g.slug)) throw new Error(`guide ${g.slug} has no English version`);

const plain = (h) => h.replace(/<[^>]+>/g, '').replace(/&[a-z#0-9]+;/g, ' ');
function md(src, lang) {
  const heads = []; const used = new Set();
  const m = new Marked({ gfm: true, renderer: {
    heading({ tokens, depth }) {
      const html = this.parser.parseInline(tokens); const text = plain(html).trim();
      let id = text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-+|-+$/g, '').slice(0, 60) || `s${heads.length + 1}`;
      while (used.has(id)) id += '-x';
      used.add(id);
      if (depth === 2) heads.push({ id, text });
      return `<h${depth} id="${id}">${html}</h${depth}>\n`;
    },
    link({ href, title, tokens }) {
      // Guide links are written for Chinese; keep English pages in English.
      if (lang === 'en' && href.startsWith('/') && !href.startsWith('/en/')) href = '/en' + href;
      const ext = /^https?:\/\//.test(href);
      return `<a href="${esc(href)}"${title ? ` title="${esc(title)}"` : ''}${ext ? ' rel="noopener" target="_blank"' : ''}>${this.parser.parseInline(tokens)}</a>`;
    },
  } });
  let html = m.parse(src);
  html = html.replace(/<table>/g, '<div class="table-wrap"><table>').replace(/<\/table>/g, '</table></div>');
  return { html, heads };
}

// ------------------------------------------------------------------ texts
const T = {
  zh: {
    nav: [['/#features', '功能'], ['/demo/', 'Demo'], ['/guide/', '教學'], ['/download/', '下載']],
    switchTo: 'English', skip: '跳到內容', menu: '選單', home: '首頁',
    macDl: '下載 Mac 版', macNote: `免費 · ${cfg.mac.requires} 以上 · Apple 晶片與 Intel`,
    ios: 'iPhone · iPad 即將推出', tryDemo: '線上試玩 Demo', guide: '使用教學', guides: '教學',
    onPage: '本頁內容', prev: '上一篇', next: '下一篇', allGuides: '所有教學',
    groups: { start: '開始使用', connect: '連接相機', use: '瀏覽、匯入與刪除', help: '說明' },
    footTag: '把相機裡的照片帶過來，最簡單的方式。',
    footProduct: '產品', footLearn: '教學', footMore: '更多', features: '功能', demo: 'Demo', download: '下載', privacy: '隱私權政策', contact: '聯絡我們',
  },
  en: {
    nav: [['/#features', 'Features'], ['/demo/', 'Demo'], ['/guide/', 'Guides'], ['/download/', 'Download']],
    switchTo: '繁體中文', skip: 'Skip to content', menu: 'Menu', home: 'Home',
    macDl: 'Download for Mac', macNote: `Free · ${cfg.mac.requires} or later · Apple silicon and Intel`,
    ios: 'iPhone · iPad coming soon', tryDemo: 'Try the live demo', guide: 'How-to guides', guides: 'Guides',
    onPage: 'On this page', prev: 'Previous', next: 'Next', allGuides: 'All guides',
    groups: { start: 'Get started', connect: 'Connect your camera', use: 'Browse, import and delete', help: 'Help' },
    footTag: 'The simplest way to bring photos from your camera.',
    footProduct: 'Product', footLearn: 'Guides', footMore: 'More', features: 'Features', demo: 'Demo', download: 'Download', privacy: 'Privacy', contact: 'Contact',
  },
};

// ------------------------------------------------------------------ shell
const brand = (lang) => `<a class="brand" href="${p(lang, '/')}" aria-label="OM Photos"><img src="/logo-mark.png" width="38" height="27" alt=""><span>OM Photos</span></a>`;
const header = (lang, cur, other) => `<header class="site-head"><div class="wrap head-in">${brand(lang)}
<button class="menu-btn" aria-label="${T[lang].menu}" aria-expanded="false" data-menu><span></span><span></span></button>
<nav class="nav" aria-label="Main">${T[lang].nav.map(([h, t]) => `<a href="${p(lang, h)}"${cur === h ? ' aria-current="page"' : ''}>${t}</a>`).join('')}<a class="lang" href="${other}" hreflang="${lang === 'zh' ? 'en' : 'zh-Hant'}" lang="${lang === 'zh' ? 'en' : 'zh-Hant'}">${T[lang].switchTo}</a></nav></div></header>`;
const footer = (lang) => { const t = T[lang]; return `<footer class="site-foot"><div class="wrap"><div class="foot-grid">
<div>${brand(lang)}<p class="foot-tag">${t.footTag}</p></div>
<div><h4>${t.footProduct}</h4><a href="${p(lang, '/#features')}">${t.features}</a><a href="${p(lang, '/demo/')}">${t.demo}</a><a href="${p(lang, '/download/')}">${t.download}</a></div>
<div><h4>${t.footLearn}</h4>${guides[lang].slice(0, 5).map((g) => `<a href="${p(lang, `/guide/${g.slug}/`)}">${esc(g.title.split(/[（(]/)[0].trim())}</a>`).join('')}</div>
<div><h4>${t.footMore}</h4><a href="${p(lang, '/privacy/')}">${t.privacy}</a><a href="mailto:${cfg.contactEmail}">${t.contact}</a></div>
</div><p class="copy">© ${new Date().getFullYear()} OM Photos</p></div></footer>`; };

const gaTag = cfg.ga4MeasurementId ? `<script async src="https://www.googletagmanager.com/gtag/js?id=${cfg.ga4MeasurementId}"></script>
<script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments)}gtag('js',new Date());gtag('config','${cfg.ga4MeasurementId}');</script>` : '';
const gscTag = cfg.gscVerification ? `<meta name="google-site-verification" content="${cfg.gscVerification}">` : '';

const registry = [];
function page({ lang, path, alt = {}, title, description, body, cur = '', graph = [], noindex = false, ogType = 'website', scripts = '', file }) {
  const L = LANGS[lang];
  const url = SITE + path;
  const alts = { ...alt, [lang]: path };
  if (!noindex) registry.push({ path, alt: alts });
  const other = lang === 'zh' ? 'en' : 'zh';
  const otherHref = alts[other] ?? p(other, '/');
  const og = `${SITE}/${lang === 'en' ? 'og-en.png' : 'og.png'}`;
  const hreflang = Object.entries(alts).map(([l, u]) => `<link rel="alternate" hreflang="${LANGS[l].hreflang}" href="${SITE + u}">`).join('\n')
    + (alts.zh ? `\n<link rel="alternate" hreflang="x-default" href="${SITE + alts.zh}">` : '');
  const html = `<!doctype html>
<html lang="${L.html}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
${noindex ? '<meta name="robots" content="noindex">' : `<link rel="canonical" href="${url}">\n${hreflang}\n<meta name="robots" content="index,follow,max-image-preview:large">`}
${gscTag}
<meta property="og:type" content="${ogType}"><meta property="og:site_name" content="OM Photos"><meta property="og:locale" content="${L.og}">
<meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(description)}"><meta property="og:url" content="${url}">
<meta property="og:image" content="${og}"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:image" content="${og}">
<meta name="theme-color" content="#ffffff">
<link rel="icon" href="/favicon.png" type="image/png"><link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="stylesheet" href="/style.css">
${graph.length ? `<script type="application/ld+json">${JSON.stringify({ '@context': 'https://schema.org', '@graph': graph })}</script>` : ''}
${gaTag}
</head>
<body>
<a class="skip" href="#main">${T[lang].skip}</a>
${header(lang, cur, otherHref)}
<main id="main">
${body}
</main>
${footer(lang)}
<script src="/site.js" defer></script>
${scripts}
</body>
</html>
`;
  if (file) { writeFileSync(join(out, file), html); return; }
  const dir = join(out, path);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'index.html'), html);
}
const crumbs = (list) => ({ '@type': 'BreadcrumbList', itemListElement: list.map((c, i) => ({ '@type': 'ListItem', position: i + 1, name: c.name, item: SITE + c.path })) });
const crumbHtml = (list) => `<nav class="crumbs" aria-label="Breadcrumb">${list.map((c, i) => (i === list.length - 1 ? `<span aria-current="page">${esc(c.name)}</span>` : `<a href="${c.path}">${esc(c.name)}</a>`)).join(' / ')}</nav>`;

// ------------------------------------------------------------------ shared blocks
const macBtn = (lang, cls = 'primary') => `<a class="btn ${cls}" href="${cfg.mac.url}" data-dl="mac"><svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M16.4 12.6c0-2.6 2.1-3.8 2.2-3.9-1.2-1.8-3.1-2-3.7-2-1.6-.2-3.1.9-3.9.9s-2-.9-3.4-.9C5.9 6.8 4.2 7.8 3.3 9.4c-1.9 3.3-.5 8.2 1.4 10.9.9 1.3 2 2.8 3.4 2.8 1.4-.1 1.9-.9 3.5-.9s2.1.9 3.5.9c1.5 0 2.4-1.3 3.3-2.7 1-1.5 1.5-3 1.5-3.1-.1 0-2.6-1-2.5-4.7zM13.8 4.9c.7-.9 1.3-2.2 1.1-3.4-1.1 0-2.4.7-3.2 1.6-.7.8-1.3 2.1-1.1 3.3 1.2.1 2.4-.6 3.2-1.5z"/></svg>${T[lang].macDl}</a>`;
const iosBadge = (lang) => `<span class="soon"><svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><rect x="7" y="2.5" width="10" height="19" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M10.5 18.5h3" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>${T[lang].ios}</span>`;

const ICONS = {
  qr: '<path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4z" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M14 14h2v2h-2zM18 14h2v2h-2zM14 18h2v2h-2zM18 18h2v2h-2z" fill="currentColor"/>',
  wifi: '<path d="M2.5 9a14 14 0 0119 0M5.5 12.5a9.5 9.5 0 0113 0M8.7 16a5 5 0 016.6 0" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><circle cx="12" cy="19.3" r="1.4" fill="currentColor"/>',
  usb: '<rect x="3" y="8" width="18" height="8" rx="4" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M8 12h8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
  raw: '<rect x="3" y="6" width="13" height="13" rx="2" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M8 3h11a2 2 0 012 2v11" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M6 16l3-4 2.5 3 1.5-2 2 3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/>',
  filter: '<path d="M4 6h16M7 12h10M10 18h4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
  check: '<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M8 12.5l2.6 2.6L16.5 9" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6.5 7l1 13h9l1-13" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>',
  folder: '<path d="M3 6.5A1.5 1.5 0 014.5 5H9l2 2h8.5A1.5 1.5 0 0121 8.5v9a1.5 1.5 0 01-1.5 1.5h-15A1.5 1.5 0 013 17.5z" fill="none" stroke="currentColor" stroke-width="1.8"/>',
  info: '<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12 11v6M12 7.5v.5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
};
const ico = (k) => `<div class="ico"><svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[k]}</svg></div>`;

const HOME = {
  zh: {
    title: 'OM Photos｜OM System、Olympus 相機照片匯入 Mac 的免費 App',
    description: 'OM Photos 用 Wi-Fi 或 USB-C 把 OM System／Olympus 相機的照片和影片匯入 Mac：掃 QR code 一次配對、RAW+JPG 合併、依日期瀏覽篩選、匯入過不重複，還能刪除記憶卡上的照片。免費下載。',
    eyebrow: 'OM System · Olympus · Mac',
    h1: '相機裡的照片，<br>一鍵帶到 Mac',
    lead: '掃一次相機上的 QR code 就配對完成。之後用 Wi-Fi 或 USB-C 連上，照片依日期排好，RAW+JPG 自動合併，挑好就匯入，匯入過的不會重抓。',
    featH: '像「照片」App 一樣好用', featLead: '專為 OM System 與 Olympus 相機做的匯入工具，簡單、快、不會搞亂你的資料夾。',
    features: [
      ['qr', '掃一次 QR code 就配對', '相機螢幕上的 QR code 掃一次，就記住相機 Wi-Fi 的名稱和密碼。之後按「連線」就好。'],
      ['wifi', '自動切換 Wi-Fi', 'Mac 會自動連到相機的 Wi-Fi，用完再切回你原本的網路。已經連著相機時，打開就能用。'],
      ['usb', 'USB-C 快 10 倍以上', '接上線自動偵測，實測 35–45 MB/s。一分鐘的 4K 影片，十幾秒就匯完。'],
      ['raw', 'RAW+JPG 自動合併', '同一張的 ORF 和 JPG 合成一格，標籤一眼看出 JPG、RAW、MOV、MP4，影片顯示長度。'],
      ['filter', '依日期瀏覽、快速篩選', '照片、RAW、影片、未匯入、已匯入，一點就篩出來；點日期直接跳到那一天。'],
      ['check', '匯入過的不重複', '換 Wi-Fi、換 USB、把檔案搬走都一樣，已匯入的會打勾，下次不會再抓。'],
      ['folder', '你選資料夾，不亂建資料夾', '每次匯入前選資料夾，檔案直接放進去；同名檔案自動改名，絕不覆蓋。'],
      ['trash', '整理記憶卡', '多選後一次刪除，確認視窗會提醒還沒匯入的檔案；受保護的照片不會被刪。'],
      ['info', '看相機資訊', '型號、韌體版本、鏡頭、記憶卡剩餘空間和檔案數，一頁看完。'],
    ],
    demoH: '不用安裝，先試試看', demoLead: '這是 OM Photos 的線上模擬：點選照片、篩選、匯入、刪除都能操作。照片是 AI 生成的範例，不會真的下載任何檔案。',
    howH: '三個步驟', how: [['連上相機', '相機打開「裝置連線」，在 OM Photos 掃 QR code 後按「連線」；或直接用 USB-C 線接上。'], ['挑照片', '照片依日期排好，用篩選找出 RAW、影片或還沒匯入的；點兩下看大圖。'], ['匯入或刪除', '選資料夾匯入，匯完可以直接刪掉記憶卡上的照片，空出空間繼續拍。']],
    cmpH: 'Wi-Fi 還是 USB-C？', cmpRows: [['連線方式', 'Wi-Fi', 'USB-C'], ['速度（實測）', '約 3 MB/s', '約 35–45 MB/s'], ['一分鐘 4K 影片', '約 3.5 分鐘', '約 15–20 秒'], ['需要配對', '第一次掃 QR code', '不需要'], ['適合', '幾張照片、不想接線', '影片、整張記憶卡']],
    faqH: '常見問題',
    faq: [
      ['OM Photos 要錢嗎？', '免費。Mac 版可以直接從下載頁下載。'],
      ['支援哪些相機？', '目前在 OM System OM-3 上完整實測。其他支援 OI.Share／OM Image Share 的 OM System 與 Olympus 機型使用相同的連線方式，理論上也能用，但還沒逐一測試。'],
      ['跟官方的 OM Image Share（OI.Share）有什麼不同？', 'OM Photos 是專為 Mac 做的工具：依日期瀏覽、RAW+JPG 合併、多選匯入到你選的資料夾、匯入過不重複、刪除記憶卡照片，也支援 USB-C 高速傳輸。'],
      ['可以匯入 RAW 和影片嗎？', '可以。RAW（.ORF）、JPG、MOV、MP4 都能匯入；同一張的 RAW 和 JPG 會合成一格顯示，並一起匯入。'],
      ['為什麼 Wi-Fi 連著相機時不能上網？', '相機開出的 Wi-Fi 沒有網際網路。OM Photos 會在連線時自動切過去，中斷連線後再切回你原本的網路。'],
      ['第一次打開時說「無法打開」怎麼辦？', '這個版本沒有 Apple 開發者簽章。到「系統設定 › 隱私權與安全性」，在 OM Photos 旁邊按「強制打開」即可，只需要做一次。'],
      ['iPhone 和 iPad 有嗎？', 'iPhone、iPad 版開發中，即將推出。'],
      ['照片會上傳到雲端嗎？', '不會。照片直接從相機傳到你的 Mac，OM Photos 沒有帳號、不收集照片或使用資料。'],
    ],
    bandH: '把照片帶回家', bandLead: '免費下載，掃一次 QR code 就能開始。',
  },
  en: {
    title: 'OM Photos | Free Mac app to import photos from OM System and Olympus cameras',
    description: 'OM Photos imports photos and videos from OM System and Olympus cameras to your Mac over Wi-Fi or USB-C: pair once with a QR code, RAW+JPG merged, browse and filter by date, never import twice, and delete from the card. Free download.',
    eyebrow: 'OM System · Olympus · Mac',
    h1: 'Your camera’s photos,<br>on your Mac in one click',
    lead: 'Scan the QR code on your camera once to pair. Then connect over Wi-Fi or USB-C, browse by date with RAW+JPG merged, pick what you want and import. What you already imported is never fetched twice.',
    featH: 'As easy as the Photos app', featLead: 'An import tool made for OM System and Olympus cameras. Simple, fast, and it keeps your folders tidy.',
    features: [
      ['qr', 'Pair once with a QR code', 'Scan the QR code on the camera screen once and OM Photos remembers the camera’s Wi-Fi. After that, just click Connect.'],
      ['wifi', 'Switches Wi-Fi for you', 'Your Mac joins the camera’s Wi-Fi and switches back to your network when you are done. Already on the camera Wi-Fi? It just works.'],
      ['usb', 'USB-C, 10× faster', 'Plug in a cable and it is detected. We measured 35–45 MB/s: a one-minute 4K video imports in seconds.'],
      ['raw', 'RAW+JPG merged', 'The ORF and JPG of the same shot appear as one. Labels show JPG, RAW, MOV or MP4, and videos show their length.'],
      ['filter', 'Browse by date, filter fast', 'Photos, RAW, videos, not imported, imported: one click. Click a date to jump to that day.'],
      ['check', 'Never import twice', 'Over Wi-Fi or USB, even after you move the files: imported photos are marked and skipped next time.'],
      ['folder', 'Your folder, no clutter', 'Choose a folder for each import; files go straight in. Same-name files are renamed, never overwritten.'],
      ['trash', 'Clear the card', 'Select many and delete at once. The confirmation warns about files you have not imported; protected photos are skipped.'],
      ['info', 'Camera information', 'Model, firmware, lens, free card space and file count in one place.'],
    ],
    demoH: 'Try it, nothing to install', demoLead: 'A live simulation of OM Photos: select, filter, import and delete. The photos are AI-generated samples and nothing is actually downloaded.',
    howH: 'Three steps', how: [['Connect', 'Open Device Connection on the camera, scan the QR code in OM Photos and click Connect. Or just plug in a USB-C cable.'], ['Pick', 'Photos are sorted by date. Filter for RAW, videos or what you have not imported; double-click for a full-size view.'], ['Import or delete', 'Import to the folder you choose, then clear the card to keep shooting.']],
    cmpH: 'Wi-Fi or USB-C?', cmpRows: [['Connection', 'Wi-Fi', 'USB-C'], ['Speed (measured)', 'about 3 MB/s', 'about 35–45 MB/s'], ['One-minute 4K video', 'about 3.5 minutes', 'about 15–20 seconds'], ['Pairing', 'Scan the QR code once', 'Not needed'], ['Best for', 'A few photos, no cable', 'Videos, a full card']],
    faqH: 'FAQ',
    faq: [
      ['Is OM Photos free?', 'Yes. Download the Mac app from the download page.'],
      ['Which cameras work?', 'OM Photos is fully tested with the OM System OM-3. Other OM System and Olympus models that work with OI.Share / OM Image Share use the same connection and should work, but have not all been tested.'],
      ['How is it different from OM Image Share (OI.Share)?', 'OM Photos is a Mac app: browse by date, RAW+JPG merged, import a selection to the folder you choose, never import twice, delete from the card, and fast USB-C transfers.'],
      ['Can it import RAW and video?', 'Yes. RAW (.ORF), JPG, MOV and MP4. The RAW and JPG of the same shot appear as one and are imported together.'],
      ['Why is my Mac offline on the camera Wi-Fi?', 'The camera’s own Wi-Fi has no internet. OM Photos switches to it while connected and back to your network when you disconnect.'],
      ['macOS says it cannot be opened. What now?', 'This build is not signed with an Apple Developer ID. Go to System Settings › Privacy & Security and click Open Anyway next to OM Photos. You only do this once.'],
      ['Is there an iPhone or iPad app?', 'It is in development and coming soon.'],
      ['Are my photos uploaded anywhere?', 'No. Photos go straight from the camera to your Mac. OM Photos has no account and collects no photos or usage data.'],
    ],
    bandH: 'Bring your photos home', bandLead: 'Free download. Scan a QR code and you are ready.',
  },
};
const faqHtml = (items) => items.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n');
const faqLd = (items) => ({ '@type': 'FAQPage', mainEntity: items.map(([q, a]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) });
const appLd = (lang) => ({
  '@type': 'SoftwareApplication', name: 'OM Photos', applicationCategory: 'PhotographyApplication', operatingSystem: `macOS 27`,
  softwareVersion: cfg.mac.version, downloadUrl: SITE + cfg.mac.url, url: SITE + p(lang, '/'), image: `${SITE}/app-icon.png`,
  description: HOME[lang].description, offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' }, inLanguage: ['zh-Hant', 'en'],
});
const orgLd = { '@type': 'Organization', name: 'OM Photos', url: SITE + '/', logo: `${SITE}/app-icon.png` };

const demoBlock = (lang) => `<div class="demo-shell" id="demo-app" data-lang="${lang}"><noscript>${lang === 'zh' ? 'Demo 需要 JavaScript。' : 'The demo needs JavaScript.'}</noscript></div>`;
const demoScript = '<script src="/demo.js" defer></script>';

// ------------------------------------------------------------------ pages
for (const lang of Object.keys(LANGS)) {
  const t = T[lang]; const H = HOME[lang];
  const home = { name: t.home, path: p(lang, '/') };

  page({
    lang, path: p(lang, '/'), alt: both('/'), cur: '/', title: H.title, description: H.description,
    graph: [orgLd, { '@type': 'WebSite', name: 'OM Photos', url: SITE + p(lang, '/'), inLanguage: LANGS[lang].hreflang }, appLd(lang), faqLd(H.faq)],
    scripts: demoScript,
    body: `
<section class="hero"><div class="wrap hero-in">
  <img class="hero-mark" src="/logo-mark.png" width="300" height="211" alt="OM Photos">
  <p class="eyebrow">${H.eyebrow}</p>
  <h1>${H.h1}</h1>
  <p class="lead">${H.lead}</p>
  <div class="cta-row">${macBtn(lang)}<a class="btn" href="#demo">${t.tryDemo}</a></div>
  <p class="hero-note">${t.macNote} · v${cfg.mac.version}</p>
  <p class="hero-note">${iosBadge(lang)}</p>
</div></section>
<section class="section" id="demo"><div class="wrap">
  <h2>${H.demoH}</h2><p class="section-lead">${H.demoLead}</p>
  ${demoBlock(lang)}
</div></section>
<section class="section alt" id="features"><div class="wrap">
  <h2>${H.featH}</h2><p class="section-lead">${H.featLead}</p>
  <div class="grid3">${H.features.map(([k, h, d]) => `<div class="card">${ico(k)}<h3>${h}</h3><p>${d}</p></div>`).join('')}</div>
</div></section>
<section class="section"><div class="wrap">
  <h2>${H.howH}</h2>
  <ol class="steps">${H.how.map(([h, d], i) => `<li><span class="num">${i + 1}</span><h3>${h}</h3><p>${d}</p></li>`).join('')}</ol>
  <p class="center"><a class="link" href="${p(lang, '/guide/')}">${t.guide} →</a></p>
</div></section>
<section class="section alt"><div class="wrap narrow">
  <h2>${H.cmpH}</h2>
  <div class="table-wrap"><table class="cmp"><thead><tr>${H.cmpRows[0].map((c) => `<th>${c}</th>`).join('')}</tr></thead><tbody>${H.cmpRows.slice(1).map((r) => `<tr>${r.map((c, i) => (i ? `<td>${c}</td>` : `<th scope="row">${c}</th>`)).join('')}</tr>`).join('')}</tbody></table></div>
</div></section>
<section class="section"><div class="wrap narrow">
  <h2>${H.faqH}</h2><div class="faq">${faqHtml(H.faq)}</div>
</div></section>
<section class="band"><div class="wrap center">
  <h2>${H.bandH}</h2><p>${H.bandLead}</p><div class="cta-row center">${macBtn(lang, 'light')}</div><p class="hero-note">${iosBadge(lang)}</p>
</div></section>`,
  });

  // Demo page
  page({
    lang, path: p(lang, '/demo/'), alt: both('/demo/'), cur: '/demo/',
    title: lang === 'zh' ? 'OM Photos 線上 Demo｜試玩相機照片匯入' : 'OM Photos live demo | Try importing camera photos',
    description: lang === 'zh' ? '不用安裝，在瀏覽器試玩 OM Photos：瀏覽相機照片、篩選 RAW 與影片、多選匯入、刪除記憶卡照片。' : 'Try OM Photos in your browser, nothing to install: browse camera photos, filter RAW and video, import a selection and delete from the card.',
    graph: [crumbs([home, { name: 'Demo', path: p(lang, '/demo/') }])],
    scripts: demoScript,
    body: `<section class="page-head"><div class="wrap">${crumbHtml([home, { name: 'Demo', path: p(lang, '/demo/') }])}
<h1>${lang === 'zh' ? '線上試玩 OM Photos' : 'Try OM Photos online'}</h1><p class="section-lead">${H.demoLead}</p></div></section>
<section class="section tight"><div class="wrap">${demoBlock(lang)}
<div class="cta-row center">${macBtn(lang)}<a class="btn" href="${p(lang, '/guide/')}">${t.guide}</a></div></div></section>`,
  });

  // Download page
  const D = lang === 'zh' ? {
    title: '下載 OM Photos Mac 版（免費）', description: `下載 OM Photos ${cfg.mac.version}，免費的 OM System／Olympus 相機照片匯入 App，支援 ${cfg.mac.requires} 以上的 Apple 晶片與 Intel Mac。iPhone、iPad 版即將推出。`,
    h1: '下載 OM Photos', macH: 'Mac', macD: `版本 ${cfg.mac.version} · ${cfg.mac.size} · ${cfg.mac.requires} 以上 · Apple 晶片與 Intel`,
    first: '第一次開啟', firstSteps: ['打開 DMG，把 OM Photos 拖到「應用程式」。', '打開 OM Photos；看到「無法打開」時按「完成」。', '到「系統設定 › 隱私權與安全性」，在 OM Photos 旁按「強制打開」。只需要做一次。'],
    firstWhy: '這個版本沒有 Apple 開發者簽章，所以 macOS 會先擋一次。',
    iosH: 'iPhone · iPad', iosD: '開發中，即將推出。和 Mac 版一樣能掃 QR code 配對、瀏覽、篩選、匯入到照片圖庫與刪除。',
    more: '安裝教學',
  } : {
    title: 'Download OM Photos for Mac (free)', description: `Download OM Photos ${cfg.mac.version}, the free photo import app for OM System and Olympus cameras, for Apple silicon and Intel Macs running ${cfg.mac.requires} or later. iPhone and iPad coming soon.`,
    h1: 'Download OM Photos', macH: 'Mac', macD: `Version ${cfg.mac.version} · ${cfg.mac.size} · ${cfg.mac.requires} or later · Apple silicon and Intel`,
    first: 'First launch', firstSteps: ['Open the DMG and drag OM Photos to Applications.', 'Open OM Photos; when macOS says it cannot be opened, click Done.', 'Go to System Settings › Privacy & Security and click Open Anyway next to OM Photos. You only do this once.'],
    firstWhy: 'This build is not signed with an Apple Developer ID, so macOS blocks it once.',
    iosH: 'iPhone · iPad', iosD: 'In development, coming soon: pair with a QR code, browse, filter, import to your Photos library and delete, just like on the Mac.',
    more: 'Installation guide',
  };
  page({
    lang, path: p(lang, '/download/'), alt: both('/download/'), cur: '/download/', title: D.title, description: D.description,
    graph: [appLd(lang), crumbs([home, { name: t.download, path: p(lang, '/download/') }])],
    body: `<section class="page-head"><div class="wrap">${crumbHtml([home, { name: t.download, path: p(lang, '/download/') }])}<h1>${D.h1}</h1></div></section>
<section class="section tight"><div class="wrap dl-grid">
  <div class="dl-card main"><img src="/app-icon.png" width="96" height="96" alt=""><h2>${D.macH}</h2><p>${D.macD}</p>${macBtn(lang)}
    <p class="small"><a href="${p(lang, '/guide/install-mac/')}">${D.more}</a></p>
    <div class="first"><h3>${D.first}</h3><ol>${D.firstSteps.map((s) => `<li>${s}</li>`).join('')}</ol><p class="small">${D.firstWhy}</p></div></div>
  <div class="dl-card muted"><div class="phone-ico"><svg viewBox="0 0 24 24" width="64" height="64" aria-hidden="true"><rect x="6.5" y="2" width="11" height="20" rx="2.6" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M10.5 19h3" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg></div><h2>${D.iosH}</h2><p>${D.iosD}</p><span class="btn disabled" aria-disabled="true">Coming soon</span></div>
</div></section>`,
  });

  // Guides index
  const gIdx = { name: t.guides, path: p(lang, '/guide/') };
  const groupsHtml = Object.entries(t.groups).map(([g, name]) => {
    const list = guides[lang].filter((x) => x.group === g);
    return list.length ? `<div class="g-group"><h2>${name}</h2>${list.map((x) => `<a class="g-item" href="${p(lang, `/guide/${x.slug}/`)}"><span class="g-num">${x.order}</span><span><b>${esc(x.title)}</b><small>${esc(x.description)}</small></span></a>`).join('')}</div>` : '';
  }).join('');
  page({
    lang, path: p(lang, '/guide/'), alt: both('/guide/'), cur: '/guide/',
    title: lang === 'zh' ? 'OM Photos 使用教學｜從連線、匯入到刪除照片' : 'OM Photos guides | From connecting to importing and deleting photos',
    description: lang === 'zh' ? 'OM Photos 完整教學：安裝 Mac 版、掃 QR code 配對相機、Wi-Fi 與 USB-C 連線、瀏覽篩選、匯入照片到 Mac、刪除記憶卡照片與疑難排解。' : 'Complete OM Photos guides: install the Mac app, pair your camera with a QR code, connect over Wi-Fi or USB-C, browse and filter, import to your Mac, delete from the card, and troubleshooting.',
    graph: [crumbs([home, gIdx]), { '@type': 'ItemList', itemListElement: guides[lang].map((x, i) => ({ '@type': 'ListItem', position: i + 1, url: SITE + p(lang, `/guide/${x.slug}/`), name: x.title })) }],
    body: `<section class="page-head"><div class="wrap">${crumbHtml([home, gIdx])}<h1>${lang === 'zh' ? '使用教學' : 'How-to guides'}</h1><p class="section-lead">${lang === 'zh' ? '從安裝、連接相機，到匯入與刪除照片，照順序看一遍就會用。' : 'From installing and connecting your camera to importing and deleting photos, in order.'}</p></div></section>
<section class="section tight"><div class="wrap narrow">${groupsHtml}</div></section>`,
  });

  // Guide pages
  guides[lang].forEach((g, i) => {
    const path = p(lang, `/guide/${g.slug}/`);
    const { html, heads } = md(g.body, lang);
    const prev = guides[lang][i - 1]; const next = guides[lang][i + 1];
    const trail = [home, gIdx, { name: g.title, path }];
    page({
      lang, path, alt: both(`/guide/${g.slug}/`), cur: '/guide/', ogType: 'article',
      title: `${g.title}｜OM Photos ${t.guides}`.replace('｜', lang === 'en' ? ' | ' : '｜'), description: g.description,
      graph: [crumbs(trail), { '@type': 'TechArticle', headline: g.title, description: g.description, inLanguage: LANGS[lang].hreflang, dateModified: today, author: { '@type': 'Organization', name: 'OM Photos' }, publisher: orgLd, mainEntityOfPage: SITE + path, about: { '@type': 'SoftwareApplication', name: 'OM Photos' } }],
      body: `<section class="page-head"><div class="wrap narrow">${crumbHtml(trail)}<p class="eyebrow">${t.groups[g.group]}</p><h1>${esc(g.title)}</h1><p class="section-lead">${esc(g.description)}</p></div></section>
<section class="section tight"><div class="wrap article-grid">
<aside class="toc"><h4>${t.onPage}</h4>${heads.map((h) => `<a href="#${h.id}">${esc(h.text)}</a>`).join('')}<h4>${t.allGuides}</h4>${guides[lang].map((x) => `<a href="${p(lang, `/guide/${x.slug}/`)}"${x.slug === g.slug ? ' aria-current="page"' : ''}>${esc(x.title.split(/[（(]/)[0].trim())}</a>`).join('')}</aside>
<article class="prose">${html}
<nav class="pager">${prev ? `<a href="${p(lang, `/guide/${prev.slug}/`)}"><small>${t.prev}</small>${esc(prev.title)}</a>` : '<span></span>'}${next ? `<a class="next" href="${p(lang, `/guide/${next.slug}/`)}"><small>${t.next}</small>${esc(next.title)}</a>` : '<span></span>'}</nav>
<div class="cta-box"><div><b>OM Photos</b><p>${t.macNote}</p></div>${macBtn(lang)}</div>
</article></div></section>`,
    });
  });

  // Privacy
  const P = lang === 'zh' ? {
    title: '隱私權政策｜OM Photos', h1: '隱私權政策', description: 'OM Photos App 與 om-photos.app 網站如何處理你的資料。',
    body: `<p>更新日期：${today}</p>
<h2>OM Photos App</h2><ul><li>OM Photos 沒有帳號，也不收集你的照片、相機資料或使用紀錄。</li><li>照片直接從相機傳到你的 Mac（或 iPhone、iPad），不經過我們的伺服器。</li><li>相機的 Wi-Fi 名稱和密碼只存在你裝置的鑰匙圈；使用 iCloud 鑰匙圈的版本會由 Apple 同步到你自己的裝置。</li><li>App 只在你連線時和相機溝通，不會連到其他網路服務。</li></ul>
<h2>這個網站</h2><ul><li>網站使用 Google Analytics 4 統計造訪次數、來源與點擊（例如下載按鈕），以改善網站內容。Google 會使用 Cookie，資料以統計形式呈現，我們不會用來辨識個人。你可以用瀏覽器設定或 <a href="https://tools.google.com/dlpage/gaoptout" rel="noopener" target="_blank">Google Analytics 停用外掛程式</a>拒絕。</li><li>下載檔案由 GitHub 提供。</li></ul>
<h2>聯絡</h2><p>有任何問題請寫信到 <a href="mailto:${cfg.contactEmail}">${cfg.contactEmail}</a>。</p>`,
  } : {
    title: 'Privacy policy | OM Photos', h1: 'Privacy policy', description: 'How the OM Photos app and the om-photos.app website handle your data.',
    body: `<p>Last updated: ${today}</p>
<h2>The OM Photos app</h2><ul><li>OM Photos has no account and does not collect your photos, camera data or usage.</li><li>Photos go straight from your camera to your Mac (or iPhone, iPad), never through our servers.</li><li>The camera’s Wi-Fi name and password are kept in your device’s keychain; builds that use iCloud Keychain are synced by Apple to your own devices.</li><li>The app only talks to your camera while connected and contacts no other online service.</li></ul>
<h2>This website</h2><ul><li>The site uses Google Analytics 4 to count visits, referrers and clicks (such as the download button) to improve the site. Google uses cookies; we see aggregated statistics and do not use them to identify you. You can opt out in your browser settings or with the <a href="https://tools.google.com/dlpage/gaoptout" rel="noopener" target="_blank">Google Analytics opt-out add-on</a>.</li><li>Downloads are served by GitHub.</li></ul>
<h2>Contact</h2><p>Questions? Email <a href="mailto:${cfg.contactEmail}">${cfg.contactEmail}</a>.</p>`,
  };
  page({ lang, path: p(lang, '/privacy/'), alt: both('/privacy/'), title: P.title, description: P.description, body: `<section class="page-head"><div class="wrap narrow">${crumbHtml([home, { name: P.h1, path: p(lang, '/privacy/') }])}<h1>${P.h1}</h1></div></section><section class="section tight"><div class="wrap narrow prose">${P.body}</div></section>` });
}

// 404 (shared)
page({ lang: 'zh', path: '/404/', file: '404.html', noindex: true, title: '找不到頁面｜OM Photos', description: '找不到這個頁面。OM Photos：把 OM SYSTEM 相機裡的照片一鍵帶到 Mac。', body: `<section class="section"><div class="wrap narrow center"><img src="/logo-mark.png" width="160" height="113" alt=""><h1>找不到這個頁面 · Page not found</h1><p><a class="btn primary" href="/">回首頁</a> <a class="btn" href="/en/">Home (English)</a></p></div></section>` });

// sitemap + robots
const urls = registry.map((r) => `<url><loc>${SITE + r.path}</loc><lastmod>${today}</lastmod>${Object.entries(r.alt).map(([l, u]) => `<xhtml:link rel="alternate" hreflang="${LANGS[l].hreflang}" href="${SITE + u}"/>`).join('')}${r.alt.zh ? `<xhtml:link rel="alternate" hreflang="x-default" href="${SITE + r.alt.zh}"/>` : ''}</url>`).join('\n');
writeFileSync(join(out, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n${urls}\n</urlset>\n`);
writeFileSync(join(out, 'robots.txt'), `User-agent: *\nAllow: /\n\nSitemap: ${SITE}/sitemap.xml\n`);
console.log(`built ${registry.length} pages`);
