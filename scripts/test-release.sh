#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$PROJECT_DIR" <<'PY'
"""离线运行真实 Bash 函数；所有外部写入命令由临时桩替代。"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import time
import zipfile

started = time.monotonic()
script = Path(sys.argv[1]) / "scripts/release.sh"
count = 0
with tempfile.TemporaryDirectory(prefix="FinderRight release tests ") as folder:
    root = Path(folder)
    (root / "website").mkdir()
    (root / "notes").write_text("### 新增与优化\n")
    for name in ("FinderRight.dmg", "FinderRight-v1.12.4.zip"):
        (root / name).write_bytes(b"offline release fixture")
        digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
        (root / (name + ".sha256")).write_text(f"{digest}  {name}\n")
    bin_dir = root / "bin"
    bin_dir.mkdir()
    mock = bin_dir / "mock"
    mock.write_text('''#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
root = Path(os.environ["RELEASE_TEST_ROOT"])
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get("RELEASE_TEST_MODE", "")
with (root / "calls").open("a") as f:
    f.write(json.dumps([tool, *args]) + "\\n")
if tool == "gh":
    if args[:2] == ["run", "list"]:
        print(123)
    elif args[:2] == ["run", "watch"]:
        sys.exit(37)
    elif args[:2] == ["release", "create"]:
        assert "--draft" in args and "--verify-tag" in args
        if mode == "create-fails":
            sys.exit(38)
        (root / "published").unlink(missing_ok=True)
    elif args[:2] == ["release", "edit"]:
        assert "--draft=false" in args and "--latest" in args
        if mode == "publish-fails":
            sys.exit(39)
        (root / "published").touch()
    elif args[:2] == ["release", "view"]:
        if mode == "view-fails":
            sys.exit(40)
        latest = "--repo" in args
        names = ["FinderRight.dmg", "FinderRight.dmg.sha256", "FinderRight-v1.12.4.zip", "FinderRight-v1.12.4.zip.sha256"]
        assets = [{"name": n, "state": "uploaded", "size": (root/n).stat().st_size,
                   "digest": "sha256:" + hashlib.sha256((root/n).read_bytes()).hexdigest()} for n in names]
        if mode == "bad-size":
            assets[0]["size"] += 1
        if mode == "bad-digest":
            assets[0]["digest"] = "sha256:" + "0"*64
        if mode == "bad-checksum-digest":
            assets[1]["digest"] = "sha256:" + "0"*64
        if mode == "missing":
            assets.pop()
        if mode == "duplicate":
            assets[-1] = assets[0]
        if mode == "uploading":
            assets[0]["state"] = "new"
        print(json.dumps({"tagName": os.environ.get("RELEASE_TEST_LATEST", "v1.12.4") if latest else "v1.12.4",
                          "isDraft": False if latest else not (root/"published").exists(),
                          "isPrerelease": mode == "prerelease", "assets": assets}))
    else:
        raise SystemExit("unexpected gh call")
elif tool == "git":
    if args == ["rev-parse", "HEAD"]:
        print("offline-sha")
    elif args[:1] == ["tag"] and "--points-at" in args:
        print("v1.12.4")
    elif args[:1] in (["add"], ["commit"], ["tag"], ["push"]):
        if args[0] == os.environ.get("RELEASE_TEST_GIT_FAIL"):
            sys.exit(41)
    else:
        raise SystemExit("unexpected git call")
elif tool == "npx":
    if "--dry-run" in args:
        sys.exit(38)
    raise SystemExit("must not deploy after failed dry-run")
elif tool == "codesign":
    if "-r-" in args:
        print("designated => offline-fixture")
    elif "-d" in args:
        print("Signature=adhoc" if mode == "adhoc" else "Authority=FinderRight Self-Signed", file=sys.stderr)
else:
    raise SystemExit("unexpected tool")
''')
    mock.chmod(0o755)
    for name in ("gh", "git", "npx", "codesign"):
        (bin_dir / name).symlink_to(mock)
    env = dict(os.environ, RELEASE_TEST_ROOT=str(root), TMPDIR=str(root),
               PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
    prefix = f"source {shlex.quote(str(script))}\ncd \"$RELEASE_TEST_ROOT\"\nPROJECT_DIR=\"$RELEASE_TEST_ROOT\"\n"

    def run(name, code, status=0, **extra_env):
        global count
        (root / "calls").write_text("")
        (root / "published").unlink(missing_ok=True)
        result = subprocess.run(
            ["/bin/bash", "-c", prefix + code], env={**env, **extra_env},
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == status, f"{name}: {result.returncode} != {status}\n{result.stdout}\n{result.stderr}"
        assert "UNREACHABLE" not in result.stdout, f"{name}: 失败后仍继续\n{result.stdout}"
        count += 1
        return [json.loads(line) for line in (root / "calls").read_text().splitlines()]

    run("中间失败不能被 echo 覆盖", 'step() { false; echo UNREACHABLE; }\nrun_timed_step test step\necho UNREACHABLE', 1)
    run("两步成功与计时数组", 'run_timed_step one true\nrun_timed_step two true\n[ "$' + '{#TIMING_NAMES[@]}" = 2 ]\nprint_timing_summary')
    run("CI 失败保留退出码", 'run_timed_step ci wait_for_remote_ci dummy\necho UNREACHABLE', 37)
    calls = run("dry-run 失败阻断正式部署", 'run_timed_step deploy deploy_website\necho UNREACHABLE', 38)
    assert len(calls) == 1 and "--dry-run" in calls[0]
    calls = run("提交失败阻断 tag", 'run_timed_step commit git_commit_and_tag 1.12.4 48\necho UNREACHABLE', 41, RELEASE_TEST_GIT_FAIL="commit")
    assert [c[1] for c in calls] == ["add", "commit"]
    calls = run("main/tag 单次原子推送", 'run_timed_step push git_push_main_and_tag 1.12.4')
    assert calls == [["git", "push", "--atomic", "origin", "main", "v1.12.4"]]
    run("Python 深度资产校验失败阻断后续", 'run_timed_step assets verify_assets 1.12.4 48\necho UNREACHABLE', 1)
    stage = root / "build/dmg-stage/FinderRight.app"
    bundles = [stage] + [stage / "Contents/PlugIns" / (name + ".appex") for name in ("FinderRightSync", "FinderRightPreview", "FinderRightMarkdown")]
    archive = root / "FinderRight-v1.12.4.zip"
    with zipfile.ZipFile(archive, "w") as z:
        for bundle in bundles:
            path = bundle / "Contents/Info.plist"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.12.4", "CFBundleVersion": "48"}))
            z.write(path, str(path.relative_to(stage.parent)))
    (root / (archive.name + ".sha256")).write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
    run("已准备资产的完整版本与签名检查", 'run_timed_step assets verify_assets 1.12.4 48', RELEASE_TEST_MODE="signed")
    run("恢复发布拒绝 ad-hoc 资产", 'run_timed_step assets verify_assets 1.12.4 48\necho UNREACHABLE', 1, RELEASE_TEST_MODE="adhoc")
    run("官网 JSON 错误不能被 checksum 成功覆盖", '''
curl() {
  if [[ "$*" == *latest.json* ]]; then
    while [ "$1" != "-o" ]; do shift; done
    echo '{"tag_name":"v1.0.0","draft":false,"prerelease":false}' > "$2"
    printf 200
  else
    cat FinderRight.dmg.sha256
  fi
}
run_timed_step website verify_website_deployment 1.12.4
echo UNREACHABLE
''', 1)

    for draft in ("0", "1"):
        calls = run("Bash 3.2 正式/草稿路径", f'run_timed_step release create_and_verify_release 1.12.4 notes {draft}')
        assert any(c[:3] == ["gh", "release", "edit"] for c in calls) == (draft == "0")
        assert (root / "published").exists() == (draft == "0")
    calls = run("完整发布管线在 CI 失败后停止", 'publish_full_pipeline 1.12.4 notes 0\necho UNREACHABLE', 37)
    assert [c[:3] for c in calls] == [["git", "push", "--atomic"], ["git", "rev-parse", "HEAD"], ["gh", "run", "list"], ["gh", "run", "watch"]], calls
    for mode in ("bad-size", "bad-digest", "bad-checksum-digest", "missing", "duplicate", "uploading", "prerelease", "view-fails", "create-fails", "publish-fails"):
        status = 38 if mode == "create-fails" else 1
        calls = run(mode, 'run_timed_step release create_and_verify_release 1.12.4 notes 0\necho UNREACHABLE',
                    status, RELEASE_TEST_MODE=mode)
        if mode != "publish-fails":
            assert not any(c[:3] == ["gh", "release", "edit"] for c in calls), mode
        assert not (root / "published").exists(), mode

    run("同步版本匹配", 'run_timed_step sync check_sync_version 1.12.4')
    calls = run("旧版本同步在任何渠道动作前停止", 'bash() { echo UNREACHABLE; return 43; }\nmain 1.12.3 --sync-only\necho UNREACHABLE', 1)
    assert len(calls) == 1 and calls[0][:3] == ["gh", "release", "view"]

    prepared = '''
check_git_state() { echo git >> checks; }
check_versions_consistent() { echo versions >> checks; }
check_ci_state() { echo ci >> checks; }
check_signing_identity() { echo signing >> checks; }
current_version() { echo 1.12.4; }
current_build() { echo 48; }
prepare_local_release() { echo UNREACHABLE; }
generate_release_notes() { echo notes > "$2"; }
publish_full_pipeline() { echo publish >> checks; }
'''
    for check in ("check_git_state", "check_versions_consistent", "check_signing_identity", "verify_assets"):
        (root / "checks").write_text("")
        run("恢复发布必须通过 " + check, prepared + f'\n{check}() {{ return 42; }}\nmain 1.12.4 --publish\necho UNREACHABLE', 42)
        assert "publish" not in (root / "checks").read_text()
    code = prepared + '''
verify_assets() { echo assets >> checks; }
main 1.12.4 --publish
'''
    (root / "checks").write_text("")
    run("恢复发布重新校验且不重复准备", code)
    assert (root / "checks").read_text().splitlines() == ["git", "versions", "ci", "signing", "assets", "publish"]
    assert not list(root.glob("finderright-release-notes-*")), "成功发布后应清理临时说明"
    unique_notes = code.replace('generate_release_notes() { echo notes > "$2"; }', 'generate_release_notes() { echo "$2" >> note-paths; echo notes > "$2"; }')
    run("首次生成临时说明", unique_notes)
    run("再次生成临时说明", unique_notes)
    assert len(set((root / "note-paths").read_text().splitlines())) == 2
    assert not list(root.glob("finderright-release-notes-*"))
print(f"发布脚本离线回归：{count} 个场景通过，耗时 {time.monotonic()-started:.2f}s（/bin/bash，无网络/发布/部署）")
PY
