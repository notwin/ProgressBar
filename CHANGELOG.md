# Changelog

All notable changes to this project will be documented in this file.

## [4.8] - 2026-04-09

### Changed
- 日历同步从导出菜单独立为工具栏按钮，与 iCloud 图标并列
- 未同步时显示同步按钮，已同步时显示解绑按钮
- 发布日志改为从 CHANGELOG 自动提取

### Fixed
- 任务行 hover 残影问题（去除动画延迟）
- 设置面板支持 ⌘W 关闭
- Swift 6 并发安全编译问题
- App bundle 改名 Progress.app 适配国际化

## [4.5] - 2026-04-09

### Added
- 国际化支持 13 种语言（简体中文、繁體中文、English、Français、Deutsch、हिन्दी、Indonesia、Italiano、日本語、한국어、Português、Español × 2）
- 设置窗口新增语言切换标签页
- 英文 README (README_en.md)

### Changed
- 主题选择器改为紧凑网格布局
- 设置窗口尺寸优化，所有标签页支持滚动
- 按钮和列表项添加 hover 高亮效果

## [4.4] - 2026-04-09

### Added
- 设置窗口（⌘,）：外观、检查更新、关于三个标签页
- GitHub Releases 检查更新功能，应用菜单新增「检查更新...」入口
- ⌘1~⌘9 快捷键切换分区

### Changed
- 精简菜单栏，移除无用的系统默认菜单项（Edit/View）
- ⌘N 修复为新建任务（不再触发系统新建窗口）

## [4.2] - 2025-04-09

### Added
- 导出文本增加完成/进行中统计摘要
- 按钮 hover 放大动效
- 跟进记录日期可编辑，按日期自动排序

### Changed
- 阻塞状态视觉优化（pause 图标 + 橙色）
- 默认示例任务改为通用引导内容，移除真实数据硬编码

### Fixed
- iCloud 数据异常时自动从本地备份恢复
- `AppData.version` 使用 `decodeIfPresent` 兼容旧数据

## [4.1] - 2025-04-08

### Changed
- 架构全面升级重构
- 全面修复 code review 发现的问题

## [4.0] - 2025-04-08

### Added
- 首个开源版本
- 多分区任务管理
- 任务状态流转（待开始 / 进行中 / 已阻塞 / 已完成）
- 跟进记录系统
- 系统日历集成（EventKit）
- 多格式导出（文本 / PNG）
- 7 套主题配色
- iCloud 同步 + 本地备份
- 命令行一键编译部署
