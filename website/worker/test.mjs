import test from "node:test";
import assert from "node:assert/strict";
import worker from "./index.js";

// 内存 Cache 实现，供 stub globalThis.caches.default 使用
class MemoryCache {
    constructor() {
        this.store = new Map();
        this.matchCalls = 0;
        this.putCalls = 0;
    }

    async match(request) {
        this.matchCalls++;
        const key = typeof request === "string" ? request : request.url;
        const entry = this.store.get(key);
        if (!entry) return undefined;
        return entry.clone();
    }

    async put(request, response) {
        this.putCalls++;
        const key = typeof request === "string" ? request : request.url;
        this.store.set(key, response.clone());
    }

    clear() {
        this.store.clear();
        this.matchCalls = 0;
        this.putCalls = 0;
    }
}

const memoryCache = new MemoryCache();
globalThis.caches = {
    default: memoryCache,
};

// 静音测试预期内的 console.error 输出，避免测试输出冗长杂乱
console.error = () => {};

let fetchHandler = null;
globalThis.fetch = async (...args) => {
    if (!fetchHandler) {
        throw new Error("No fetchHandler registered in test");
    }
    return fetchHandler(...args);
};

const BASE_URL = "https://finderright.erhuerhu.dpdns.org";

test.beforeEach(() => {
    memoryCache.clear();
    fetchHandler = null;
});

test("GET /update/latest.json 成功并被 Cache API 缓存 120 秒；第二次命中缓存且不上游 fetch", async () => {
    const validData = {
        tag_name: "v1.2.3",
        html_url: "https://github.com/funny-dog/FinderRight/releases/tag/v1.2.3",
        assets: [
            {
                name: "FinderRight-v1.2.3.zip",
                browser_download_url: "https://github.com/funny-dog/FinderRight/releases/download/v1.2.3/FinderRight-v1.2.3.zip",
                digest: "sha256:1234567890abcdef",
            },
        ],
    };

    let fetchCount = 0;
    fetchHandler = async (url, options) => {
        fetchCount++;
        assert.equal(url, "https://api.github.com/repos/funny-dog/FinderRight/releases/latest");
        assert.equal(options.headers["User-Agent"], "FinderRight-Worker");
        assert.equal(options.headers["Accept"], "application/vnd.github.v3+json");
        return new Response(JSON.stringify(validData), {
            status: 200,
            headers: { "Content-Type": "application/json; charset=utf-8" },
        });
    };

    // 第一次调用：未命中缓存，触发 fetch
    const req1 = new Request(`${BASE_URL}/update/latest.json`);
    const res1 = await worker.fetch(req1);
    assert.equal(res1.status, 200);
    assert.equal(res1.headers.get("Content-Type"), "application/json; charset=utf-8");
    assert.equal(res1.headers.get("Cache-Control"), "public, max-age=120");
    const json1 = await res1.json();
    assert.deepEqual(json1, validData);
    assert.equal(fetchCount, 1);
    assert.equal(memoryCache.putCalls, 1);

    // 第二次调用：命中缓存，fetchCount 仍为 1
    const req2 = new Request(`${BASE_URL}/update/latest.json`);
    const res2 = await worker.fetch(req2);
    assert.equal(res2.status, 200);
    const json2 = await res2.json();
    assert.deepEqual(json2, validData);
    assert.equal(fetchCount, 1, "第二次请求应直接命中 Cache API，不应再次请求上游");
});

test("HEAD /update/latest.json 返回 200 且 body 为空", async () => {
    const validData = {
        tag_name: "v1.2.3",
        html_url: "https://github.com/funny-dog/FinderRight/releases/tag/v1.2.3",
        assets: [
            {
                name: "FinderRight-v1.2.3.zip",
                browser_download_url: "https://github.com/funny-dog/FinderRight/releases/download/v1.2.3/FinderRight-v1.2.3.zip",
            },
        ],
    };

    fetchHandler = async () => new Response(JSON.stringify(validData), { status: 200 });

    const req = new Request(`${BASE_URL}/update/latest.json`, { method: "HEAD" });
    const res = await worker.fetch(req);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Content-Type"), "application/json; charset=utf-8");
    assert.equal(res.headers.get("Cache-Control"), "public, max-age=120");
    const text = await res.text();
    assert.equal(text, "", "HEAD 请求 body 应为空");
});

test("GET /update/latest.json 上游异常处理：网络错误返回 502，不缓存，不 302", async () => {
    fetchHandler = async () => {
        throw new Error("DNS lookup failure");
    };

    const req = new Request(`${BASE_URL}/update/latest.json`);
    const res = await worker.fetch(req);
    assert.equal(res.status, 502);
    assert.notEqual(res.status, 302);
    assert.equal(res.headers.get("Location"), null);
    assert.equal(memoryCache.putCalls, 0, "错误不应写入缓存");
});

test("GET /update/latest.json 上游超时处理：返回 504，不缓存，不 302", async () => {
    fetchHandler = async () => {
        const error = new Error("The operation was aborted");
        error.name = "AbortError";
        throw error;
    };

    const req = new Request(`${BASE_URL}/update/latest.json`);
    const res = await worker.fetch(req);
    assert.equal(res.status, 504);
    assert.notEqual(res.status, 302);
    assert.equal(res.headers.get("Location"), null);
    assert.equal(memoryCache.putCalls, 0, "超时错误不应写入缓存");
});

test("GET /update/latest.json 上游状态错误与无效数据：返回 502，不缓存", async () => {
    // 500 内部服务错误
    fetchHandler = async () => new Response("GitHub 500 Server Error", { status: 500 });
    let res = await worker.fetch(new Request(`${BASE_URL}/update/latest.json`));
    assert.equal(res.status, 502);
    assert.equal(memoryCache.putCalls, 0);

    // 404 未找到
    fetchHandler = async () => new Response(JSON.stringify({ message: "Not Found" }), { status: 404 });
    res = await worker.fetch(new Request(`${BASE_URL}/update/latest.json`));
    assert.equal(res.status, 502);
    assert.equal(memoryCache.putCalls, 0);

    // 200 但返回 HTML / 非合法 JSON
    fetchHandler = async () => new Response("<html>Bad Gateway</html>", { status: 200 });
    res = await worker.fetch(new Request(`${BASE_URL}/update/latest.json`));
    assert.equal(res.status, 502);
    assert.equal(memoryCache.putCalls, 0);

    // 200 且是 JSON，但缺少 tag_name
    fetchHandler = async () =>
        new Response(
            JSON.stringify({
                html_url: "https://github.com/...",
                assets: [],
            }),
            { status: 200 }
        );
    res = await worker.fetch(new Request(`${BASE_URL}/update/latest.json`));
    assert.equal(res.status, 502);
    assert.equal(memoryCache.putCalls, 0);

    // 200 且是 JSON，但 assets 非数组
    fetchHandler = async () =>
        new Response(
            JSON.stringify({
                tag_name: "v1.0.0",
                html_url: "https://github.com/...",
                assets: "invalid",
            }),
            { status: 200 }
        );
    res = await worker.fetch(new Request(`${BASE_URL}/update/latest.json`));
    assert.equal(res.status, 502);
    assert.equal(memoryCache.putCalls, 0);

    // 200 且 assets 中缺少 browser_download_url
    fetchHandler = async () =>
        new Response(
            JSON.stringify({
                tag_name: "v1.0.0",
                html_url: "https://github.com/...",
                assets: [{ name: "foo.zip" }],
            }),
            { status: 200 }
        );
    res = await worker.fetch(new Request(`${BASE_URL}/update/latest.json`));
    assert.equal(res.status, 502);
    assert.equal(memoryCache.putCalls, 0);
});

test("精确固定路径和版本不匹配拒绝（404）", async () => {
    // 路径版本与文件名版本不一致
    let res = await worker.fetch(new Request(`${BASE_URL}/download/v1.0.0/FinderRight-v1.0.1.zip`));
    assert.equal(res.status, 404);

    // 非三段数字版本（两段）
    res = await worker.fetch(new Request(`${BASE_URL}/download/v1.0/FinderRight-v1.0.zip`));
    assert.equal(res.status, 404);

    // 非三段数字版本（四段）
    res = await worker.fetch(new Request(`${BASE_URL}/download/v1.0.0.1/FinderRight-v1.0.0.1.zip`));
    assert.equal(res.status, 404);

    // 缺少前缀 v
    res = await worker.fetch(new Request(`${BASE_URL}/download/1.0.0/FinderRight-1.0.0.zip`));
    assert.equal(res.status, 404);

    // 非白名单文件名
    res = await worker.fetch(new Request(`${BASE_URL}/download/v1.0.0/FinderRight-v1.0.0.tar.gz`));
    assert.equal(res.status, 404);
    res = await worker.fetch(new Request(`${BASE_URL}/download/v1.0.0/other.zip`));
    assert.equal(res.status, 404);

    // /update/ 其它任意路径
    res = await worker.fetch(new Request(`${BASE_URL}/update/something.json`));
    assert.equal(res.status, 404);
    res = await worker.fetch(new Request(`${BASE_URL}/update/`));
    assert.equal(res.status, 404);

    // /download/ 其它任意路径
    res = await worker.fetch(new Request(`${BASE_URL}/download/other.dmg`));
    assert.equal(res.status, 404);
});

test("固定版本资产成功代理：正确 Headers 与不可变长缓存", async () => {
    let capturedUrl = "";
    fetchHandler = async (url) => {
        capturedUrl = url;
        return new Response("binary-zip-content", {
            status: 200,
            headers: {
                "Content-Length": "18",
                ETag: '"etag-123"',
                "Last-Modified": "Wed, 21 Oct 2026 00:00:00 GMT",
            },
        });
    };

    // 1. 请求 .zip
    const zipRes = await worker.fetch(new Request(`${BASE_URL}/download/v2.3.4/FinderRight-v2.3.4.zip`));
    assert.equal(zipRes.status, 200);
    assert.equal(
        capturedUrl,
        "https://github.com/funny-dog/FinderRight/releases/download/v2.3.4/FinderRight-v2.3.4.zip"
    );
    assert.equal(zipRes.headers.get("Content-Type"), "application/zip");
    assert.equal(zipRes.headers.get("Content-Disposition"), 'attachment; filename="FinderRight-v2.3.4.zip"');
    assert.equal(zipRes.headers.get("Content-Length"), "18");
    assert.equal(zipRes.headers.get("ETag"), '"etag-123"');
    assert.equal(zipRes.headers.get("Cache-Control"), "public, max-age=31536000, immutable");
    assert.equal(await zipRes.text(), "binary-zip-content");

    // 2. 请求 .zip.sha256
    fetchHandler = async (url) => {
        capturedUrl = url;
        return new Response("sha256-hash-value", {
            status: 200,
            headers: { "Content-Length": "17" },
        });
    };
    const shaRes = await worker.fetch(new Request(`${BASE_URL}/download/v2.3.4/FinderRight-v2.3.4.zip.sha256`));
    assert.equal(shaRes.status, 200);
    assert.equal(
        capturedUrl,
        "https://github.com/funny-dog/FinderRight/releases/download/v2.3.4/FinderRight-v2.3.4.zip.sha256"
    );
    assert.equal(shaRes.headers.get("Content-Type"), "text/plain; charset=utf-8");
    assert.equal(shaRes.headers.get("Content-Disposition"), null, "sha256 文件不设置 attachment 强制下载");
    assert.equal(shaRes.headers.get("Cache-Control"), "public, max-age=31536000, immutable");
    assert.equal(await shaRes.text(), "sha256-hash-value");
});

test("固定版本资产 Range 转发与 206 状态透传", async () => {
    let capturedRange = null;
    fetchHandler = async (url, options) => {
        capturedRange = options.headers.get("Range");
        return new Response("partial-content", {
            status: 206,
            headers: {
                "Content-Range": "bytes 0-14/100",
                "Content-Length": "15",
                "Accept-Ranges": "bytes",
            },
        });
    };

    const req = new Request(`${BASE_URL}/download/v1.0.0/FinderRight-v1.0.0.zip`, {
        headers: { Range: "bytes=0-14" },
    });
    const res = await worker.fetch(req);
    assert.equal(capturedRange, "bytes=0-14", "应向上游转发 Range 请求头");
    assert.equal(res.status, 206, "应透传 206 状态码");
    assert.equal(res.headers.get("Content-Range"), "bytes 0-14/100");
    assert.equal(res.headers.get("Accept-Ranges"), "bytes");
    assert.equal(await res.text(), "partial-content");
});

test("固定版本资产 HEAD 请求支持", async () => {
    let capturedMethod = "";
    fetchHandler = async (url, options) => {
        capturedMethod = options.method;
        return new Response(null, {
            status: 200,
            headers: {
                "Content-Length": "5000000",
                "Content-Type": "application/zip",
            },
        });
    };

    const req = new Request(`${BASE_URL}/download/v1.0.0/FinderRight-v1.0.0.zip`, {
        method: "HEAD",
    });
    const res = await worker.fetch(req);
    assert.equal(capturedMethod, "HEAD");
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Content-Length"), "5000000");
    assert.equal(res.headers.get("Content-Disposition"), 'attachment; filename="FinderRight-v1.0.0.zip"');
    assert.equal(await res.text(), "", "HEAD 响应 body 必须为空");
});

test("固定版本资产失败绝不 302，返回 502/504", async () => {
    // 1. 网络异常 -> 502
    fetchHandler = async () => {
        throw new Error("Connection reset by peer");
    };
    let res = await worker.fetch(new Request(`${BASE_URL}/download/v1.0.0/FinderRight-v1.0.0.zip`));
    assert.equal(res.status, 502);
    assert.notEqual(res.status, 302);
    assert.equal(res.headers.get("Location"), null);

    // 2. 超时 -> 504
    fetchHandler = async () => {
        const err = new Error("timeout");
        err.name = "AbortError";
        throw err;
    };
    res = await worker.fetch(new Request(`${BASE_URL}/download/v1.0.0/FinderRight-v1.0.0.zip`));
    assert.equal(res.status, 504);
    assert.notEqual(res.status, 302);
    assert.equal(res.headers.get("Location"), null);

    // 3. 上游 404 -> 502（不 302）
    fetchHandler = async () => new Response("Not Found", { status: 404 });
    res = await worker.fetch(new Request(`${BASE_URL}/download/v1.0.0/FinderRight-v1.0.0.zip`));
    assert.equal(res.status, 502);
    assert.notEqual(res.status, 302);
    assert.equal(res.headers.get("Location"), null);

    // 4. 上游 500 -> 502（不 302）
    fetchHandler = async () => new Response("Internal Server Error", { status: 500 });
    res = await worker.fetch(new Request(`${BASE_URL}/download/v1.0.0/FinderRight-v1.0.0.zip`));
    assert.equal(res.status, 502);
    assert.notEqual(res.status, 302);
    assert.equal(res.headers.get("Location"), null);
});

test("现有 DMG 入口行为保留：上游失败时 302 降级到 GitHub", async () => {
    // 1. DMG 上游失败时 302 降级到 GitHub
    fetchHandler = async () => {
        throw new Error("GitHub download network error");
    };
    let res = await worker.fetch(new Request(`${BASE_URL}/download/FinderRight.dmg`));
    assert.equal(res.status, 302);
    assert.equal(
        res.headers.get("Location"),
        "https://github.com/funny-dog/FinderRight/releases/latest/download/FinderRight.dmg"
    );
    assert.equal(res.headers.get("Cache-Control"), "no-store");

    // 2. DMG.sha256 上游非 200 时 302 降级到同名资产
    fetchHandler = async () => new Response("Failed", { status: 500 });
    res = await worker.fetch(new Request(`${BASE_URL}/download/FinderRight.dmg.sha256`));
    assert.equal(res.status, 302);
    assert.equal(
        res.headers.get("Location"),
        "https://github.com/funny-dog/FinderRight/releases/latest/download/FinderRight.dmg.sha256"
    );

    // 3. 现有 DMG 成功时：5 分钟缓存
    fetchHandler = async () =>
        new Response("dmg-data", {
            status: 200,
            headers: { "Content-Length": "8" },
        });
    res = await worker.fetch(new Request(`${BASE_URL}/download/FinderRight.dmg`));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Cache-Control"), "public, max-age=300");
    assert.equal(res.headers.get("Content-Disposition"), 'attachment; filename="FinderRight.dmg"');
    assert.equal(res.headers.get("Content-Type"), "application/x-apple-diskimage");
});

test("官网镜像优先提供四类资产，GitHub 不可用也能下载", async () => {
    fetchHandler = async () => { throw new Error("不应回源 GitHub"); };
    for (const [path, type] of [
        ["/download/FinderRight.dmg", "application/x-apple-diskimage"],
        ["/download/FinderRight.dmg.sha256", "text/plain; charset=utf-8"],
        ["/download/v1.10.1/FinderRight-v1.10.1.zip", "application/zip"],
        ["/download/v1.10.1/FinderRight-v1.10.1.zip.sha256", "text/plain; charset=utf-8"],
    ]) {
        const response = await worker.fetch(new Request(BASE_URL + path), { ASSETS: {
            async fetch(request) {
                assert.equal(new URL(request.url).pathname, path);
                assert.equal(request.headers.get("Accept-Encoding"), "identity");
                return new Response("original release bytes", { headers: { "Content-Length": "22" } });
            },
        } });
        assert.equal(response.status, 200);
        assert.equal(response.headers.get("Content-Type"), type);
        assert.equal(response.headers.get("X-FinderRight-Download-Source"), "cloudflare-assets");
        assert.equal(await response.text(), "original release bytes");
    }
});

test("镜像 HEAD 保留大小，镜像缺失或异常仍可回退 GitHub", async () => {
    let githubCalls = 0;
    fetchHandler = async () => {
        githubCalls++;
        return new Response("github bytes");
    };
    const response = await worker.fetch(new Request(`${BASE_URL}/download/FinderRight.dmg`, { method: "HEAD" }), { ASSETS: {
        async fetch(request) {
            assert.equal(request.method, "HEAD");
            return new Response(null, { headers: { "Content-Length": "4444266" } });
        },
    } });
    assert.equal(await response.text(), "");
    assert.equal(response.headers.get("Content-Length"), "4444266");
    assert.equal(githubCalls, 0);
    for (const fetch of [
        async () => new Response("missing", { status: 404 }),
        async () => new Response("failed", { status: 503 }),
        async () => { throw new Error("assets unavailable"); },
    ]) {
        const fallback = await worker.fetch(new Request(`${BASE_URL}/download/FinderRight.dmg`), { ASSETS: { fetch } });
        assert.equal(await fallback.text(), "github bytes");
        assert.equal(fallback.headers.get("X-FinderRight-Download-Source"), "github");
    }
    assert.equal(githubCalls, 3);
});

test("镜像 Range 被 Static Assets 忽略时交给 Cache API 生成 206", async () => {
    const originalCaches = globalThis.caches;
    let stored = false;
    globalThis.caches = { default: {
        async match(request) {
            assert.equal(request.headers.get("Range"), "bytes=1-2");
            assert.equal(new URL(request.url).searchParams.get("asset"), '"current-digest"');
            if (stored) return new Response("23", { status: 206, headers: { "Content-Range": "bytes 1-2/5", "Content-Length": "2" } });
        },
        async put(request, response) {
            assert.equal(request.headers.get("Range"), null);
            assert.equal(response.status, 200);
            assert.equal(response.headers.get("Content-Length"), "5");
            assert.equal(await response.text(), "12345");
            stored = true;
        },
    } };
    fetchHandler = async () => { throw new Error("不应回源 GitHub"); };
    try {
        const response = await worker.fetch(new Request(`${BASE_URL}/download/FinderRight.dmg`, {
            headers: { Range: "bytes=1-2" },
        }), { ASSETS: { async fetch() {
            return new Response("12345", { headers: { ETag: '"current-digest"', "Content-Length": "5" } });
        } } });
        assert.equal(response.status, 206);
        assert.equal(response.headers.get("Content-Range"), "bytes 1-2/5");
        assert.equal(await response.text(), "23");
    } finally {
        globalThis.caches = originalCaches;
    }
});

test("If-Range 与当前镜像不匹配时返回完整文件，避免跨版本拼接", async () => {
    const response = await worker.fetch(new Request(`${BASE_URL}/download/FinderRight.dmg`, {
        headers: { Range: "bytes=1-2", "If-Range": '"old-digest"' },
    }), { ASSETS: { async fetch() {
        return new Response("12345", { headers: { ETag: '"new-digest"', "Content-Length": "5" } });
    } } });
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "12345");
    assert.equal(memoryCache.putCalls, 0);
});

test("镜像 206/416/304 状态保留，不当作 GitHub 故障", async () => {
    fetchHandler = async () => { throw new Error("不应回源 GitHub"); };
    for (const status of [206, 416, 304]) {
        const response = await worker.fetch(new Request(`${BASE_URL}/download/FinderRight.dmg`), { ASSETS: {
            async fetch() {
                return new Response(null, { status, headers: { "Content-Range": status === 416 ? "bytes */5" : "bytes 0-1/5" } });
            },
        } });
        assert.equal(response.status, status);
        if (status === 416) assert.equal(response.headers.get("Cache-Control"), "no-store");
    }
});

test("只允许 GET/HEAD，其它 HTTP 方法返回 405 (Allow: GET, HEAD)", async () => {
    const methods = ["POST", "PUT", "DELETE", "PATCH"];
    const testPaths = [
        "/update/latest.json",
        "/download/v1.0.0/FinderRight-v1.0.0.zip",
        "/download/v1.0.0/FinderRight-v1.0.0.zip.sha256",
        "/download/FinderRight.dmg",
    ];

    for (const pathname of testPaths) {
        for (const method of methods) {
            const req = new Request(`${BASE_URL}${pathname}`, { method });
            const res = await worker.fetch(req);
            assert.equal(res.status, 405, `${method} ${pathname} 应返回 405`);
            assert.equal(res.headers.get("Allow"), "GET, HEAD");
        }
    }
});

test("版本响应不等待后台缓存写入完成", async () => {
    const originalPut = memoryCache.put;
    let finishWrite;
    const writes = [];
    memoryCache.put = () => new Promise(resolve => { finishWrite = resolve; });
    fetchHandler = async () => new Response(JSON.stringify({
        tag_name: "v1.2.3", html_url: "https://github.com/funny-dog/FinderRight/releases/tag/v1.2.3", assets: [],
    }));
    try {
        const response = await worker.fetch(new Request(`${BASE_URL}/update/latest.json`), {}, {
            waitUntil(promise) { writes.push(promise); },
        });
        assert.equal(response.status, 200);
        assert.equal(writes.length, 1);
        finishWrite();
        await Promise.all(writes);
    } finally {
        memoryCache.put = originalPut;
    }
});

for (const status of [403, 429]) {
    test(`GitHub API ${status} 时通过正式Release跳转和同版本校验和获取版本`, async () => {
        const calls = [];
        const hash = "a".repeat(64);
        fetchHandler = async (url, options) => {
            calls.push(url);
            if (url.startsWith("https://api.github.com/")) return new Response("restricted", { status });
            if (url.endsWith("/releases/latest")) {
                assert.equal(options.method, "HEAD");
                assert.equal(options.redirect, "manual");
                return new Response(null, { status: 302, headers: { Location: "https://github.com/funny-dog/FinderRight/releases/tag/v1.2.3" } });
            }
            assert.equal(url, "https://github.com/funny-dog/FinderRight/releases/download/v1.2.3/FinderRight-v1.2.3.zip.sha256");
            return new Response(`${hash}  FinderRight-v1.2.3.zip`);
        };
        const response = await worker.fetch(new Request(`${BASE_URL}/update/latest.json`));
        assert.equal(response.status, 200);
        const data = await response.json();
        assert.equal(data.tag_name, "v1.2.3");
        assert.equal(data.assets[0].digest, `sha256:${hash}`);
        assert.equal(data.assets[0].browser_download_url, calls[2].slice(0, -7));
        assert.equal(memoryCache.putCalls, 1);
    });
}

test("受限API备用取数拒绝跨仓库跳转和无效校验和，不缓存错误", async () => {
    for (const [location, checksum] of [
        ["https://evil.invalid/funny-dog/FinderRight/releases/tag/v1.2.3", "a".repeat(64)],
        ["https://github.com/other/FinderRight/releases/tag/v1.2.3", "a".repeat(64)],
        ["https://github.com/funny-dog/FinderRight/releases/tag/v1.2.3", "<html>error</html>"],
    ]) {
        fetchHandler = async url => {
            if (url.startsWith("https://api.github.com/")) return new Response("restricted", { status: 429 });
            if (url.endsWith("/releases/latest")) return new Response(null, { status: 302, headers: { Location: location } });
            return new Response(checksum);
        };
        const response = await worker.fetch(new Request(`${BASE_URL}/update/latest.json`));
        assert.equal(response.status, 502);
        assert.equal(memoryCache.putCalls, 0);
    }
});
