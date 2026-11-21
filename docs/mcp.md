# 面向 AI 智能体的 MCP 服务

`miko mcp` 通过标准输入输出提供 [Model Context Protocol](https://modelcontextprotocol.io) 服务。智能体可以调用 miko 命令，也可以使用查看画面、点击、输入和读取界面等工具；后台未运行时会自动启动 daemon。

## 在 Codex 中配置

在 miko 模拟器设置中选择「配置 Codex」。命令路径默认为应用内的 miko 命令，可按需修改。按钮运行 `codex mcp add`，保留其他 Codex 设置。配置后重启 Codex 或开始新对话。

也可以手动运行：

```bash
codex mcp add miko -- "/Applications/miko simulator.app/Contents/Helpers/miko" mcp
codex mcp list
```

请将路径改为实际安装位置。手动编辑时，可在 `~/.codex/config.toml` 中添加：

```toml
[mcp_servers.miko]
command = "/Applications/miko simulator.app/Contents/Helpers/miko"
args = ["mcp"]
```

设置按钮需要 Codex CLI。其他 MCP 客户端仍可按自己的方式配置 `miko mcp`。`miko uninstall` 会移除 miko 的 Codex 条目（D31）。

## 在 WorkBuddy 中配置

在设置中选择「配置 WorkBuddy」，将 miko 服务加入用户级 `~/.workbuddy/mcp.json`，保留原有条目；也可以选择「复制 WorkBuddy MCP 配置」，再将 JSON 合并到 WorkBuddy 的 MCP 配置。保存后请在 WorkBuddy 中检查服务连接状态。用户级配置对各项目生效；详情见 [WorkBuddy MCP 指南](https://www.codebuddy.ai/docs/zh/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/MCP-Guide)。

`miko uninstall` 也会移除该用户级文件中的 miko 条目。

miko 模拟器尚未发布到 MCP Registry。可使用 `cargo xtask release --rehearsal` 构建匹配的本地 MCP 包；`server.json` 中存在版本号不代表对应发行资源或 Registry 条目已发布。实际资源发布前，Registry 校验值仍是占位值。

## 工具

| 工具 | 类型 | 功能 |
|---|---|---|
| `command_list {prefix?}` | 只读 | 列出所有 miko 命令、参数 schema 和标记。 |
| `command_run {command, params, timeout_s?}` | 可能有破坏性 | 运行命令；启动、镜像安装等长任务等待最多 `timeout_s`（900 秒），然后以任务形式返回。 |
| `pool_get {base, ttl_s?, timeout_s?}` | 交互 | 从基底创建写时复制的临时设备并从快照恢复，返回 `{lease, device, serial, connect}`。不指定 `ttl_s` 时，租约持续到 MCP 会话结束后两分钟。 |
| `pool_release {lease \| device}` | 破坏性，仅限自己的克隆 | 归还克隆设备，停止并删除它。 |
| `jobs_list {all?}`、`jobs_cancel {job}` | 只读 / 幂等 | 查看或取消长任务。 |
| `screenshot {device}` | 只读 | 返回适配到 1024×1024 内的 PNG、屏幕尺寸和缩放比例。 |
| `tap {device, x, y, coords?}` | 交互 | 点击；默认使用截图坐标，`coords: "device"` 使用设备坐标。 |
| `swipe {device, x1, y1, x2, y2, duration_ms?, coords?}` | 交互 | 滑动或拖动，例如滚动或打开应用抽屉。 |
| `type_text {device, text, enter?}` | 交互 | 向焦点输入框输入可打印 ASCII。 |
| `press_key {device, key}` | 交互 | 发送 `GoHome`、`GoBack`、`AppSwitch`、`Enter`、`Power`、音量或方向键等。 |
| `ui_dump {device}` | 只读 | 返回 uiautomator XML，可通过文字、ID 和边界定位点击目标。 |
| `logcat_tail {device, lines?, filter?}` | 只读 | 返回匹配过滤条件的最近 N 行日志。 |
| `ca_cert_install {device, path}` | 可能重启设备 | 在运行中的 Full Root 设备上安装并验证本机 PEM 或 DER CA 证书；`root.cacert.list` / `.verify` / `.remove` 通过 `command_run` 调用。 |
| `command_run root.writable_system {device, enabled}` | 重启运行中的设备 | 设置 `adb` Root 设备的 `/system` 可写或恢复只读。其他 Root 模式、Play Store 镜像及低于 API 31 的镜像会返回 `usage`；见 [Root 指南](root.md)。 |
| `proxy_set {device, host?, port}`、`proxy_clear {device}` | 幂等 | 设置或清除设备全局 HTTP 代理，供 Mac 上的 Burp 或 mitmproxy 使用；`host` 默认 `10.0.2.2`，即模拟器看到的 Mac 地址。 |
| `sync_start {leader, followers, options?}`、`sync_stop`、`sync_status` | 交互 / 幂等 / 只读 | 管理多设备输入同步（D45，[同步指南](sync.md)）；主控端需打开播放器窗口。 |

TTL 租约从克隆设备交付时开始，daemon 重启后保留 ID 和截止时间。连接租约在 daemon 重启后进入相同的两分钟宽限期；已有宽限截止时间不会因再次重启而延长。正在释放的克隆设备续租时返回 `busy`。

创建基底会保留源设备的动画设置；设备池克隆在启动后、交付给智能体之前会禁用动画。

其他操作通过 `command_run` 调用。例如，使用 Mac 上的 WAV 作为设备麦克风输入：`command_run {command: "audio.inject", params: {device, path, loop?}, timeout_s: 5}` 在播放期间返回任务，`command_run {command: "audio.stop", params: {device}}` 停止播放。

网络模拟可通过 `network.shaping.get` 和 `network.shaping.set {device, loss_pct?, dns?, dns_delay_ms?}` 调用，需要 Shell Root 或 Full Root 及 netem 支持；设置会在启动后恢复。`identity.get/set`、`input.gamepad.*`、`file.sync.*` 和 `file.flash` 也可通过 `command_run` 调用。文件夹同步支持默认的 `one_way`（主机删除会移除此前同步的文件，保留设备独有文件）和 `bidirectional`（双向同步增删，通过 `file.sync.resolve` 处理冲突）。接口与 qdisc 限制见[设备内辅助程序](on-device-helper.md)。

各工具带有 `readOnlyHint`、`destructiveHint`、`idempotentHint` 和 `openWorldHint` 标记。miko 错误以 `isError: true` 和结构化 `{code, message, data}` 返回；错误码见[控制协议](control-protocol.md)。例如，智能体可以在 `not_found` 后启动已停止的设备。

## 智能体使用的设备（D42）

智能体应使用自己的设备，不要使用用户的设备（例如不要直接使用用户的 `emulator-5554`）：

- **临时设备**：使用 `pool_get {base}`。通过 `command_run base.list` 查看基底，用户可用 `miko base create <device> <name>` 创建。使用返回的 `serial` 配合 adb、Flutter 或 Gradle，完成后调用 `pool_release`；会话结束时未归还的克隆会在两分钟后删除。长任务可设置 `ttl_s` 并通过 `command_run pool.renew` 续租。
- **Magisk 基底**：如果源设备已有有效的 shell `su` 授权，可以使用 Magisk Root 基底。克隆继承基底快照的数据和 Root 设置，只使用专为智能体访问准备的基底；见 [Root 指南](root.md#magisk-pool-bases)。
- **持久设备**：使用 `command_run device.create {name, image, profile: "agent-lean"}` 和 `device.start`；该配置约使用 4 GB 主机内存，而非约 7.6 GB。空闲时可用 `device.hibernate` 休眠。
- **主机内存不足**：`pool_get` 最多等待 `timeout_s`（120 秒）后返回 `resource_exhausted`；`device.start` 则立即返回。`data.devices` 描述内存占用，`data.hibernate_candidates` 列出空闲时间最长的设备。应休眠或释放自己的设备，或等待，不要休眠用户的设备。

## 安全策略（D5）

默认允许智能体读取、交互、启动和停止。标记为破坏性的命令（如 `device.delete`、`device.reset`）只有在以下情况才允许：

- 设备属于 **agent-owned**：智能体通过 `command_run device.create` 创建的设备自动具有此标记；用户也可使用 `miko device edit <name> --agent-owned true` 标记；或
- 服务以 `miko mcp --allow-destructive` 启动。

拒绝响应包含 `data.policy = "D5"`。连接级协议方法（`hello`、`events.subscribe`、`logcat.follow`、`daemon.shutdown`）不能通过 MCP 调用。

## 已测延迟（非门槛）

在 M1 Pro、API 31 arm64 上对五项脚本化智能体任务的历史测量（`cargo nextest run -p miko-mcp --features emulator`）：截图约 0.4～1.1 秒、点击约 0.2～0.4 秒、`type_text` 约 0.7～1.2 秒、`press_key` 约 0.01～0.1 秒、滑动 1～4 秒、`logcat_tail` 约 0.2～0.5 秒、`ui_dump` 中位数 4～6 秒（uiautomator 本身较慢），`command_run device.start` 冷启动 25～32 秒。实际表现取决于设备和场景。
