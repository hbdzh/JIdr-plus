# Miko 设计

设计方向 **Workbench**：采用类似 IDE 的单一主窗口、以深色为主的柔和卡片，设备在独立原生窗口中打开。请先阅读 `system/README.md`，其中规定了文案语气、颜色、状态、字体、动效、图标和从右向左排版规则。

| 内容 | 位置 |
|---|---|
| 设计令牌（W3C DTCG，深色和浅色） | `tokens.json` |
| 设计系统规则 | `system/README.md` |
| 组件 CSS（应用的减少动态效果覆盖样式来自此处） | `system/components/bundle.css` |
| Workbench 组件 CSS（保留作设计参考） | `miko.css` |
| 产品简报 | `PRODUCT.md` |
| 品牌素材（图标、符号、网页素材） | `../../assets/brand/` |
| SwiftUI 设计工具包 | [`../../apps/miko-swiftui/Center/DesignKit.swift`](../../apps/miko-swiftui/Center/DesignKit.swift) |

选定的方案：启动器 **1A**（侧边栏设备列表和设备详情）、设备窗口 **4A**（停靠式组件面板）、落地页 **8A**（应用上方的标题）。

## 实现规则（D41）

- **唯一来源：** `tokens.json`。不要手工复制十六进制颜色值。
  - `apps/miko-swiftui/generate-tokens.sh` 生成 Swift 原始令牌层和语义化 Workbench 层。CI 检查生成过程的幂等性。
  - Swift 语义层将共享令牌映射到原生控件和 AppKit 窗口外观。
- **字体：** Geist、Geist Mono 和 Noto Kufi Arabic（均为 OFL-1.1）。将字体和许可证一并放入应用的 `apps/miko-swiftui/Resources/fonts/`，并附上必要的 OFL 声明。
- **图标：** 使用原生 SF Symbols，由 Swift 生成器维护 Lucide 含义映射；Lucide 的 ISC 许可证保留在 `assets/lucide/LICENSE-lucide.txt`。
- **品牌与令牌：** 应用图标渐变（`#2A88FA → #1267E0`，`assets/brand/`）是已批准的图标，保持不变。界面内部只使用令牌：操作使用 `miko-color-accent-*`，root 专用紫色使用 `miko-color-root`。阿拉伯文标识 جذر 使用 `miko-color-root`。
- 优先使用原生 macOS 控件、窗口和面板；令牌驱动的自定义界面保持一致。
