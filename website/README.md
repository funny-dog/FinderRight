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
```

中文内容在 `dist/index.html`；对应英文在 `data-en` 属性。`dist/script.js` 处理语言切换、深浅色主题切换和安装命令复制，`dist/style.css` 处理桌面与手机布局。

深浅色主题由 `<html data-theme>` 控制：`dist/index.html` 的内联脚本在首次绘制前按本地记录或系统偏好设置主题，颜色全部定义为 `dist/style.css` 顶部的 CSS 变量，新增颜色时两套主题都要补齐。

下载入口是站内路径 `/download/FinderRight.dmg`，由 `worker/index.js` 代理到 GitHub 最新 Release，不写死版本号；`/download/FinderRight.dmg.sha256` 提供对应校验和，页面下载区链接到它。因为 App 是自签名、未公证，校验和是用户确认安装包未被替换的唯一手段，发版时必须一并上传 `FinderRight.dmg.sha256`（`scripts/build.sh` 生成，`scripts/release.sh` 校验并上传）。应用功能、系统要求和安装说明更新时，应同步核实主仓库 README。

## 下载代理

`worker/index.js` 只处理 `/download/*`。`wrangler.jsonc` 用 `assets.run_worker_first` 把入口限定在这个前缀，其余路径仍由静态资源直接响应，因此 Worker 出错或超额时网站本身照常可用，只有下载受影响。

- 文件名白名单 `FinderRight.dmg` / `FinderRight.dmg.sha256`，避免变成开放代理；只接受 `GET`/`HEAD`。
- 转发 `Range`，保留断点续传（GitHub 资产返回 `206`）。
- 上游超时（30 秒）、抛错或返回非 2xx 时，`302` 跳回 GitHub 的同名资产，下载降级为慢而不是不可用。
- 固定文件名内容随版本变化，`Cache-Control` 只给 5 分钟，避免发版后长时间拿到旧包。

改动 `worker/index.js` 后重新执行 `wrangler deploy` 即可生效；`dist/` 与 Worker 在同一次部署中上传。

## Cloudflare 部署

使用 Workers 静态托管加一个下载代理 Worker，配置在 `wrangler.jsonc`，无需构建步骤。

```sh
npx --yes wrangler@4.147.0 login --scopes account:read user:read workers_scripts:write
npx --yes wrangler@4.147.0 deploy --dry-run
npx --yes wrangler@4.147.0 deploy
```

从网站目录执行。首次发布前确认登录账号及同名 Worker，避免覆盖已有项目。`wrangler.jsonc` 保存正式域名，后续部署沿用此绑定；账户由 Wrangler 登录状态选择。访客无需登录。修改应用功能、截图或安装要求时，同步更新网站内容；应用发布与网站部署各自执行。

凭据不放入仓库。Wrangler OAuth 凭据由 CLI 保存在用户配置目录；如使用 API Token，通过环境变量 `CLOUDFLARE_API_TOKEN` 提供。`.env*`、`.dev.vars*`、`.wrangler/`、本地日志、私钥和 Sites 项目配置均已忽略。

仅通过配置中的自定义域名公开访问；默认托管地址与预览地址均关闭。仓库主页 About 的 Website 字段维护官网入口。
