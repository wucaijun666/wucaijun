# sundiro-widget

新大洲本田（`com.sundirohonda.app`）的 **WidgetKit 小组件扩展**源码。

> **配套仓库**：宿主 App 的注入补丁（蓝牙无感解锁）与产物在
> [`gan-jibamao/sundiro-ble`](https://github.com/gan-jibamao/sundiro-ble)。
> 小组件通过 **App Group** 读取宿主写入的 `state.json` 快照取数。

## 当前版本

| 项目 | 值 |
|---|---|
| 版本 | `1.4.0`（`CFBundleShortVersionString`，随宿主 App） |
| 尺寸 | `systemSmall` / `systemMedium` / 锁屏 `accessoryCircular`、`accessoryRectangular`、`accessoryInline` |
| 产物 | `SundiroWidget.appex`（arm64） |
| 发布 | [Releases](https://github.com/gan-jibamao/sundiro-widget/releases) —— `v1.4.0` |

显示内容：油量环、小电池电压、前/后胎压、总里程（中号），小号为其精简版；
锁屏圆形为「油量数字（无 %）→ 小电池电压 → 缺口内踏板摩托车」。

### 1.4.1 · 锁屏圆形排版微调（大字版）

- 油量数字 `16.5 → 21.5`（放大 30%）
- 小电池电压 `10 → 8.5`（缩小 15%）
- 圈内整组 `offset(y: 2.6 → 3.4)`（整体下移）
- v2：数字↔电压 `2.5 → 0.5`、整组 `3.4 → 4.4`（只有 33 下移 2pt）
- **v3（现役）**：摩托车钉回原位 `offset(y: 3.5)` + 队内间距 `2.5 → -2.875` / `1.5 → 0.875`，33 再下移、摩托上移 2.7pt 回原位，空隙 3.0pt / 2.0pt 不重叠

### 1.4.0 · 锁屏圆形配件

- **圆形环几何逐条还原自理想汽车 App 8.27.0** 的 `CustomGaugeStyle.makeBody`（反汇编取证）：
  环外框 `52pt`、环宽 `5.4pt`（占 10.4%）、`lineCap/lineJoin = round`、`miterLimit = 10`、
  量程 `value × 0.75`（3/4 周）、底轨 `Color.white.opacity(0.4)`、进度 `Color.white`、
  整体旋转 `132.4746°`（= `2.3121106 rad`），使 90° 缺口落在正下方。
- **缺口内踏板摩托车**：`moped` / `motorcycle` 需 SF Symbols 6.0（iOS 18）→ 本项目目标 iOS 15/16 不可用，
  `scooter` 又只是滑板车。故取自开源 **Material Symbols「moped」** 矢量（Apache-2.0），
  按 `x → 20−x` 镜像重建为**车头朝左**，再由脚本逐条 path 指令转成 SwiftUI `Path`（`MopedShape`）。
- **矩形配件回到 1.3.0 的三行表格**：1.3.1 的 2×2 网格从未打包交付，本次一并以现役版为基线，保持改动面最小。

## 文件

```
.github/workflows/build-appex.yml   # CI：macos-14 编译 arm64 appex
widget/
├── SundiroWidget.swift             # SwiftUI + WidgetKit 主源码
├── Info.plist                      # 扩展 Info.plist
├── SundiroWidget.entitlements      # 扩展权限（App Group 等）
└── build_appex.sh                  # 本地编译脚本
```

## 编译

**必须 macOS + Xcode**（WidgetKit 无法在 Linux 上编译）。推荐直接走 CI：

推送后 GitHub Actions 自动构建，产物在 Actions 的 `SundiroWidget.appex` artifact 中。

## ★ 在 TrollStore 上运行的四项前提

这是小组件能否加载的关键，全部踩过坑：

1. **必须有 `com.apple.security.application-groups`** 权限
2. **必须沙盒化** —— WidgetKit **会拒绝加载未沙盒化的扩展**（`.deb` 装到 `/Applications`
   会被注入 `no-sandbox`，因此必须走 TrollStore 以 User App 方式安装）
3. `Info.plist` **不应有 `NSExtensionPrincipalClass`**（现代 `@main` 写法；写了幽灵类名会让扩展静默失败）
4. 依赖**只能是系统框架**（WidgetKit / SwiftUI / Foundation / libswift*），缺任何 `.framework` 会被 dyld 静默杀掉

## 关键修复（相对早期版本）

- **`fuelCap` 语义修正** —— 它是最新油量，不是油箱容量（此前当容量作除数）
- **`home` 分支改「快照优先」** —— 避免停车时 `6/6` 覆盖真值
- **删除只赋值不读取的死代码**（`locked` / `moving` / `soc` / `range` 及 `asBool` / `socColor`）
- **CI 产物必须移除 appex 的 `_CodeSignature`** —— TrollStore 安装时会用自身 entitlements 重签，
  签名块一变 `CodeResources` 哈希即失效，`pkd` 会拒绝启动扩展（**现象：小组件加出来是空白**）
- **CI 每次构建递增 `CFBundleVersion`** —— 避免 WidgetKit 按版本号缓存 appex，
  导致覆盖安装 / 重加小组件都不生效、**必须 respring**

## 未采用的功能

「锁车 / 解锁 / 寻车」三按钮与车辆地址**未采用** —— 配套的 dylib 侧远程控车在真机下车机无响应、
根因未定位。源码保留在 git 历史中（`0cc2458` / `53d5660` / `5e9b8ae`）。

## 安装

将 `SundiroWidget.appex`（连同 `Info.plist`）注入宿主 App 的 `Runner.app/PlugIns/` 下。
**安装前请移除 `_CodeSignature`**（见上）。若小组件列表里不出现，在 TrollStore 中
**Reload Icon Cache** 后重试。

> 本仓库只分发我们自己的产物，**不含新大洲本田 App 本体**。

## 许可

[MIT License](LICENSE)

Copyright (c) 2026 gan-jibamao
