# 播放器操作录制（v1）

状态：已在播放器窗口 MVP 中实现。CLI/MCP 播放属于后续阶段，不属于本约定。

该功能以类似 MuMu 的方式记录用户归一化输入及时间，将时间线保存为 JSON，并在播放器桥中本地回放。脚本是数据，不是代码。

## 范围（v1）

- 入口仅为播放器窗口。
- 记录触摸、映射触摸、按键按下/抬起、文本、粘贴和工具键。
- 不记录旋转、录屏、截图、文件操作、复制、剪切、全选、应用检查和卸载。
- 回放可设置次数、时长、无限循环、循环间隔和速度（0.25x–4x）。
- 关闭播放器窗口会停止录制和回放，桥进程随之退出。
- 脚本存放在 `<Miko data>/scripts/`，使用可移植 JSON 文件。
- v1 不修改 daemon、CLI、MCP 或控制协议。

## 脚本格式

```json
{
  "format": "miko.operation-recording",
  "version": 2,
  "id": "uuid",
  "name": "每日签到",
  "created_at": "2026-11-12T01:00:00.000Z",
  "device": "Phone 6.1 FHD+",
  "display": { "width": 576, "height": 1280 },
  "playback": {
    "mode": "count",
    "count": 1,
    "duration_ms": 0,
    "interval_ms": 0,
    "speed": 1.0
  },
  "events": [
    { "t": 0, "type": "touch", "x": 0.5, "y": 0.4, "down": true },
    { "t": 80, "type": "touch", "x": 0.5, "y": 0.4, "down": false },
    { "t": 300, "type": "key", "key": "ENTER", "down": true },
    { "t": 340, "type": "key", "key": "ENTER", "down": false },
    { "t": 600, "type": "text", "text": "hello" },
    { "t": 900, "type": "tool_key", "key": "back" }
  ]
}
```

规则：

- `t` 是从开始计算的毫秒数，单调不递减。
- 触摸坐标使用显示屏幕的归一化坐标（0…1），与桥的 `touch` 命令相同；`mapped_touch` 的 id 为 3…9。
- 名称为 1…80 字符；每个脚本包含 1…200,000 个事件，最长 24 小时。
- `playback` 是上次使用的默认值；界面可在每次运行时覆盖。
- 显示尺寸仅用于兼容性提示，归一化坐标仍映射到当前屏幕。

## 核心 crate API（`crates/miko-automation`）

纯 Rust，不依赖界面或 daemon。桥使用的公开 API：

- `Script`、`Event`（由 `type` 标记）、`TimedEvent`、`DisplayInfo`、`PlaybackOptions`、`PlaybackMode`、`ScriptSummary`。
- `validate(&Script) -> MikoResult<()>`。
- `Recorder`：`new(now)`、`record(event, now)`、`pause(now)`、`resume(now)`、`is_paused()`、`event_count()`、`finish(name, device, display, playback, now)`。结束时补充仍按住的触摸和按键的释放事件并验证。
- `ScriptStore::new(data_dir)`：`list()`、`load(id)`、`save(&script)`、`delete(id)`、`rename(id, name)`、`import(path)`、`export(id, path)`。
- 错误使用 `miko_core::MikoError`（`usage` / `not found` 语义）。

## 播放器桥协议扩展

播放器桥是 Swift 播放器启动的 Rust 进程：stdin 接收 NDJSON 命令，stderr 发送 JSON 通知。桥不依赖特定界面，以便未来 Windows/HarmonyOS 界面复用。

### 命令（stdin）

```text
{"type":"script_record_start"}
{"type":"script_record_pause"}
{"type":"script_record_resume"}
{"type":"script_record_stop","name":"..."}
{"type":"script_record_cancel"}
{"type":"script_list"}
{"type":"script_delete","id":"..."}
{"type":"script_rename","id":"...","name":"..."}
{"type":"script_import","path":"/abs/path.json"}
{"type":"script_export","id":"...","path":"/abs/path.json"}
{"type":"script_play_start","id":"...","options":{...PlaybackOptions...}}
{"type":"script_play_pause"}
{"type":"script_play_resume"}
{"type":"script_play_stop"}
```

规则：

- 录制和回放互斥，冲突命令返回 `script.busy`。
- 回放期间忽略来自界面的普通输入（界面禁用输入），脚本命令仍可用。
- v1 不允许旋转：不会录制旋转，包含旋转的脚本无效。
- 停止、取消、暂停或结束时释放仍按住的按键和触摸。

### 通知（stderr，`MIKO_SCRIPT:` + JSON）

```text
{"op":"record","state":"recording"|"paused"|"progress"|"saved"|"stopped"|"failed","event_count":..., "name":..., "message":..., "script":{summary}}
{"op":"list","scripts":[{summary...}]}
{"op":"play","state":"playing"|"paused"|"finished"|"stopped"|"failed","loop":1,"count":3,"name":...,"message":...}
{"op":"error","code":"script.busy","message":"..."}
```

`message` 为英文回退文本（Swift 界面可翻译常见错误码）。摘要包含 `id,name,duration_ms,event_count,action_count,created_at,display`。`event_count` 统计全部录制样本；`action_count` 将一次触摸手势或按键归为一个动作，每条文本、粘贴或工具键命令各算一个动作。只有摘要变化，录制文件和回放时间线仍保留全部事件。

### 回放引擎

回放状态属于桥主循环，与用户输入使用同一控制器，因而共享按住和释放处理。约每 5 毫秒推进到期事件，同时保持对画面和暂停、继续、停止命令的响应。事件时间除以 `speed`，循环间隔使用真实时间。开始、循环、暂停、继续、停止和结束时发送 `play` 通知。

## Swift 界面

- 播放器侧栏提供「操作录制」，以非模态窗口打开，录制时仍可使用播放器。
- 窗口提供紧凑列表、原生新建录制工具栏操作、直接播放、按需显示的播放设置，以及重命名、删除和导入/导出；播放设置保存在本机。
- 运行中的设备可作为录制和播放目标；必要时打开播放器，停止录制后直接保存为默认名称。
- Android 屏幕顶部的浮动控件在录制时显示用时和事件数，播放时显示当前循环，并提供暂停、停止。窗口和设备视图尺寸不变，控件只占少量屏幕空间；桥会合并录制计数更新。
- 关闭播放器会随桥退出自然停止所有操作；所有文案通过现有播放器本地化工具提供中英文。
