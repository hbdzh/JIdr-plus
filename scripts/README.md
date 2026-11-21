# 项目脚本

脚本按用途保留在本目录；运行前请查看脚本开头的条件和参数。SwiftUI 专用脚本位于 [`apps/miko-swiftui/`](../apps/miko-swiftui/README.md)，发行流程入口见[打包材料索引](../packaging/README.md)。

- `e2e-cli.sh`、`e2e-root.sh`、`e2e-studio-untouched.sh`：端到端与 SDK 隔离验证，使用时需要准备相应测试环境。
- `m4-swiftui-acceptance.sh`：SwiftUI 实机验收脚本，创建隔离的测试数据。
- `player-baseline.py`、`test-player-baseline.py`：播放器性能对照及其脚本测试；使用条件见[性能记录](../docs/display-performance.md)。
- `build-runtime-core.py`、`audit-runtime-dependencies.py`：运行时本地构建与源码审核辅助工具；限制和参数见[运行时源码记录](../packaging/runtime-source/README.md)。
- `test-ci-runtime-action.sh`：固定运行时准备流程的脚本验证。
- `lib/`：由其他脚本调用的辅助代码。
