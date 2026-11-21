# 安全策略

## 支持的版本

miko 模拟器尚未达到 1.0。安全修复只进入最新发行版；报告前请先更新。

## 报告漏洞

请**不要为安全问题创建公开 Issue**。请在仓库 GitHub 的 **Security** 页面选择 **Report a vulnerability**，私下提交问题。说明发现的问题、复现步骤、miko 版本、macOS 版本和预期影响。

维护者目标是在 7 天内确认收到、30 天内完成初步评估，并与你沟通披露时间。除非你不希望署名，修复说明会致谢。

## 安全关注范围

- **后台 socket**：其他本地用户或无特权进程通过 Unix socket 控制设备。
- **MCP 服务**：绕过破坏性操作策略（D5），例如未使用 `--allow-destructive` 就删除或重置非 `agent-owned` 设备。
- **下载**：SDK 或系统镜像未校验仓库提供的校验值，内置 Magisk APK 未校验 `xtask/src/release.rs` 中固定的 SHA-256，或者下载路径可被攻击者篡改。
- **Root 与 ramdisk 修改**：补丁影响其他设备或原始镜像，或 Root 权限越过模拟设备影响 Mac。
- **文件处理**：拖入应用的 APK、ZIP、GPX/KML 或快照写入预期位置以外的路径。
- **发行资源**：破坏 DMG 签名或公证的情况。

Android 系统镜像本身的安全问题应向 Google 报告，Magisk 本身的问题应向其项目报告；模拟设备内拥有 Root 权限属于预期功能。

## 遥测

miko 不发送遥测数据，也不提供账号（D17）。它会连接 Google SDK 服务器以及 GPS 地图所需的 OpenStreetMap 瓦片服务器；独立 CLI 构建也可能连接 GitHub 获取固定版本的 Magisk。
