# Changelog

All notable changes to this project will be documented in this file.

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
