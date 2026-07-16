#!/bin/bash
# NetWatch 发版自检脚本
# 用法：scripts/release_check.sh   （在仓库根目录或任意目录均可，脚本会自行定位仓库根）
# 全部检查项跑完再汇总；任何一项 ❌ 则整体 exit 1。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAILED_ITEMS=()
PASS="✅"
FAIL="❌"

ok()   { echo "✅ $1 — $2"; }
bad()  { echo "❌ $1 — $2"; FAILED_ITEMS+=("$1"); }

echo "==> NetWatch 发版自检开始（$(date '+%Y-%m-%d %H:%M:%S')）"
echo ""

# 1. 版本一致性：VERSION 文件 vs main.swift 版本常量 vs README.md 最新版本号
VERSION_FILE_VER="$(cat VERSION 2>/dev/null | tr -d '[:space:]')"
# main.swift 中唯一的版本号字面量出现在 APP_VERSION 的 fallback 默认值里：
#   let APP_VERSION: String = (...) ?? "5.3"
SWIFT_VER="$(grep -oE 'let APP_VERSION: String = .*\?\? "[0-9.]+"' main.swift | grep -oE '"[0-9.]+"' | tr -d '"')"
README_VER="$(grep -oE '^> 当前版本：v[0-9.]+' README.md | grep -oE '[0-9.]+' | head -1)"

if [ -n "$VERSION_FILE_VER" ] && [ -n "$SWIFT_VER" ] && [ -n "$README_VER" ] \
   && [ "$VERSION_FILE_VER" = "$SWIFT_VER" ] && [ "$VERSION_FILE_VER" = "$README_VER" ]; then
  ok "版本一致性" "VERSION=$VERSION_FILE_VER, main.swift(APP_VERSION fallback)=$SWIFT_VER, README=$README_VER 三处一致"
else
  bad "版本一致性" "VERSION=${VERSION_FILE_VER:-<空>}, main.swift=${SWIFT_VER:-<空>}, README=${README_VER:-<空>} —— 三处不一致，需同步"
fi

# 2. 脚本语法：bash -n 三个 .sh
SYNTAX_OK=1
SYNTAX_DETAIL=""
for f in netwatch.sh risk_check.sh proxy_detect.sh; do
  if ! bash -n "$f" 2>/tmp/release_check_syntax_err; then
    SYNTAX_OK=0
    SYNTAX_DETAIL="$SYNTAX_DETAIL $f:[$(cat /tmp/release_check_syntax_err | tr '\n' ' ')]"
  fi
done
rm -f /tmp/release_check_syntax_err
if [ "$SYNTAX_OK" -eq 1 ]; then
  ok "脚本语法" "netwatch.sh / risk_check.sh / proxy_detect.sh 均通过 bash -n"
else
  bad "脚本语法" "语法错误：$SYNTAX_DETAIL"
fi

# 3. 免依赖回归守卫：三个 .sh 不得出现 jq 或 python3
DEP_HIT=""
for f in netwatch.sh risk_check.sh proxy_detect.sh; do
  if grep -nE '\bjq\b|\bpython3\b' "$f" >/dev/null 2>&1; then
    DEP_HIT="$DEP_HIT $f"
  fi
done
if [ -z "$DEP_HIT" ]; then
  ok "免依赖回归守卫" "netwatch.sh / risk_check.sh / proxy_detect.sh 均未发现 jq / python3 依赖回归"
else
  bad "免依赖回归守卫" "以下脚本发现 jq/python3 依赖回归:$DEP_HIT —— 请改回免依赖实现"
fi

# 4. 产物存在且新鲜：dmg 存在，且 mtime 不早于源码
DMG_PATH="dist/NetWatch-v${VERSION_FILE_VER}.dmg"
if [ ! -f "$DMG_PATH" ]; then
  bad "产物存在且新鲜" "$DMG_PATH 不存在 —— 请先跑 scripts/build.sh"
else
  DMG_MTIME=$(stat -f "%m" "$DMG_PATH" 2>/dev/null)
  STALE=0
  STALE_SRC=""
  for f in main.swift netwatch.sh risk_check.sh proxy_detect.sh; do
    SRC_MTIME=$(stat -f "%m" "$f" 2>/dev/null)
    if [ -n "$SRC_MTIME" ] && [ -n "$DMG_MTIME" ] && [ "$SRC_MTIME" -gt "$DMG_MTIME" ]; then
      STALE=1
      STALE_SRC="$STALE_SRC $f"
    fi
  done
  if [ "$STALE" -eq 0 ]; then
    ok "产物存在且新鲜" "$DMG_PATH 存在，且不早于所有源码文件"
  else
    bad "产物存在且新鲜" "$DMG_PATH 比以下源码旧:$STALE_SRC —— 产物过期，请重跑 scripts/build.sh"
  fi
fi

# 5. dmg 可挂载且 App 完好：挂载、codesign --verify、lipo -archs 含 arm64+x86_64
if [ -f "$DMG_PATH" ]; then
  MOUNT_POINT=""
  DETACHED=0
  cleanup_mount() {
    if [ -n "$MOUNT_POINT" ] && [ "$DETACHED" -eq 0 ]; then
      hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1
      DETACHED=1
    fi
  }
  trap cleanup_mount EXIT

  ATTACH_OUT=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" 2>&1)
  MOUNT_POINT=$(echo "$ATTACH_OUT" | grep -oE '/Volumes/[^	]+' | tail -1)

  if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
    bad "dmg 可挂载且 App 完好" "hdiutil attach 失败：$ATTACH_OUT"
  else
    APP_PATH="$MOUNT_POINT/NetWatch.app"
    if [ ! -d "$APP_PATH" ]; then
      bad "dmg 可挂载且 App 完好" "挂载成功但未找到 $APP_PATH"
    else
      BIN_PATH="$APP_PATH/Contents/MacOS/NetWatch"
      SIGN_OK=0
      LIPO_OK=0
      SIGN_DETAIL=""
      LIPO_DETAIL=""

      if codesign --verify --deep "$APP_PATH" >/tmp/release_check_codesign_err 2>&1; then
        SIGN_OK=1
      else
        SIGN_DETAIL="$(cat /tmp/release_check_codesign_err | tr '\n' ' ')"
      fi
      rm -f /tmp/release_check_codesign_err

      if [ -f "$BIN_PATH" ]; then
        ARCHS="$(lipo -archs "$BIN_PATH" 2>/dev/null)"
        if echo "$ARCHS" | grep -q "arm64" && echo "$ARCHS" | grep -q "x86_64"; then
          LIPO_OK=1
        else
          LIPO_DETAIL="实际架构: ${ARCHS:-<获取失败>}"
        fi
      else
        LIPO_DETAIL="主二进制不存在: $BIN_PATH"
      fi

      if [ "$SIGN_OK" -eq 1 ] && [ "$LIPO_OK" -eq 1 ]; then
        ok "dmg 可挂载且 App 完好" "挂载成功，codesign --verify 通过，lipo -archs 含 arm64+x86_64（$ARCHS）"
      else
        bad "dmg 可挂载且 App 完好" "codesign${SIGN_OK:+ok}$([ $SIGN_OK -eq 0 ] && echo "失败:$SIGN_DETAIL"); lipo$([ $LIPO_OK -eq 0 ] && echo " 失败:$LIPO_DETAIL" || echo " ok")"
      fi
    fi
  fi

  cleanup_mount
  trap - EXIT
fi

# 6. 密钥扫描：对 git 跟踪文件 grep 常见密钥模式
SECRET_PATTERN='sk-ant-|ghp_|github_pat_|AKIA[A-Z0-9]{16}|-----BEGIN.*PRIVATE KEY'
SECRET_HITS=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  # 本脚本自身携带模式字符串，入库后会自己扫中自己，跳过防自指误报
  [ "$f" = "scripts/release_check.sh" ] && continue
  if grep -lE "$SECRET_PATTERN" "$f" >/dev/null 2>&1; then
    SECRET_HITS="$SECRET_HITS $f"
  fi
done < <(git ls-files 2>/dev/null)

if [ -z "$SECRET_HITS" ]; then
  ok "密钥扫描" "git 跟踪文件中未发现常见密钥模式"
else
  bad "密钥扫描" "以下文件命中密钥模式:$SECRET_HITS —— 立即处理，不要发版"
fi

# 7. git 整洁度：工作区无未提交改动（允许 untracked 的 工作交接_*.md 与 .github/），且存在 tag v$VERSION
GIT_STATUS="$(git -c core.quotepath=false status --porcelain 2>/dev/null)"
UNEXPECTED=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  STATUS_CODE="${line:0:2}"
  FILE="${line:3}"
  if [ "$STATUS_CODE" = "??" ]; then
    case "$FILE" in
      工作交接_*.md|.github/|.github/*) continue ;;
      *) UNEXPECTED="$UNEXPECTED
$line" ;;
    esac
  else
    UNEXPECTED="$UNEXPECTED
$line"
  fi
done <<< "$GIT_STATUS"

TAG_NAME="v${VERSION_FILE_VER}"
TAG_EXISTS=0
if git tag -l "$TAG_NAME" 2>/dev/null | grep -q "^${TAG_NAME}$"; then
  TAG_EXISTS=1
fi

if [ -z "$UNEXPECTED" ] && [ "$TAG_EXISTS" -eq 1 ]; then
  ok "git 整洁度" "工作区无未提交改动（allowlist 之外），且存在 tag $TAG_NAME"
else
  DETAIL=""
  if [ -n "$UNEXPECTED" ]; then
    DETAIL="$DETAIL 存在未预期的未提交改动:${UNEXPECTED};"
  fi
  if [ "$TAG_EXISTS" -eq 0 ]; then
    DETAIL="$DETAIL 缺少 tag $TAG_NAME;"
  fi
  bad "git 整洁度" "$DETAIL —— 先 commit + 打 tag 再发版"
fi

echo ""
if [ "${#FAILED_ITEMS[@]}" -eq 0 ]; then
  echo "==> ✅ 全部检查通过，可以发版"
  exit 0
else
  echo "==> ❌ 以下 ${#FAILED_ITEMS[@]} 项未通过，修复后重跑本脚本："
  for item in "${FAILED_ITEMS[@]}"; do
    echo "   - $item"
  done
  exit 1
fi
