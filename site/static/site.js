// Mobile menu and download tracking.
document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-menu]');
  if (b) {
    const nav = document.querySelector('.nav');
    const open = nav.classList.toggle('open');
    b.setAttribute('aria-expanded', String(open));
  }
  const dl = e.target.closest('a[data-dl]');
  if (dl && typeof window.gtag === 'function') {
    window.gtag('event', 'file_download', { file_name: 'OM-Photos.dmg', link_url: dl.href, platform: dl.getAttribute('data-dl') });
  }
});
