#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 0 ] || { echo "用法：GITEE_TOKEN=... sync-gitee-release.sh（无参数，先执行 sync-website-downloads.sh）" >&2; exit 2; }
[ -n "${GITEE_TOKEN:-}" ] || { echo "错误：缺少环境变量 GITEE_TOKEN（Gitee 私人令牌，勿写入仓库）" >&2; exit 2; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$PROJECT_DIR" <<'PY'
"""把官网镜像中已校验的发布资产同步到 Gitee 发行版，供国内下载。

只上传 sync-website-downloads.sh 校验过的本地镜像；全部资产经公开地址回读并核对
SHA-256 后，才写入 gitee-latest.txt，让官网 Worker 开始把国内下载重定向到 Gitee。
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid


def require(condition, message):
    if not condition:
        raise SystemExit("错误：" + message)


project = Path(sys.argv[1])
repo = os.environ.get("GITEE_REPO", "no_ink_no_book/FinderRight")
require(re.fullmatch(r"[\w.-]+/[\w.-]+", repo), "GITEE_REPO 必须形如 owner/repo")
api = os.environ.get("GITEE_API", "https://gitee.com/api/v5") + f"/repos/{repo}"
web = os.environ.get("GITEE_WEB", "https://gitee.com") + f"/{repo}"
# 令牌只放请求头，避免出现在 URL、错误信息或日志里。
auth = {"Authorization": "token " + os.environ["GITEE_TOKEN"], "User-Agent": "FinderRight-Release"}


def call(method, url, data=None, headers=None, authorized=True):
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={**(auth if authorized else {"User-Agent": auth["User-Agent"]}), **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def call_json(method, path, fields=None):
    data = json.dumps(fields).encode() if fields is not None else None
    status, body = call(method, api + path, data, {"Content-Type": "application/json"} if data else None)
    require(200 <= status < 300, f"Gitee {method} {path} 返回 HTTP {status}：{body[:200].decode(errors='replace')}")
    return json.loads(body) if body else None


release = json.loads(subprocess.check_output([
    "gh", "release", "view", "--repo", "funny-dog/FinderRight", "--json", "tagName,isDraft,isPrerelease,body",
]))
require(release.get("isDraft") is False and release.get("isPrerelease") is False, "只同步正式发布")
tag = release.get("tagName")
require(isinstance(tag, str) and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "版本必须为 vX.Y.Z")
zip_name = f"FinderRight-{tag}.zip"
mirror = project / "website/dist/download"
files = {
    "FinderRight.dmg": mirror / "FinderRight.dmg",
    "FinderRight.dmg.sha256": mirror / "FinderRight.dmg.sha256",
    zip_name: mirror / tag / zip_name,
    zip_name + ".sha256": mirror / tag / (zip_name + ".sha256"),
}
hashes = {}
for name, path in files.items():
    require(path.is_file(), f"官网镜像缺少 {name}，请先执行 sync-website-downloads.sh")
    hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
# 镜像必须是当前正式发布：两份校验文件都要与镜像内容一致。
for name in ["FinderRight.dmg", zip_name]:
    require(files[name + ".sha256"].read_text().split() == [hashes[name], name], f"{name} 与镜像校验文件不符，请重新同步官网镜像")

commit = subprocess.check_output(["git", "-C", str(project), "rev-parse", f"{tag}^{{commit}}"], text=True).strip()
tags = call_json("GET", "/tags?per_page=100&sort=updated&direction=desc")
remote = next((t for t in tags if t.get("name") == tag), None)
require(remote, f"Gitee 仓库缺少标签 {tag}，请先在 Gitee 仓库页面从 GitHub 强制同步")
require(remote["commit"]["sha"] == commit, f"Gitee 标签 {tag} 指向的提交与本地不同")

status, body = call("GET", f"{api}/releases/tags/{tag}")
existing = json.loads(body) if status == 200 and body.strip() not in (b"", b"null") else None
if not existing:
    existing = call_json("POST", "/releases", {
        "tag_name": tag, "name": tag, "body": release.get("body") or tag,
        "prerelease": False, "target_commitish": commit,
    })
    print(f"已创建 Gitee 发行版 {tag}")
release_id = existing["id"]


def public_hash(url):
    # 匿名访问公开地址，确认国内用户实际拿到的内容。
    status, body = call("GET", url, authorized=False)
    return hashlib.sha256(body).hexdigest() if status == 200 else None


attached = {a["name"]: a for a in call_json("GET", f"/releases/{release_id}/attach_files?per_page=100")}
for name, path in files.items():
    url = f"{web}/releases/download/{tag}/{name}"
    current = attached.get(name)
    if current and public_hash(url) == hashes[name]:
        continue
    if current:
        call_json("DELETE", f"/releases/{release_id}/attach_files/{current['id']}")
    boundary = uuid.uuid4().hex
    data = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
            "Content-Type: application/octet-stream\r\n\r\n").encode() + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    status, body = call("POST", f"{api}/releases/{release_id}/attach_files", data,
                        {"Content-Type": f"multipart/form-data; boundary={boundary}"})
    require(200 <= status < 300, f"上传 {name} 返回 HTTP {status}：{body[:200].decode(errors='replace')}")
    print(f"已上传 {name}")

for name in files:
    require(public_hash(f"{web}/releases/download/{tag}/{name}") == hashes[name], f"Gitee 公开下载的 {name} 摘要不符")

# 标记文件最后原子写入：Worker 只在标签一致时重定向，未同步完成的版本仍走官网镜像。
marker = mirror / "gitee-latest.txt"
with tempfile.NamedTemporaryFile("w", dir=mirror, delete=False) as output:
    output.write(tag + "\n")
Path(output.name).chmod(0o644)
Path(output.name).replace(marker)
print(f"已同步 {tag} 到 Gitee（{repo}），四个资产公开下载校验通过")
PY
