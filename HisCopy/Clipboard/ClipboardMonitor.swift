import Foundation
import AppKit

/// 剪贴板监听占位。
/// 后续：轮询 NSPasteboard.changeCount，在变更时读取字符串并写入历史。
protocol ClipboardMonitoring: AnyObject {
    func start()
    func stop()
}

final class ClipboardMonitor: ClipboardMonitoring {
    // 后续实现：Timer / RunLoop 轮询 NSPasteboard.general.changeCount
    func start() {}
    func stop() {}
}
