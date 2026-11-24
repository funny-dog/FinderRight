#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$PROJECT_DIR" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="FinderRight mirror tests ") as folder:
    root = Path(folder)
    project = root / "project with spaces"
    script = project / "scripts/sync-website-downloads.sh"
    script.parent.mkdir(parents=True)
    shutil.copyfile(Path(sys.argv[1]) / "scripts/sync-website-downloads.sh", script)
    mock = root / "bin/gh"
    mock.parent.mkdir()
    mock.write_text('''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
root = Path(os.environ["MIRROR_TEST_ROOT"])
args = sys.argv[1:]
assert args[args.index("--repo") + 1] == "funny-dog/FinderRight"
if args[:2] == ["release", "view"]:
    print((root / "release.json").read_text())
else:
    assert args[:3] == ["release", "download", "v1.10.1"]
    target = Path(args[args.index("--dir") + 1])
    patterns = [args[i + 1] for i, a in enumerate(args) if a == "--pattern"]
    with (root / "downloads.log").open("a") as f:
        f.write(json.dumps(patterns) + "\\n")
    for pattern in patterns:
        shutil.copyfile(root / "assets" / pattern, target / pattern)
''')
    mock.chmod(0o755)
    env = dict(os.environ, PATH=str(mock.parent) + os.pathsep + os.environ["PATH"], MIRROR_TEST_ROOT=str(root))
    source = root / "assets"
    source.mkdir()
    zip_name = "FinderRight-v1.10.1.zip"
    payloads = {"FinderRight.dmg": b"original dmg bytes", zip_name: b"original zip bytes"}
    for name, content in list(payloads.items()):
        payloads[name + ".sha256"] = f"{hashlib.sha256(content).hexdigest()}  {name}\n".encode()
    metadata = {"tagName": "v1.10.1", "isDraft": False, "isPrerelease": False, "assets": []}
    for name, content in payloads.items():
        (source / name).write_bytes(content)
        metadata["assets"].append({"name": name, "state": "uploaded", "size": len(content), "digest": "sha256:" + hashlib.sha256(content).hexdigest()})
    metadata_path = root / "release.json"
    metadata_path.write_text(json.dumps(metadata))
    mirror = project / "website/dist/download"
    history = mirror / "v0.9.0/old.zip"
    history.parent.mkdir(parents=True)
    history.write_bytes(b"keep old version")
    marker = mirror / "gitee-latest.txt"
    marker.write_text("v1.9.0\n")

    def run():
        return subprocess.run(["bash", str(script)], env=env, cwd=root, capture_output=True, text=True)

    result = run()
    assert result.returncode == 0, result.stderr
    for name, content in payloads.items():
        destination = mirror / name if name.startswith("FinderRight.dmg") else mirror / "v1.10.1" / name
        assert destination.read_bytes() == content
    # 旧版本的 Gitee 标记要撤掉；同版本标记保留。
    assert not marker.exists()
    marker.write_text("v1.10.1\n")
    assert run().returncode == 0 and marker.read_text() == "v1.10.1\n"
    before = {p.relative_to(mirror): p.read_bytes() for p in mirror.rglob("*") if p.is_file()}
    cases = ["checksum", "filename", "digest", "size", "oversized", "draft", "prerelease", "tag", "state", "missing"]
    for case in cases:
        data = json.loads(json.dumps(metadata))
        for name, content in payloads.items():
            (source / name).write_bytes(content)
        if case in ["checksum", "filename"]:
            content = (b"0" * 64 + b"  FinderRight.dmg\n") if case == "checksum" else payloads["FinderRight.dmg.sha256"].replace(b"FinderRight.dmg", b"../../other")
            (source / "FinderRight.dmg.sha256").write_bytes(content)
            asset = next(a for a in data["assets"] if a["name"] == "FinderRight.dmg.sha256")
            asset.update(size=len(content), digest="sha256:" + hashlib.sha256(content).hexdigest())
        elif case == "digest": data["assets"][0]["digest"] = "sha256:" + "0" * 64
        elif case == "size": data["assets"][0]["size"] += 1
        elif case == "oversized": data["assets"][0]["size"] = 25 * 1024 * 1024 + 1
        elif case == "draft": data["isDraft"] = True
        elif case == "prerelease": data["isPrerelease"] = True
        elif case == "tag": data["tagName"] = "../../1.10.1"
        elif case == "state": data["assets"][0]["state"] = "new"
        elif case == "missing": data["assets"].pop()
        metadata_path.write_text(json.dumps(data))
        result = run()
        assert result.returncode != 0, case
        after = {p.relative_to(mirror): p.read_bytes() for p in mirror.rglob("*") if p.is_file()}
        assert after == before, f"{case}: existing mirror changed"

    # 本地已存在完全匹配的构建产物时跳过远端下载。
    for name, content in payloads.items():
        (project / name).write_bytes(content)
    (root / "downloads.log").write_text("")
    metadata_path.write_text(json.dumps(metadata))
    for name, content in payloads.items():
        (source / name).write_bytes(content)
    result = run()
    assert result.returncode == 0, result.stderr
    assert (root / "downloads.log").read_text() == "", "命中本地资产时不应该下载"
    assert "本地复用 4 个，远端下载 0 个" in result.stdout

    # 若本地某个资产过期或损坏，仅重下该文件，其余仍复用本地。
    (project / "FinderRight.dmg").write_bytes(b"stale local dmg")
    (root / "downloads.log").write_text("")
    result = run()
    assert result.returncode == 0, result.stderr
    assert [json.loads(line) for line in (root / "downloads.log").read_text().splitlines()] == [["FinderRight.dmg"]]
    assert "本地复用 3 个，远端下载 1 个" in result.stdout
    assert (mirror / "FinderRight.dmg").read_bytes() == payloads["FinderRight.dmg"]
    print("✓ 镜像同步：原始字节、历史版本保留、Gitee 标记更新、本地复用与 10 类校验失败保护均通过")
PY
