/** 官网版本接口与下载代理；其他页面由静态资源直接响应。 */
const REPO = "https://github.com/funny-dog/FinderRight";
const RELEASE_API = "https://api.github.com/repos/funny-dog/FinderRight/releases/latest";
const DMG_FILES = new Set(["FinderRight.dmg", "FinderRight.dmg.sha256"]);
const VERSIONED_ZIP = /^\/download\/(v\d+\.\d+\.\d+)\/FinderRight-(v\d+\.\d+\.\d+)\.zip(\.sha256)?$/;
const UPSTREAM_TIMEOUT_MS = 30_000;
const GITEE = "https://gitee.com/no_ink_no_book/FinderRight";

function gatewayError(error) {
    const timedOut = error?.name === "AbortError" || error?.name === "TimeoutError";
    return new Response(timedOut ? "Gateway Timeout" : "Bad Gateway", {
        status: timedOut ? 504 : 502,
        headers: { "Cache-Control": "no-store" },
    });
}

function validRelease(data) {
    return data && /^v\d+\.\d+\.\d+$/.test(data.tag_name)
        && typeof data.html_url === "string" && data.html_url.length > 0
        && Array.isArray(data.assets) && data.assets.every(asset =>
            asset && typeof asset.name === "string" && typeof asset.browser_download_url === "string"
            && asset.browser_download_url.length > 0);
}

// API 共享出口可能被 GitHub 限流；正式 Release 跳转与固定校验和不走 API 配额。
async function releaseFromAssets(signal) {
    const latest = await fetch(`${REPO}/releases/latest`, { method: "HEAD", redirect: "manual", signal });
    const location = latest.headers.get("Location");
    const releaseURL = location && new URL(location, REPO);
    const match = releaseURL?.pathname.match(/^\/funny-dog\/FinderRight\/releases\/tag\/(v\d+\.\d+\.\d+)$/);
    if (latest.status !== 302 || releaseURL?.origin !== "https://github.com" || !match) {
        throw new Error("Invalid latest Release redirect");
    }
    const tag = match[1];
    const name = `FinderRight-${tag}.zip`;
    const zipURL = `${REPO}/releases/download/${tag}/${name}`;
    const checksum = await fetch(`${zipURL}.sha256`, { redirect: "follow", signal });
    if (!checksum.ok) throw new Error(`Release checksum HTTP ${checksum.status}`);
    const hash = (await checksum.text()).trim().split(/\s+/)[0];
    if (!/^[a-fA-F0-9]{64}$/.test(hash)) throw new Error("Invalid Release checksum");
    return JSON.stringify({
        tag_name: tag, html_url: releaseURL.href,
        assets: [{ name, browser_download_url: zipURL, digest: `sha256:${hash.toLowerCase()}` }],
    });
}

async function latestRelease(request, url, ctx) {
    // 查询串不改变版本信息，避免相同接口产生大量缓存键。
    const key = new Request(new URL("/update/latest.json", url.origin), { method: "GET" });
    const cache = globalThis.caches?.default;
    let response;
    try {
        response = await cache?.match(key);
    } catch (error) {
        console.error("release cache read failed", error);
    }
    if (!response) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
        try {
            const upstream = await fetch(RELEASE_API, {
                headers: { "User-Agent": "FinderRight-Worker", Accept: "application/vnd.github.v3+json" },
                signal: controller.signal,
            });
            let text;
            if (upstream.status === 403 || upstream.status === 429) {
                console.error("release API restricted; using fixed assets", upstream.status);
                await upstream.body?.cancel();
                text = await releaseFromAssets(controller.signal);
            } else {
                if (!upstream.ok) {
                    console.error("release upstream status", upstream.status);
                    return gatewayError({ name: upstream.status === 504 ? "TimeoutError" : "Error" });
                }
                // 超时覆盖读取 JSON，防止只返回响应头的上游一直挂起。
                text = await upstream.text();
            }
            if (!validRelease(JSON.parse(text))) return gatewayError();
            response = new Response(text, {
                headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=120" },
            });
            if (cache) {
                const write = cache.put(key, response.clone()).catch(error => console.error("release cache write failed", error));
                // 缓存写入不阻塞发给 App 的版本响应。
                if (ctx) ctx.waitUntil(write);
                else await write;
            }
        } catch (error) {
            console.error("release upstream failed", error);
            return gatewayError(error);
        } finally {
            clearTimeout(timer);
        }
    }
    return request.method === "HEAD" ? new Response(null, response) : response;
}

// 国内直连 Cloudflare 只有几 KB/s；已同步到 Gitee 的安装包改由 Gitee 发行版提供。
// 校验和仍由官网提供，与安装包来自不同主机；标记缺失或版本不一致时照常走官网镜像。
async function giteeDownloadURL(request, name, version, env) {
    if (request.cf?.country !== "CN" || name.endsWith(".sha256") || !env?.ASSETS) return null;
    try {
        const marker = await env.ASSETS.fetch(new Request(new URL("/download/gitee-latest.txt", request.url)));
        if (!marker.ok) {
            await marker.body?.cancel();
            return null;
        }
        const tag = (await marker.text()).trim();
        if (!/^v\d+\.\d+\.\d+$/.test(tag) || (version && version !== tag)) return null;
        return `${GITEE}/releases/download/${tag}/${name}`;
    } catch (error) {
        console.error("gitee marker failed", error);
        return null;
    }
}

async function download(request, name, version, env) {
    const gitee = await giteeDownloadURL(request, name, version, env);
    if (gitee) {
        return new Response(null, {
            status: 302,
            headers: { Location: gitee, "Cache-Control": "no-store", "X-FinderRight-Download-Source": "gitee" },
        });
    }
    const upstreamURL = version ? `${REPO}/releases/download/${version}/${name}` : `${REPO}/releases/latest/download/${name}`;
    // 固定版本错误交给 App 切换；网页 DMG 保留现有 302 降级。
    const failure = error => version ? gatewayError(error) : new Response(null, {
        status: 302,
        headers: { Location: upstreamURL, "Cache-Control": "no-store" },
    });
    const headers = new Headers();
    const range = request.headers.get("Range");
    if (range) headers.set("Range", range);
    let upstream;
    let source = "github";
    if (env?.ASSETS) {
        try {
            const assetHeaders = new Headers(request.headers);
            assetHeaders.set("Accept-Encoding", "identity");
            const asset = await env.ASSETS.fetch(new Request(request, { headers: assetHeaders }));
            if (asset.ok || asset.status === 304 || asset.status === 416) {
                // HEAD 原样返回资产响应，避免构造空响应改变平台元数据。
                if (request.method === "HEAD") return asset;
                upstream = asset;
                source = "cloudflare-assets";
            } else {
                await asset.body?.cancel();
            }
        } catch (error) {
            console.error("download mirror failed", error);
        }
    }
    if (!upstream) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
        try {
            upstream = await fetch(upstreamURL, {
                method: request.method, headers, redirect: "follow", signal: controller.signal,
            });
        } catch (error) {
            console.error("download upstream failed", error);
            return failure(error);
        } finally {
            clearTimeout(timer);
        }
    }
    // Static Assets 可能忽略 Range；由 Cache API 从完整镜像生成 206，保持下载器续传。
    const cache = globalThis.caches?.default;
    const ifRange = request.headers.get("If-Range");
    if (source === "cloudflare-assets" && upstream.status === 200 && range && request.method === "GET"
        && cache && (!ifRange || ifRange === upstream.headers.get("ETag"))) {
        try {
            const url = new URL(request.url);
            url.search = "";
            url.searchParams.set("asset", upstream.headers.get("ETag") || "");
            const key = new Request(url);
            const partialKey = new Request(url, { headers: request.headers });
            let partial = await cache.match(partialKey);
            if (!partial) {
                const full = upstream.clone();
                const fullHeaders = new Headers(full.headers);
                fullHeaders.set("Cache-Control", "public, max-age=31536000, immutable");
                await cache.put(key, new Response(full.body, { headers: fullHeaders }));
                partial = await cache.match(partialKey);
            }
            if (partial) {
                upstream.body?.cancel().catch(error => console.error("unused asset stream failed", error));
                upstream = partial;
            }
        } catch (error) {
            console.error("download range cache failed", error);
        }
    }
    if (upstream.status === 416) {
        const errorHeaders = new Headers(upstream.headers);
        errorHeaders.set("Cache-Control", "no-store");
        return new Response(upstream.body, { status: 416, headers: errorHeaders });
    }
    if (upstream.status === 304) return new Response(null, upstream);
    if (!upstream.ok) return failure({ name: upstream.status === 504 ? "TimeoutError" : "Error" });

    const responseHeaders = new Headers();
    for (const header of ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"]) {
        const value = upstream.headers.get(header);
        if (value) responseHeaders.set(header, value);
    }
    if (name.endsWith(".sha256")) responseHeaders.set("Content-Type", "text/plain; charset=utf-8");
    else {
        responseHeaders.set("Content-Type", name.endsWith(".dmg") ? "application/x-apple-diskimage" : "application/zip");
        responseHeaders.set("Content-Disposition", `attachment; filename="${name}"`);
    }
    if (source === "cloudflare-assets" && cache) responseHeaders.set("Accept-Ranges", "bytes");
    responseHeaders.set("X-FinderRight-Download-Source", source);
    responseHeaders.set("Cache-Control", version ? "public, max-age=31536000, immutable" : "public, max-age=300");
    // 只透传流，避免将整个安装包读入 Worker 内存。
    return new Response(request.method === "HEAD" ? null : upstream.body, {
        status: upstream.status, headers: responseHeaders,
    });
}

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);
        const name = url.pathname.slice("/download/".length);
        const versioned = url.pathname.match(VERSIONED_ZIP);
        const isLatest = url.pathname === "/update/latest.json";
        const isDmg = url.pathname.startsWith("/download/") && DMG_FILES.has(name);
        const isVersioned = versioned && versioned[1] === versioned[2];
        if (!isLatest && !isDmg && !isVersioned) return new Response("Not Found", { status: 404 });
        if (request.method !== "GET" && request.method !== "HEAD") {
            return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
        }
        if (isLatest) return latestRelease(request, url, ctx);
        if (isDmg) return download(request, name, undefined, env);
        return download(request, `FinderRight-${versioned[1]}.zip${versioned[3] || ""}`, versioned[1], env);
    },
};
