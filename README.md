# 进度条 - macOS 任务管理应用

## 文件结构

```
进度条项目/
├── main.swift              # 全部源码（约1160行，单文件 SwiftUI 应用）
├── build.sh                # 一键编译+部署脚本
├── README.md               # 本文件
└── AppBundle/              # App Bundle 模板
    └── Contents/
        ├── Info.plist      # 应用配置（bundle id: com.notwin.progressbar）
        └── Resources/
            └── AppIcon.icns # 应用图标
```

## 一键编译部署

```bash
cd 进度条项目
chmod +x build.sh
./build.sh
```

脚本会自动：编译 → 关闭旧应用 → 复制到 /Applications/进度条.app → ad-hoc签名（无需密码） → 启动

## 手动编译

```bash
swiftc main.swift -parse-as-library -framework SwiftUI -framework AppKit -framework QuartzCore -framework UniformTypeIdentifiers -o jindu
```

## App Bundle 信息

- 安装路径: `/Applications/进度条.app/`
- 可执行文件名: `ProgressBar`（Info.plist 中 CFBundleExecutable=ProgressBar）
- Bundle ID: `com.notwin.progressbar`
- 最低系统版本: macOS 14.0

## 已知问题（导出图片功能）

当前用 `ImageRenderer` + `scale = 2.0` 导出高清图片，但可能仍有问题。

**踩过的坑，不要再踩：**
- ❌ `CGContext` + `layer.render(in:)` → 图片水平镜像，完全不能用
- ❌ `NSHostingView` + `bitmapImageRepForCachingDisplay` → 只能输出 1x 低清
- ❌ `NSBitmapImageRep` 2x pixels + `cacheDisplay` → 也没有产出 2x

## 功能概览

- 任务分组管理（多 section）
- 拖动排序（SwiftUI onDrag/onDrop + DropDelegate）
- 跟进记录（日志），默认全部展开
- hover 显示操作栏（+ 添加日志、✓ 完成、🗑 删除）
- 所有删除操作有确认弹窗
- 导出为 PNG 图片（含跟进记录）
- 深色/浅色主题
- 数据持久化
