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

    /// 主窗口的 sheet。同一时间只显示一个。
    enum Sheet: String, Identifiable {
        case login
        case addLink

        var id: String { rawValue }
    }

    var sheet: Sheet?

    /// 登录 sheet 显示的登录方式。
    enum LoginMethod {
        case web
        case cookie
    }

    /// 打开登录 sheet 时设定，用户在 sheet 中可以切换。
    var loginMethod = LoginMethod.web
    /// 主窗口关闭后，用它重新打开（例如点击 Dock 图标）。
    @ObservationIgnored var openMainWindow: (() -> Void)?

    @ObservationIgnored private let source: BaiduDownloadSource
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var hasRequestedNotifications = false
    /// 设置中的下载目录。应用在选择期间一直持有它的访问权限；任务另外持有各自目录的访问权限。
    @ObservationIgnored private var accessedDirectory: URL?

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
                                     settings: settings, downloadFolder: DownloadFolder(url: Self.defaultDownloadDirectory))
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
        try await logIn(credential: Credential.parse(cookie))
    }

    /// 校验凭据，通过后存入 Keychain 并开始使用。调用方取消时不保存。
    func logIn(credential: Credential) async throws {
        let client = BaiduClient(credential: credential)
        let account = try await client.validate()
        // 用户在校验期间取消了登录。
        try Task.checkCancellation()
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
        coordinator.accountUK = nil
    }

    private func apply(_ client: BaiduClient, account: Account) {
        self.client = client
        self.account = account
        isLoginExpired = false
        source.setClient(client)
        coordinator.netdisk = client
        coordinator.accountUK = account.uk
    }

    /// 网络错误不算失效，只有百度明确说登录失效才提示。
    private func revalidate() async {
        guard let client else { return }
        do {
            let account = try await client.validate()
            guard client === self.client else { return }
            self.account = account
            coordinator.accountUK = account.uk
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

    /// 新任务默认的下载目录（设置中的下载目录）。任务记录它，以后每次启动用 bookmark 重新取得访问权限。
    var currentFolder: DownloadFolder {
        DownloadFolder(url: downloadDirectory, bookmark: accessedDirectory == nil ? nil : settings.downloadDirectoryBookmark)
    }

    private func resolveDownloadDirectory() {
        defer { coordinator.downloadFolder = currentFolder }
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
            accessedDirectory = url
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
            releaseAccessedDirectory()
            if isAccessing { accessedDirectory = url }
            downloadDirectory = url
            downloadDirectoryProblem = nil
            coordinator.downloadFolder = DownloadFolder(url: url, bookmark: settings.downloadDirectoryBookmark)
        } catch {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
            downloadDirectoryProblem = "无法保存下载目录的访问权限：\(error.localizedDescription)"
        }
    }

    /// 添加链接时为一个任务选择的下载目录。`url` 来自用户在打开面板中的选择。不修改设置。
    /// 任务开始时 `JobCoordinator` 用 bookmark 取得访问权限，所以这里只在创建 bookmark 期间访问。
    func makeDownloadFolder(for url: URL) throws -> DownloadFolder {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        return DownloadFolder(url: url, bookmark: try url.bookmarkData(options: .withSecurityScope))
    }

    func useDefaultDownloadDirectory() {
        settings.downloadDirectoryBookmark = nil
        releaseAccessedDirectory()
        downloadDirectory = Self.defaultDownloadDirectory
        downloadDirectoryProblem = nil
        coordinator.downloadFolder = currentFolder
    }

    /// 之前选择的目录中未完成的任务持有自己的访问权限，所以这里可以交回。
    private func releaseAccessedDirectory() {
        accessedDirectory?.stopAccessingSecurityScopedResource()
        accessedDirectory = nil
    }

    // MARK: - 任务

    /// 未登录时改为打开登录。
    func presentAddLink() {
        if account == nil {
            presentLogin()
        } else {
            sheet = .addLink
        }
    }

    /// 默认显示网页登录。
    func presentLogin(method: LoginMethod = .web) {
        loginMethod = method
        sheet = .login
    }

    /// 百度明确返回登录失效时，显示失效横幅。其他错误不影响登录状态。
    func noteError(_ error: any Error) {
        if let error = error as? BaiduError, error == .loginExpired, client != nil {
            isLoginExpired = true
        }
    }

    /// 没有未完成的任务时直接退出登录，返回 false；否则返回 true，由界面先确认。
    func requestLogOut() -> Bool {
        guard hasUnfinishedJobs else {
            logOut()
            return false
        }
        return true
    }

    var hasUnfinishedJobs: Bool {
        coordinator.jobs.contains { $0.isUnfinished }
    }

    /// `downloadFolder` 为 nil 时，任务使用设置中的下载目录。
    func addJob(session: ShareSession, entries: [ShareEntry], downloadFolder: DownloadFolder? = nil) {
        coordinator.addJob(session: session, entries: entries, downloadFolder: downloadFolder)
        requestNotificationAuthorization()
    }

    /// 启动恢复完成前和移除期间，任务不接受操作。
    func canOperate(on job: Job) -> Bool {
        coordinator.isStarted && !coordinator.removingJobs.contains(job.id)
    }

    func pause(_ job: Job) {
        Task { await coordinator.pause(job.id) }
    }

    func resume(_ job: Job) {
        Task { await coordinator.resume(job.id) }
    }

    /// 其中下载中且未暂停、可以暂停的任务。
    func pausableJobs(in jobs: [Job]) -> [Job] {
        jobs.filter { $0.phase == .downloading && !$0.isPaused && canOperate(on: $0) }
    }

    /// 其中已暂停、可以继续的任务。
    func resumableJobs(in jobs: [Job]) -> [Job] {
        jobs.filter { $0.phase == .downloading && $0.isPaused && canOperate(on: $0) }
    }

    func pauseAll(_ jobs: [Job]) {
        pausableJobs(in: jobs).forEach(pause)
    }

    func resumeAll(_ jobs: [Job]) {
        resumableJobs(in: jobs).forEach(resume)
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
