# Root 模式

Miko 可为用户自己的 Android 模拟器启用 Root。Root 是每台设备的独立属性（`root_mode: none | adb | magisk`），通过 `miko root set` 切换，不修改共享 SDK 系统镜像。

| 模式 | 镜像 | 原理 | 验证 |
|---|---|---|---|
| `none` | 全部 | 原版启动 | `adb shell id` → uid 2000 |
| `adb` | `default`、`google_apis`、`aosp_atd` | 每次启动后执行 `adb root` | `adb shell id` → uid 0 |
| `magisk` | 全部 | 修补设备独立的 ramdisk，冷启动 | `adb shell su -c id` → uid 0，`su -c 'magisk -v'` |

```bash
miko root set <device> magisk           # 一键完整 Root
miko root set <device> adb              # Shell Root
miko root set <device> none             # 恢复原版
miko root writable-system <device> on   # adb 模式：可写 /system
miko root verify <device>               # 核对运行时 uid
miko root status <device>               # 已保存模式、健康状态和 Magisk 版本
```

> 所有模拟器均无法通过 Play Integrity；Zygisk/DenyList 只能对本地检查隐藏 Root。

<a id="how-magisk-mode-works"></a>

## Magisk 模式的工作方式

`root.set magisk` 作为一个支持进度和取消的任务完成以下步骤：

1. 验证 macOS 应用内置的官方 Magisk APK 并导入本地缓存；独立 CLI 可从 GitHub 获取固定版本，见[许可证](#magisk-licence)。
2. 计算原始镜像 `ramdisk.img` 的哈希值。
3. 在宿主机使用 `miko-cpio` 修补**设备独立副本**：将 `init` 替换为 `magiskinit`，压缩载荷放入 `overlay.d/sbin`，配置写入 `.backup/.magisk`。结果先写临时文件再重命名，原子保存为 `<avd>/miko/ramdisk.magisk-<ver>.img`。
4. 某些系统镜像（特别是 Android Studio 安装的镜像）使用 Android boot image（`ANDROID!` 容器）而非裸压缩 cpio 保存 `ramdisk.img`。Miko 会提取内嵌 ramdisk 后修补，输出仍是供模拟器 `-ramdisk` 使用的裸 ramdisk。支持 boot image v0–v4；不支持或截断的容器会报告专门的 boot image 错误。
5. 使用 `-ramdisk <patched>` 冷启动并安装 Magisk 应用（发行 APK 同时也是管理器）。
6. 设置 `/data/adb/magisk` 并重启一次，由 `magiskd` 启用 su。
7. 自动授权 adb shell 使用 su，然后验证。

在 `google_apis`、`default` 和 `aosp_atd` 镜像上，流程无需手动操作：使用 `adb root` 写入 shell 的 Magisk su 策略，再将 adbd 降权，最终验证 Magisk 自己的 `su`。其他应用仍显示逐应用授权提示；「全部自动授权」默认关闭。

Root 冷启动前，Miko 会请求 Android 关机，使服务有机会写入缓冲数据，包括首次启动的 Wi-Fi 配置。如果无法确认关机，则回退到常规停止设备。

<a id="packet-loss"></a>

## 丢包、DNS 和设备身份

运行中的 Shell Root 或完整 Root 设备可使用 `miko network loss <device> 10` 设置 10% 出站丢包，`miko network loss <device> 0` 清除设置；`miko root helper <device>` 查看设备内辅助程序状态。设备中心的「设备工具 → 网络」提供相同控制。内核、网络和 qdisc 限制见[设备内辅助程序](on-device-helper.md)。

`miko network dns <device> slow --delay-ms 3000` 延迟 DNS 查询；`fail` 丢弃查询，`normal` 清除 DNS 模拟。设备的 Root 模式和内核支持时，重启后会恢复设置。

`miko identity <device>` 读取 Android ID 和 IMEI；`--android-id` 为已安装应用写入 16 位十六进制 Android ID 并重启 Android 框架，需要 Shell Root 或完整 Root。IMEI 为只读。

`miko flash <device> <zip>` 先检查压缩包：Magisk 和 Zygisk 模块可安装到完整 Root 设备，其他设备则复制到 Download；Recovery、Riru 和镜像包会被拒绝，其他 ZIP 复制到 Download。SDK 系统镜像不会被覆盖。

<a id="magisk-pool-bases"></a>

## Magisk 设备池基底

可将运行中的完整 Root 设备保存为供智能体使用的一次性克隆基底：

```bash
miko base create <device> <base>
miko --json pool get <base>
miko pool release <lease>
```

保存快照后，创建基底会停止源设备。Miko 先确认修补后的 ramdisk 属于该设备，并且 `su -c id` 无需提示即可成功。Play Store 镜像需要用户在 Magisk 中授权 shell；请选择 **Forever**，因为到期授权在克隆中同样会失效。基底和每个克隆分别保存修补后的 ramdisk；克隆从快照恢复原来的 Magisk 版本和设置，使用新版本须创建新基底。快照包含源设备的应用数据和凭据，因此应使用适合交给智能体的预备设备。

<a id="revert"></a>

## 恢复原版

在 Magisk 设备上执行 `root.set none`（或 `adb`）会清除 `launch.ramdisk`、删除修补文件及元数据，并使用原版 ramdisk 冷启动。`none` 和 `adb` 随后与新设备相同。Magisk 设置失败时设备仍可恢复（健康状态为 `failed`，修补文件仍在）。

<a id="re-patch"></a>

## 重新修补

修补后的 ramdisk 记录原始 SHA-256、Magisk 版本及 APK 和构建属性。镜像或版本变化后（例如镜像更新或固定 Magisk 版本更新），下一次 `root.set magisk` 或启动钩子会从原始镜像重建副本；属性变化则立即重建。修补不会叠加。

<a id="offline-magisk"></a>

## 离线使用 Magisk

macOS 应用包包含已验证的官方 Magisk APK、许可证和在线源码获取说明；完整 Root 不会下载 Magisk。独立 CLI 可离线导入官方 APK：

```bash
miko root set <device> magisk --magisk /path/to/Magisk-v30.7.apk
```

CLI 按 SHA-256 将 APK 加入下载缓存，`root.set` 使用该缓存（`magisk_sha256`）而非下载。仍会验证 SHA-256，文件错误或被篡改时拒绝使用。

<a id="auto-grant-all-d22"></a>

## 全部自动授权（D22）

完整 Root 设备上的 adb shell 始终自动获得 `su`；其他应用默认逐一提示，用户可按设备主动开启：

```bash
miko root auto-grant <device> on    # 不提示，授予所有应用 Root
miko root auto-grant <device> off   # 恢复提示（默认关闭）
```

`root.auto_grant` 将开关保存在设备上。设备运行时，经 `adb root` 设置 Magisk 超级用户的自动响应（`su_auto_response`：`2` 为允许、`0` 为提示），并读回确认；设备停止时在下次启动应用。退出完整 Root 会关闭该开关。此设置不影响 Play Integrity。

<a id="build-props-phase-9f"></a>

## 构建属性

完整 Root 设备可报告不同的 `Build.MODEL`、`BRAND`、`MANUFACTURER`、`DEVICE`、`FINGERPRINT` 和 `VERSION.SECURITY_PATCH`。界面入口为「设备中心 → 设备工具 → Root → 构建设备身份」，CLI 或智能体可执行：

```bash
miko call device.props.set '{"device":"Phone","props":{"model":"Pixel 8","brand":"google","security_patch":"2026-10-05"}}'
miko call device.props.get '{"device":"Phone"}'
miko call device.props.set '{"device":"Phone","props":{}}'   # 恢复原值
```

`props` 是完整集合：省略或留空的字段保留镜像原值。值去除首尾空白、最多 256 字符且不能换行；`security_patch` 使用 `YYYY-MM-DD`。拒绝的字段见 `error.data.field`。

模拟器 `-prop` 只作用于 `qemu.*`，因此启动时使用 Magisk `resetprop` 设置属性。`device.props.set` 将值保存在 `<avd>/miko/props.json`，并使用相同 APK 重新修补设备 ramdisk：添加供 Magisk 加入 `init.rc` 的 `overlay.d/miko-props.rc` 和 `overlay.d/sbin` 脚本；在 zygote 启动前的 `post-fs-data` 阶段对每项属性及其分区副本（如 `ro.product.model`、`ro.product.vendor.model`）执行 `resetprop -n`。只设置身份属性，不设置硬件或 HAL 属性。

下次冷启动后生效，在此之前 `restart_required` 为 true。其他 Root 模式以 `usage` 拒绝 `device.props.set`。恢复 Root 时启动原版 ramdisk、丢弃保存的属性并恢复原值。更改指纹不能使模拟器通过 Play Integrity。

<a id="writable-system-adb-mode"></a>

## 可写 /system（adb 模式）

设备中心的「设备工具 → Root → 系统分区」提供资格检查和冷启动确认。恢复只读会移除可写 overlay 及其中的系统修改；概览只显示 Root 信息，验证与修改在 Root 工具中进行。界面操作见[设备中心指南](device-center.md)。

API 31 及以上的 Shell Root（`adb`）设备可启动可写 `/system`，以便将文件推入系统分区：

```bash
miko root writable-system <device> on    # -writable-system + adb remount
miko root writable-system <device> off   # 恢复原版只读镜像
```

`root.writable_system {device, enabled}` 将设置保存在设备 Root 状态的 `writable_system` 中。修改会强制冷启动（D29）：运行中立即重启，已停止的设备下次启动时生效。API 30 及更旧镜像以 `usage`（退出码 2）拒绝：API 30 的 `adb remount` 会使 `/system` 保持只读，且无法从用于修复的重启恢复。

启用后，模拟器以 `-writable-system` 启动系统镜像的可写副本；每次启动后 Root 钩子执行 `adb root` 和 `adb remount`。首次 remount 会关闭 verity 并要求重启；若 remount 后仍只读，Miko 重启一次、等待启动、重新 root adbd 并 remount。随后验证能否在 `/system` 创建文件，失败则返回 `root_failed`（退出码 7）。后续启动只需 remount。

关闭运行中设备的设置会执行 `adb enable-verity` 移除 overlay，再不带 `-writable-system` 冷启动，恢复原版只读镜像；停止中的设备若仍挂载 overlay，下次启动时同样清理。退出 adb Root（`root.set none` 或 `magisk`）也会关闭设置。

仅允许能执行 `adb root` 的 `adb` 模式镜像（`default`、`google_apis`、`aosp_atd`）；对 `none`、`magisk` 或 Play Store 镜像启用会返回 `usage`，关闭始终允许。完整 Root 设备应通过 Magisk 模块修改系统文件。可写 `/system` 的设备不能创建为设备池基底（D42），须先关闭；可写副本可能占用设备目录数 GB 空间。

<a id="ca-certificates-system-trust"></a>

## CA 证书（系统信任）

要在 Burp 或 mitmproxy 中查看应用 HTTPS 流量，应用必须信任代理 CA。面向 Android 7 或更高版本的应用忽略用户安装的 CA，因此 Miko 在完整 Root 设备的**系统证书库**中添加：

```bash
miko cert install <device> ~/Downloads/cacert.der   # PEM 或 DER；重启设备
miko cert list <device>                             # Miko 证书及信任状态
miko cert verify <device>                           # 未全部进入证书库则退出码 7
miko cert remove <device> a4ac454c.0                # 也可使用主题哈希、SHA-256 或 --all
miko proxy set <device> 8080                        # 流量发往 10.0.2.2:8080
```

Burp 在 Proxy › Proxy settings › Import / export CA certificate 导出 DER；mitmproxy 证书位于 `~/.mitmproxy/mitmproxy-ca-cert.pem`。界面入口为「设备中心 → 设备工具 → Root → CA 证书 → 添加」。

Miko 按 Magisk 文档规定的模块布局写入 `/data/adb/modules/miko_cacerts`。证书名称为 Android 证书库格式 `<subject hash>.<n>`（OpenSSL 的 `subject_hash_old`；`n` 区分同一主题的证书，例如重新生成的 Burp CA 可为 `.1`）。

- **API 29–33：**读取 `/system/etc/security/cacerts`；模块的 `system/` 文件夹通过 Magisk 系统 overlay 放入证书。
- **API 34+：**读取 Conscrypt APEX 的 `/apex/com.android.conscrypt/cacerts`，overlay 无法覆盖。Magisk 在 Zygote 启动前执行模块的 `post-fs-data.sh`，把原证书库和 Miko 证书复制到 tmpfs，再绑定挂载覆盖 APEX 证书库；Zygote 及其派生应用继承挂载。

更改在下次启动生效，因此 `install` 和 `remove` 会冷启动设备并验证。验证使用 `nsenter` 进入 Zygote 的挂载命名空间，逐字节比较其看到的证书；`list` 对尚未进入该证书库的证书返回 `trusted: false`。

已信任证书再次安装不会修改或重启；删除最后一张会删除模块。Root 恢复到 `none` 或 `adb` 后 Magisk 停止，证书不再生效；同一数据重新启用完整 Root 后恢复，清除设备数据则删除证书。仅支持完整 Root：`adb root` 不能修改运行中设备的系统证书库。证书固定的应用仍会拒绝代理，需要另用 Frida 等工具。

<a id="play-store-images-beta"></a>

## Play Store 镜像（测试版）

`google_apis_playstore` 拒绝 `adb root`，无法预先授权 shell。Miko 按 ADR-0002 引导用户操作：

1. 按上述流程修补、冷启动、安装应用并设置环境。
2. Miko 提示 Magisk 将请求授予 Shell Root，执行 `su -c id` 唤出正常授权提示。
3. 在 60 秒内点击 Grant，授权 shell。
4. 拒绝或超时则状态为 `awaiting_user_grant`，可选择重试或恢复。

Play Store 镜像没有无界面绕过方式，应用仍需逐个通过 Magisk 授权。

<a id="magisk-licence"></a>

## Magisk 许可证

Magisk 使用 **GPL-3.0-or-later**。macOS 应用包含已验证的官方 APK 和许可证；对应源码及子模块检出说明见 [Magisk 声明](../packaging/magisk/NOTICE.txt)。内置 APK 用于完整 Root，无需下载；独立 CLI 可从 GitHub 获取固定 APK 并验证 SHA-256。Miko 的修补器根据公开文档重现 ramdisk 布局，不复制 Magisk GPL 代码（见 `docs/clean-room.md`）。
