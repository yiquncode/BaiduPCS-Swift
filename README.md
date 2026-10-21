# Ferry

Ferry 是 Swift 编写的 macOS 原生百度网盘下载工具。它把分享链接中或自己网盘中的文件下载到本地。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/screenshot-dark.png">
  <img src=".github/screenshot-light.png" alt="Ferry 主窗口：侧边栏按状态列出任务，右边是转存中、下载中、等待、失败和已完成的任务" width="1100">
</picture>

## 功能

- **下载分享链接**：复制分享链接后切换到 Ferry，Ferry 自动填入链接和提取码并打开分享。文件先转存到自己网盘的 `/Ferry` 目录，再下载到本地。下载完成后可以自动删除转存的文件。
- **从我的网盘下载**：在文件树中勾选自己网盘中的文件和目录，直接下载。Ferry 不修改、不删除网盘中的源文件。
- **网页登录**：在百度的官方登录页登录。Ferry 只读取登录后的 Cookie，凭据存在 Keychain 中。
- **按会员类型设置并发**：同时下载的文件数和每个文件的连接数默认都是 1。非超级会员使用多个连接会被百度限速，超级会员可以在设置中调高。

## 系统要求

- macOS 14 或更高版本
- 构建需要 Xcode 26（Swift 6.2）

## 构建

```sh
git clone <仓库地址>
cd BaiduPCS-Swift
open BaiduPCS-Swift.xcodeproj
```

在 Xcode 中选择 `BaiduPCS-Swift` scheme，然后运行。

要用自己的开发团队签名，在 `Config/` 中新建 `Local.xcconfig`：

```
DEVELOPMENT_TEAM = <你的 Apple 开发团队 ID>
```

这个文件不提交到仓库。没有这个文件时，工程也能构建。

## 测试

协议和下载逻辑在本地 Swift Package `Packages/FerryKit` 中，可以不打开 Xcode 测试：

```sh
cd Packages/FerryKit
swift test
```

测试使用桩服务器和假网盘，不访问百度。

`LiveSmokeTests` 用真实账号做只读检查（校验登录、打开分享、列目录），不转存、不删除。设置以下两个环境变量后才运行：

```sh
FERRY_LIVE_COOKIE_FILE=~/cookie.txt \
FERRY_LIVE_SHARE='https://pan.baidu.com/s/1qYZEsSc' \
swift test --filter LiveSmokeTests
```

## 项目结构

```
BaiduPCS-Swift/          Ferry.app：SwiftUI 界面、Keychain、下载目录权限、应用生命周期
Packages/FerryKit/
├── FerryCore            任务流程：任务模型、任务列表、JobCoordinator、设置
├── BaiduKit             百度协议：凭据、分享、转存、网盘操作、下载链接
└── DownloadKit          通用分片下载：分片、并发、断点续传、进度持久化
```

`BaiduKit` 和 `DownloadKit` 互不依赖。`FerryCore` 把两者组合起来，不依赖界面。

## 致谢

百度网盘接口的用法参考了 [BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go)。

## 许可证

[Apache License 2.0](LICENSE)
