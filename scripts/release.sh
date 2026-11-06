#!/usr/bin/env bash
set -euo pipefail

# 发版脚本：固化「校验 → 本地发版准备 → 单次推送 → 等待远端CI → GitHub正式发布 → 官网/Gitee镜像 → Cloudflare部署 → 官网curl核验 → Homebrew Cask同步」的主线流程。
#
#   scripts/release.sh --check                      # 发版前只读校验，不修改任何文件
#   scripts/release.sh 1.12.4                       # 本地准备：校验 → 递增版本 → 本地完整CI → 提交与打tag → 签名打包 → 资产深度校验，输出就绪汇总与耗时表
#   scripts/release.sh 1.12.4 --publish             # 全流程自动化发布：单次推送main+tag → 等待远端CI → 创建正式Release → 同步官网/Gitee → 部署官网 → curl核验 → 同步Homebrew Cask → 耗时统计
#   scripts/release.sh 1.12.4 --publish --draft      # 仅推送到 draft Release（如需手动在网页端核验）
#   scripts/release.sh 1.12.4 --publish --notes-file <file> # 指定更新说明文件发布
#   scripts/release.sh 1.12.4 --sync-only           # 仅对已正式发布的版本执行全渠道同步（官网、Gitee、Cloudflare、Homebrew Cask）

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PLISTS=(
  "FinderRight/Info.plist"
  "FinderRightSync/Info.plist"
  "FinderRightPreview/Info.plist"
  "FinderRightMarkdown/Info.plist"
)

# 计时统计
declare -a TIMING_NAMES=()
declare -a TIMING_DURATIONS=()
declare -a TIMING_STATUSES=()

fail() {
  echo "错误：$*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

plist_set() {
  /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1"
}

current_version() {
  plist_value "${PLISTS[0]}" CFBundleShortVersionString
}

current_build() {
  plist_value "${PLISTS[0]}" CFBundleVersion
}

run_timed_step() {
  local name="$1"
  shift
  local start_time
  start_time=$(date +%s)
  echo ""
  echo ">>> [开始] $name"
  # 不把函数放进 || / if：Bash 会因此忽略函数内部的 errexit，吞掉中间失败。
  local status
  set +e
  (
    set -e
    "$@"
  )
  status=$?
  set -e
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  TIMING_NAMES+=("$name")
  TIMING_DURATIONS+=("${duration}s")
  if [ $status -eq 0 ]; then
    TIMING_STATUSES+=("成功")
    echo ">>> [完成] $name (耗时 ${duration}s)"
  else
    TIMING_STATUSES+=("失败 (退出码 $status)")
    echo ">>> [失败] $name (耗时 ${duration}s, 退出码 $status)" >&2
    print_timing_summary
    return $status
  fi
}

print_timing_summary() {
  echo ""
  echo "========================================="
  echo "              发版耗时统计"
  echo "========================================="
  printf "| %-36s | %-10s | %-10s |\n" "阶段" "耗时" "状态"
  printf "|-%-36s-|-%-10s-|-%-10s-|\n" "------------------------------------" "----------" "----------"
  local total=0
  for i in "${!TIMING_NAMES[@]}"; do
    printf "| %-36s | %-10s | %-10s |\n" "${TIMING_NAMES[$i]}" "${TIMING_DURATIONS[$i]}" "${TIMING_STATUSES[$i]}"
    local d="${TIMING_DURATIONS[$i]%s}"
    total=$((total + d))
  done
  printf "| %-36s | %-10s | %-10s |\n" "总计" "${total}s" "-"
  echo "========================================="
  echo ""
}

check_versions_consistent() {
  local version build file
  version="$(current_version)"
  build="$(current_build)"
  for file in "${PLISTS[@]}"; do
    [ -f "$file" ] || fail "找不到 $file"
    [ "$(plist_value "$file" CFBundleShortVersionString)" = "$version" ] \
      || fail "版本号不一致：$file 是 $(plist_value "$file" CFBundleShortVersionString)，主 App 是 $version"
    [ "$(plist_value "$file" CFBundleVersion)" = "$build" ] \
      || fail "构建号不一致：$file 是 $(plist_value "$file" CFBundleVersion)，主 App 是 $build"
  done
  echo "版本一致性：v$version (build $build)，四个 Info.plist 全部匹配"
}

check_git_state() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "main" ] || fail "发版请在 main 上进行，当前是 $branch"
  [ -z "$(git status --porcelain)" ] || fail "工作区不干净，先提交或清理改动：
$(git status --short)"

  git fetch --quiet origin main
  local behind ahead
  behind="$(git rev-list --count HEAD..origin/main)"
  ahead="$(git rev-list --count origin/main..HEAD)"

  if [ "$behind" -gt 0 ]; then
    fail "本地 main 落后于 origin/main ($behind 个提交)，请先 pull / rebase"
  fi

  if [ "$ahead" -gt 0 ]; then
    echo "Git 状态：main 干净，本地超前 origin/main $ahead 个提交（将在发版时一并推送）"
  else
    echo "Git 状态：main 干净，且与 origin/main 完全同步"
  fi
}

check_ci_state() {
  command -v gh >/dev/null 2>&1 || { echo "提示：未安装 gh，跳过远端 CI 状态检查"; return 0; }
  local origin_head
  origin_head="$(git rev-parse origin/main 2>/dev/null || true)"
  local conclusion=""
  if [ -n "$origin_head" ]; then
    conclusion="$(gh run list --workflow CI --commit "$origin_head" --json conclusion -q '.[0].conclusion' 2>/dev/null || true)"
  fi
  if [ -z "$conclusion" ]; then
    # 日常 push main 不跑远端 CI，fallback 查询最近一次运行（如上个版本的 tag 构建或手动运行）
    conclusion="$(gh run list --workflow CI --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null || true)"
  fi
  case "$conclusion" in
    success) echo "CI 状态：远端最近一次运行成功" ;;
    "") echo "提示：读不到远端 CI 运行记录，本地将执行完整 CI" ;;
    *) fail "远端最近一次 CI 结果是 ${conclusion}，必须修复后再发版" ;;
  esac
}

check_signing_identity() {
  local name="${FINDERRIGHT_SIGN_IDENTITY:-FinderRight Self-Signed}"
  local identities
  identities="$(security find-identity -p codesigning ${FINDERRIGHT_KEYCHAIN:+"$FINDERRIGHT_KEYCHAIN"} 2>/dev/null || true)"
  if [[ "$identities" != *"\"$name\""* ]]; then
    fail "未在钥匙串中找到签名证书「${name}」。发版严禁使用 ad-hoc 签名！请先执行 bash scripts/setup-signing.sh"
  fi
  echo "代码签名证书：找到「${name}」"
}

check_installed_app_safety() {
  local installed="/Applications/FinderRight.app"
  if [ -d "$installed" ]; then
    local installed_ver installed_build
    installed_ver="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$installed/Contents/Info.plist" 2>/dev/null || true)"
    installed_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$installed/Contents/Info.plist" 2>/dev/null || true)"
    echo "本机已安装应用：/Applications/FinderRight.app (v$installed_ver build ${installed_build}，发布流程不安装)"
  fi
}

check_new_version() {
  local new="$1" current
  current="$(current_version)"
  [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "版本号格式应为 x.y.z，收到：$new"
  [ "$new" != "$current" ] || fail "新版本号与当前版本相同（${current}）"
  if [ "$(printf '%s\n%s\n' "$current" "$new" | sort -V | tail -1)" != "$new" ]; then
    fail "新版本号 $new 必须大于当前版本 $current"
  fi
  echo "版本升级：$current → $new (build $(( $(current_build) + 1 )))"
}

bump_version() {
  local new="$1" next_build file
  next_build=$(( $(current_build) + 1 ))
  for file in "${PLISTS[@]}"; do
    plist_set "$file" CFBundleShortVersionString "$new"
    plist_set "$file" CFBundleVersion "$next_build"
  done
  check_versions_consistent
}

verify_assets() {
  local version="$1"
  local build="$2"

  [ -f "FinderRight.dmg" ] || fail "缺少 FinderRight.dmg"
  [ -f "FinderRight.dmg.sha256" ] || fail "缺少校验文件 FinderRight.dmg.sha256"
  [ -f "FinderRight-v${version}.zip" ] || fail "缺少 FinderRight-v${version}.zip"
  [ -f "FinderRight-v${version}.zip.sha256" ] || fail "缺少校验文件 FinderRight-v${version}.zip.sha256"

  (shasum -a 256 -c "FinderRight-v${version}.zip.sha256" >/dev/null) || fail "zip sha256 校验不通过"
  (shasum -a 256 -c "FinderRight.dmg.sha256" >/dev/null) || fail "dmg sha256 校验不通过"

  python3 - "$version" "$build" <<'PY'
import sys, plistlib, subprocess, zipfile, os
from pathlib import Path

version, build = sys.argv[1], sys.argv[2]
root = Path.cwd()
app = root / "build/dmg-stage/FinderRight.app"
assert app.exists(), "build/dmg-stage/FinderRight.app 不存在"

bundles = [app] + [app / "Contents/PlugIns" / f"{name}.appex" for name in ["FinderRightSync", "FinderRightPreview", "FinderRightMarkdown"]]
for bundle in bundles:
    plist_path = bundle / "Contents/Info.plist"
    with plist_path.open("rb") as f:
        info = plistlib.load(f)
    assert (info["CFBundleShortVersionString"], info["CFBundleVersion"]) == (version, build), f"{bundle.name} 版本或构建号不匹配: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})"
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    signature = subprocess.run(["codesign", "-d", "--verbose=2", str(bundle)], check=True, capture_output=True, text=True)
    identity = os.environ.get("FINDERRIGHT_SIGN_IDENTITY", "FinderRight Self-Signed")
    assert f"Authority={identity}" in signature.stderr.splitlines(), f"{bundle.name} 未使用发布证书签名（禁止 ad-hoc）"

installed = Path("/Applications/FinderRight.app")
if installed.exists():
    def req(p):
        r = subprocess.run(["codesign", "-d", "-r-", str(p)], check=True, capture_output=True, text=True)
        return next((l for l in (r.stdout + r.stderr).splitlines() if l.startswith("designated =>")), None)
    req_stage = req(app)
    req_inst = req(installed)
    if req_stage and req_inst:
        assert req_stage == req_inst, "发布产物与本机 /Applications/FinderRight.app 签名要求不一致"

with zipfile.ZipFile(root / f"FinderRight-v{version}.zip") as z:
    names = [n for n in z.namelist() if n.endswith("/Contents/Info.plist") and not n.startswith("__MACOSX/") and "/__MACOSX/" not in n]
    assert len(names) == 4, f"ZIP 内 Info.plist 数量不等于 4：{names}"
    for name in names:
        info = plistlib.loads(z.read(name))
        assert (info["CFBundleShortVersionString"], info["CFBundleVersion"]) == (version, build), f"ZIP 内 {name} 版本不匹配"
print("深度资产校验通过：四个 bundle 严格签名一致、版本匹配，ZIP 内部组件完整")
PY
  echo "发布资产校验：dmg / dmg.sha256 / zip / zip.sha256 齐备，校验和匹配"
}

generate_release_notes() {
  local version="$1"
  local target_file="$2"
  local prev_tag
  prev_tag="$(git describe --tags --abbrev=0 "v${version}^" 2>/dev/null || true)"
  local range="v$version"
  if [ -n "$prev_tag" ]; then
    range="${prev_tag}..v$version"
  fi
  {
    echo "### 新增与优化"
    echo ""
    git log --pretty='- %s' "$range" | grep -v -E 'chore: 发布|chore\(release\)' || true
  } > "$target_file"
}

git_commit_and_tag() {
  local version="$1"
  local build="$2"
  git add "${PLISTS[@]}"
  git commit -m "chore: 发布 v${version}（构建号 ${build}）"
  git tag -a "v$version" -m "v$version"
}

git_push_main_and_tag() {
  local version="$1"
  echo "推送 main 与 tag v$version 到 GitHub..."
  git push --atomic origin main "v$version"
}

wait_for_remote_ci() {
  local target_sha="$1"
  echo "等待远端针对提交 $target_sha 的 GitHub Actions CI 启动..."
  local run_id=""
  for i in {1..30}; do
    run_id="$(gh run list --workflow CI --commit "$target_sha" --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
    if [ -n "$run_id" ]; then
      break
    fi
    sleep 3
  done
  [ -n "$run_id" ] || fail "未能在 90 秒内检测到针对提交 $target_sha 的 CI 运行记录"
  echo "远端 CI 正在运行 (Run ID: $run_id)，等待完成..."
  gh run watch "$run_id" --exit-status
  echo "远端 GitHub Actions CI 运行通过！"
}

create_and_verify_release() {
  local version="$1"
  local notes_file="$2"
  local is_draft="$3"

  local title="v$version"
  local tag="v$version"
  echo "创建 GitHub draft Release ($tag)，校验后再公开..."
  gh release create "$tag" --draft --verify-tag --title "$title" --notes-file "$notes_file" \
    "FinderRight.dmg" "FinderRight.dmg.sha256" "FinderRight-v$version.zip" "FinderRight-v$version.zip.sha256"

  echo "核验远端 Release 资产与 SHA-256..."
  python3 - "$tag" "$is_draft" <<'PYTHON'
import sys, json, subprocess, hashlib
from pathlib import Path

tag = sys.argv[1]
keep_draft = sys.argv[2] == "1"
data = json.loads(subprocess.check_output([
    "gh", "release", "view", tag,
    "--json", "tagName,isDraft,isPrerelease,assets",
]))
assert data.get("tagName") == tag
assert data.get("isDraft") is True, "校验资产时 Release 必须仍为 draft"
assert data.get("isPrerelease") is False, "Release 不应为 prerelease"

names = ["FinderRight.dmg", "FinderRight.dmg.sha256", f"FinderRight-{tag}.zip", f"FinderRight-{tag}.zip.sha256"]
selected = [a for a in data.get("assets", []) if a.get("name") in names]
assert len(selected) == 4, "四个资产必须齐备且无重复"
assets = {a["name"]: a for a in selected}
for name in names:
    assert name in assets, f"远端 Release 缺少资产: {name}"
    assert assets[name]["state"] == "uploaded", f"资产 {name} 未上传完成"
    local = Path(name)
    assert assets[name]["size"] == local.stat().st_size, f"资产 {name} 大小不符"
    digest = hashlib.sha256(local.read_bytes()).hexdigest()
    assert assets[name]["digest"] == f"sha256:{digest}", f"资产 {name} SHA-256 不符"
print(f"远端 Release {tag} 四个资产全部上传完成，SHA-256 校验一致")
if not keep_draft:
    subprocess.run(["gh", "release", "edit", tag, "--draft=false", "--latest"], check=True)
    published = json.loads(subprocess.check_output([
        "gh", "release", "view", tag, "--json", "tagName,isDraft,isPrerelease",
    ]))
    assert published.get("tagName") == tag
    assert published.get("isDraft") is False and published.get("isPrerelease") is False, "Release 未正式公开"
    print(f"正式发布完成：{tag}")
PYTHON
}

check_sync_version() {
  python3 - "$1" <<'PYTHON'
import json, subprocess, sys
data = json.loads(subprocess.check_output([
    "gh", "release", "view", "--repo", "funny-dog/FinderRight",
    "--json", "tagName,isDraft,isPrerelease",
]))
assert data.get("isDraft") is False and data.get("isPrerelease") is False, "只同步正式发布"
assert data.get("tagName") == f"v{sys.argv[1]}", f"请求版本不是最新正式版：{data.get('tagName')}；尚未执行渠道同步"
PYTHON
}

deploy_website() {
  (
    cd "$PROJECT_DIR/website"
    npx --yes wrangler@4.147.0 deploy --dry-run
    npx --yes wrangler@4.147.0 deploy
  )
}

verify_website_deployment() {
  local version="$1"
  local base_url="https://finderright.erhutech.com"
  local dmg_sha
  dmg_sha="$(awk '{print $1}' FinderRight.dmg.sha256)"

  echo "正在使用 curl 回读核验官网更新接口与 DMG 校验和..."

  local body_file
  body_file="$(mktemp)"
  local http_code
  http_code="$(curl --max-time 30 -sS -o "$body_file" -w "%{http_code}" "${base_url}/update/latest.json" || true)"
  if [ "$http_code" != "200" ]; then
    rm -f "$body_file"
    fail "官网更新接口回读失败 (HTTP $http_code)"
  fi

  python3 - "$version" "$body_file" <<'PY'
import sys, json
version, path = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
assert data.get("tag_name") == f"v{version}", f"更新接口 tag 错误: {data.get('tag_name')}"
assert not data.get("draft"), "更新接口返回的是 draft"
assert not data.get("prerelease"), "更新接口返回的是 prerelease"
print(f"官网更新接口核验通过：v{version} 正式版")
PY
  rm -f "$body_file"

  local remote_sha
  remote_sha="$(curl --max-time 30 -sS "${base_url}/download/FinderRight.dmg.sha256" | awk '{print $1}' || true)"
  [ "$remote_sha" = "$dmg_sha" ] || fail "官网 DMG sha256 ($remote_sha) 与本地 ($dmg_sha) 不一致"
  echo "官网 DMG 校验文件核验一致 ($remote_sha)"
}

prepare_local_release() {
  local new_version="$1"
  check_new_version "$new_version"
  local next_build=$(( $(current_build) + 1 ))

  run_timed_step "更新版本号与构建号 ($new_version build $next_build)" bump_version "$new_version"
  run_timed_step "运行完整本地 CI (bash scripts/ci.sh)" bash scripts/ci.sh
  run_timed_step "提交 Info.plist 并打本地 tag" git_commit_and_tag "$new_version" "$next_build"
  run_timed_step "签名并打包发布件 (RELEASE=1 bash scripts/build.sh)" env RELEASE=1 bash scripts/build.sh
  run_timed_step "深度校验发布资产与签名" verify_assets "$new_version" "$next_build"
  run_timed_step "安全复核（保留本机已安装版本）" check_installed_app_safety
}

publish_full_pipeline() {
  local version="$1"
  local notes_file="$2"
  local is_draft="$3"

  run_timed_step "单次推送 main 与 tag 到 GitHub" git_push_main_and_tag "$version"

  local release_sha
  release_sha="$(git rev-parse HEAD)"
  run_timed_step "等待远端 GitHub Actions CI 完成" wait_for_remote_ci "$release_sha"

  run_timed_step "创建 GitHub Release 并上传资产" create_and_verify_release "$version" "$notes_file" "$is_draft"

  if [ "$is_draft" = "1" ]; then
    echo "draft Release v$version 创建完成，等待在网页上补充说明并正式 Publish。"
    return 0
  fi

  run_timed_step "确认渠道同步的目标版本" check_sync_version "$version"
  run_timed_step "同步官网下载镜像" bash scripts/sync-website-downloads.sh
  run_timed_step "同步 Gitee 发行版" bash scripts/sync-gitee-release.sh
  run_timed_step "部署官网到 Cloudflare Workers" deploy_website
  run_timed_step "核验官网线上接口 (curl)" verify_website_deployment "$version"
  run_timed_step "同步 Homebrew Cask" bash scripts/sync-homebrew-cask.sh "$version"
  run_timed_step "安全复核（保留本机已安装版本）" check_installed_app_safety
}

main() {
  # 参数解析
  MODE="release"
  VERSION_ARG=""
  PUBLISH=0
  DRAFT=0
  SYNC_ONLY=0
  NOTES_FILE=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) MODE="check"; shift ;;
      --publish) PUBLISH=1; shift ;;
      --draft) DRAFT=1; shift ;;
      --sync-only) SYNC_ONLY=1; shift ;;
      --notes-file)
        shift
        [ "$#" -gt 0 ] || fail "缺少 --notes-file 参数值"
        NOTES_FILE="$1"
        shift
        ;;
      -*) fail "未知参数：$1" ;;
      *)
        if [ -z "$VERSION_ARG" ]; then
          VERSION_ARG="$1"
        else
          fail "多余的参数：$1"
        fi
        shift
        ;;
    esac
  done

  if [ "$MODE" = "check" ]; then
    echo "=== 发版前校验 ==="
    check_git_state
    check_versions_consistent
    check_ci_state
    check_signing_identity
    check_installed_app_safety
    echo ""
    echo "发版前校验全部通过（未改动任何文件）。"
    exit 0
  fi

  [ -n "$VERSION_ARG" ] || fail "缺少版本号。用法：scripts/release.sh x.y.z [--publish] [--draft] [--notes-file <file>]"
  VERSION="${VERSION_ARG#v}"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "版本号格式应为 x.y.z"

  # 仅同步模式
  if [ "$SYNC_ONLY" = "1" ]; then
    echo "=== 仅同步全渠道：v$VERSION ==="
    run_timed_step "确认渠道同步的目标版本" check_sync_version "$VERSION"
    run_timed_step "同步官网下载镜像" bash scripts/sync-website-downloads.sh
    run_timed_step "同步 Gitee 发行版" bash scripts/sync-gitee-release.sh
    run_timed_step "部署官网到 Cloudflare Workers" deploy_website
    run_timed_step "核验官网线上接口 (curl)" verify_website_deployment "$VERSION"
    run_timed_step "同步 Homebrew Cask" bash scripts/sync-homebrew-cask.sh "$VERSION"
    run_timed_step "安全复核（保留本机已安装版本）" check_installed_app_safety
    print_timing_summary
    echo "全渠道同步完成：v$VERSION"
    exit 0
  fi

  # 检查当前是否已经生成了该版本的 commit 与 tag
  echo "=== 发版前校验 ==="
  check_git_state
  check_versions_consistent
  check_ci_state
  check_signing_identity

  TAG_AT_HEAD="$(git tag --points-at HEAD --list "v$VERSION")"
  IS_PREPARED=0
  if [ "$TAG_AT_HEAD" = "v$VERSION" ] && [ "$(current_version)" = "$VERSION" ]; then
    echo "检测到 HEAD 已打上标签 v${VERSION}，重新校验发布资产。"
    IS_PREPARED=1
    run_timed_step "恢复发布：深度校验发布资产与签名" verify_assets "$VERSION" "$(current_build)"
  fi

  if [ "$IS_PREPARED" = "0" ]; then
    echo ""
    echo "=== 执行本地发版准备 (Phase 1) ==="
    prepare_local_release "$VERSION"
  fi

  # 准备更新说明
  TMP_NOTES=""
  if [ -z "$NOTES_FILE" ]; then
    TMP_NOTES="$(mktemp "${TMPDIR:-/tmp}/finderright-release-notes-XXXXXX")"
    generate_release_notes "$VERSION" "$TMP_NOTES"
    NOTES_FILE="$TMP_NOTES"
  fi

  if [ "$PUBLISH" = "1" ]; then
    echo ""
    echo "=== 执行自动化发布与全渠道同步 (Phase 2) ==="
    publish_full_pipeline "$VERSION" "$NOTES_FILE" "$DRAFT"
    [ -z "$TMP_NOTES" ] || rm -f "$TMP_NOTES"
    print_timing_summary
    echo "🎉 FinderRight v$VERSION 发布流程全部完成！"
    exit 0
  fi

  # 本地准备完成，尚未推送
  print_timing_summary
  echo "========================================="
  echo "  本地发版准备已完成（尚未推送到远端）"
  echo "========================================="
  echo "版本号：v$VERSION (构建号 $(current_build))"
  echo "本地最新提交：$(git log -1 --oneline)"
  echo "待推送提交数：$(git rev-list --count origin/main..HEAD)"
  echo "待推送标签：v$VERSION"
  echo ""
  echo "更新说明草稿预览 ($NOTES_FILE)："
  echo "-----------------------------------------"
  cat "$NOTES_FILE"
  echo "-----------------------------------------"
  echo ""
  echo "若仅要求本地准备，到此完成；用户已要求正式发布时，直接继续以下命令，无需二次确认："
  echo "  bash scripts/release.sh $VERSION --publish --notes-file \"$NOTES_FILE\""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
