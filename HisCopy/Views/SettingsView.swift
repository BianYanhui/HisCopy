import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("通用") {
                // 占位：暂不真正注册 SMAppService
                Toggle("开机时启动 HisCopy", isOn: $launchAtLogin)
            }
            Section("关于") {
                LabeledContent("版本", value: versionString)
                Text("当前为 MVP 骨架，剪贴板监听与辅助功能尚未实现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 240)
        .padding()
    }
}

#Preview {
    SettingsView()
}
