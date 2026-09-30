# DSH大肥鱼桌宠

一个用于 **DeepSeek Harness** 的 macOS 原生余额桌宠。角色手持平板显示余额，扣费时播放受击动画与原版音效，充值时显示提示。使用 Swift + AppKit 开发，无第三方运行时依赖。

**当前版本 v1.3.1**：支持蓝色大肥鱼、GPT龙娘、大小姐Claude、北美猫娘Gemini四个角色；蓝色大肥鱼未连接时显示抱盆图，隐藏余额文字。

## 四个角色

以下为应用实际渲染的四角色拼图，使用统一示例余额，不包含真实账号信息。

[![四个角色使用预览](dsh-balance-pet-macos/docs/previews/four-characters-usage.webp)](dsh-balance-pet-macos/docs/screenshots/four-characters-usage.png)

<table>
  <tr><th width="50%">蓝色大肥鱼</th><th width="50%">GPT龙娘</th></tr>
  <tr>
    <td align="center" width="50%"><a href="dsh-balance-pet-macos/Resources/sprite.png"><img src="dsh-balance-pet-macos/docs/previews/sprite.webp" alt="蓝色大肥鱼" width="360" height="240"></a></td>
    <td align="center" width="50%"><a href="dsh-balance-pet-macos/Resources/sprite-gpt.png"><img src="dsh-balance-pet-macos/docs/previews/sprite-gpt.webp" alt="GPT龙娘" width="360" height="240"></a></td>
  </tr>
  <tr><th width="50%">大小姐Claude</th><th width="50%">北美猫娘Gemini</th></tr>
  <tr>
    <td align="center" width="50%"><a href="dsh-balance-pet-macos/Resources/sprite-claude.png"><img src="dsh-balance-pet-macos/docs/previews/sprite-claude.webp" alt="大小姐Claude" width="360" height="240"></a></td>
    <td align="center" width="50%"><a href="dsh-balance-pet-macos/Resources/sprite-gemini.png"><img src="dsh-balance-pet-macos/docs/previews/sprite-gemini.webp" alt="北美猫娘Gemini" width="360" height="240"></a></td>
  </tr>
</table>

四张原始透明 PNG 均包含在 [`Resources`](dsh-balance-pet-macos/Resources) 文件夹中；上表图片可点击查看原图。

**切换方法：** 右键桌宠，或点击菜单栏 **¥ → 切换角色**。选择立即生效，重启后自动恢复；切换保留余额、动画、窗口位置和尺寸。

蓝色大肥鱼在未配置 API Key / 账号凭证、连接中或连接失败时，改为显示抱盆图，不显示余额标题、金额、状态点或金额飘字；连接成功后自动恢复手持平板和余额显示。其他三个角色保持原有显示方式。

[![大肥鱼未连接状态](dsh-balance-pet-macos/docs/previews/deepseek-offline.webp)](dsh-balance-pet-macos/docs/screenshots/deepseek-offline.png)

## 更新记录

### Windows 版 · 免 API Key 运行与音效修复

- Windows 版三个目录同时修复：`大肥鱼桌宠改_D-16B`、`原版（Windows版）`、`大肥鱼桌宠初代_D-16A`
  （后两者是同一份脚本）。新增 **DSH 账号凭证**支持：直接读取
  `~/.dsh/.credentials.yaml` 里 `deepseek-account-platform/default` 的 `token` 与 `issuer`，
  调用 `<issuer>/api/v0/users/get_user_summary`，因此**没有 `sk-` 开头的 API Key 也能显示真实余额**。
  原有 API Key 方式（`apikey.txt`、环境变量、凭证里的 `DEEPSEEK_API_KEY`）优先级更高，保持不变。
- 修复**音效从来不响**的问题：原先用相对文件名（`hit.mp3`）打开 MCI 设备，Windows 会直接返回
  "找不到文件"；同时用"返回字符串是否为空"判断成败，而该字符串在失败时为空、成功时是设备号，
  判断正好反了，真正的备用路径永远不会执行。现在改用绝对路径并按返回码判断。
- 凭证来源会写入 `pet.log`（只记来源与端点，不记录密钥）。
- `.gitignore` 新增 `_shot*.png`、`shot.png` 与 `state.ini`，避免把含真实余额和整屏画面的诊断截图、以及本机窗口位置等运行状态提交进仓库。

### v1.3.1 · 离线抱盆状态

- 蓝色大肥鱼在未配置 API Key / 账号凭证、连接中或连接失败时，使用上方抱盆图。
- 隐藏余额标题、金额、状态点及金额飘字；连接成功后自动恢复平板图和余额。
- 透明点击区域随图片切换，其他三个角色不变。
- README 使用轻量预览图与固定尺寸的双列表格，点击图片仍可查看完整 PNG。

### v1.3.0 · 四角色切换

- 新增 GPT龙娘、大小姐Claude、北美猫娘Gemini，与蓝色大肥鱼共四个角色。
- 通过桌宠右键菜单或菜单栏即时切换，重启后保留选择。
- 切换保留余额、动画、位置及尺寸；加入四角色使用截图和透明原图展示。

## 下载与运行

前往 [最新 Release](https://github.com/Andromedahk/DSH-DaFeiYu-Desktop-Pet/releases/latest)，下载 `DSH-DaFeiYu-macOS.zip`，解压后将 **DSH大肥鱼桌宠.app** 放入“应用程序”并打开。

- 支持 **macOS 13 及以上**；发布包同时包含 Apple Silicon 与 Intel 架构。
- 应用可读取本机 DeepSeek Harness 凭证，独立运行，无需持续打开 DSH；具体配置见 [macOS 使用说明](dsh-balance-pet-macos/README.md#凭证与余额)。
- 应用使用本地临时签名，尚未经过 Apple 开发者签名和公证。首次打开可能被系统拦截；确认下载来源后，可在“系统设置 → 隐私与安全性”中允许打开。

## Windows 版运行（不需要 Xcode）

仓库同时保留了 PowerShell 版挂件，可在普通 Windows 上直接运行，**没有 `sk-` API Key 也能显示余额**：

1. 进入 `大肥鱼桌宠改_D-16B` 目录。
2. 双击 **`启动DSH余额宠物.vbs`**（无黑框）。排错时改双击 `启动（调试窗口）.cmd`，它会保留窗口显示错误。

- 装了 DSH 就自动读取 `~/.dsh/.credentials.yaml` 的账号凭证，不会弹框要 Key；凭证读不到时才需要右键 →「设置 API Key…」填 `sk-` 开头的 Key。
- 运行日志在 `pet.log`：会记录凭证来源与每次请求结果，但不记录密钥。
- `原版（Windows版）` 与 `大肥鱼桌宠初代_D-16A` 内容完全相同（同一份脚本），同样支持账号凭证与音效修复，但没有 `改_D-16B` 的米饭盆充值、音量菜单等新增功能；推荐使用 `大肥鱼桌宠改_D-16B`。

## 日常操作

| 操作 | 功能 |
| --- | --- |
| 左键拖动 | 移动桌宠；默认松手吸附当前屏幕左下角，可在菜单关闭 |
| 右键 / Control + 单击 | 打开菜单，切换角色、尺寸及音效等 |
| 菜单栏 ¥ | 查看余额状态、刷新余额或打开操作菜单 |
| 测试一次扣费 / 演示连续扣费 | 本地演示动画，不发起真实扣费 |

角色透明区域支持鼠标穿透，余额文字随手持平板倾斜和震动，长金额自动缩小显示。

## 从源码构建

安装 Xcode Command Line Tools 后运行：

```sh
cd dsh-balance-pet-macos
ARCH=universal ./build.sh
./verify.sh
open "dist/DSH大肥鱼桌宠.app"
```

省略 `ARCH=universal` 时只构建当前机器架构。离线验证使用独立临时配置，检查四角色资源、切换绘制、配置恢复、余额逻辑、签名和启动行为。

## 文档与来源

- [macOS 版源码与完整使用说明](dsh-balance-pet-macos/README.md)
- [代码审查与验证记录](dsh-balance-pet-macos/docs/REVIEW.md)
- [角色素材来源与文件哈希](dsh-balance-pet-macos/Resources/README.md)
- [Windows 原版存档](原版（Windows版）/DSH余额桌宠/先看这里（快速开始）.md)

本项目基于 [VKmich16/V](https://github.com/VKmich16/V) 的 Windows 原版移植，感谢原作者。原版代码和素材完整保留在 `原版（Windows版）` 目录；缓存、编译产物及个人凭证不纳入版本控制。

上游暂未附带许可证；本仓库保留来源说明，不对上游代码和素材另行授予许可。
