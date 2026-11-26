// OM Photos — interactive in-browser simulation (no real camera, nothing downloaded).
(() => {
  const root = document.getElementById('demo-app');
  if (!root) return;
  const zh = root.dataset.lang !== 'en';
  const T = zh ? {
    title: 'OM Photos', sources: '來源', wifi: 'OM-3（Wi-Fi）', usb: 'OM SYSTEM（USB）', types: '類型',
    all: '全部', photos: '照片', raw: 'RAW', videos: '影片', locked: '已保護',
    sAll: '全部', sNew: '未匯入', sDone: '已匯入',
    importNew: (n) => `匯入所有新項目（${n}）`, nothingNew: '所有項目都已匯入',
    selected: (n) => `已選取 ${n} 項`, clear: '取消', imp: '匯入', del: '刪除',
    importing: (a, b) => `匯入中 ${a}/${b}`, done: (n) => `已匯入 ${n} 項到「圖片/OM-3」`,
    delTitle: (n) => `從相機刪除 ${n} 項？`, delWarn: (n) => `其中 ${n} 項還沒匯入，刪除後無法復原。`,
    delOk: '刪除', cancel: '取消', deleted: (n) => `已從相機刪除 ${n} 項`, lockedSkip: (n) => `${n} 項已保護，相機不允許刪除`,
    empty: '沒有符合條件的項目', reset: '重設 Demo', hint: '提示：點一下選取，Shift 或 ⌘ 點選可多選，再點一次（或雙擊）打開照片。',
    switched: (s) => `已切換到 ${s}`, folder: '選擇資料夾：圖片/OM-3', video: '影片預覽', of: (a, b) => `${a} / ${b}`,
    wday: ['日', '一', '二', '三', '四', '五', '六'],
  } : {
    title: 'OM Photos', sources: 'Sources', wifi: 'OM-3 (Wi-Fi)', usb: 'OM SYSTEM (USB)', types: 'Types',
    all: 'All', photos: 'Photos', raw: 'RAW', videos: 'Videos', locked: 'Protected',
    sAll: 'All', sNew: 'New', sDone: 'Imported',
    importNew: (n) => `Import all new items (${n})`, nothingNew: 'Everything is imported',
    selected: (n) => `${n} selected`, clear: 'Clear', imp: 'Import', del: 'Delete',
    importing: (a, b) => `Importing ${a}/${b}`, done: (n) => `Imported ${n} items to Pictures/OM-3`,
    delTitle: (n) => `Delete ${n} items from the camera?`, delWarn: (n) => `${n} of them are not imported yet. This cannot be undone.`,
    delOk: 'Delete', cancel: 'Cancel', deleted: (n) => `Deleted ${n} items from the camera`, lockedSkip: (n) => `${n} protected items were skipped by the camera`,
    empty: 'No items match', reset: 'Reset demo', hint: 'Tip: click to select, Shift or ⌘ click for more, click again (or double-click) to open.',
    switched: (s) => `Switched to ${s}`, folder: 'Choose folder: Pictures/OM-3', video: 'Video preview', of: (a, b) => `${a} of ${b}`,
    wday: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
  };

  // 12 sample shots (AI-generated). Missing files fall back to the first one.
  const SHOTS = ['alley', 'mountain', 'portrait', 'food', 'harbor', 'temple', 'coffee', 'forest', 'cat', 'night', 'beach', 'train'];
  const FALLBACK = '01-alley';
  const seed = () => {
    const kinds = ['rawjpg', 'jpg', 'rawjpg', 'jpg', 'mov', 'rawjpg', 'jpg', 'rawjpg', 'jpg', 'mov', 'rawjpg', 'jpg'];
    const days = ['2026-11-22', '2026-11-22', '2026-11-22', '2026-11-22', '2026-11-23', '2026-11-23', '2026-11-23', '2026-11-23', '2026-11-24', '2026-11-24', '2026-11-24', '2026-11-24'];
    return SHOTS.map((s, i) => {
      const n = String(i + 1).padStart(2, '0');
      return {
        id: i, key: `${n}-${s}`, kind: kinds[i], day: days[i],
        name: kinds[i] === 'mov' ? `P${1122 + i}0${n}.MOV` : `P${1122 + i}0${n}.JPG`,
        dur: kinds[i] === 'mov' ? (i === 4 ? '0:18' : '0:42') : '',
        mb: kinds[i] === 'mov' ? (i === 4 ? 48 : 112) : kinds[i] === 'rawjpg' ? 27 : 9,
        locked: i === 7, imported: i < 2,
      };
    });
  };

  let S;
  const reset = () => {
    S = { items: seed(), source: 'wifi', type: 'all', status: 'all', sel: new Set(), anchor: null, busy: null, modal: null, viewer: null, toast: '' };
  };
  reset();

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const missing = new Set(); // sample files that are not published yet
  const fb = (big) => `/demo/${big ? 'd' : 't'}${FALLBACK}.jpg`;
  const img = (it, big) => (missing.has(it.key) ? fb(big) : `/demo/${big ? 'd' : 't'}${it.key}.jpg`);
  const ofType = (it, t) => t === 'all' || (t === 'photos' && it.kind !== 'mov') || (t === 'raw' && it.kind === 'rawjpg') || (t === 'videos' && it.kind === 'mov') || (t === 'locked' && it.locked);
  const visible = () => S.items.filter((it) => ofType(it, S.type) && (S.status === 'all' || (S.status === 'new' ? !it.imported : it.imported)));
  const svg = {
    check: '<svg width="12" height="12" viewBox="0 0 12 12"><path d="M2.5 6.2l2.3 2.3 4.7-5" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    lock: '<svg width="11" height="12" viewBox="0 0 11 12"><rect x="1" y="5" width="9" height="6.5" rx="1.5" fill="#fff"/><path d="M3 5V3.6a2.5 2.5 0 015 0V5" fill="none" stroke="#fff" stroke-width="1.4"/></svg>',
    play: '<svg width="46" height="46" viewBox="0 0 46 46"><circle cx="23" cy="23" r="22" fill="rgba(0,0,0,.45)" stroke="#fff" stroke-width="1.5"/><path d="M18 14l14 9-14 9z" fill="#fff"/></svg>',
  };
  const badge = (it) => it.kind === 'mov' ? `▶ ${it.dur}` : it.kind === 'rawjpg' ? 'RAW+JPG' : 'JPG';
  const dayLabel = (d) => {
    const dt = new Date(d + 'T12:00:00');
    return zh ? `${dt.getMonth() + 1}月${dt.getDate()}日 <span>星期${T.wday[dt.getDay()]}</span>` : `${dt.toLocaleDateString('en', { month: 'short', day: 'numeric' })} <span>${T.wday[dt.getDay()]}</span>`;
  };

  function sidebar() {
    const c = (t) => S.items.filter((it) => ofType(it, t)).length;
    const btn = (k, label, extra) => `<button data-src="${k}" aria-pressed="${S.source === k}">${label}${extra}</button>`;
    const typ = (k, label) => `<button data-type="${k}" aria-pressed="${S.type === k}">${label}<span class="n">${c(k)}</span></button>`;
    return `<aside class="dm-side"><h5>${T.sources}</h5>${btn('wifi', T.wifi, S.source === 'wifi' ? '<span class="dot"></span>' : '')}${btn('usb', T.usb, S.source === 'usb' ? '<span class="dot"></span>' : '')}
<h5>${T.types}</h5>${typ('all', T.all)}${typ('photos', T.photos)}${typ('raw', T.raw)}${typ('videos', T.videos)}${typ('locked', T.locked)}</aside>`;
  }

  function grid(list) {
    if (!list.length) return `<div class="dm-empty">${T.empty}</div>`;
    let out = '', day = null;
    for (const it of list) {
      if (it.day !== day) { if (day) out += '</div>'; day = it.day; out += `<div class="dm-day">${dayLabel(day)}</div><div class="dm-grid">`; }
      const sel = S.sel.has(it.id);
      out += `<div class="dm-cell${sel ? ' sel' : ''}" data-id="${it.id}" role="button" tabindex="0" aria-pressed="${sel}" aria-label="${esc(it.name)}">
<img src="${img(it)}" alt="" draggable="false" data-key="${it.key}">
<span class="dm-badge">${badge(it)}</span>${it.imported ? `<span class="dm-imp" title="${T.sDone}">${svg.check}</span>` : ''}${it.locked ? `<span class="dm-lock">${svg.lock}</span>` : ''}${sel ? `<span class="dm-check">${svg.check}</span>` : ''}</div>`;
    }
    return out + '</div>';
  }

  function footer() {
    if (S.busy) {
      const { done, total } = S.busy;
      return `<div class="dm-foot"><span>${T.importing(done, total)}</span><span class="dm-prog"><i style="width:${Math.round((done / total) * 100)}%"></i></span></div>`;
    }
    if (S.sel.size) {
      return `<div class="dm-foot"><button class="ghost" data-act="clear">${T.clear}</button><span>${T.selected(S.sel.size)}</span><button data-act="import">${T.imp}</button><button class="del" data-act="delete">${T.del}</button></div>`;
    }
    const n = S.items.filter((it) => !it.imported).length;
    return `<div class="dm-foot">${n ? `<button data-act="import-new">${T.importNew(n)}</button>` : `<span class="muted" style="padding-right:10px">${T.nothingNew}</span>`}</div>`;
  }

  function modal() {
    if (!S.modal) return '';
    const ids = S.modal.ids;
    const items = S.items.filter((it) => ids.includes(it.id));
    const notImp = items.filter((it) => !it.imported).length;
    const names = items.slice(0, 5).map((it) => it.name).join('\n') + (items.length > 5 ? `\n…（+${items.length - 5}）` : '');
    return `<div class="dm-modal"><div class="dm-dialog" role="alertdialog" aria-label="${esc(T.delTitle(items.length))}"><h4>${T.delTitle(items.length)}</h4><p>${esc(names)}</p>${notImp ? `<p class="warn">${T.delWarn(notImp)}</p>` : ''}
<div class="row"><button data-act="cancel">${T.cancel}</button><button class="danger" data-act="confirm-delete">${T.delOk}</button></div></div></div>`;
  }

  function viewer(list) {
    if (S.viewer == null) return '';
    const idx = list.findIndex((it) => it.id === S.viewer);
    if (idx < 0) { S.viewer = null; return ''; }
    const it = list[idx];
    return `<div class="dm-viewer"><div class="dm-vtop"><button class="dm-round" data-act="close" aria-label="Close">×</button><div><b>${esc(it.name)}</b><small>${T.of(idx + 1, list.length)} · ${it.mb} MB</small></div><span style="width:34px"></span></div>
<div class="dm-vimg"><img src="${img(it, true)}" alt="" draggable="false" data-key="${it.key}" data-big="1">${it.kind === 'mov' ? `<div class="dm-play">${svg.play}<span>${T.video} · ${it.dur}</span></div>` : ''}
${idx > 0 ? '<button class="dm-arrow l" data-act="prev" aria-label="Previous">‹</button>' : ''}${idx < list.length - 1 ? '<button class="dm-arrow r" data-act="next" aria-label="Next">›</button>' : ''}</div>
<div class="dm-vbtns"><button class="${it.imported ? '' : 'go'}" data-act="v-import">${it.imported ? '✓ ' + T.sDone : T.imp}</button><button class="del" data-act="v-delete">${T.del}</button></div></div>`;
  }

  function render() {
    const list = visible();
    const seg = (k, l) => `<button data-status="${k}" aria-pressed="${S.status === k}">${l}</button>`;
    const scrollTop = root.querySelector('.dm-main')?.scrollTop || 0;
    root.innerHTML = `<div class="dm" role="application" aria-label="OM Photos demo">
<div class="dm-bar"><span class="dm-dots"><i></i><i></i><i></i></span><span class="dm-title">${T.title}</span><div class="dm-seg">${seg('all', T.sAll)}${seg('new', T.sNew)}${seg('done', T.sDone)}</div></div>
<div class="dm-body">${sidebar()}<div class="dm-stage"><div class="dm-main">${grid(list)}</div>${footer()}${viewer(list)}${modal()}${S.toast ? `<div class="dm-toast" role="status">${esc(S.toast)}</div>` : ''}</div></div></div>
<p class="dm-hint">${T.hint} <button class="dm-reset" data-act="reset">${T.reset}</button></p>`;
    const m = root.querySelector('.dm-main');
    if (m) m.scrollTop = scrollTop;
  }

  let toastTimer;
  const toast = (msg) => { S.toast = msg; render(); clearTimeout(toastTimer); toastTimer = setTimeout(() => { S.toast = ''; render(); }, 2600); };

  function runImport(ids) {
    const todo = S.items.filter((it) => ids.includes(it.id) && !it.imported);
    if (!todo.length) { toast(T.nothingNew); return; }
    const mbps = S.source === 'usb' ? 44 : 3.1; // measured on a real OM-3
    const totalMb = todo.reduce((a, it) => a + it.mb, 0);
    const ms = Math.min(4200, Math.max(1200, (totalMb / mbps) * 60)); // sped up for the demo
    S.busy = { done: 0, total: todo.length }; S.sel.clear(); render();
    let i = 0;
    const step = () => {
      todo[i].imported = true; i += 1; S.busy.done = i; render();
      if (i < todo.length) setTimeout(step, ms / todo.length);
      else { S.busy = null; toast(T.done(todo.length)); }
    };
    toast(T.folder);
    setTimeout(step, ms / todo.length);
  }

  function runDelete(ids) {
    const locked = S.items.filter((it) => ids.includes(it.id) && it.locked).length;
    const gone = ids.length - locked;
    S.items = S.items.filter((it) => !ids.includes(it.id) || it.locked);
    S.sel.clear(); S.modal = null;
    if (S.viewer != null && ids.includes(S.viewer)) S.viewer = null;
    toast([gone ? T.deleted(gone) : '', locked ? T.lockedSkip(locked) : ''].filter(Boolean).join(' · '));
  }

  function clickCell(id, e) {
    const list = visible().map((it) => it.id);
    const plain = !e.shiftKey && !e.metaKey && !e.ctrlKey;
    if (plain && S.sel.size === 1 && S.sel.has(id)) { S.viewer = id; render(); return; }
    if (e.shiftKey && S.anchor != null) {
      const a = list.indexOf(S.anchor), b = list.indexOf(id);
      if (a >= 0 && b >= 0) for (let k = Math.min(a, b); k <= Math.max(a, b); k++) S.sel.add(list[k]);
    } else if (e.metaKey || e.ctrlKey || S.sel.size) {
      S.sel.has(id) ? S.sel.delete(id) : S.sel.add(id);
      S.anchor = id;
    } else {
      S.sel = new Set([id]); S.anchor = id;
    }
    render();
  }

  root.addEventListener('click', (e) => {
    if (S.busy) return;
    const t = e.target.closest('button,[data-id]');
    if (!t || !root.contains(t)) return;
    if (t.dataset.src) {
      if (S.source !== t.dataset.src) { S.source = t.dataset.src; toast(T.switched(t.dataset.src === 'usb' ? T.usb : T.wifi)); }
      return;
    }
    if (t.dataset.type) { S.type = t.dataset.type; S.sel.clear(); render(); return; }
    if (t.dataset.status) { S.status = t.dataset.status; S.sel.clear(); render(); return; }
    if (t.dataset.id != null && !t.dataset.act) { clickCell(Number(t.dataset.id), e); return; }
    const list = visible();
    const vi = list.findIndex((it) => it.id === S.viewer);
    switch (t.dataset.act) {
      case 'clear': S.sel.clear(); render(); break;
      case 'import': runImport([...S.sel]); break;
      case 'import-new': runImport(S.items.filter((it) => !it.imported).map((it) => it.id)); break;
      case 'delete': S.modal = { ids: [...S.sel] }; render(); break;
      case 'cancel': S.modal = null; render(); break;
      case 'confirm-delete': runDelete(S.modal.ids); break;
      case 'close': S.viewer = null; render(); break;
      case 'prev': if (vi > 0) { S.viewer = list[vi - 1].id; render(); } break;
      case 'next': if (vi < list.length - 1) { S.viewer = list[vi + 1].id; render(); } break;
      case 'v-import': runImport([S.viewer]); break;
      case 'v-delete': S.modal = { ids: [S.viewer] }; render(); break;
      case 'reset': reset(); render(); break;
    }
  });
  root.addEventListener('error', (e) => {
    const el = e.target;
    if (el.tagName !== 'IMG' || !el.dataset.key || missing.has(el.dataset.key)) return;
    missing.add(el.dataset.key);
    el.src = fb(!!el.dataset.big);
  }, true);
  root.addEventListener('dblclick', (e) => {
    const c = e.target.closest('[data-id]');
    if (c && !S.busy) { S.viewer = Number(c.dataset.id); S.sel = new Set([S.viewer]); render(); }
  });
  root.addEventListener('keydown', (e) => {
    if (S.busy) return;
    const c = e.target.closest('[data-id]');
    if (c && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); S.viewer = Number(c.dataset.id); render(); return; }
    if (S.viewer != null) {
      if (e.key === 'Escape') { S.viewer = null; render(); }
      if (e.key === 'ArrowLeft') root.querySelector('[data-act="prev"]')?.click();
      if (e.key === 'ArrowRight') root.querySelector('[data-act="next"]')?.click();
    } else if (S.modal && e.key === 'Escape') { S.modal = null; render(); }
  });

  render();
})();
