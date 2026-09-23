# 安装程序（构建与说明）

本目录用于把程序打包成**单文件、双击即装**的安装程序。

## 安装程序做了什么

1. 解压程序到 `%LOCALAPPDATA%\KatiChat\`
   - `app\` —— 程序本体（`server.mjs`、前端、`launch.ps1`、`tray.ps1` 等）
   - `runtime\node.exe` —— 内置 Node 运行时（目标机器无需预装 Node.js）
   - `runtime\llama\` —— llama.cpp Vulkan 推理后端
2. 准备模型到 `models\`：优先复制安装包同级的 `models\` 文件夹，找不到则从 ModelScope 联网下载（约 5.6 GB）
3. 创建桌面快捷方式 + 开始菜单项（图标取自 `app\assets\whale-v2.ico`）
4. 在 `HKCU\...\Uninstall\KatiChat` 登记卸载入口，并生成 `卸载.cmd`
5. 启动程序

> 全程**不需要管理员权限**，所有内容装在当前用户目录。

## 构建

```powershell
# 在仓库根目录执行
.\installer\build-installer.ps1
```

构建脚本会：

1. 暂存负载（程序 + 运行时）到 `installer\payload\`
   - 校验并自动补齐所有 `.ps1` 的 UTF-8 BOM（PowerShell 5.1 解析中文脚本必需）
2. 打包成 `installer\payload.zip`
3. 用系统自带的 `iexpress.exe` 生成自解压安装程序
4. 输出到 `F:\aiworking\卡提聊天助手_安装包\`

可自行修改脚本顶部的路径变量：

```powershell
$src      = 'F:\aiworking\whale-translator'   # 程序源目录
$outDir   = 'F:\aiworking\卡提聊天助手_安装包' # 输出目录
$llamaSrc = 'C:\aiuse\llama-b11100-bin-win-vulkan-x64'  # llama.cpp Vulkan 运行时
```

## 产物

```
卡提聊天助手_安装包\
├─ 卡提聊天助手_安装程序.exe   ← 单文件安装程序（约 64 MB）
├─ models\                     ← 离线模型（安装时复制，5.6 GB）
├─ 安装.cmd / install.ps1 / payload.zip  ← 备用安装方式（exe 被拦截时用）
└─ 安装说明.txt
```

## 注意

- 安装程序由 `iexpress` 生成，**未做代码签名**，首次运行可能出现「未知发布者」提示，选择「仍要运行」即可
- `iexpress` 内部调用 `makecab` 压缩，整个过程约 40 秒，请耐心等待脚本输出
- 如果只想给别人源码而非安装包，直接分享仓库即可（见根目录 README 的「从源码运行」）
