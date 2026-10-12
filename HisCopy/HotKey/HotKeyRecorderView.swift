import AppKit
import SwiftUI

/// 点击后监听下一组修饰键+按键，写入全局热键（无第三方依赖）。
struct HotKeyRecorderView: View {
    @ObservedObject private var manager = GlobalHotKeyManager.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    toggleRecording()
                } label: {
                    Text(isRecording ? "按下新快捷键…" : manager.shortcut.displayString)
                        .font(.body.monospaced())
                        .frame(minWidth: 120, alignment: .center)
                }
                .buttonStyle(.bordered)
                .help(isRecording ? "按下包含修饰键的组合；Esc 取消" : "点击后按下新的全局快捷键")

                Button("恢复默认") {
                    stopRecording()
                    manager.resetToDefault()
                }
                .disabled(isRecording || manager.shortcut == .default)
            }

            if let message = manager.registrationFailureMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc 取消录制
            if event.keyCode == 53 {
                DispatchQueue.main.async { stopRecording() }
                return nil
            }

            let mods = HotKeyShortcut.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else {
                // 忽略纯字符键，继续等待
                return nil
            }

            // 忽略单独修饰键产生的 keyDown（若有）
            let keyCode = UInt32(event.keyCode)
            let shortcut = HotKeyShortcut(keyCode: keyCode, carbonModifiers: mods)
            DispatchQueue.main.async {
                manager.updateShortcut(shortcut)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
}
