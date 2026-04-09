# Contributing

感谢你对「进度条」项目的关注！欢迎任何形式的贡献。

## 如何贡献

### 报告 Bug

1. 在 [Issues](https://github.com/notwin/ProgressBar/issues) 中搜索是否已有相关问题
2. 如没有，新建 Issue 并选择 **Bug Report** 模板
3. 提供 macOS 版本、复现步骤和截图

### 功能建议

1. 新建 Issue 并选择 **Feature Request** 模板
2. 描述你的使用场景和期望的行为

### 提交代码

1. Fork 本仓库
2. 创建功能分支：`git checkout -b feat/your-feature`
3. 提交更改：`git commit -m "feat: 描述你的更改"`
4. 推送到你的 Fork：`git push origin feat/your-feature`
5. 创建 Pull Request

### Commit 规范

使用 [Conventional Commits](https://www.conventionalcommits.org/) 格式：

- `feat:` 新功能
- `fix:` Bug 修复
- `refactor:` 重构
- `docs:` 文档
- `chore:` 杂项

### 编译运行

```bash
./build.sh
```

要求：macOS 14.0+、Xcode Command Line Tools（提供 Swift 6 编译器）

## 代码规范

- 遵循 Swift 官方编码风格
- 保持文件职责单一
- 提交前确保编译通过
