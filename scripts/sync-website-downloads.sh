#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 0 ] || { echo "用法：sync-website-downloads.sh（无参数，同步最新正式发布）" >&2; exit 2; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$PROJECT_DIR" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise SystemExit("错误：" + message)


repo = "funny-dog/FinderRight"
data = json.loads(subprocess.check_output([
    "gh", "release", "view", "--repo", repo,
    "--json", "tagName,isDraft,isPrerelease,assets",
]))
require(isinstance(data, dict), "Release 元数据不是对象")
require(data.get("isDraft") is False and data.get("isPrerelease") is False, "只同步正式发布")
tag = data.get("tagName")
require(isinstance(tag, str) and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "版本必须为 vX.Y.Z")
zip_name = f"FinderRight-{tag}.zip"
names = ["FinderRight.dmg", "FinderRight.dmg.sha256", zip_name, zip_name + ".sha256"]
assets = data.get("assets")
require(isinstance(assets, list), "缺少资产列表")
selected = [a for a in assets if isinstance(a, dict) and a.get("name") in names]
require(len(selected) == 4 and {a["name"] for a in selected} == set(names), "四个资产必须齐备且无重复")
assets = {a["name"]: a for a in selected}
limit = 25 * 1024 * 1024
for name, asset in assets.items():
    require(asset.get("state") == "uploaded", f"{name} 尚未上传完成")
    require(re.fullmatch(r"sha256:[0-9a-fA-F]{64}", str(asset.get("digest"))), f"{name} 缺少合法 SHA-256 digest")
    size = asset.get("size")
    require(type(size) is int and 0 <= size <= limit, f"{name} 大小非法或超过 25 MiB")

with tempfile.TemporaryDirectory(prefix="finderright-mirror-") as folder:
    source = Path(folder)
    command = ["gh", "release", "download", tag, "--repo", repo, "--dir", folder]
    for name in names:
        command += ["--pattern", name]
    subprocess.run(command, check=True)
    hashes = {}
    for name in names:
        path = source / name
        require(path.is_file() and path.stat().st_size == assets[name]["size"], f"{name} 缺失或大小不符")
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        require(assets[name]["digest"].lower() == "sha256:" + hashes[name], f"{name} digest 不符")
    for name in ["FinderRight.dmg", zip_name]:
        fields = (source / (name + ".sha256")).read_text().split()
        require(fields == [hashes[name], name], f"{name} 校验文件必须引用原文件名并与摘要一致")

    destination = Path(sys.argv[1]) / "website/dist/download"
    staged = []
    try:
        for name in names:
            target = destination / name if name.startswith("FinderRight.dmg") else destination / tag / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
                temporary = Path(output.name)
            staged.append((temporary, target))
            shutil.copyfile(source / name, temporary)
        for temporary, target in staged:
            temporary.replace(target)
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)
print(f"已同步 {tag} 的四个原始发布资产，SHA-256 校验通过")
PY
