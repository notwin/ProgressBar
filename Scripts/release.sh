#!/bin/bash
# 本地一键发布：编译 → 打包 .app/.dmg → 推 tag → 上传到 GitHub Release
# 用法: ./release.sh        → 自动 +0.1（如 4.5 → 4.6）
#       ./release.sh 5.0    → 指定版本号

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ── 前置检查 ──────────────────────────────────────────────────
command -v gh >/dev/null || { echo "❌ 需要 gh CLI: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ gh 未登录: gh auth login"; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作区有未提交的改动，请先提交"
  exit 1
fi

# ── 版本号 ────────────────────────────────────────────────────
CURRENT=$(grep -A1 CFBundleShortVersionString AppBundle/Contents/Info.plist | grep string | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
echo "当前版本: $CURRENT"

if [ -n "$1" ]; then
  VERSION="$1"
else
  MAJOR=$(echo "$CURRENT" | cut -d. -f1)
  MINOR=$(echo "$CURRENT" | cut -d. -f2)
  VERSION="$MAJOR.$((MINOR + 1))"
fi
echo "新版本:   $VERSION"

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "❌ Tag v$VERSION 已存在"
  exit 1
fi
if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "❌ Release v$VERSION 已存在"
  exit 1
fi

# ── 修改 Info.plist（失败回滚） ──────────────────────────────
python3 -c "
import re
with open('AppBundle/Contents/Info.plist', 'r') as f:
    content = f.read()
content = re.sub(
    r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)',
    r'\g<1>$VERSION\g<2>', content)
content = re.sub(
    r'(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)',
    r'\g<1>$VERSION\g<2>', content)
with open('AppBundle/Contents/Info.plist', 'w') as f:
    f.write(content)
"

rollback() {
  echo "⚠️  发布中断，回滚 Info.plist"
  git checkout -- AppBundle/Contents/Info.plist 2>/dev/null || true
  rm -rf Progress.app ProgressBar.dmg dmg_content /tmp/progressbar-release-notes.md
}
trap rollback ERR

# ── 编译 ───────────────────────────────────────────────────────
echo "==> 编译 ..."
SRC="Sources"
swiftc \
  "$SRC/Models/Models.swift" "$SRC/Models/Theme.swift" \
  "$SRC/Services/PersistenceManager.swift" "$SRC/Services/CalendarManager.swift" \
  "$SRC/Services/AppState.swift" "$SRC/Services/UpdateChecker.swift" \
  "$SRC/Views/CalendarPicker.swift" "$SRC/Views/SectionTabBar.swift" \
  "$SRC/Views/TaskRowView.swift" "$SRC/Views/ArchiveSectionView.swift" \
  "$SRC/Views/ThemePickerView.swift" "$SRC/Views/SettingsView.swift" \
  "$SRC/Views/ExportCardView.swift" "$SRC/Views/ContentView.swift" \
  "$SRC/App/ProgressBarApp.swift" \
  -parse-as-library \
  -O -whole-module-optimization \
  -framework SwiftUI -framework AppKit -framework QuartzCore \
  -framework UniformTypeIdentifiers -framework EventKit \
  -o jindu

# ── 打包 .app ──────────────────────────────────────────────────
echo "==> 打包 Progress.app ..."
APP="Progress.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppBundle/Contents/Info.plist "$APP/Contents/Info.plist"
cp AppBundle/Contents/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp jindu "$APP/Contents/MacOS/ProgressBar"

for lproj in Sources/Localization/*.lproj; do
  lname="$(basename "$lproj")"
  mkdir -p "$APP/Contents/Resources/$lname"
  cp "$lproj/"*.strings "$APP/Contents/Resources/$lname/"
done

codesign --force --sign - "$APP"

# ── 打包 DMG ──────────────────────────────────────────────────
echo "==> 生成 DMG ..."
rm -f ProgressBar.dmg
DMG_DIR="dmg_content"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "Progress" -srcfolder "$DMG_DIR" -ov -format UDZO "ProgressBar.dmg" >/dev/null
rm -rf "$DMG_DIR"

# ── release notes ──────────────────────────────────────────────
NOTES=$(awk "/^## \[$VERSION\]/{found=1; next} /^## \[/{if(found) exit} found{print}" CHANGELOG.md)
if [ -z "$NOTES" ]; then
  PREV_TAG=$(git tag --sort=-v:refname | head -1 2>/dev/null || true)
  if [ -n "$PREV_TAG" ]; then
    NOTES=$(git log --pretty=format:"- %s" "$PREV_TAG..HEAD" 2>/dev/null | grep -v "^- chore: bump" || true)
  fi
fi
[ -z "$NOTES" ] && NOTES="Release v$VERSION"
echo "$NOTES" > /tmp/progressbar-release-notes.md

# ── 提交 + 推 tag ─────────────────────────────────────────────
echo "==> 提交版本号 + 推 tag ..."
git add AppBundle/Contents/Info.plist
git commit -m "chore: bump version to $VERSION"
git push origin main
git tag "v$VERSION"
git push origin "v$VERSION"

# ── 创建 Release + 上传 DMG ──────────────────────────────────
echo "==> 上传到 GitHub Release ..."
gh release create "v$VERSION" ProgressBar.dmg \
  --title "v$VERSION" \
  --notes-file /tmp/progressbar-release-notes.md

trap - ERR

# ── 清理 ──────────────────────────────────────────────────────
rm -rf Progress.app dmg_content /tmp/progressbar-release-notes.md

echo ""
echo "✅ v$VERSION 已发布"
echo "   https://github.com/notwin/ProgressBar/releases/tag/v$VERSION"
