# BKGitClient

BKGitClient 是一个 macOS 菜单栏 Git 客户端，用于浏览本地仓库的提交历史、分支图、文件差异、未提交改动和项目文件，也支持从远端抓取上游更新。

## 构建与使用

需要 macOS 14 或更高版本，以及 Xcode。用 Xcode 打开 `BKGitClient.xcodeproj`，选择 `BKGitClient` 方案和 `My Mac`，点击运行。启动后，从菜单栏图标打开应用，选择本地 Git 仓库或其中的目录。

项目包含构建所需的 Monaco 查看器资源。修改查看器源码后，可在 `MonacoSource` 目录运行 `npm ci` 和 `npm run build` 来重新生成资源。

## 许可

项目自有代码采用 [MIT License](LICENSE)。随项目分发的第三方组件保留各自的许可证与声明，见 [MonacoViewer](BKGitClient/MonacoViewer) 和 [MaterialIconTheme](BKGitClient/MaterialIconTheme)。
