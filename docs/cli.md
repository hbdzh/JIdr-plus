# `miko` 命令行

`miko` 可从终端或 CI 脚本操作 Miko 功能，通过 daemon 通信，并在需要时自动启动 daemon（D4）。运行 `miko --help` 或 `miko <command> --help` 查看参数；`miko completions zsh|bash|fish` 输出 shell 补全。

macOS 默认数据目录为 `~/Library/Application Support/miko`；其中 `sdk`、`avd`、`cache` 和 `logs` 分别存放私有 SDK、设备、下载和日志。Miko 默认在该目录管理模拟器、ADB 和系统镜像。

## 快速开始

```bash
miko image list                                   # 适用于此 Mac 的镜像
miko sdk install emulator platform-tools          # 准备运行时
miko image install 35 --accept-licenses           # API 35 的 google_apis 镜像
miko device create Phone --image 35               # 默认使用 adb Root（D7）
miko device start Phone                           # 等待启动完成
miko install Phone app.apk
miko logcat Phone -n 100
miko device stop Phone
```

在 CI 中添加 `--json` 并检查退出码：

```bash
miko --json device start Phone --timeout 300 || exit $?
```

## 命令

| 命令 | 用途 |
|---|---|
| `device create <name> --image <img> [--profile id] [--ram MB] [--cpus N] [--width px] [--height px] [--density dpi] [--data-mb MB] [--root none\|adb\|magisk] [--agent-owned]` | 创建设备。`<img>` 可为 `35`、`35:google_apis`、`35:google_apis_playstore`、`35:google_apis:arm64-v8a` 或完整 `system-images;…` 包名。 |
| `device start <names…> \| --all [--cold-boot] [--no-wait] [--timeout s] [--force]` | 启动并等待设备完成启动；超时取消启动并返回 5，`--no-wait` 返回启动任务 ID；超出主机内存预算时返回 9，除非指定 `--force`。 |
| `device stop <names…> \| --all` | 停止设备并保存快速启动状态（D29）；先执行 `sync` 刷新设备存储，保留停止前修改的设置。 |
| `device hibernate <names…> \| --all` | 将完整状态保存到 `miko-hibernate` 快照、确认包含内存后停止设备，不保存快速启动状态（D42）。休眠不占内存，`device start` 可在数秒内恢复；`device stop` 保持休眠，`device reset` 丢弃状态。`settings set --auto-hibernate-minutes N` 设置空闲自动休眠（默认关闭）；每台设备可用 `device edit <name> --auto-hibernate N`（`0` 为从不）或 `--auto-hibernate-default` 跟随全局设置。空闲指设备没有 Miko 命令且没有连接播放器。 |
| `device list`, `device details <name>`, `device connect-info <name>` | 查看状态、设置、磁盘占用，或运行中设备的 gRPC 地址、令牌和 adb 序列号。 |
| `device clone <name> <new> [--keep-snapshot snap]`, `device edit <name> [--rename n] [--ram …] [--agent-owned bool] [--auto-hibernate N \| --auto-hibernate-default]` | 复制或修改已停止设备。`--keep-snapshot` 创建保留指定快照的写时复制克隆（APFS / reflink；其他文件系统在检查磁盘后完整复制），首次启动数秒内从快照恢复（D42）；否则冷启动。 |
| `device reset <name> --yes`, `device delete <names…> \| --all --yes` | 破坏性操作：清除数据或删除设备。缺少 `--yes` 时会在终端询问，在非交互环境拒绝。 |
| `install <name> <apk> [--no-replace] [--grant] [--downgrade]` | 安装 APK；签名不匹配时失败并返回 `details.signature_mismatch = true`。 |
| `push <name> <local> [remote]`, `pull <name> <remote> <local>` | 复制文件；push 默认目标为 `/sdcard/Download/`。 |
| `logcat <name> [-n N] [--filter spec…] [-f] [--clear]` | 输出、持续跟随（`-f`）或清除日志。 |
| `flash <name> <zip>` | 在完整 Root 设备安装 Magisk/Zygisk 模块，或把其他支持的 ZIP 复制到 Download；拒绝 Recovery、Riru 和分区镜像包。 |
| `sync start <device> <folder> [remote] [--bidirectional]`, `sync list [device]`, `sync resolve <id> <path> --keep local\|remote\|both`, `sync stop <id>` | 单向或双向文件夹同步。单向同步主机修改和删除，保留仅存在于设备的文件；`--bidirectional` 双向同步修改和删除，并保留冲突以供 `sync resolve` 处理。启动命令会在首次复制完成前返回。 |
| `input-sync start --leader <dev> --follower <dev>… [--adaptation stretch\|letterbox] [--no-keyboard] [--no-text] [--no-tool-keys] [--unlock-followers] [--jitter-ms N]`, `input-sync stop`, `input-sync status`, `input-sync add\|remove\|leader <dev>` | 将主设备的播放器输入镜像到运行中的跟随设备（D45，[sync.md](sync.md)）。CLI 管理会话；主设备播放器窗口打开时才传送输入。 |
| `gamepad list`, `gamepad connect <device> [--controller id]`, `gamepad disconnect <device>` | 将 Mac 游戏手柄转发至运行中的模拟器；连接命令返回任务 ID。 |
| `identity <device> [--android-id ID]` | 读取 Android ID 和 IMEI，或通过 Root 设置 16 位十六进制 Android ID；设置会重启 Android 框架。IMEI 只读。 |
| `image list [--installed]`, `image install <img> [--accept-licenses]` | 列出或安装系统镜像。 |
| `profile list` | 内置硬件配置（D24）。`agent-lean`（720×1280、2 GB、2 核、不启用音频或相机）约占用 4 GB 主机内存，而非约 7.6 GB。 |
| `budget` | 查看主机内存、设备预算（`settings set --budget-percent`，默认 75%）和运行设备预估及实际占用（D42）。 |
| `network loss <device> [percent]`, `network dns <device> [normal\|slow\|fail] [--delay-ms N]` | 控制出站丢包及 DNS 模拟；需要 Root 和 netem，启动时恢复已保存设置。见[设备内辅助程序](on-device-helper.md)。 |
| `root helper <device>` | 按需启动设备内辅助程序，报告版本、协议、uid 和 SELinux 上下文。 |
| `sdk status`, `sdk licenses <pkgs…>`, `sdk install <pkgs…> [--accept-licenses]` | 查看托管 SDK、审核软件包许可证并安装组件。 |
| `root set <name> none\|adb\|magisk`, `root verify <name>`, `root status <name>`, `root auto-grant <name> on\|off` | Root 模式（由 Root 引擎提供）。`auto-grant` 使完整 Root 设备上的所有应用无需提示即可获得 Root（D22，默认关闭；`root.auto_grant`）。 |
| `root writable-system <name> on\|off` | 在 `adb` Root 设备上启用可写 `/system`（`-writable-system` + `adb remount`）；`off` 恢复原版只读镜像。运行中设备会冷启动（D29）；`none`/`magisk`、Play Store 镜像和 API 31 以下镜像返回退出码 2。详见 docs/root.md。 |
| `snapshot list\|save\|load\|delete <name> [snapshot]` | 带 Root 模式标记的快照（由工具组件提供）。 |
| `base create <device> <name>`, `base ls`, `base rm <name> --yes` | 基底（D42）：`create` 将运行设备（包括 Magisk Root）保存为含 `miko-base` 快照的只读基底，并停止设备。基底保留动画设置，设备池克隆交付前关闭动画。Magisk 需要有效的设备独立修补 ramdisk 和可用的 shell `su` 授权；基底不能启动，克隆仍被租用时 `rm` 会拒绝删除。 |
| `pool get <base> [--ttl 2h] [--timeout s]`, `pool release <lease\|device>`, `pool renew <lease> [--ttl 2h]`, `pool ls` | 为智能体和 CI 提供一次性基底克隆（D42）。`get` 恢复写时复制克隆并输出序列号；租约从交付开始按 `--ttl` 计时（默认 2 小时），到期后 daemon 停止并删除克隆。daemon 重启后保留租约 ID 和期限。内存预算已满时 `get` 最多等待 `--timeout`（默认 120 秒），然后返回 9。存在租约时 daemon 保持运行（D4）。 |
| `cert install <name> <file>`, `cert list <name>`, `cert verify <name>`, `cert remove <name> <cert>\|--all` | 管理完整 Root 设备系统证书库中的 CA 证书（Root 引擎，`root.cacert.*`）；安装和删除会重启设备。详见 docs/root.md。 |
| `proxy set <name> [host:]port`, `proxy clear <name>`, `proxy show <name>` | 设置、清除或查看设备全局 HTTP 代理（工具组件，`network.proxy.*`）；主机默认 `10.0.2.2`，即本机 Mac。 |
| `audio inject <name> <file> [--loop] [--rate Hz [--channels 1\|2]] [--no-wait]`, `audio stop <name>` | 将 WAV 作为设备麦克风播放（工具组件，`audio.*`）；`--rate` 将文件作为无头 16 位 PCM 读取。见[麦克风](#microphone)。 |
| `jobs list [--all]`, `jobs wait <job>`, `jobs cancel <job>` | 查看、等待或取消长时间运行的任务。 |
| `commands` | 列出全部协议命令（与 GUI 和 MCP 所见相同）。 |
| `call <method> [params-json]` | 直接调用任意协议命令，例如 `miko call device.start '{"device":"Phone","cold_boot":true}'`，并跟踪任务。 |
| `daemon [run]`, `daemon stop`, `daemon status` | 前台运行 daemon、停止 daemon（设备保持运行）或查看其状态。 |
| `shell [script]` | 交互式 shell 或执行命令脚本，见 [Shell](#shell)。 |
| `completions <shell>` | 输出 shell 补全。 |

全局参数：`--json`、`-q/--quiet`（不显示进度）、`--restart-stale`（或 `MIKO_RESTART_STALE=1`）。

<a id="shell"></a>

## Shell

`miko shell` 是交互式 shell，借鉴 Genymotion Shell。每行输入省略 `miko` 的命令；也会忽略开头的 `miko`，便于直接粘贴。它通过一条 daemon 连接使用 CLI 自身的命令定义，因此命令、参数、输出和退出码与单次 CLI 相同，不增加协议命令。

```text
$ miko shell
miko> use Phone
Using Phone.
miko (Phone)> device start --timeout 300
miko (Phone)> proxy set 8080
miko (Phone)> snapshot save before-login
miko (Phone)> call sensor.rotate '{"angle":90}'
miko (Phone)> --json device details
miko (Phone)> exit
```

| 内置命令 | 用途 |
|---|---|
| `use <device>` | 设置提示符中显示的当前设备；单独输入 `use` 清除。 |
| `source <file>` | 在 shell 中执行脚本。 |
| `help [command]` | 显示内置命令及命令列表，或指定命令的 `--help`。 |
| `exit [code]`、`quit`、Ctrl-D | 退出 shell。 |

**当前设备：** 对设备作为第一个参数的命令（如 `device start`、`proxy set`、`snapshot save`、`install`、`logcat`、`root`、`cert`），未指定设备时自动填入当前设备。如果第一个参数是已有设备名称或 ID，则直接使用；否则将当前设备插到参数之前（例如 `proxy set 8080` 实际执行 `proxy set Phone 8080`）。包含 `--all` 的命令不改变。`call <method> [params]` 在方法需要设备且参数未指定时加入 `"device"`。

**分词：** 类似 POSIX shell，但不做展开：单引号为字面值，双引号识别反斜杠转义的引号和反斜杠，反斜杠转义一个字符，词首 `#` 开始注释。不支持变量、管道或 `$(…)`；需要时使用外部 shell。

**补全与历史：** Tab 可补全内置命令、子命令、参数、可选值（如 `root set Phone <Tab>`）、设备名称、`call` 后 `commands.list` 中的协议方法及文件路径。历史保存在 Miko 数据目录的 `shell_history`（`~/Library/Application Support/miko` 或 `$MIKO_HOME/data`）。Ctrl-C 中断当前命令但 shell 继续运行；已启动的 daemon 任务会继续，使用 `jobs cancel` 停止。

**脚本：** `miko shell setup.miko`、管道输入（`miko shell < setup.miko` 或以 `-` 表示 stdin）和 `source` 按顺序运行各行，跳过空行与 `#` 注释，因此可用 `#!/usr/bin/env -S miko shell` 作为首行。第一条失败命令停止脚本，stderr 输出如 `setup.miko:5: stopped here (exit code 3)`，shell 返回该命令的[退出码](#exit-codes)。`exit <code>` 可提前结束脚本。`shell` 前的 `--json` 和 `-q` 对所有行生效；`--json` 下每条命令输出自己的 JSON 封套行。

```bash
# setup.miko
device create Phone --image 35 --profile phone-6.1-fhd
use Phone
device start --timeout 300
proxy set 8080
snapshot save clean
```

<a id="http-proxy"></a>

## HTTP 代理

将运行中的设备连接到 Mac 上的 Burp、mitmproxy 或其他 HTTP 代理：

```bash
miko proxy set Phone 8080             # 10.0.2.2:8080，即此 Mac 的 8080 端口
miko proxy set Phone 192.168.1.5:3128 # 网络中另一台主机的代理
miko proxy show Phone
miko proxy clear Phone
```

模拟器中的 `10.0.2.2` 是 Mac 的 `127.0.0.1`，因此 Burp 默认监听地址 `127.0.0.1:8080` 可直接使用；设备内的 `127.0.0.1` 则指设备自身。该代理使用 Android 全局 `http_proxy` 设置：使用系统代理的应用（多数 HTTP 栈、WebView、Chrome）通过 Wi-Fi 和移动数据发送流量。设置立即生效并跨重启、快照保留，直到清除。读取 HTTPS 还需要应用信任代理 CA；可在完整 Root 设备使用 `miko cert install`，见 [CA 证书](#ca-certificates)。

<a id="ca-certificates"></a>

## CA 证书

要读取应用 HTTPS，将代理 CA 作为系统证书安装到完整 Root（Magisk）设备：

```bash
miko root set Phone magisk                   # 执行一次
miko cert install Phone ~/Downloads/cacert.der   # Burp 的 CA（PEM 或 DER）；重启设备
miko cert list Phone
miko cert remove Phone a4ac454c.0            # 也可使用 --all
```

`install` 重启设备；如果证书未进入应用读取的证书库，返回退出码 7（Root 失败）。各 Android 版本的工作方式见 docs/root.md。

<a id="microphone"></a>

## 麦克风

将音频文件播放到运行中设备的麦克风，可用于语音输入、识别或通话测试：

```bash
miko audio inject Phone ~/Desktop/hello.wav           # 等待播放完成
miko audio inject Phone ~/Desktop/hello.wav --loop --no-wait
miko audio stop Phone
miko audio inject Phone capture.pcm --rate 16000      # 无文件头的 16 位小端 PCM，单声道
```

Miko 通过模拟器 gRPC `injectAudio` 流式发送文件。支持单声道或立体声 8–48 kHz WAV：8/16 位 PCM 原样发送，24/32 位 PCM 或 32/64 位浮点转换为 16 位。其他文件、采样率或更多声道返回 2；可先转换，例如 `afconvert -f WAVE -d LEI16@44100 in.m4a out.wav`。设备读取麦克风时才会播放：应用可在播放前后开始录音；没有应用读取时进度暂停，直到开始读取或停止。`--loop` 持续循环至 `audio stop`；`jobs cancel` 也可结束。每台设备同时只能播放一个文件，第二个 `audio inject` 返回 4。当前不转发 Mac 实时麦克风。

<a id="licenses-d8"></a>

## 许可证（D8）

从 Google 下载的镜像和模拟器须由用户接受许可证。终端中 `miko image install` 显示并逐项询问；无界面时 `--accept-licenses` 输出每个许可证 ID 和文本 SHA-256，再记录用户同意。请先用 `miko sdk licenses <package>` 阅读文本；文本变化时 Miko 重新询问。

<a id="json-output---json"></a>

## JSON 输出（`--json`）

每条命令输出一行 JSON（`logcat -f` 每条日志输出一行）：

```json
{"miko_json": 2, "ok": true, "result": …}
{"miko_json": 2, "ok": false, "error": {"code": "not_found", "exit_code": 3, "message": "no device named \"x\"", "data": null}}
```

`miko_json` 是封套版本，仅在不兼容变更时改变，见下方变更记录。`result` 是底层命令的协议结果（docs/control-protocol.md）。作用于多个设备的命令（`device start|stop|delete`）返回数组。

<a id="exit-codes"></a>

## 退出码

| 代码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 意外错误 |
| 2 | 用法错误：参数无效、未知命令或缺少 `--yes` |
| 3 | 未找到设备、镜像或任务等，或设备未运行 |
| 4 | 忙：另一操作持有设备（`error.data.holder` 为任务） |
| 5 | 启动超时 |
| 6 | SDK、模拟器、下载或许可证问题 |
| 7 | Root 失败 |
| 8 | daemon 版本过期：其他版本的 daemon 正在运行（使用 `--restart-stale`） |
| 9 | 资源不足：启动会超出主机内存预算（`error.data.devices` 列出占用，参见 `miko budget`） |

<a id="environment"></a>

## 环境变量

| 变量 | 作用 |
|---|---|
| `MIKO_HOME` | 将所有 Miko 数据放在指定目录，用于测试或便携环境 |
| `MIKO_LOG` | daemon 日志过滤条件，如 `debug` |
| `MIKO_DAEMON_BIN` | 自动启动 daemon 所使用的 `miko` 二进制文件 |
| `MIKO_SDK_REPO` | SDK 仓库镜像（默认 Google） |
| `MIKO_RESTART_STALE` | 与 `--restart-stale` 相同 |

<a id="changelog"></a>

## 变更记录

| `miko_json` | 变更 |
|---|---|
| 2 | 将封套版本字段改名为 `miko_json`。 |
| 1 | 初始格式使用之前的封套字段。 |
