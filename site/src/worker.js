// om-photos.app: static site. Assets are served first; only unmatched requests reach here.
const MAC_DMG = 'https://github.com/jimmyLC/OM-Photos/releases/latest/download/OM-Photos.dmg';
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname === 'www.om-photos.app') {
      url.hostname = 'om-photos.app';
      return Response.redirect(url.toString(), 301);
    }
    // Short, stable download link that always points at the newest release.
    if (url.pathname === '/download/mac' || url.pathname === '/download/mac/') {
      return Response.redirect(MAC_DMG, 302);
    }
    const page = await env.ASSETS.fetch(new Request(new URL('/404.html', url), request));
    return new Response(page.body, { status: 404, headers: page.headers });
  },
};
