import Foundation

/// 应用内更新占位。后续对接 GitHub Releases。
final class AppUpdater {
    static let shared = AppUpdater()

    private init() {}

    /// 启动时检查更新（当前为空实现）。
    func checkOnLaunchIfNeeded() {
        // 后续：请求 GitHub Releases API，比较 MARKETING_VERSION
    }
}
