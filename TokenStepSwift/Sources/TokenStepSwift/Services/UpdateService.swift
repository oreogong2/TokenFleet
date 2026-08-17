import AppKit
import Darwin
import Foundation

struct AvailableUpdate: Identifiable, Equatable {
    var id: String { version }
    var version: String
    var tagName: String
    var title: String
    var notes: String
    var pageURL: URL
    var assetURL: URL
    var assetName: String
    var assetSize: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(assetSize), countStyle: .file)
    }

    var noteLines: [String] {
        let cleaned = notes
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                guard !trimmed.hasPrefix("#") else { return nil }
                guard !trimmed.lowercased().hasPrefix("sha256") else { return nil }
                let cleaned = trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•* ").union(.whitespacesAndNewlines))
                    .replacingOccurrences(of: "`", with: "")
                    .replacingOccurrences(of: "**", with: "")
                return cleaned.isEmpty ? nil : cleaned
            }
        return Array(cleaned.prefix(upTo: min(4, cleaned.count))).map { String($0) }
    }
}

enum UpdateCheckResult {
    case upToDate
    case available(AvailableUpdate)
}

enum UpdateDownloadPolicyError: Error, Equatable {
    case invalidDeclaredSize
    case insecureURL
    case tooManyRedirects
    case invalidResponse
    case invalidContentLength
    case responseTooLarge
    case contentLengthMismatch
    case bodyTooLarge
    case finalSizeMismatch
}

enum UpdateNetworkPolicy {
    static let maximumManifestBytes = 1 * 1_024 * 1_024
    static let maximumDMGBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    static let maximumDMGRedirects = 3

    static func downloadConfiguration() -> URLSessionConfiguration {
        BoundedNetworkPolicy.ephemeralConfiguration(
            requestTimeout: 30,
            resourceTimeout: 60 * 60
        )
    }

    static func validateDeclaredAssetSize(_ size: Int) throws -> Int64 {
        let value = Int64(size)
        guard value > 0, value <= maximumDMGBytes else {
            throw UpdateDownloadPolicyError.invalidDeclaredSize
        }
        return value
    }

    static func validateDownloadURL(_ url: URL?) throws {
        guard BoundedNetworkPolicy.isSecureHTTPSURL(url) else {
            throw UpdateDownloadPolicyError.insecureURL
        }
    }

    static func validatedRedirectCount(
        from sourceURL: URL?,
        to destinationURL: URL?,
        currentCount: Int
    ) throws -> Int {
        try validateDownloadURL(sourceURL)
        try validateDownloadURL(destinationURL)
        guard currentCount >= 0, currentCount < maximumDMGRedirects else {
            throw UpdateDownloadPolicyError.tooManyRedirects
        }
        return currentCount + 1
    }

    @discardableResult
    static func validateDownloadResponse(
        _ response: HTTPURLResponse,
        declaredAssetSize: Int64
    ) throws -> Int64? {
        try validateDownloadURL(response.url)
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateDownloadPolicyError.invalidResponse
        }
        guard declaredAssetSize > 0, declaredAssetSize <= maximumDMGBytes else {
            throw UpdateDownloadPolicyError.invalidDeclaredSize
        }

        let contentLength: Int64?
        do {
            contentLength = try BoundedNetworkPolicy.declaredContentLength(response)
        } catch {
            throw UpdateDownloadPolicyError.invalidContentLength
        }
        if let contentLength {
            guard contentLength <= maximumDMGBytes else {
                throw UpdateDownloadPolicyError.responseTooLarge
            }
            guard contentLength == declaredAssetSize else {
                throw UpdateDownloadPolicyError.contentLengthMismatch
            }
        }
        return contentLength
    }

    static func validatedCumulativeBytes(
        currentBytes: Int64,
        nextChunkBytes: Int,
        declaredAssetSize: Int64
    ) throws -> Int64 {
        guard currentBytes >= 0,
              nextChunkBytes >= 0,
              declaredAssetSize > 0,
              declaredAssetSize <= maximumDMGBytes,
              currentBytes <= declaredAssetSize,
              Int64(nextChunkBytes) <= declaredAssetSize - currentBytes
        else {
            throw UpdateDownloadPolicyError.bodyTooLarge
        }
        return currentBytes + Int64(nextChunkBytes)
    }

    static func validateFinalFileSize(
        _ actualSize: Int64,
        declaredAssetSize: Int64
    ) throws {
        guard actualSize >= 0, actualSize <= maximumDMGBytes else {
            throw UpdateDownloadPolicyError.bodyTooLarge
        }
        guard actualSize == declaredAssetSize else {
            throw UpdateDownloadPolicyError.finalSizeMismatch
        }
    }
}

enum UpdateDownloadedFileValidator {
    static func validateOrRemove(
        _ fileURL: URL,
        declaredAssetSize: Int64,
        fileManager: FileManager = .default
    ) throws {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let rawSize = attributes[.size] as? NSNumber else {
                throw UpdateDownloadPolicyError.finalSizeMismatch
            }
            try UpdateNetworkPolicy.validateFinalFileSize(
                rawSize.int64Value,
                declaredAssetSize: declaredAssetSize
            )
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw error
        }
    }
}

enum UpdateService {
    private static var configuredDeveloperTeamID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TokenFleetDeveloperTeamID") as? String,
              value.count == 10,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
              })
        else {
            return nil
        }
        return value
    }

    private static var latestReleaseURL: URL? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "TokenFleetUpdateAPIURL") as? String,
              let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              configuredDeveloperTeamID != nil
        else {
            return nil
        }
        let lowercasedComponents = url.pathComponents.map { $0.lowercased() }
        guard !(lowercasedComponents.contains("backtthefuture") && lowercasedComponents.contains("tokenstep")) else {
            return nil
        }
        return url
    }

    static var currentVersion: String {
        #if TOKENSTEP_TESTING
        let testingVersion = ProcessInfo.processInfo.environment["TOKENFLEET_TEST_RELEASE_VERSION"]
        #else
        let testingVersion: String? = nil
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "TokenFleetReleaseVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? testingVersion
            ?? "0.0.0"
    }

    static var isConfigured: Bool {
        latestReleaseURL != nil
    }

    static func checkForUpdates(currentVersion: String = Self.currentVersion) async throws -> UpdateCheckResult {
        guard let latestReleaseURL else {
            throw UpdateError.notConfigured
        }
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TokenFleet/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let configuration = BoundedNetworkPolicy.ephemeralConfiguration(
            requestTimeout: 15,
            resourceTimeout: 30
        )
        let loader = BoundedDataLoader(
            maximumBytes: UpdateNetworkPolicy.maximumManifestBytes,
            configuration: configuration
        )
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await loader.load(request)
        } catch {
            throw UpdateError.checkFailed
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateError.checkFailed
        }

        return try updateResult(fromManifestData: data, currentVersion: currentVersion)
    }

    static func updateResult(
        fromManifestData data: Data,
        currentVersion: String
    ) throws -> UpdateCheckResult {
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.checkFailed
        }
        guard !release.draft else { return .upToDate }
        let installedVersion = Version(currentVersion)
        // A beta/RC installation remains on the prerelease channel and may
        // advance to a newer prerelease or a stable release. Stable installs
        // never opt into prereleases implicitly.
        guard !release.prerelease || installedVersion.isPrerelease else {
            return .upToDate
        }
        let version = release.tagName.strippingVersionPrefix
        guard Version(version) > installedVersion else { return .upToDate }
        guard let asset = release.assets.first(where: {
                  let name = $0.name.lowercased()
                  return name.hasPrefix("tokenfleet-")
                      && name.hasSuffix(".dmg")
                      && !$0.name.contains("/")
                      && !$0.name.contains("\\")
                      && (try? UpdateNetworkPolicy.validateDeclaredAssetSize($0.size)) != nil
                      && BoundedNetworkPolicy.isSecureHTTPSURL(URL(string: $0.downloadURL))
              }),
              let pageURL = URL(string: release.htmlURL),
              let assetURL = URL(string: asset.downloadURL),
              BoundedNetworkPolicy.isSecureHTTPSURL(pageURL),
              BoundedNetworkPolicy.isSecureHTTPSURL(assetURL)
        else {
            throw UpdateError.missingDMG
        }

        return .available(
            AvailableUpdate(
                version: version,
                tagName: release.tagName,
                title: release.name ?? "TokenFleet \(version)",
                notes: release.body ?? "",
                pageURL: pageURL,
                assetURL: assetURL,
                assetName: asset.name,
                assetSize: asset.size
            )
        )
    }

    static func downloadAndInstall(
        _ update: AvailableUpdate,
        requireVerified: Bool,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let declaredAssetSize: Int64
        do {
            declaredAssetSize = try UpdateNetworkPolicy.validateDeclaredAssetSize(update.assetSize)
            try UpdateNetworkPolicy.validateDownloadURL(update.assetURL)
        } catch {
            throw UpdateError.downloadFailed
        }

        let downloader = UpdateDownloader(
            declaredAssetSize: declaredAssetSize,
            progress: progress
        )
        let temporaryURL: URL
        do {
            temporaryURL = try await downloader.download(from: update.assetURL)
        } catch {
            throw UpdateError.downloadFailed
        }

        let destination = AppPaths.updates.appendingPathComponent(update.assetName)
        var movedToDestination = false
        do {
            try FileManager.default.createDirectory(at: AppPaths.updates, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            movedToDestination = true
            try preflightDMG(destination, requireVerified: requireVerified)
            try launchInstaller(for: destination, version: update.version, requireVerified: requireVerified)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            if movedToDestination {
                try? FileManager.default.removeItem(at: destination)
            }
            if let updateError = error as? UpdateError {
                throw updateError
            }
            throw UpdateError.installFailed
        }
    }

    private static func preflightDMG(_ dmgURL: URL, requireVerified: Bool) throws {
        detachStaleTokenFleetMounts()
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenfleet-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer {
            _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force", "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        try runProcess("/usr/bin/hdiutil", arguments: ["attach", "-nobrowse", "-quiet", "-mountpoint", mountPoint.path, dmgURL.path])
        let appURL = try findTokenFleetApp(in: mountPoint)
        guard let expectedTeamID = configuredDeveloperTeamID,
              bundleIdentifier(appURL) == Bundle.main.bundleIdentifier,
              signingTeamIdentifier(appURL) == expectedTeamID
        else {
            throw UpdateError.verificationFailed
        }
        guard isVerifiedApp(appURL) else {
            throw UpdateError.verificationFailed
        }
    }

    private static func findTokenFleetApp(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw UpdateError.installFailed
        }

        for case let url as URL in enumerator where url.lastPathComponent == "TokenFleet.app" {
            return url
        }
        throw UpdateError.installFailed
    }

    private static func isVerifiedApp(_ appURL: URL) -> Bool {
        (try? runProcess("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", appURL.path])) != nil
            && (try? runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])) != nil
    }

    private static func bundleIdentifier(_ appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    private static func signingTeamIdentifier(_ appURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", appURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else {
            return nil
        }
        return text
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    private static func launchInstaller(for dmgURL: URL, version: String, requireVerified: Bool) throws {
        guard let expectedTeamID = configuredDeveloperTeamID,
              let bundleID = Bundle.main.bundleIdentifier
        else {
            throw UpdateError.notConfigured
        }
        let helperURL = try prepareTemporaryHelper()
        let logURL = AppPaths.logs.appendingPathComponent("update-install-\(Int(Date().timeIntervalSince1970)).log")
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let launchLog = """
        TokenFleet update launcher prepared at \(Date())
        Expected version: \(version)
        DMG: \(dmgURL.path)
        Helper: \(helperURL.path)

        """
        try launchLog.write(to: logURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "install",
            "--dmg", dmgURL.path,
            "--version", version,
            "--current-pid", "\(currentPID)",
            "--require-verified", requireVerified ? "1" : "0",
            "--log", logURL.path,
            "--helper-path", helperURL.path,
            "--bundle-id", bundleID,
            "--team-id", expectedTeamID
        ]
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
            exitCurrentAppAfterLaunchingInstaller()
        } catch {
            throw UpdateError.installFailed
        }
    }

    private static func prepareTemporaryHelper() throws -> URL {
        guard let helperURL = DataService.bundledHelperURL() else {
            throw UpdateError.installFailed
        }

        try FileManager.default.createDirectory(at: AppPaths.updates, withIntermediateDirectories: true)
        let destination = AppPaths.updates
            .appendingPathComponent("TokenFleetHelper-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: helperURL, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    private static func exitCurrentAppAfterLaunchingInstaller() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Darwin.exit(0)
        }
    }

    private static func installerScript(
        dmgPath: String,
        version: String,
        currentPID: Int32,
        logPath: String,
        requireVerified: Bool,
        scriptPath: String
    ) -> String {
        let failureTitle = L("TokenFleet 自动更新失败")
        let failureBody = L("请手动把 DMG 里的 TokenFleet 拖到 Applications。")
        return """
        #!/bin/bash
        set -euo pipefail

        DMG=\(shellQuote(dmgPath))
        DEST="/Applications/TokenFleet.app"
        APP_NAME="TokenFleet.app"
        EXECUTABLE_NAME="TokenFleet"
        EXPECTED_VERSION=\(shellQuote(version))
        CURRENT_PID="\(currentPID)"
        LOG=\(shellQuote(logPath))
        REQUIRE_VERIFIED="\(requireVerified ? "1" : "0")"
        SCRIPT_PATH=\(shellQuote(scriptPath))
        FAILURE_TITLE=\(shellQuote(failureTitle))
        FAILURE_BODY=\(shellQuote(failureBody))
        MOUNT_POINT=""
        MOUNT_ROOT=""
        BACKUP=""

        mkdir -p "$(dirname "$LOG")"
        exec >>"$LOG" 2>&1
        echo "TokenFleet update installer started at $(date)"
        echo "Expected version: $EXPECTED_VERSION"
        echo "DMG: $DMG"
        echo "Destination: $DEST"

        cleanup() {
          if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
            /usr/bin/hdiutil detach "$MOUNT_POINT" -force -quiet || true
          fi
          if [ -n "$MOUNT_ROOT" ] && [ -d "$MOUNT_ROOT" ]; then
            /bin/rm -rf "$MOUNT_ROOT" 2>/dev/null || true
          fi
          /bin/rm -f "$SCRIPT_PATH" 2>/dev/null || true
        }
        finish() {
          STATUS=$?
          if [ "$STATUS" -ne 0 ]; then
            echo "TokenFleet update installer failed with status $STATUS"
            if [ -n "$BACKUP" ] && [ -d "$BACKUP" ] && [ ! -d "$DEST" ]; then
              /bin/mv "$BACKUP" "$DEST" || true
            fi
            /usr/bin/osascript -e "display notification \\"$FAILURE_BODY\\" with title \\"$FAILURE_TITLE\\"" || true
          fi
          cleanup
          exit "$STATUS"
        }
        trap finish EXIT

        detach_tokenfleet_mounts() {
          /sbin/mount | while IFS= read -r line; do
            if [[ "$line" == *" on /Volumes/TokenFleet"* || "$line" == *tokenfleet-preflight-* || "$line" == *tokenfleet-update.* || "$line" == *tokenfleet-update-root.* ]]; then
              MP="${line#* on }"
              MP="${MP%% (*}"
              echo "Detaching stale mount: $MP"
              /usr/bin/hdiutil detach "$MP" -force -quiet || true
            fi
          done
        }

        detach_tokenfleet_mounts

        MOUNT_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tokenfleet-update-root.XXXXXX")"
        echo "Mounting DMG under $MOUNT_ROOT"
        ATTACH_OUTPUT="$(/usr/bin/hdiutil attach -nobrowse -readonly -mountroot "$MOUNT_ROOT" "$DMG" 2>&1)" || {
          echo "hdiutil attach failed"
          echo "$ATTACH_OUTPUT"
          exit 1
        }
        echo "$ATTACH_OUTPUT"
        MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | /usr/bin/awk '/\\// { mount=$NF } END { print mount }')"
        if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
          echo "Mounted volume path not found"
          exit 1
        }
        echo "Mounted at $MOUNT_POINT"

        SRC="$(/usr/bin/find "$MOUNT_POINT" -name "$APP_NAME" -type d -print -quit)"
        if [ -z "$SRC" ]; then
          echo "TokenFleet.app not found in DMG"
          exit 1
        fi
        echo "Found source app: $SRC"

        if [ "$REQUIRE_VERIFIED" = "1" ]; then
          echo "Verifying source app"
          /usr/sbin/spctl --assess --type execute "$SRC"
          /usr/bin/codesign --verify --deep --strict "$SRC"
        fi

        SRC_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist" 2>/dev/null || true)"
        echo "Source version: $SRC_VERSION"
        if [ "$SRC_VERSION" != "$EXPECTED_VERSION" ]; then
          echo "Source version mismatch: expected $EXPECTED_VERSION, got $SRC_VERSION"
          exit 1
        fi

        echo "Stopping old TokenFleet process"
        /bin/kill -TERM "$CURRENT_PID" 2>/dev/null || true
        /usr/bin/pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
        for _ in {1..50}; do
          if ! /usr/bin/pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
            break
          fi
          /bin/sleep 0.2
        done
        if /usr/bin/pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
          echo "Force stopping old TokenFleet process"
          /usr/bin/pkill -9 -x "$EXECUTABLE_NAME" 2>/dev/null || true
          /bin/sleep 0.4
        fi

        BACKUP="/Applications/TokenFleet.app.previous.$(/bin/date +%s)"
        if [ -d "$DEST" ]; then
          echo "Backing up existing app to $BACKUP"
          /bin/mv "$DEST" "$BACKUP"
        fi

        echo "Copying new app into Applications"
        if ! /usr/bin/ditto "$SRC" "$DEST"; then
          /bin/rm -rf "$DEST"
          if [ -d "$BACKUP" ]; then
            /bin/mv "$BACKUP" "$DEST"
          fi
          echo "Failed to copy TokenFleet.app into /Applications"
          exit 1
        fi

        if [ -d "$BACKUP" ]; then
          /bin/rm -rf "$BACKUP"
        fi

        INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
        echo "Installed version: $INSTALLED_VERSION"
        if [ "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ]; then
          echo "Installed version mismatch: expected $EXPECTED_VERSION, got $INSTALLED_VERSION"
          exit 1
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        echo "Opening updated app"
        /usr/bin/open -n "$DEST"
        for _ in {1..25}; do
          if /usr/bin/pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
            echo "Updated app relaunched"
            break
          fi
          /bin/sleep 0.2
        done
        echo "TokenFleet update installer finished at $(date)"
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    @discardableResult
    private static func runProcess(_ executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.installFailed
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private static func detachStaleTokenFleetMounts() {
        guard let output = try? runProcess("/sbin/mount", arguments: []),
              let text = String(data: output, encoding: .utf8)
        else { return }

        for line in text.split(separator: "\n").map(String.init) {
            guard line.contains(" on /Volumes/TokenFleet")
                    || line.contains("tokenfleet-preflight-")
                    || line.contains("tokenfleet-update.")
                    || line.contains("tokenfleet-update-root.")
            else { continue }

            guard let range = line.range(of: " on ") else { continue }
            let afterOn = line[range.upperBound...]
            guard let endRange = afterOn.range(of: " (") else { continue }
            let mountPoint = String(afterOn[..<endRange.lowerBound])
            _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-force", "-quiet"])
        }
    }
}

enum UpdateError: LocalizedError {
    case notConfigured
    case checkFailed
    case missingDMG
    case downloadFailed
    case verificationFailed
    case installFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L("当前版本未配置 TokenFleet 更新服务，已停止检查更新。")
        case .checkFailed:
            return L("检查更新失败，请稍后再试。")
        case .missingDMG:
            return L("新版本没有可下载的 DMG。")
        case .downloadFailed:
            return L("下载更新失败，请稍后再试。")
        case .verificationFailed:
            return L("新版本未通过签名或公证验证，已停止安装。")
        case .installFailed:
            return L("自动安装失败，请稍后重试，或手动把 TokenFleet 拖到 Applications。")
        }
    }
}

final class UpdateDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let declaredAssetSize: Int64
    private let configuration: URLSessionConfiguration
    private let stagingDirectory: URL
    private let progress: @MainActor (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var temporaryURL: URL?
    private var response: HTTPURLResponse?
    private var receivedBytes: Int64 = 0
    private var redirectCount = 0
    private var terminalError: Error?

    init(
        declaredAssetSize: Int64,
        configuration: URLSessionConfiguration = UpdateNetworkPolicy.downloadConfiguration(),
        stagingDirectory: URL = FileManager.default.temporaryDirectory,
        progress: @escaping @MainActor (Double) -> Void
    ) {
        self.declaredAssetSize = declaredAssetSize
        self.configuration = configuration
        self.stagingDirectory = stagingDirectory
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        try UpdateNetworkPolicy.validateDownloadURL(url)
        guard declaredAssetSize > 0,
              declaredAssetSize <= UpdateNetworkPolicy.maximumDMGBytes
        else {
            throw UpdateDownloadPolicyError.invalidDeclaredSize
        }

        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let temporaryURL = stagingDirectory
            .appendingPathComponent("tokenfleet-update-\(UUID().uuidString)")
            .appendingPathExtension("dmg")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw UpdateDownloadPolicyError.invalidResponse
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.fileHandle = handle
            self.temporaryURL = temporaryURL
            response = nil
            receivedBytes = 0
            redirectCount = 0
            terminalError = nil

            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: delegateQueue
            )
            self.session = session
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = configuration.timeoutIntervalForRequest
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard terminalError == nil else {
            completionHandler(nil)
            return
        }
        do {
            redirectCount = try UpdateNetworkPolicy.validatedRedirectCount(
                from: response.url,
                to: request.url,
                currentCount: redirectCount
            )
            completionHandler(request)
        } catch {
            terminalError = error
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard terminalError == nil,
              let http = response as? HTTPURLResponse
        else {
            terminalError = terminalError ?? UpdateDownloadPolicyError.invalidResponse
            completionHandler(.cancel)
            return
        }
        do {
            try UpdateNetworkPolicy.validateDownloadResponse(
                http,
                declaredAssetSize: declaredAssetSize
            )
            self.response = http
            completionHandler(.allow)
        } catch {
            terminalError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard terminalError == nil else { return }
        do {
            let updatedBytes = try UpdateNetworkPolicy.validatedCumulativeBytes(
                currentBytes: receivedBytes,
                nextChunkBytes: data.count,
                declaredAssetSize: declaredAssetSize
            )
            guard let fileHandle else {
                throw UpdateDownloadPolicyError.invalidResponse
            }
            try fileHandle.write(contentsOf: data)
            receivedBytes = updatedBytes
            let value = Double(receivedBytes) / Double(declaredAssetSize)
            Task { @MainActor in
                progress(min(max(value, 0), 1))
            }
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let terminalError {
            finish(.failure(terminalError))
            return
        }
        if let error {
            finish(.failure(error))
            return
        }
        guard response != nil, let temporaryURL else {
            finish(.failure(UpdateDownloadPolicyError.invalidResponse))
            return
        }

        do {
            try UpdateNetworkPolicy.validateFinalFileSize(
                receivedBytes,
                declaredAssetSize: declaredAssetSize
            )
            try fileHandle?.synchronize()
            try fileHandle?.close()
            fileHandle = nil
            try UpdateDownloadedFileValidator.validateOrRemove(
                temporaryURL,
                declaredAssetSize: declaredAssetSize
            )
            finish(.success(temporaryURL))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        try? fileHandle?.close()
        fileHandle = nil
        if case .failure = result, let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        self.temporaryURL = nil
        session?.invalidateAndCancel()
        session = nil
        continuation.resume(with: result)
    }
}

private struct GitHubRelease: Decodable {
    var tagName: String
    var name: String?
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var htmlURL: String
    var assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    var name: String
    var downloadURL: String
    var size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
    }
}

struct Version: Comparable {
    var core: [Int]
    var prerelease: [String]?

    init(_ value: String) {
        let withoutBuildMetadata = value.strippingVersionPrefix
            .split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let components = withoutBuildMetadata
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        core = components[0]
            .split(separator: ".")
            .map { Int($0) ?? 0 }
        if components.count == 2 {
            prerelease = components[1].split(separator: ".").map(String.init)
        } else {
            prerelease = nil
        }
    }

    var isPrerelease: Bool {
        prerelease != nil
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.core.count, rhs.core.count)
        for index in 0..<count {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(left), .some(right)):
            let identifierCount = min(left.count, right.count)
            for index in 0..<identifierCount {
                let leftIdentifier = left[index]
                let rightIdentifier = right[index]
                if leftIdentifier == rightIdentifier { continue }
                switch (Int(leftIdentifier), Int(rightIdentifier)) {
                case let (.some(leftNumber), .some(rightNumber)):
                    return leftNumber < rightNumber
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    return leftIdentifier < rightIdentifier
                }
            }
            return left.count < right.count
        }
    }
}

private extension String {
    var strippingVersionPrefix: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
    }
}
