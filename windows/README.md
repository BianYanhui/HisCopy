# HisCopy for Windows

Windows 端剪切板历史（与 macOS HisCopy 同仓库）。

## 功能（v0.1.0）

- 托盘常驻（无任务栏主窗口）
- 监听系统剪贴板（文本 / 图片 / 文件）
- **Ctrl+Shift+V** 呼出居中历史面板
- **Enter** 粘贴原文，**Ctrl+Enter** 粘贴纯文本，双击同 Enter
- **Ctrl+F** 搜索，**Esc** / 失焦关闭
- 本地持久化（`%LocalAppData%\HisCopy`）
- 菜单「检查更新…」打开 GitHub Releases

## 要求

- Windows 10/11 x64
- 无需安装 .NET（Release 为自包含单文件）

## 本地开发

在 Windows 上：

```bash
cd windows/HisCopy.Windows
dotnet run
```

Linux / macOS 无法编译 WPF，请用 GitHub Actions `Build Windows` 验证。

## 下载

见 [GitHub Releases](https://github.com/BianYanhui/HisCopy/releases) 中的 `HisCopy-Windows.zip`。
