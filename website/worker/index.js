/**
 * /download/* 下载代理。
 *
 * 目的：让访客只连 finderright.erhuerhu.dpdns.org，不直连 github.com。
 * GitHub 的 Release 资产按固定文件名寻址（FinderRight.dmg 每次发版都被替换），
 * 所以这里不需要知道版本号，永远跟随 latest。
 *
 * 只有 /download/* 会进入本脚本（wrangler.jsonc 里用 run_worker_first 限定），
 * 其余路径仍由静态资源直接响应，Worker 挂掉不影响网站本身。
 */

const REPO = "https://github.com/funny-dog/FinderRight";
const LATEST = `${REPO}/releases/latest/download`;

/** 允许代理的文件名，白名单避免变成任意 URL 的开放代理。 */
const FILES = new Set(["FinderRight.dmg", "FinderRight.dmg.sha256"]);

/** 上游拉取超时；超时即降级，避免用户对着空白页等待。 */
const UPSTREAM_TIMEOUT_MS = 30_000;

/**
 * 降级出口：上游出问题时跳回 GitHub 对应资产，让访问者仍能拿到文件。
 * 用同名资产而不是固定 DMG，否则 .sha256 会被跳成安装包。
 */
function fallback(name) {
    return new Response(null, {
        status: 302,
        headers: { Location: `${LATEST}/${name}`, "Cache-Control": "no-store" },
    });
}

export default {
    async fetch(request) {
        const url = new URL(request.url);
        const name = url.pathname.slice("/download/".length);

        if (!FILES.has(name)) {
            return new Response("Not Found", { status: 404 });
        }

        // 只读场景，其余方法直接拒绝，避免被当作写入通道。
        if (request.method !== "GET" && request.method !== "HEAD") {
            return new Response("Method Not Allowed", {
                status: 405,
                headers: { Allow: "GET, HEAD" },
            });
        }

        // 转发 Range，保留断点续传能力；GitHub 资产实测支持 206。
        const headers = new Headers();
        const range = request.headers.get("Range");
        if (range) headers.set("Range", range);

        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);

        let upstream;
        try {
            upstream = await fetch(`${LATEST}/${name}`, {
                method: request.method,
                headers,
                redirect: "follow",
                signal: controller.signal,
            });
        } catch (error) {
            clearTimeout(timer);
            console.error("download upstream failed", error);
            return fallback(name);
        }
        clearTimeout(timer);

        // 4xx/5xx 一律降级：包括 GitHub 限流、资产缺失、预签名过期等。
        if (!upstream.ok && upstream.status !== 206) {
            console.error("download upstream status", upstream.status);
            return fallback(name);
        }

        const responseHeaders = new Headers();
        for (const header of ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"]) {
            const value = upstream.headers.get(header);
            if (value) responseHeaders.set(header, value);
        }
        // 校验和直接显示更便于对照；安装包才强制下载。
        if (name.endsWith(".sha256")) {
            responseHeaders.set("Content-Type", "text/plain; charset=utf-8");
        } else {
            responseHeaders.set("Content-Disposition", `attachment; filename="${name}"`);
        }
        // 文件名固定、内容随版本变化，只缓存 5 分钟，避免发版后长时间拿到旧包。
        responseHeaders.set("Cache-Control", "public, max-age=300");

        // 流式透传，不整体读入内存：DMG 有 3.5MB，免费版内存只有 128MB。
        const body = request.method === "HEAD" ? null : upstream.body;
        return new Response(body, { status: upstream.status, headers: responseHeaders });
    },
};
