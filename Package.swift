// swift-tools-version:5.9
// 仅供 SourceKit-LSP 索引使用（VSCode/Cursor/Zed/nvim 等编辑器跳转、补全、报错）
// 实际构建走 Scripts/build.sh，不依赖 SwiftPM。
import PackageDescription

let package = Package(
    name: "ProgressBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ProgressBar",
            path: "Sources",
            exclude: ["Localization"]
        )
    ]
)
