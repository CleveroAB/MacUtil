import AppKit
import Foundation

final class UpdateChecker {
    private enum Constants {
        static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
        static let minimumTimerDelay: TimeInterval = 60
        static let latestReleaseURL = URL(string: "https://api.github.com/repos/CleveroAB/MacUtil/releases/latest")!
        static let releasesURL = URL(string: "https://github.com/CleveroAB/MacUtil/releases")!
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private struct Version: Comparable {
        let parts: [Int]

        init(_ string: String) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
                ? String(trimmed.dropFirst())
                : trimmed
            parts = withoutPrefix
                .split(separator: ".")
                .map { component in
                    let digits = component.prefix { $0.isNumber }
                    return Int(digits) ?? 0
                }
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            let count = max(lhs.parts.count, rhs.parts.count)
            for index in 0..<count {
                let left = index < lhs.parts.count ? lhs.parts[index] : 0
                let right = index < rhs.parts.count ? rhs.parts[index] : 0
                if left != right {
                    return left < right
                }
            }
            return false
        }
    }

    private let settings = Settings.shared
    private var automaticTimer: Timer?
    private var isChecking = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func start() {
        guard settings.automaticUpdateChecksEnabled else { return }
        if automaticCheckIsDue {
            checkForUpdates(userInitiated: false)
        } else {
            scheduleNextAutomaticCheck()
        }
    }

    func stop() {
        automaticTimer?.invalidate()
        automaticTimer = nil
    }

    func setAutomaticChecksEnabled(_ isEnabled: Bool) {
        settings.automaticUpdateChecksEnabled = isEnabled
        isEnabled ? start() : stop()
    }

    func checkForUpdates(userInitiated: Bool) {
        if isChecking {
            if userInitiated {
                showMessage(
                    title: "Checking for Updates",
                    message: "MacUtil is already checking for updates."
                )
            }
            return
        }

        isChecking = true
        settings.lastUpdateCheckDate = Date()

        var request = URLRequest(url: Constants.latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("MacUtil/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleResponse(
                    data: data,
                    response: response,
                    error: error,
                    userInitiated: userInitiated
                )
            }
        }.resume()
    }

    private var automaticCheckIsDue: Bool {
        guard let lastCheck = settings.lastUpdateCheckDate else { return true }
        return Date().timeIntervalSince(lastCheck) >= Constants.automaticCheckInterval
    }

    private func scheduleNextAutomaticCheck() {
        stop()
        guard settings.automaticUpdateChecksEnabled else { return }

        let lastCheck = settings.lastUpdateCheckDate ?? .distantPast
        let dueAt = lastCheck.addingTimeInterval(Constants.automaticCheckInterval)
        let delay = max(Constants.minimumTimerDelay, dueAt.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
        automaticTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleResponse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        userInitiated: Bool
    ) {
        isChecking = false
        if settings.automaticUpdateChecksEnabled {
            scheduleNextAutomaticCheck()
        }

        if let error {
            showErrorIfNeeded(error.localizedDescription, userInitiated: userInitiated)
            return
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let data else {
            let status = (response as? HTTPURLResponse)?.statusCode
            showErrorIfNeeded("GitHub returned \(status.map(String.init) ?? "an invalid response").", userInitiated: userInitiated)
            return
        }

        do {
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            handle(release, userInitiated: userInitiated)
        } catch {
            showErrorIfNeeded("The update response could not be read.", userInitiated: userInitiated)
        }
    }

    private func handle(_ release: GitHubRelease, userInitiated: Bool) {
        let latestVersion = Version(release.tagName)
        let installedVersion = Version(currentVersion)
        if latestVersion > installedVersion {
            showUpdateAvailable(release)
        } else if userInitiated {
            showMessage(
                title: "MacUtil Is Up to Date",
                message: "You are running MacUtil \(currentVersion)."
            )
        }
    }

    private func showUpdateAvailable(_ release: GitHubRelease) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "MacUtil \(displayVersion(release.tagName)) Is Available"
        alert.informativeText = "You are running MacUtil \(currentVersion). Download the latest signed and notarized release from GitHub."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(downloadURL(for: release))
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    private func showMessage(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorIfNeeded(_ message: String, userInitiated: Bool) {
        guard userInitiated else { return }
        showMessage(
            title: "Update Check Failed",
            message: "\(message)\n\nYou can also check GitHub Releases manually."
        )
    }

    private func downloadURL(for release: GitHubRelease) -> URL {
        release.assets.first { asset in
            asset.name.lowercased().hasSuffix(".dmg")
        }?.browserDownloadURL ?? release.htmlURL
    }

    private func displayVersion(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }
}
