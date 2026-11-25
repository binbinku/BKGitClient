# BKGitClient 交付流程

每次完成代码或工程改动后，在交付前执行以下步骤：

1. 用 Xcode 的 `BKGitClient` 方案构建 macOS Release 版 `BKGitClient.app`，验证应用签名。
2. 将新应用安装到 `/Applications/BKGitClient.app`。已有同名应用时，先确认其 bundle ID 是 `com.baiwenbin.BKGitClient`，并在替换期间保留可恢复的旧版本。
3. 退出正在运行的 BKGitClient 实例。如果旧实例由 Xcode 调试启动，通过 Xcode 的 Stop 结束调试。然后从 `/Applications/BKGitClient.app` 启动新版，核对运行进程来自该安装路径，再报告交付完成。

安装和重启沿用应用的偏好设置。验证 Git 功能时只使用临时仓库。
