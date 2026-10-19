# 安全说明 / Security policy

## 支持范围

安全修复优先面向最新正式版。请先确认问题是否仍存在于 [最新 Release](https://github.com/funny-dog/FinderRight/releases/latest)。历史版本不承诺提供补丁。

## 私密报告

请通过 GitHub 的 [Report a vulnerability](https://github.com/funny-dog/FinderRight/security/advisories/new) 私密提交安全问题，避免在公开 Issue 中披露尚未修复的漏洞细节。

请提供受影响版本、macOS 版本、复现步骤、预期与实际结果、安全影响，以及必要的最小示例。文件移动、复制和解压问题请使用临时测试文件复现。不要提交真实私人文件、签名私钥、令牌或其他凭据。

适合私密报告的问题包括文件越界写入或意外删除、权限边界绕过、压缩包路径穿越、更新包校验绕过等。普通功能故障、系统授权或扩展开启问题请使用 [Bug 反馈](https://github.com/funny-dog/FinderRight/issues/new/choose)。

## English

Security fixes prioritize the latest stable release; patches for older versions are not guaranteed. Please check the [latest release](https://github.com/funny-dog/FinderRight/releases/latest) before reporting.

Use [Report a vulnerability](https://github.com/funny-dog/FinderRight/security/advisories/new) to report vulnerabilities privately. Include the affected app and macOS versions, reproduction steps, expected and actual results, security impact, and a minimal example. Use disposable test files for file operations. Do not include private files, signing keys, tokens, or other credentials.

Examples include writes outside the intended directory, unintended deletion, permission bypass, archive path traversal, and update integrity bypass. Use the public bug template for ordinary functional or system permission issues. Avoid publishing details of unpatched vulnerabilities in public issues.
