# 参与贡献 / Contributing

欢迎通过 [Issues](https://github.com/funny-dog/FinderRight/issues) 反馈问题或提出建议，中英文均可。目前项目由维护者直接提交到 `main`，暂不采用 PR 流程；较大改动请先在 Issue 中讨论。

问题反馈请使用 Bug 模板，提供版本、系统与芯片、权限和扩展状态、复现步骤。安全漏洞请按照 [安全说明](SECURITY.md) 私密报告。

## 开发与验证

项目要求 macOS 13+、Apple Silicon 和 Swift 工具链。沿用原生 Swift 构建方式：

```bash
bash scripts/ci.sh     # Kit 编译与测试、主程序与扩展检查
bash scripts/build.sh  # 需要验证打包时执行，产物在 build/，不自动安装
```

Xcode 构建、签名和安装说明见 [README](README.md)。不要提交签名私钥、证书导出文件、令牌、个人日志或构建产物。

改动应保持范围集中；按风险执行相关验证，提交前说明无法完成的检查。修改应用功能、系统要求或安装步骤时，同步更新 README 中英文内容及官网 `website/dist/`；仅修改网站时，按 [网站说明](website/README.md) 执行轻量检查。

## 发版

版本号分散在三个 Info.plist（`FinderRight`、`FinderRightSync`、`FinderRightPreview`），必须一致；`CFBundleVersion` 每次发版递增。

```bash
bash scripts/release.sh --check         # 只校验：分支、工作区、三处版本号、CI 状态
bash scripts/release.sh 1.9.0           # bump → ci.sh → 提交 → 打 tag → RELEASE=1 构建
bash scripts/release.sh 1.9.0 --publish # 继续推送 main 与 tag，并创建 draft Release
```

日常 `bash scripts/build.sh` 只写 `build/`，不会碰仓库根目录已发布的 `FinderRight.dmg` 与 `FinderRight-v<版本>.zip`；`RELEASE=1` 或经 `release.sh` 才会生成发布件。Release 资产名必须保持 `FinderRight.dmg`、`FinderRight-v<版本>.zip`、`FinderRight-v<版本>.zip.sha256`：`UpdateChecker` 按前者下载、按后者校验。draft Release 建好后补完更新说明再点 Publish。

正式 Release 发布后，同步维护 [Homebrew Tap](https://github.com/funny-dog/homebrew-tap#维护-cask)：下载该版本 ZIP 和 `.sha256` 并校验，更新 `Casks/finderright.rb` 的 `version` 与 ZIP 的 `sha256`，复核签名、架构和系统要求，运行 Tap README 中的 style、audit、fetch 检查后提交推送。Tap 直接安装同一份正式 ZIP，保持发布证书不变；此步骤不需要重新打包 App。不要在正式 Release 公开前让 Tap 指向新版本。

正式 Release 公开后，在 `website/` 执行 `bash ../scripts/sync-website-downloads.sh`，再执行 `bash ../scripts/sync-gitee-release.sh`：自动把 GitHub 的 `main` 与本次标签推到 Gitee，并把同一批资产同步到 Gitee 发行版（国内下载）。令牌取环境变量 `GITEE_TOKEN`，未设置时读钥匙串（`security add-generic-password -U -s finderright-gitee -a gitee -w` 存入一次即可），最后按 [官网部署说明](website/README.md#cloudflare-部署) 部署。镜像同步会校验原始发布资产，不能跳过同步后直接部署空目录；Gitee 同步失败时可照常部署，国内下载会留在官网镜像。

## English

After publishing a release, run `bash ../scripts/sync-website-downloads.sh` from `website/`, then `bash ../scripts/sync-gitee-release.sh`, which pushes GitHub's `main` and the release tag to Gitee and copies the same assets to the Gitee release used for downloads in mainland China (the token comes from `GITEE_TOKEN` or the login keychain item `finderright-gitee`), then deploy as described in the website README. Sync verifies the official assets before updating the mirror. Run it before every deployment so an empty or outdated local download directory cannot replace the live mirror.

Please use [Issues](https://github.com/funny-dog/FinderRight/issues) for bugs and suggestions. Chinese and English are welcome. Maintainers currently commit directly to `main`; the project does not use a PR workflow. Discuss larger changes in an issue first. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Development requires macOS 13+, Apple Silicon, and the Swift toolchain. Run `bash scripts/ci.sh` for application checks. Run `bash scripts/build.sh` when packaging needs verification; it writes to `build/` without installing the app. See the README for Xcode and signing instructions.

Keep changes focused and verification proportional to risk. State any checks you could not run. Keep both README languages and the website consistent when changing user-facing behavior. Follow `website/README.md` for website-only checks. Never commit signing keys, exported certificates, tokens, personal logs, or build artifacts.

For releases: the version lives in three Info.plist files (`FinderRight`, `FinderRightSync`, `FinderRightPreview`) and must match, with `CFBundleVersion` bumped every time. `scripts/release.sh --check` verifies the branch, a clean tree, the three plists and CI; `scripts/release.sh <x.y.z>` bumps, runs CI, commits, tags and builds with `RELEASE=1`; add `--publish` to push and open a draft release. A plain `scripts/build.sh` only writes to `build/` and never touches published artifacts. Keep the asset names `FinderRight.dmg`, `FinderRight-v<version>.zip` and its `.sha256` — the updater downloads and verifies exactly those.

After publishing the final Release, update the [Homebrew tap](https://github.com/funny-dog/homebrew-tap#维护-cask): verify the published ZIP against its `.sha256`, update `version` and the ZIP's `sha256` in `Casks/finderright.rb`, and check signing, architecture and macOS requirements. Run the tap README's style, audit and fetch checks, then commit and push. Use the original release ZIP and the same signing certificate; no separate App build is needed. Publish the Release before updating the tap.
