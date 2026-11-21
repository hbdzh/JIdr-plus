# Miko 品牌素材

标志是一株根（جذر）生长成手机轮廓。旧版标志和网页素材由 `build.sh` 从 `source/appLogoOnPaper.jpg` 生成；应用包与 MCP 图标使用 `../icon/Icon/` 中已批准的默认图稿，`build.sh` 从该文件重新生成。

```bash
brew install potrace librsvg imagemagick   # 首次安装
assets/brand/build.sh
```

## 颜色

| 令牌 | 色值 | 用途 |
|---|---|---|
| 品牌蓝（上） | `#2A88FA` | 图标渐变起点 |
| 品牌蓝（下） | `#1267E0` | 图标渐变终点、favicon 标志 |
| 淡紫 | `#B9A6F7` | 深色背景的阿拉伯文标识 جذر |
| 墨色 | `#101010` | 社交卡片背景 |

这些颜色取自已批准的 `source/brand-board.jpg`。`docs/design/tokens.json` 是设计系统的来源；调整时同步更新 `build.sh` 并重新运行。

## 文件

| 文件 | 内容 | 用途 |
|---|---|---|
| `symbol.svg` | 标志，`fill="currentColor"` | 通用，可按需要着色 |
| `symbol-bold.svg` | ≤32 px 的较粗线条 | 小图标、favicon、菜单栏 |
| `app-icon.svg` / `app-icon-1024.png` | 旧版图标 | 文档和旧网页素材 |
| `app-icon-small.svg` | 旧版 16/32 px 图稿 | favicon |
| `avatar.svg` / `avatar-1024.png` | 圆形头像 | GitHub 组织/仓库和社交主页 |
| `social-card.svg` / `.png` | 1200×630 预览卡片 | Open Graph / Twitter 卡片 |
| `web/` | 由 `build.sh` 生成的网页图标和社交素材 | 本地生成，不纳入仓库 |
| `../../apps/miko-swiftui/Resources/Miko.icns` | 应用包图标（16–1024，@1x/@2x） | 应用包（`CFBundleIconFile`） |

## 规则

- 不得使用上述令牌以外的颜色重新绘制应用图标渐变；应用内的 `symbol.svg` 可使用文本或强调色令牌着色。
- 标志周围的留白至少为其宽度的四分之一。
- 标志旁不得使用 Google、Android 或 Genymotion 标识。
- 该目录由各工作流共享并只读；仅 `build.sh` 修改生成文件。

原生应用图标生成到 `apps/miko-swiftui/Resources/Miko.icns`，不再生成已退役的 Slint/菜单栏栅格副本。仓库保留 macOS 应用包和 MCP 扩展使用的默认图稿；不参与当前构建的 iOS 深色和透明变体不纳入仓库。macOS `.icns` 不会自动选择这些变体。
