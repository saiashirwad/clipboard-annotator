// Static site plus one dynamic route: /download sends the visitor to the
// newest zip on the GitHub releases page.

const REPO = "saiashirwad/sendpoint";
const RELEASES_PAGE = `https://github.com/${REPO}/releases/latest`;
const CACHE_SECONDS = 600;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/download") {
      return download(request, ctx);
    }
    return env.ASSETS.fetch(request);
  },
};

async function download(request, ctx) {
  const cache = caches.default;
  const cacheKey = new Request(new URL("/download", request.url), { method: "GET" });
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  const target = (await latestAssetURL()) ?? RELEASES_PAGE;
  const response = new Response(null, {
    status: 302,
    headers: {
      Location: target,
      "Cache-Control": `public, max-age=${CACHE_SECONDS}`,
    },
  });
  ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}

async function latestAssetURL() {
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "sendpoint.app",
      },
    });
    if (!res.ok) return null;
    const release = await res.json();
    const asset = (release.assets ?? []).find((a) => a.name.endsWith(".zip"));
    return asset?.browser_download_url ?? null;
  } catch {
    return null;
  }
}
