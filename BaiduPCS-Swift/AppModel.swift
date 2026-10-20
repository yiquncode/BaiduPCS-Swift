import AppKit
import BaiduKit
import DownloadKit
import FerryCore
import Observation
import UserNotifications

/// 界面读取的全部状态：账号、设置和任务列表。界面的操作都经过它。
@Observable
final class AppModel {
    private(set) var account: Account?
    private(set) var client: BaiduClient?
    /// 后台校验发现 Cookie 已失效。正在进行的下载不停止。
    private(set) var isLoginExpired = false
    var settings: FerrySettings {
        didSet { settingsDidChange() }
    }
    private(set) var downloadDirectory: URL
    /// 用户选择的下载目录无法访问时的说明。
    private(set) var downloadDirectoryProblem: String?
    let coordinator: JobCoordinator

    var isShowingLogin = false
    var isShowingAddLink = false

    @ObservationIgnored private let source: BaiduDownloadSource
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var hasRequestedNotifications = false

    private static let settingsKey = "settings"

    /// 沙盒中的“下载”目录是指向用户“下载”目录的符号链接。解析后显示和保存真实路径。
    private static var defaultDownloadDirectory: URL { URL.downloadsDirectory.resolvingSymlinksInPath() }

    init() {
        let settings = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(FerrySettings.self, from: $0) } ?? FerrySettings()
        let source = BaiduDownloadSource()
        let engine = DownloadEngine(stateDirectory: FerryDirectories.downloadState, source: source,
                                    configuration: settings.downloadConfiguration())
        self.settings = settings
        self.source = source
        downloadDirectory = Self.defaultDownloadDirectory
        coordinator = JobCoordinator(engine: engine, store: JobStore(fileURL: FerryDirectories.jobsFile),
                                     settings: settings, downloadDirectory: Self.defaultDownloadDirectory)
        coordinator.onJobCompleted = { [weak self] job in self?.notifyCompletion(of: job) }
        resolveDownloadDirectory()
        if let login = CredentialStore.load() {
            apply(BaiduClient(credential: login.credential), account: login.account)
        }
    }

    // MARK: - 生命周期

    /// 恢复任务，然后在后台校验账号。
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await coordinator.start()
        await revalidate()
    }

    func shutdown() async {
        await coordinator.shutdown()
    }

    // MARK: - 账号

    func logIn(cookie: String) async throws {
        let credential = try Credential.parse(cookie)
        let client = BaiduClient(credential: credential)
        let account = try await client.validate()
        try CredentialStore.save(StoredLogin(credential: credential, account: account))
        apply(client, account: account)
    }

    func logOut() {
        CredentialStore.delete()
        client = nil
        account = nil
        isLoginExpired = false
        source.setClient(nil)
        coordinator.netdisk = nil
    }

    private func apply(_ client: BaiduClient, account: Account) {
        self.client = client
        self.account = account
        isLoginExpired = false
        source.setClient(client)
        coordinator.netdisk = client
    }

    /// 网络错误不算失效，只有百度明确说登录失效才提示。
    private func revalidate() async {
        guard let client else { return }
        do {
            let account = try await client.validate()
            guard client === self.client else { return }
            self.account = account
            let credential = await client.credential
            try? CredentialStore.save(StoredLogin(credential: credential, account: account))
        } catch BaiduError.loginExpired {
            if client === self.client { isLoginExpired = true }
        } catch {}
    }

    // MARK: - 设置

    private func settingsDidChange() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        let settings = settings
        Task { await coordinator.updateSettings(settings) }
    }

    /// 访问权限在应用运行期间一直保持：已加入队列的文件下载可能还要写入这个目录。
    private func resolveDownloadDirectory() {
        defer { coordinator.downloadDirectory = downloadDirectory }
        guard let bookmark = settings.downloadDirectoryBookmark else {
            downloadDirectory = Self.defaultDownloadDirectory
            return
        }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            if isStale, let renewed = try? url.bookmarkData(options: .withSecurityScope) {
                settings.downloadDirectoryBookmark = renewed
            }
            downloadDirectory = url
            downloadDirectoryProblem = nil
        } catch {
            downloadDirectory = Self.defaultDownloadDirectory
            downloadDirectoryProblem = "无法访问之前选择的下载目录，文件会下载到“下载”目录。请重新选择下载目录。"
        }
    }

    /// `url` 来自用户在打开面板中的选择。
    func chooseDownloadDirectory(_ url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        do {
            settings.downloadDirectoryBookmark = try url.bookmarkData(options: .withSecurityScope)
            downloadDirectory = url
            downloadDirectoryProblem = nil
            coordinator.downloadDirectory = url
        } catch {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
            downloadDirectoryProblem = "无法保存下载目录的访问权限：\(error.localizedDescription)"
        }
    }

    func useDefaultDownloadDirectory() {
        settings.downloadDirectoryBookmark = nil
        downloadDirectory = Self.defaultDownloadDirectory
        downloadDirectoryProblem = nil
        coordinator.downloadDirectory = downloadDirectory
    }

    // MARK: - 任务

    func presentAddLink() {
        if account == nil {
            isShowingLogin = true
        } else {
            isShowingAddLink = true
        }
    }

    func addJob(session: ShareSession, entries: [ShareEntry]) {
        coordinator.addJob(session: session, entries: entries)
        requestNotificationAuthorization()
    }

    func pause(_ job: Job) {
        Task { await coordinator.pause(job.id) }
    }

    func resume(_ job: Job) {
        Task { await coordinator.resume(job.id) }
    }

    func retry(_ job: Job) {
        Task { await coordinator.retry(job.id) }
    }

    func remove(_ job: Job) {
        Task { await coordinator.remove(job.id) }
    }

    func reveal(_ job: Job) {
        NSWorkspace.shared.activateFileViewerSelecting(job.revealURLs)
    }

    // MARK: - 通知

    private func requestNotificationAuthorization() {
        guard !hasRequestedNotifications else { return }
        hasRequestedNotifications = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func notifyCompletion(of job: Job) {
        let content = UNMutableNotificationContent()
        content.title = "下载完成"
        content.body = job.title
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
