# 参与贡献 / Contributing

欢迎通过 [Issues](https://github.com/funny-dog/FinderRight/issues) 反馈问题或提出建议，中英文均可。目前项目由维护者直接提交到 `master`，暂不采用 PR 流程；较大改动请先在 Issue 中讨论。

问题反馈请使用 Bug 模板，提供版本、系统与芯片、权限和扩展状态、复现步骤。安全漏洞请按照 [安全说明](SECURITY.md) 私密报告。

## 开发与验证

项目要求 macOS 13+、Apple Silicon 和 Swift 工具链。沿用原生 Swift 构建方式：

```bash
bash scripts/ci.sh     # Kit 编译与测试、主程序与扩展检查
bash scripts/build.sh  # 需要验证打包时执行，产物在 build/，不自动安装
```

Xcode 构建、签名和安装说明见 [README](README.md)。不要提交签名私钥、证书导出文件、令牌、个人日志或构建产物。

改动应保持范围集中；按风险执行相关验证，提交前说明无法完成的检查。修改应用功能、系统要求或安装步骤时，同步更新 README 中英文内容及官网 `website/dist/`；仅修改网站时，按 [网站说明](website/README.md) 执行轻量检查。

## English

Please use [Issues](https://github.com/funny-dog/FinderRight/issues) for bugs and suggestions. Chinese and English are welcome. Maintainers currently commit directly to `master`; the project does not use a PR workflow. Discuss larger changes in an issue first. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Development requires macOS 13+, Apple Silicon, and the Swift toolchain. Run `bash scripts/ci.sh` for application checks. Run `bash scripts/build.sh` when packaging needs verification; it writes to `build/` without installing the app. See the README for Xcode and signing instructions.

Keep changes focused and verification proportional to risk. State any checks you could not run. Keep both README languages and the website consistent when changing user-facing behavior. Follow `website/README.md` for website-only checks. Never commit signing keys, exported certificates, tokens, personal logs, or build artifacts.
