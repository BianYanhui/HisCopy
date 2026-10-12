# HisCopy

菜单栏剪贴板历史工具（macOS）。当前为 **MVP 骨架**：菜单栏图标、历史面板与设置占位，尚未实现真实剪贴板监听与粘贴。

## P0 计划

- 轮询 `NSPasteboard.changeCount` 采集文本历史
- 历史列表搜索、置顶、删除
- 选中条目粘贴到前台应用（辅助功能 / Apple Events）
- 开机自启（`SMAppService`）
- 对接 GitHub Releases 应用内更新

## 下载

从 [Actions](https://github.com/BianYanhui/HisCopy/actions) 产物或 [Releases](https://github.com/BianYanhui/HisCopy/releases) 下载 `HisCopy.zip`。

### 未公证打开方式

本仓库构建为 ad-hoc 签名、未公证。首次打开可任选：

- 右键 App →「打开」
- 或在终端执行：`xattr -cr /path/to/HisCopy.app`

## 本地开发

用 Xcode 打开 `HisCopy.xcodeproj`，选择 scheme **HisCopy** 运行。

要求：macOS 13.0+，Xcode 16+。零第三方依赖。

## 发版（对齐 iReader）

合并到 `main` 后打 tag 触发 CI 构建并创建 Release：

```bash
git tag v0.1.0
git push origin v0.1.0
```

Workflow 会在 macOS 上编译、ad-hoc 签名、打包 `HisCopy.zip`，并在 tag 推送时附加到 GitHub Release。

## License

MIT
