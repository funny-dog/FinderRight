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
```

中文内容在 `dist/index.html`；对应英文在 `data-en` 属性。`dist/script.js` 处理语言切换和安装命令复制，`dist/style.css` 处理桌面与手机布局。

下载按钮使用 GitHub 最新 Release 地址，不写死版本号。应用功能、系统要求和安装说明更新时，应同步核实主仓库 README。

## Cloudflare 部署

使用 Workers 静态托管，配置在 `wrangler.jsonc`，无需构建或后端。

```sh
npx --yes wrangler@4.147.0 login --scopes account:read user:read workers_scripts:write
npx --yes wrangler@4.147.0 deploy --dry-run
npx --yes wrangler@4.147.0 deploy
```

从网站目录执行。首次发布前确认登录账号及同名 Worker，避免覆盖已有项目。`wrangler.jsonc` 保存正式域名，后续部署沿用此绑定；账户由 Wrangler 登录状态选择。访客无需登录。修改应用功能、截图或安装要求时，同步更新网站内容；应用发布与网站部署各自执行。

凭据不放入仓库。Wrangler OAuth 凭据由 CLI 保存在用户配置目录；如使用 API Token，通过环境变量 `CLOUDFLARE_API_TOKEN` 提供。`.env*`、`.dev.vars*`、`.wrangler/`、本地日志、私钥和 Sites 项目配置均已忽略。

仅通过配置中的自定义域名公开访问；默认托管地址与预览地址均关闭。仓库主页 About 的 Website 字段维护官网入口。
