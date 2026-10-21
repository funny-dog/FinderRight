# FinderRight 宣传网站

FinderRight 官网源码，与应用在同一仓库维护，独立部署到 Cloudflare Workers。使用静态 HTML/CSS/JavaScript 和真实应用截图，无需构建工具或后端；`dist/` 中的文件就是可直接编辑和发布的源码。

## 本地预览

```sh
docker run --rm --name finderright-site-preview -p 127.0.0.1:4187:80 \
  -v "$PWD/dist:/usr/share/nginx/html:ro" nginx:alpine
```

在网站目录执行，浏览器访问 `http://localhost:4187`。OrbStack 将此端口映射到本机。

## 检查

```sh
uv run --no-project python check.py
uvx ruff check check.py
node --check dist/script.js
node --check worker/index.js
node worker/test.mjs
```

中文内容在 `dist/index.html`；对应英文在 `data-en` 属性。`dist/script.js` 处理语言切换、深浅色主题切换和安装命令复制，`dist/style.css` 处理桌面与手机布局。

深浅色主题由 `<html data-theme>` 控制：`dist/index.html` 的内联脚本在首次绘制前按本地记录或系统偏好设置主题，颜色全部定义为 `dist/style.css` 顶部的 CSS 变量，新增颜色时两套主题都要补齐。

下载入口是站内路径 `/download/FinderRight.dmg`，优先由 Cloudflare Static Assets 提供已发布安装包，无需为每次下载回源 GitHub；`/download/FinderRight.dmg.sha256` 提供对应校验和。镜像缺失或服务异常时，才使用 GitHub 代理及原有兜底。发版时必须一并上传 `FinderRight.dmg.sha256`（`scripts/build.sh` 生成，`scripts/release.sh` 校验并上传），正式发布后执行下方镜像同步和部署步骤。应用功能、系统要求和安装说明更新时，应同步核实主仓库 README。

## 下载与更新通道代理

`worker/index.js` 处理 `/download/*` 与 `/update/*`。`wrangler.jsonc` 用 `assets.run_worker_first` 把入口限定在这两个前缀，其余路径仍由静态资源直接响应，因此 Worker 出错或超额时网站本身照常可用。

### 最新 DMG 下载

- 路径白名单 `/download/FinderRight.dmg` 与 `/download/FinderRight.dmg.sha256`，避免变成开放代理；只接受 `GET`/`HEAD`。
- 优先从 `ASSETS` 绑定读取官网镜像；Static Assets 忽略 `Range` 时，使用 Cache API 从完整资产生成 `206`，保留断点续传。缓存键包含资产 ETag，避免新旧版本拼接；`If-Range` 不匹配时返回完整文件。
- 镜像缺失或异常才回源 GitHub；GitHub 上游超时（30 秒）、抛错或返回非 2xx 时，`302` 跳回同名资产。
- GET 响应头 `X-FinderRight-Download-Source` 标明 `cloudflare-assets` 或 `github`，DMG 使用 `application/x-apple-diskimage` 类型。HEAD 原样返回资产响应；平台可能省略其 `Content-Length`，文件大小可从 GET 或分片响应的 `Content-Range` 获取。
- 固定文件名内容随版本变化，`Cache-Control` 只给 5 分钟（`public, max-age=300`），避免发版后长时间拿到旧包。

### 固定版本资产代理

- 严格白名单匹配 `/download/vX.Y.Z/FinderRight-vX.Y.Z.zip` 与同名 `.zip.sha256`（严格三段纯数字版本，路径版本与文件名版本必须一致）；只接受 `GET`/`HEAD`。
- 优先读取官网同版本镜像，缺失时回源 GitHub Release 固定版本资产，支持 `Range` 与 `206` 断点续传。
- 成功固定版本设置不可变长缓存（`public, max-age=31536000, immutable`）；提供正确的 `Content-Type`、`Content-Length` 与 `Content-Disposition`；错误不缓存。
- 上游超时或失败返回 `502`/`504`，不 `302` 回退到 GitHub（由 App 客户端自行切换或处理故障）。

### 版本更新检查

- 固定接口 `GET`/`HEAD /update/latest.json`，只代理 GitHub 最新 Release API（`https://api.github.com/repos/funny-dog/FinderRight/releases/latest`），不接受任意 URL。
- 响应兼容 GitHub Release JSON 结构（包含 `tag_name`、`html_url`、`assets`、`browser_download_url`、`digest` 等）。API 返回 403/429 时，改读 GitHub 最新正式 Release 的 302 跳转和该固定版本 ZIP 的 `.sha256`，生成所需版本信息；避免共享出口限流导致官网更新通道不可用，无需保存 GitHub 令牌。
- 校验响应的基本合法结构后，使用显式 Cache API 缓存 120 秒（`public, max-age=120`），降低 GitHub API 限流风险。
- 上游超时、网络异常或返回无效 JSON / 非法结构时返回适当的 `502`/`504`，错误不缓存且不 `302` 降级到 GitHub。

`dist/download/` 由 `scripts/sync-website-downloads.sh` 从最新正式 Release 生成：下载四个原始资产，校验 GitHub digest 和两份校验文件后再更新镜像。构建产物不提交 Git。保留已同步的旧版本 ZIP，供应用按固定版本下载。

## Cloudflare 部署

使用 Workers 静态托管加一个下载与更新 Worker，配置在 `wrangler.jsonc`。每次部署前同步最新正式发布，避免用空镜像目录或旧版本覆盖现有下载。

```sh
npx --yes wrangler@4.147.0 login --scopes account:read user:read workers_scripts:write
bash ../scripts/sync-website-downloads.sh
npx --yes wrangler@4.147.0 deploy --dry-run
npx --yes wrangler@4.147.0 deploy
```

从网站目录执行。首次发布前确认登录账号及同名 Worker，避免覆盖已有项目。`wrangler.jsonc` 保存正式域名，后续部署沿用此绑定；账户由 Wrangler 登录状态选择。访客无需登录。修改应用功能、截图或安装要求时，同步更新网站内容；应用发布与网站部署各自执行。

正式 Release 公开后立即同步并部署官网镜像；同步失败时停止部署，保留现有线上版本。单个镜像文件受 Static Assets 的 25 MiB 限制，超过时脚本会报错，需要改用对象存储。

凭据不放入仓库。Wrangler OAuth 凭据由 CLI 保存在用户配置目录；如使用 API Token，通过环境变量 `CLOUDFLARE_API_TOKEN` 提供。`.env*`、`.dev.vars*`、`.wrangler/`、本地日志、私钥和 Sites 项目配置均已忽略。

仅通过配置中的自定义域名公开访问；默认托管地址与预览地址均关闭。仓库主页 About 的 Website 字段维护官网入口。
