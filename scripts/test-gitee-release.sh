#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$PROJECT_DIR" <<'PY'
"""离线验证 sync-gitee-release.sh：绕过代理直连、并发上传/回读、幂等跳过及篡改拦截。"""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlparse

started = time.monotonic()

with tempfile.TemporaryDirectory(prefix="FinderRight gitee tests ") as folder:
    root = Path(folder)
    project = root / "project"
    script = project / "scripts/sync-gitee-release.sh"
    script.parent.mkdir(parents=True)
    shutil.copyfile(Path(sys.argv[1]) / "scripts/sync-gitee-release.sh", script)

    # 初始化带 origin/main 与 tag 的项目仓库，以及作为 Gitee 远端的 bare 仓库。
    subprocess.run(["git", "init", "-b", "main", str(project)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "-C", str(project), "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", str(project), "config", "user.name", "Test"], check=True)
    (project / "README.md").write_text("fixture\n")
    subprocess.run(["git", "-C", str(project), "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(project), "commit", "-m", "init"], check=True, stdout=subprocess.DEVNULL)
    commit = subprocess.check_output(["git", "-C", str(project), "rev-parse", "HEAD"], text=True).strip()
    subprocess.run(["git", "-C", str(project), "tag", "-a", "v1.10.1", "-m", "v1.10.1"], check=True)
    subprocess.run(["git", "-C", str(project), "update-ref", "refs/remotes/origin/main", commit], check=True)

    gitee_bare = root / "gitee.git"
    subprocess.run(["git", "init", "--bare", "-b", "main", str(gitee_bare)], check=True, stdout=subprocess.DEVNULL)

    # 准备官网镜像目录的 4 个资产。
    mirror = project / "website/dist/download"
    tag_dir = mirror / "v1.10.1"
    tag_dir.mkdir(parents=True)
    zip_name = "FinderRight-v1.10.1.zip"
    payloads = {
        "FinderRight.dmg": b"dmg payload bytes",
        zip_name: b"zip payload bytes",
    }
    for name, content in list(payloads.items()):
        payloads[name + ".sha256"] = f"{hashlib.sha256(content).hexdigest()}  {name}\n".encode()

    (mirror / "FinderRight.dmg").write_bytes(payloads["FinderRight.dmg"])
    (mirror / "FinderRight.dmg.sha256").write_bytes(payloads["FinderRight.dmg.sha256"])
    (tag_dir / zip_name).write_bytes(payloads[zip_name])
    (tag_dir / (zip_name + ".sha256")).write_bytes(payloads[zip_name + ".sha256"])

    # 模拟 gh CLI。
    bin_dir = root / "bin"
    bin_dir.mkdir()
    mock_gh = bin_dir / "gh"
    mock_gh.write_text('''#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
assert args[:3] == ["release", "view", "--repo"]
print(json.dumps({"tagName": "v1.10.1", "isDraft": False, "isPrerelease": False, "body": "notes"}))
''')
    mock_gh.chmod(0o755)

    state_lock = threading.Lock()
    state = {
        "release_created": False,
        "attachments": {},
        "next_id": 1,
        "post_count": 0,
        "delete_count": 0,
        "active_uploads": 0,
        "max_concurrent_uploads": 0,
        "public_auth_seen": False,
        "tamper_download": None,
    }
    token = "secret-gitee-token"
    expected_basic = "Basic " + base64.b64encode(f"gitee-user:{token}".encode()).decode()

    class MockGiteeHandler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def send_json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def read_body(self):
            length = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(length) if length > 0 else b""

        def do_GET(self):
            parsed = urlparse(self.path)
            path = parsed.path
            if path == "/api/v5/user":
                assert self.headers.get("Authorization") == f"token {token}"
                return self.send_json(200, {"login": "gitee-user"})
            if path == "/api/v5/repos/test/repo/tags":
                assert self.headers.get("Authorization") == f"token {token}"
                sha = subprocess.check_output(
                    ["git", f"--git-dir={gitee_bare}", "rev-parse", "v1.10.1^{commit}"], text=True
                ).strip()
                return self.send_json(200, [{"name": "v1.10.1", "commit": {"sha": sha}}])
            if path == "/api/v5/repos/test/repo/releases/tags/v1.10.1":
                assert self.headers.get("Authorization") == f"token {token}"
                with state_lock:
                    if not state["release_created"]:
                        return self.send_json(404, {"message": "not found"})
                    return self.send_json(200, {"id": 101, "tag_name": "v1.10.1"})
            if path == "/api/v5/repos/test/repo/releases/101/attach_files":
                assert self.headers.get("Authorization") == f"token {token}"
                with state_lock:
                    items = [{"id": item["id"], "name": name} for name, item in state["attachments"].items()]
                return self.send_json(200, items)
            if path == "/test/repo.git/info/refs":
                assert self.headers.get("Authorization") == expected_basic
                adv = subprocess.check_output(
                    ["git", "receive-pack", "--stateless-rpc", "--advertise-refs", str(gitee_bare)]
                )
                pkt = b"# service=git-receive-pack\n"
                body = f"{len(pkt) + 4:04x}".encode() + pkt + b"0000" + adv
                self.send_response(200)
                self.send_header("Content-Type", "application/x-git-receive-pack-advertisement")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            prefix = "/test/repo/releases/download/v1.10.1/"
            if path.startswith(prefix):
                name = path[len(prefix):]
                with state_lock:
                    if "Authorization" in self.headers:
                        state["public_auth_seen"] = True
                    item = state["attachments"].get(name)
                    tamper = state["tamper_download"]
                if not item:
                    self.send_response(404)
                    self.end_headers()
                    return
                body = item["data"]
                if tamper == name:
                    body = b"TAMPERED-" + body
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(404)
            self.end_headers()

        def do_POST(self):
            parsed = urlparse(self.path)
            path = parsed.path
            raw = self.read_body()
            if path == "/test/repo.git/git-receive-pack":
                assert self.headers.get("Authorization") == expected_basic
                if self.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.decompress(raw)
                out = subprocess.check_output(
                    ["git", "receive-pack", "--stateless-rpc", str(gitee_bare)], input=raw
                )
                self.send_response(200)
                self.send_header("Content-Type", "application/x-git-receive-pack-result")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)
                return
            if path == "/api/v5/repos/test/repo/releases":
                assert self.headers.get("Authorization") == f"token {token}"
                with state_lock:
                    state["release_created"] = True
                return self.send_json(201, {"id": 101, "tag_name": "v1.10.1"})
            if path == "/api/v5/repos/test/repo/releases/101/attach_files":
                assert self.headers.get("Authorization") == f"token {token}"
                ctype = self.headers.get("Content-Type", "")
                m = re.search(r"boundary=([^\s;]+)", ctype)
                assert m, f"missing boundary: {ctype}"
                boundary = m.group(1).encode()
                part = raw.split(b"--" + boundary)[1]
                header_bytes, file_body = part.split(b"\r\n\r\n", 1)
                if file_body.endswith(b"\r\n"):
                    file_body = file_body[:-2]
                fn_match = re.search(rb'filename="([^"]+)"', header_bytes)
                assert fn_match
                name = fn_match.group(1).decode()
                with state_lock:
                    state["active_uploads"] += 1
                    state["max_concurrent_uploads"] = max(state["max_concurrent_uploads"], state["active_uploads"])
                time.sleep(0.05)
                with state_lock:
                    state["active_uploads"] -= 1
                    item_id = state["next_id"]
                    state["next_id"] += 1
                    state["post_count"] += 1
                    state["attachments"][name] = {"id": item_id, "data": file_body}
                return self.send_json(201, {"id": item_id, "name": name})
            self.send_response(404)
            self.end_headers()

        def do_DELETE(self):
            path = urlparse(self.path).path
            prefix = "/api/v5/repos/test/repo/releases/101/attach_files/"
            if path.startswith(prefix):
                assert self.headers.get("Authorization") == f"token {token}"
                target_id = int(path[len(prefix):])
                with state_lock:
                    state["delete_count"] += 1
                    for k, v in list(state["attachments"].items()):
                        if v["id"] == target_id:
                            del state["attachments"][k]
                self.send_response(204)
                self.end_headers()
                return
            self.send_response(404)
            self.end_headers()

    server = ThreadingHTTPServer(("127.0.0.1", 0), MockGiteeHandler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        # 故意注入不可达代理且清空 NO_PROXY，验证脚本默认直连 Gitee（urllib 与 git push 均不走代理）。
        env = dict(
            os.environ,
            PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
            GITEE_TOKEN=token,
            GITEE_REPO="test/repo",
            GITEE_API=f"http://127.0.0.1:{port}/api/v5",
            GITEE_WEB=f"http://127.0.0.1:{port}",
            HTTP_PROXY="http://127.0.0.1:1",
            HTTPS_PROXY="http://127.0.0.1:1",
            http_proxy="http://127.0.0.1:1",
            https_proxy="http://127.0.0.1:1",
            NO_PROXY="",
            no_proxy="",
        )

        # 场景 1：绕过代理直连成功、并发上传 4 个资产、匿名回读不含 Authorization、写入标记。
        r1 = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=15)
        assert r1.returncode == 0, r1.stderr
        assert state["post_count"] == 4, state["post_count"]
        assert state["max_concurrent_uploads"] >= 2, f"未观测到并发上传：{state['max_concurrent_uploads']}"
        assert not state["public_auth_seen"], "匿名公开回读请求不能携带 Authorization"
        marker = mirror / "gitee-latest.txt"
        assert marker.read_text() == "v1.10.1\n"
        assert subprocess.check_output(["git", f"--git-dir={gitee_bare}", "rev-parse", "refs/heads/main"], text=True).strip() == commit
        assert subprocess.check_output(["git", f"--git-dir={gitee_bare}", "rev-parse", "v1.10.1^{commit}"], text=True).strip() == commit

        # 场景 2：再次同步全部命中幂等校验，不再触发 DELETE/POST。
        r2 = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=15)
        assert r2.returncode == 0, r2.stderr
        assert state["post_count"] == 4 and state["delete_count"] == 0, state

        # 场景 3：公开下载摘要不符时报错退出，且不写入 gitee-latest.txt。
        marker.unlink()
        with state_lock:
            state["tamper_download"] = "FinderRight.dmg"
        r3 = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=15)
        assert r3.returncode != 0, "摘要被篡改时必须失败"
        assert not marker.exists(), "校验失败后绝不能写入 gitee-latest.txt"
    finally:
        server.shutdown()
        server.server_close()

print(f"✓ Gitee 同步离线测试：绕代理直连、并发上传与匿名回读、幂等跳过、摘要阻断均通过（耗时 {time.monotonic()-started:.2f}s）")
PY