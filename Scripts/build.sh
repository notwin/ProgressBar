#!/bin/bash
# 编译并部署 Progress 应用
# 用法: ./Scripts/build.sh（从项目根目录运行）

set -e

# 定位到项目根目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="/Applications/Progress.app"
SRC="$ROOT_DIR/Sources"

echo "==> 编译 ..."
cd "$ROOT_DIR"
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
  -framework SwiftUI \
  -framework AppKit \
  -framework QuartzCore \
  -framework UniformTypeIdentifiers \
  -framework EventKit \
  -o "$ROOT_DIR/jindu"

echo "==> 关闭正在运行的应用 ..."
killall 'ProgressBar' 2>/dev/null || true
sleep 1
killall -9 'ProgressBar' 2>/dev/null || true
sleep 1

# 清理旧版中文名 app（迁移用）
if [ -d "/Applications/进度条.app" ] && [ "$APP_PATH" != "/Applications/进度条.app" ]; then
  echo "    清理旧版「进度条.app」..."
  rm -rf "/Applications/进度条.app"
fi

echo "==> 部署到 $APP_PATH ..."
if [ ! -d "$APP_PATH" ]; then
  echo "    创建 App Bundle ..."
  mkdir -p "$APP_PATH/Contents/MacOS"
  mkdir -p "$APP_PATH/Contents/Resources"
fi

cp "$ROOT_DIR/AppBundle/Contents/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ROOT_DIR/AppBundle/Contents/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/jindu" "$APP_PATH/Contents/MacOS/ProgressBar"

echo "==> 复制本地化资源 ..."
for lproj in "$SRC/Localization/"*.lproj; do
  lname="$(basename "$lproj")"
  mkdir -p "$APP_PATH/Contents/Resources/$lname"
  cp "$lproj/"*.strings "$APP_PATH/Contents/Resources/$lname/"
done

echo "==> Ad-hoc 签名 ..."
codesign --force --sign - "$APP_PATH"

echo "==> 启动应用 ..."
sleep 1
open -a 'Progress'

echo "==> 完成！"
