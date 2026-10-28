# 右键工具箱 · RightClickTools

[![Release](https://github.com/ApricityXX/RightClickTools/actions/workflows/release.yml/badge.svg)](https://github.com/ApricityXX/RightClickTools/actions/workflows/release.yml)
[![CI](https://github.com/ApricityXX/RightClickTools/actions/workflows/ci.yml/badge.svg)](https://github.com/ApricityXX/RightClickTools/actions/workflows/ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/ApricityXX/RightClickTools)](https://github.com/ApricityXX/RightClickTools/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

给 macOS 访达补齐右键菜单：新建文档、打开终端、复制路径、算哈希、显隐隐藏文件。
纯 Objective-C，无第三方依赖，**没有后台常驻进程、不轮询、不联网**。

![管理台](docs/screenshot.png)

---

## 安装

### 方式一：下载现成的

到 [Releases](https://github.com/ApricityXX/RightClickTools/releases/latest) 下载 `RightClickTools-<版本>-arm64.zip`，解压后：

```bash
# 把 App 拖进 /Applications，再解除隔离（未公证，必须做）
xattr -dr com.apple.quarantine "/Applications/右键工具箱.app"
open "/Applications/右键工具箱.app"
```

### 方式二：让 AI 帮你装

不想自己敲命令，把下面整段丢给 AI 助手，让它全程代劳：

````text
请在这台 Mac 上帮我安装并启用开源工具「右键工具箱 / RightClickTools」，自己执行命令，不要只给我步骤。

1. 环境：macOS 13+ 且 Apple Silicon；xcode-select -p 若报错就先 xcode-select --install（只需命令行工具）。
2. 克隆编译：git clone https://github.com/ApricityXX/RightClickTools.git ~/RightClickTools && cd ~/RightClickTools && bash build.sh
3. 安装（必须是 /Applications，路径含中文要加引号）：
   pkill -f RightClickTools; rm -rf "/Applications/右键工具箱.app"; cp -R "build/右键工具箱.app" /Applications/
   xattr -dr com.apple.quarantine "/Applications/右键工具箱.app"
4. 打开一次让它安装功能脚本：open "/Applications/右键工具箱.app"，等 3 秒；确认
   ~/Library/Application Scripts/com.user.rightclicktools.RightClickToolsExt/helper.sh 存在且可执行，否则 chmod +x。
5. 注册扩展并重启访达：
   pluginkit -a "/Applications/右键工具箱.app/Contents/PlugIns/RightClickToolsExt.appex"; killall Finder
6. 提醒我到 系统设置 → 通用 → 登录项与扩展 → 访达扩展 勾选「右键工具箱」（这一步必须我手动点）。

注意（逐条自查，别跳过）：
- 扩展缺 com.apple.security.app-sandbox entitlement 时系统设置里根本不显示；build.sh 已内置该步骤，重签时务必保留 --entitlements。
- 沙箱内不能起进程，功能靠 NSUserScriptTask 调 helper.sh；脚本缺失或不可执行的表现是「菜单有、点了没反应」。
- 不要用 sudo，否则产物属主变 root，签名和写日志都会失败。
- build.sh 只出 arm64。
- ad-hoc 签名未公证，每次重装都要重新勾选一次扩展。
- 若装了「超级右键」iRightMouse 等同类工具，先退出，否则会抢菜单层级。

验收：任意文件夹右键出现「右键工具箱」子菜单。若点击无反应，在管理台打开「记录诊断日志」再试一次，然后看
~/Library/Containers/com.user.rightclicktools.RightClickToolsExt/Data/tmp/rc_log.txt
````

### 方式三：自己编译

需要 macOS 13+、Apple Silicon、命令行工具（`xcode-select --install`，不用完整 Xcode）。

```bash
git clone git@github.com:ApricityXX/RightClickTools.git
cd RightClickTools
bash build.sh                          # 产物：build/右键工具箱.app
cp -R build/右键工具箱.app /Applications/
open "/Applications/右键工具箱.app"
```

Intel 机器用 `ARCH=x86_64 bash build.sh`。

> `build.sh` 固定 `-mmacosx-version-min=13.0`，否则在高版本系统上编出的包在 macOS 13 上会报 `-10825 kLSIncompatibleSystemVersionErr`。可用 `MACOS_MIN=` 覆盖。

### 三种方式都必经：启用扩展

装好之后，**系统设置 → 通用 → 登录项与扩展 → 访达扩展**，勾选「右键工具箱」（部分系统在「隐私与安全性 → 扩展」）。

之后在访达任意位置右键，就能看到「右键工具箱」子菜单。

## 功能

| 功能 | 说明 |
| --- | --- |
| 新建文件（子菜单） | `txt` / `md` / `docx` / `xlsx` / `pptx`，重名自动加序号，创建后自动选中 |
| 在此处打开终端 | 定位到当前目录 |
| 复制文件路径 / 文件名 | 支持多选，换行拼接 |
| 复制 MD5 / SHA256 | 两个值一起算，直接进剪贴板 |
| 用 VS Code / Typora 打开 | 装了才出现 |
| 显示 / 隐藏隐藏文件 | 切换 `AppleShowAllFiles`，会自动重启访达 |

每项都能在**管理台**里单独开关，关掉的不出现在菜单里。管理台还负责：查看扩展与脚本安装状态、开关诊断日志（默认关）、一键重装功能脚本、快速跳转系统扩展设置。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| 系统设置里找不到扩展 | App 必须在 `/Applications`；执行 `pluginkit -a` 后 `killall Finder` 重试 |
| 菜单出来了，点了没反应 | 多为 `helper.sh` 没装上或不可执行，管理台点「重装功能脚本」 |
| 打开终端但目录不对 | 要在文件夹空白处右键，不是在选中的文件上 |
| 隐藏文件开关没变化 | 该开关靠重启访达生效，功能会自动执行 |
| 重装后菜单消失 | ad-hoc 签名变了，回系统设置重新勾选扩展 |

调试：管理台开「记录诊断日志」→ 右键用一次 → 读上面的 `rc_log.txt`。

## 开发

- 目录：`src/`（`ExtMain.m` 扩展、`HostMain.m` 管理台）、`resources/`（plist、`helper.sh`、图标）、`templates/`（Office 空白模板，`make_templates.py` 生成）
- 发版：版本号以 git tag 为唯一来源，CI 自动写进两个 plist 并出包

  ```bash
  git tag -a v1.2.3 -m "改动说明" && git push origin v1.2.3
  ```

  tag 带 `-`（如 `v1.2.3-beta.1`）自动标 prerelease。本地想手动改版本用 `bash set_version.sh 1.2.3 [build号]`。

## 许可证

MIT
