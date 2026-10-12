import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let hisCopyWillQuitForUpdate = Notification.Name("HisCopy.willQuitForUpdate")
}

/// Checks GitHub Releases for a newer `HisCopy.zip` and installs it safely.
///
/// Sparkle was considered but not used: it needs EdDSA keys, an appcast feed and
/// extra CI, and the project aims for zero third-party dependencies. Updates are
/// authenticated by HTTPS to the official repo, plus bundle-ID and version checks.
///
/// ## Crash we are carefully avoiding
/// Replacing or deleting the *running* `.app` while the process is still alive
/// unmaps the binary vnode. Background SharedFileList / NSXPC callbacks (Open Recent)
/// then SIGBUS when decoding replies against class metadata in those pages
/// (`KERN_MEMORY_ERROR` / "backing vnode was force unmounted"). The same crash can
/// happen if the app was launched from an ephemeral path under `/var/folders` and
/// that folder is purged (e.g. after sleep). Therefore we:
/// 1. Never touch the live bundle until the process has fully exited.
/// 2. Prefer installing into `/Applications` (or `~/Applications`) when the current
///    bundle lives in a temp / App Translocation location.
/// 3. Run the installer helper detached (`nohup`) so `exit(0)` cannot kill it.
/// 4. Quiet document / recent-list activity before quitting.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    static let owner = "BianYanhui"
    static let repo = "HisCopy"
    static let assetName = "HisCopy.zip"
    static let expectedBundleID = "io.github.bianyanhui.HisCopy"
    static let autoCheckKey = "HisCopy.autoCheckForUpdates"
    static let lastCheckKey = "HisCopy.lastUpdateCheck"

    @Published private(set) var isBusy = false
    @Published var autoCheckEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCheckEnabled, forKey: Self.autoCheckKey) }
    }

    private let session: URLSession
    private var progressAlert: NSAlert?
    private var progressIndicator: NSProgressIndicator?

    private init() {
        if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.autoCheckKey)
        }
        autoCheckEnabled = UserDefaults.standard.bool(forKey: Self.autoCheckKey)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    // MARK: - Public API

    private var didScheduleLaunchCheck = false

    /// Called once after launch. Silent when already up to date.
    func checkOnLaunchIfNeeded() {
        guard !didScheduleLaunchCheck else { return }
        didScheduleLaunchCheck = true
        guard autoCheckEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        Task { await checkForUpdates(interactive: false) }
    }

    /// Menu / Help action.
    func checkForUpdatesFromMenu() {
        Task { await checkForUpdates(interactive: true) }
    }

    func checkForUpdates(interactive: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let release = try await fetchLatestRelease()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            let current = Self.currentVersion()
            guard Self.isVersion(release.version, newerThan: current) else {
                if interactive {
                    presentInfo(
                        title: "已是最新版本",
                        message: "当前版本 \(current)，最新发布也是 \(release.version)。"
                    )
                }
                return
            }

            let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            var message: String
            if let notes, !notes.isEmpty {
                message = "当前版本 \(current) → \(release.version)\n\n\(Self.plainText(fromMarkdown: notes))"
            } else {
                message = "当前版本 \(current)，可更新到 \(release.version)。"
            }

            let running = Bundle.main.bundleURL
            let installURL = Self.preferredInstallURL(current: running)
            if installURL.standardizedFileURL != running.standardizedFileURL {
                message += "\n\n当前应用位于临时目录，新版本将安装到：\n\(installURL.path)"
            }

            let update = presentChoice(
                title: "发现新版本 \(release.version)",
                message: message + "\n\n更新将退出并重新打开 HisCopy。请先保存所有更改。",
                confirm: "立即更新",
                cancel: "稍后"
            )
            guard update else { return }

            // HisCopy is a menu-bar app with no NSDocument; skip unsaved-document checks.
            try await downloadAndInstall(release, installURL: installURL, runningURL: running)
        } catch {
            if interactive || !(error is CancellationError) {
                presentError(error)
            }
        }
    }

    // MARK: - GitHub Releases

    struct ReleaseInfo {
        let version: String
        let tagName: String
        let body: String?
        let downloadURL: URL
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HisCopy/\(Self.currentVersion())", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw UpdateError.noReleases
            }
            guard (200..<300).contains(http.statusCode) else {
                throw UpdateError.httpStatus(http.statusCode)
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw UpdateError.badResponse
        }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String) == Self.assetName }),
              let download = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: download) else {
            throw UpdateError.missingAsset
        }

        return ReleaseInfo(
            version: Self.normalizedVersion(tag),
            tagName: tag,
            body: json["body"] as? String,
            downloadURL: downloadURL
        )
    }

    // MARK: - Download & install

    private func downloadAndInstall(
        _ release: ReleaseInfo,
        installURL: URL,
        runningURL: URL
    ) async throws {
        guard installURL.pathExtension == "app" else {
            throw UpdateError.notInstalled
        }

        let installParent = installURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: installParent.path) {
            try FileManager.default.createDirectory(at: installParent, withIntermediateDirectories: true)
        }
        guard FileManager.default.isWritableFile(atPath: installParent.path) else {
            throw UpdateError.notWritable(installURL.path)
        }

        showProgress(title: "正在下载 HisCopy \(release.version)…")
        defer { hideProgress() }

        let (tempURL, response) = try await session.download(from: release.downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }

        updateProgress(title: "正在安装…", indeterminate: true)

        // Work directory for the zip only. The staged .app is copied out before we
        // quit; we must never delete or overwrite the *running* bundle here.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HisCopy-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let zipPath = workDir.appendingPathComponent(Self.assetName)
        if FileManager.default.fileExists(atPath: zipPath.path) {
            try FileManager.default.removeItem(at: zipPath)
        }
        try FileManager.default.moveItem(at: tempURL, to: zipPath)

        let unzipDir = workDir.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try Self.unzip(zipPath, into: unzipDir)

        let newApp = try Self.findAppBundle(in: unzipDir)
        try Self.validateAppBundle(newApp, expectedVersion: release.version)
        _ = try? Self.run("/usr/bin/xattr", arguments: ["-cr", newApp.path])

        // Stage outside workDir so a future cleanup cannot touch it; the helper
        // owns this copy after we quit.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("HisCopy-new-\(UUID().uuidString).app", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.copyItem(at: newApp, to: staging)
        // Zip/workDir are no longer needed; removing them cannot affect the running
        // bundle (runningURL) or the staging copy.
        try? FileManager.default.removeItem(at: workDir)

        try Self.launchReplacementScript(
            sourceApp: staging,
            installApp: installURL,
            runningApp: runningURL,
            pid: ProcessInfo.processInfo.processIdentifier
        )

        prepareToQuitForUpdate()
        // Brief pause so the detached helper is definitely scheduled, then exit.
        // exit(0) skips Swift defer / terminate save panels on purpose.
        try await Task.sleep(nanoseconds: 400_000_000)
        hideProgress()
        exit(0)
    }

    /// Stop clipboard polling, hide windows, and quiet activity before the
    /// binary vnode goes away on quit. HisCopy has no NSDocument.
    private func prepareToQuitForUpdate() {
        NotificationCenter.default.post(name: .hisCopyWillQuitForUpdate, object: nil)
        ClipboardMonitor.shared.stop()
        for window in NSApp.windows {
            window.orderOut(nil)
        }
        NSApp.mainWindow?.makeFirstResponder(nil)
    }

    private static func unzip(_ zip: URL, into directory: URL) throws {
        let result = try run("/usr/bin/ditto", arguments: ["-x", "-k", zip.path, directory.path])
        guard result == 0 else { throw UpdateError.unzipFailed }
    }

    private static func findAppBundle(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if let direct = contents.first(where: { $0.lastPathComponent == "HisCopy.app" }) {
            return direct
        }
        for item in contents where item.hasDirectoryPath {
            let nested = try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            if let app = nested.first(where: { $0.lastPathComponent == "HisCopy.app" }) {
                return app
            }
        }
        throw UpdateError.missingAppInZip
    }

    private static func validateAppBundle(_ app: URL, expectedVersion: String) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw UpdateError.invalidAppBundle
        }
        guard bundleID == expectedBundleID else {
            throw UpdateError.bundleIDMismatch(bundleID)
        }
        let version = (info["CFBundleShortVersionString"] as? String).map(normalizedVersion)
            ?? expectedVersion
        if isVersion(expectedVersion, newerThan: version) {
            throw UpdateError.versionNotNewer(version)
        }
        if !isVersion(version, newerThan: currentVersion()) {
            throw UpdateError.versionNotNewer(version)
        }
        let executable = app.appendingPathComponent("Contents/MacOS/HisCopy")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.invalidAppBundle
        }
    }

    // MARK: - Install location

    /// True when the bundle is likely to be purged or relocated underfoot
    /// (temp dirs, App Translocation). Running from such a path matches the
    /// reported SIGBUS after sleep / update.
    static func isEphemeralAppLocation(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        if path.contains("/AppTranslocation/") { return true }
        let prefixes = [
            "/private/var/folders/",
            "/var/folders/",
            "/tmp/",
            "/private/tmp/",
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path,
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }

    /// Prefer a stable Applications location when the running app is ephemeral.
    static func preferredInstallURL(current: URL) -> URL {
        guard isEphemeralAppLocation(current) else { return current }

        let systemApps = URL(fileURLWithPath: "/Applications/HisCopy.app")
        if FileManager.default.isWritableFile(atPath: "/Applications") {
            return systemApps
        }

        let homeAppsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: homeAppsDir, withIntermediateDirectories: true)
        return homeAppsDir.appendingPathComponent("HisCopy.app", isDirectory: true)
    }

    /// Spawns a detached helper that waits for this PID to exit, then installs
    /// the new app (without ever deleting the live bundle beforehand).
    private static func launchReplacementScript(
        sourceApp: URL,
        installApp: URL,
        runningApp: URL,
        pid: Int32
    ) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HisCopy-install-\(UUID().uuidString).sh")

        // Paths embedded below are absolute UUID temp paths — no user-controlled spaces
        // beyond standard macOS locations; still quote every expansion in the script.
        let script = """
        #!/bin/bash
        # Detach from the app's process group so exit(0) / SIGHUP cannot kill us.
        if [ "${HISCOPY_UPDATER_DETACHED:-}" != "1" ]; then
          export HISCOPY_UPDATER_DETACHED=1
          /usr/bin/nohup /bin/bash "$0" >/dev/null 2>&1 &
          exit 0
        fi

        set -e
        PID="\(pid)"
        SRC="\(sourceApp.path)"
        DST="\(installApp.path)"
        RUNNING="\(runningApp.path)"
        LOG="$HOME/Library/Logs/HisCopy-update.log"
        mkdir -p "$(dirname "$LOG")"
        exec >>"$LOG" 2>&1
        echo "$(date) updater start pid=$PID"
        echo "SRC=$SRC"
        echo "DST=$DST"
        echo "RUNNING=$RUNNING"

        # Wait until the old process is fully gone (not merely a zombie).
        waited=0
        while /bin/kill -0 "$PID" 2>/dev/null; do
          sleep 0.25
          waited=$((waited + 1))
          if [ "$waited" -gt 240 ]; then
            echo "$(date) timeout waiting for pid $PID"
            exit 1
          fi
        done
        while /bin/ps -p "$PID" -o pid= >/dev/null 2>&1; do
          sleep 0.25
        done
        # Extra settle time for SharedFileList / NSXPC / vnode teardown after exit.
        sleep 1.5

        if [ ! -d "$SRC" ]; then
          echo "$(date) missing staged app: $SRC"
          exit 1
        fi

        /usr/bin/xattr -cr "$SRC" || true

        DST_DIR="$(dirname "$DST")"
        DST_BASE="$(basename "$DST")"
        STAGED="$DST_DIR/$DST_BASE.new"
        BACKUP="$DST_DIR/$DST_BASE.old"
        /bin/rm -rf "$STAGED" "$BACKUP"
        /usr/bin/ditto "$SRC" "$STAGED"
        /usr/bin/codesign --force --deep --sign - "$STAGED" || true
        /usr/bin/xattr -cr "$STAGED" || true

        # Only now — after the old process has exited — replace the install target.
        if [ -e "$DST" ]; then
          /bin/mv "$DST" "$BACKUP"
        fi
        /bin/mv "$STAGED" "$DST"

        /usr/bin/open "$DST"
        sleep 0.8

        /bin/rm -rf "$BACKUP" "$SRC"
        # If we relocated out of a temp bundle, remove it only after the new app opened.
        if [ "$RUNNING" != "$DST" ] && [ -e "$RUNNING" ]; then
          /bin/rm -rf "$RUNNING" || true
        fi
        /bin/rm -f "$0"
        echo "$(date) updater done"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // First invocation only re-execs under nohup and exits; wait for that so
        // the detached child exists before we exit(0).
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.helperFailed
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Version helpers

    static func currentVersion() -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return normalizedVersion(raw)
    }

    static func currentBuild() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static func normalizedVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s.removeFirst()
        }
        return s
    }

    /// True when `lhs` is strictly newer than `rhs` (semver-ish: major.minor.patch).
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = numericParts(lhs)
        let b = numericParts(rhs)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { part in
                let digits = part.prefix(while: { $0.isNumber })
                return Int(digits) ?? 0
            }
    }

    /// Very light Markdown → plain text for the alert body.
    static func plainText(fromMarkdown markdown: String) -> String {
        var text = markdown
        let patterns: [(String, String)] = [
            (#"```[\s\S]*?```"#, ""),
            (#"`([^`]*)`"#, "$1"),
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"^#{1,6}\s+"#, ""),
            (#"^\s*[-*+]\s+"#, "• "),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"\*([^*]+)\*"#, "$1"),
        ]
        for (pattern, template) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                let range = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
            }
        }
        let maxLen = 1200
        if text.count > maxLen {
            let idx = text.index(text.startIndex, offsetBy: maxLen)
            text = String(text[..<idx]) + "…"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Alerts

    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @discardableResult
    private func presentChoice(title: String, message: String, confirm: String, cancel: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        if case .noReleases? = error as? UpdateError {
            alert.addButton(withTitle: "打开 Releases 页面")
            if alert.runModal() == .alertSecondButtonReturn {
                if let url = URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }
        alert.runModal()
    }

    private func showProgress(title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "请稍候，不要退出 HisCopy。"
        alert.alertStyle = .informational

        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 16))
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        alert.accessoryView = indicator

        progressIndicator = indicator
        progressAlert = alert

        let window = alert.window
        window.level = .floating
        alert.layout()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func updateProgress(title: String, indeterminate: Bool) {
        progressAlert?.messageText = title
        progressIndicator?.isIndeterminate = indeterminate
        if indeterminate {
            progressIndicator?.startAnimation(nil)
        }
    }

    private func hideProgress() {
        progressAlert?.window.orderOut(nil)
        progressAlert = nil
        progressIndicator = nil
    }
}

enum UpdateError: LocalizedError {
    case noReleases
    case missingAsset
    case badResponse
    case httpStatus(Int)
    case notInstalled
    case notWritable(String)
    case unzipFailed
    case missingAppInZip
    case invalidAppBundle
    case bundleIDMismatch(String)
    case versionNotNewer(String)
    case unsavedDocuments
    case helperFailed

    var errorDescription: String? {
        switch self {
        case .noReleases:
            return "还没有任何 GitHub Release。发布一个 v* 标签后，构建会自动附上 HisCopy.zip。"
        case .missingAsset:
            return "最新 Release 中没有找到 HisCopy.zip 资源。"
        case .badResponse:
            return "无法解析 GitHub 的响应。"
        case .httpStatus(let code):
            return "GitHub 返回了 HTTP \(code)。"
        case .notInstalled:
            return "当前不是从 .app 包运行（例如在 Xcode 里调试）。请先把 HisCopy.app 装到「应用程序」后再更新。"
        case .notWritable(let path):
            return "没有权限写入：\n\(path)\n请把应用拖到你的「应用程序」文件夹后再试。"
        case .unzipFailed:
            return "解压下载的更新包失败。"
        case .missingAppInZip:
            return "更新包里没有找到 HisCopy.app。"
        case .invalidAppBundle:
            return "更新包中的应用无效。"
        case .bundleIDMismatch(let id):
            return "更新包的 Bundle ID（\(id)）与当前应用不一致，已取消安装。"
        case .versionNotNewer(let v):
            return "下载到的版本（\(v)）不比当前版本新，已取消安装。"
        case .unsavedDocuments:
            return "有未保存的文档。请先保存或关闭它们，然后再更新。"
        case .helperFailed:
            return "无法启动安装脚本。请从 GitHub Releases 手动下载更新。"
        }
    }
}
