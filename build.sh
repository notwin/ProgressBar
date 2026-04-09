#!/bin/bash
# 编译并部署「进度条」应用
# 用法: ./build.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="/Applications/进度条.app"

echo "==> 编译 main.swift ..."
cd "$SCRIPT_DIR"
swiftc \
  Models.swift Theme.swift \
  PersistenceManager.swift CalendarManager.swift AppState.swift \
  CalendarPicker.swift \
  SectionTabBar.swift TaskRowView.swift ArchiveSectionView.swift \
  UpdateChecker.swift \
  ThemePickerView.swift SettingsView.swift ExportCardView.swift ContentView.swift \
  ProgressBarApp.swift \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework QuartzCore \
  -framework UniformTypeIdentifiers \
  -framework EventKit \
  -o jindu

echo "==> 关闭正在运行的应用 ..."
killall 'ProgressBar' 2>/dev/null || true
killall '进度条' 2>/dev/null || true
sleep 1
killall -9 'ProgressBar' 2>/dev/null || true
killall -9 '进度条' 2>/dev/null || true
sleep 1

echo "==> 部署到 $APP_PATH ..."
# 如果 app bundle 不存在，从模板创建
if [ ! -d "$APP_PATH" ]; then
  echo "    创建 App Bundle ..."
  mkdir -p "$APP_PATH/Contents/MacOS"
  mkdir -p "$APP_PATH/Contents/Resources"
  cp "$SCRIPT_DIR/AppBundle/Contents/Info.plist" "$APP_PATH/Contents/Info.plist"
  cp "$SCRIPT_DIR/AppBundle/Contents/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

cp "$SCRIPT_DIR/AppBundle/Contents/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$SCRIPT_DIR/jindu" "$APP_PATH/Contents/MacOS/ProgressBar"

echo "==> 复制本地化资源 ..."
for lproj in "$SCRIPT_DIR/Localization/"*.lproj; do
  lname="$(basename "$lproj")"
  mkdir -p "$APP_PATH/Contents/Resources/$lname"
  cp "$lproj/"*.strings "$APP_PATH/Contents/Resources/$lname/"
done

echo "==> Ad-hoc 签名 ..."
codesign --force --sign - "$APP_PATH"

echo "==> 启动应用 ..."
sleep 1
open -a '进度条'

echo "==> 完成！"
