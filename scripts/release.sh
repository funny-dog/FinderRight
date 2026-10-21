#!/usr/bin/env bash
set -euo pipefail

# 发版脚本：把「改版本号 → 提交 → 打 tag → 构建 → 上传」这条手工链路固化下来。
#
#   scripts/release.sh --check          # 只做发版前校验，不改任何文件
#   scripts/release.sh 1.9.0            # 校验 → bump → 提交 → 打 tag → RELEASE=1 构建，停在这里
#   scripts/release.sh 1.9.0 --publish  # 继续推送 main 与 tag，并创建 draft Release 上传三个资产
#
# 推送与发布默认不做：draft Release 建好后到 GitHub 上补更新说明再点 Publish。

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PLISTS=(
  "FinderRight/Info.plist"
  "FinderRightSync/Info.plist"
  "FinderRightPreview/Info.plist"
)

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
  echo "版本一致性：v$version (build $build)，三个 Info.plist 全部匹配"
}

check_git_state() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "main" ] || fail "发版请在 main 上进行，当前是 $branch"
  [ -z "$(git status --porcelain)" ] || fail "工作区不干净，先提交或清理改动：
$(git status --short)"
  git fetch --quiet origin main
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    fail "本地 main 与 origin/main 不一致，先 push 或 pull"
  fi
  echo "Git 状态：main 干净，且与 origin/main 同步"
}

check_ci_state() {
  command -v gh >/dev/null 2>&1 || { echo "提示：未安装 gh，跳过 CI 状态检查"; return 0; }
  local conclusion
  conclusion="$(gh run list --branch main --workflow CI --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null || true)"
  case "$conclusion" in
    success) echo "CI 状态：main 最新一次运行成功" ;;
    "") echo "提示：读不到 CI 运行记录，跳过检查" ;;
    *) echo "警告：main 最新一次 CI 结果是 $conclusion，确认无误再继续" >&2 ;;
  esac
}

check_new_version() {
  local new="$1" current
  current="$(current_version)"
  [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "版本号格式应为 x.y.z，收到：$new"
  [ "$new" != "$current" ] || fail "新版本号与当前版本相同（$current）"
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
  [ -f "FinderRight.dmg" ] || fail "缺少 FinderRight.dmg"
  [ -f "FinderRight.dmg.sha256" ] || fail "缺少校验文件 FinderRight.dmg.sha256"
  [ -f "FinderRight-v$version.zip" ] || fail "缺少 FinderRight-v$version.zip"
  [ -f "FinderRight-v$version.zip.sha256" ] || fail "缺少校验文件 FinderRight-v$version.zip.sha256"
  (cd "$PROJECT_DIR" && shasum -a 256 -c "FinderRight-v$version.zip.sha256" >/dev/null) \
    || fail "zip sha256 校验不通过"
  (cd "$PROJECT_DIR" && shasum -a 256 -c "FinderRight.dmg.sha256" >/dev/null) \
    || fail "dmg sha256 校验不通过"
  echo "发布资产校验：dmg / dmg.sha256 / zip / zip.sha256 齐备，校验和匹配"
}

MODE="release"
VERSION_ARG=""
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --publish) PUBLISH=1 ;;
    -*) fail "未知参数：$arg" ;;
    *) VERSION_ARG="$arg" ;;
  esac
done

echo "=== 发版前校验 ==="
check_git_state
check_versions_consistent
check_ci_state

if [ "$MODE" = "check" ]; then
  echo "校验完成（未改动任何文件）"
  exit 0
fi

[ -n "$VERSION_ARG" ] || fail "缺少版本号。用法：scripts/release.sh 1.9.0 [--publish]"
check_new_version "$VERSION_ARG"

echo "=== 更新版本号 ==="
bump_version "$VERSION_ARG"

echo "=== 运行 CI ==="
bash scripts/ci.sh

echo "=== 提交并打 tag ==="
git add "${PLISTS[@]}"
git commit -m "chore: 发布 v${VERSION_ARG}（构建号 $(current_build)）"
git tag -a "v$VERSION_ARG" -m "v$VERSION_ARG"

echo "=== 构建发布件（RELEASE=1）==="
RELEASE=1 bash scripts/build.sh
verify_assets "$VERSION_ARG"

echo ""
echo "已就绪：v$VERSION_ARG (build $(current_build)) 的提交、tag 与发布件都已生成，尚未推送。"

if [ "$PUBLISH" = "1" ]; then
  echo "=== 推送并创建 draft Release ==="
  git push origin main
  git push origin "v$VERSION_ARG"
  NOTES_FILE="$(mktemp)"
  PREV_TAG="$(git describe --tags --abbrev=0 "v$VERSION_ARG^" 2>/dev/null || true)"
  if [ -n "$PREV_TAG" ]; then RANGE="$PREV_TAG..v$VERSION_ARG"; else RANGE="v$VERSION_ARG"; fi
  {
    echo "## 变更"
    echo ""
    git log --pretty='- %s' "$RANGE"
  } > "$NOTES_FILE"
  gh release create "v$VERSION_ARG" --draft --title "v$VERSION_ARG" --notes-file "$NOTES_FILE" \
    "FinderRight.dmg" "FinderRight.dmg.sha256" \
    "FinderRight-v$VERSION_ARG.zip" "FinderRight-v$VERSION_ARG.zip.sha256"
  rm -f "$NOTES_FILE"
  echo "draft Release v$VERSION_ARG 已创建，补完更新说明后在 GitHub 上点 Publish。"
else
  echo "下一步（确认无误后手动执行）："
  echo "  git push origin main"
  echo "  git push origin v$VERSION_ARG"
  echo "  gh release create v$VERSION_ARG --draft --title v$VERSION_ARG \\"
  echo "    FinderRight.dmg FinderRight.dmg.sha256 \\"
  echo "    FinderRight-v$VERSION_ARG.zip FinderRight-v$VERSION_ARG.zip.sha256"
fi
