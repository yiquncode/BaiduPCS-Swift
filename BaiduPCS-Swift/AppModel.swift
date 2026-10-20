import AppKit
import BaiduKit
import DownloadKit
import FerryCore
import Network
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
    /// SOCKS5 代理的密码。存在 Keychain 中，不在 `settings` 中。
    private(set) var proxyPassword: String
    /// 代理密码没能存入 Keychain 时的说明。这次运行仍使用新密码。
    private(set) var proxyPasswordProblem: String?
    let coordinator: JobCoordinator

    /// 主窗口的 sheet。同一时间只显示一个。
    enum Sheet: String, Identifiable {
        case login
        case addLink

        var id: String { rawValue }
    }

    var sheet: Sheet?

    /// 移除任务时没能移到废纸篓的文件或目录。界面提示后清空。
    var untrashedItems: [URL] = []

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
    @ObservationIgnored private let engine: DownloadEngine
    /// 当前登录的凭据。换代理时用它同步创建新客户端；后台校验用它判断期间是否换了账号，因为换代理也会换 `client`。
    @ObservationIgnored private var credential: Credential?
    /// 引擎和 `client` 的会话使用的代理。只在它变化时换会话。
    @ObservationIgnored private var activeProxy: ActiveProxy?
    /// 最近一次换引擎会话的 Task。下一次先等它完成，因为各个 Task 到达引擎的顺序不一定和创建顺序相同。
    @ObservationIgnored private var sessionReplacement: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var hasRequestedNotifications = false
    /// 最近一次读取剪贴板的结果。剪贴板没变时不再读取，所以每次复制最多触发一次系统的剪贴板隐私提示，
    /// 也最多自动打开一次添加链接。
    @ObservationIgnored private var pasteboardCheck: (changeCount: Int, link: ShareLink?)?
    /// 设置中的下载目录。应用在选择期间一直持有它的访问权限；任务另外持有各自目录的访问权限。
    @ObservationIgnored private var accessedDirectory: URL?

    private static let settingsKey = "settings"

    /// 沙盒中的“下载”目录是指向用户“下载”目录的符号链接。解析后显示和保存真实路径。
    static var defaultDownloadDirectory: URL { URL.downloadsDirectory.resolvingSymlinksInPath() }

    /// 正在使用系统的“下载”目录：没有选择过目录、选择的就是它，或之前选择的目录无法访问。
    var usesDefaultDownloadDirectory: Bool {
        downloadDirectory.standardizedFileURL.path == Self.defaultDownloadDirectory.standardizedFileURL.path
    }

    init() {
        let settings = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(FerrySettings.self, from: $0) } ?? FerrySettings()
        let proxyPassword = ProxyPasswordStore.load()
        let proxy = ActiveProxy(settings.proxy, password: proxyPassword)
        let source = BaiduDownloadSource()
        let engine = DownloadEngine(stateDirectory: FerryDirectories.downloadState, source: source,
                                    configuration: settings.downloadConfiguration(),
                                    sessionConfiguration: Self.applying(proxy, to: DownloadEngine.defaultSessionConfiguration()))
        self.settings = settings
        self.proxyPassword = proxyPassword
        activeProxy = proxy
        self.source = source
        self.engine = engine
        downloadDirectory = Self.defaultDownloadDirectory
        coordinator = JobCoordinator(engine: engine, store: JobStore(fileURL: FerryDirectories.jobsFile),
                                     settings: settings, downloadFolder: DownloadFolder(url: Self.defaultDownloadDirectory))
        coordinator.onJobCompleted = { [weak self] job in self?.notifyCompletion(of: job) }
        resolveDownloadDirectory()
        if let login = CredentialStore.load() {
            apply(makeClient(credential: login.credential), credential: login.credential, account: login.account)
        }
    }

    // MARK: - 生命周期

    /// 恢复任务，然后在后台校验账号。
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await coordinator.start()
        // 启动时应用变为活跃的那次检测在任务列表加载前，被跳过，所以加载后再检测一次。
        if NSApp.isActive { await detectCopiedLink() }
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
        let proxy = activeProxy
        var client = makeClient(credential: credential)
        let account = try await client.validate()
        // 用户在校验期间取消了登录。
        try Task.checkCancellation()
        try CredentialStore.save(StoredLogin(credential: credential, account: account))
        // 校验期间代理变了。
        if proxy != activeProxy {
            client = makeClient(credential: credential)
        }
        apply(client, credential: credential, account: account)
    }

    func logOut() {
        CredentialStore.delete()
        client = nil
        credential = nil
        account = nil
        isLoginExpired = false
        source.setClient(nil)
        coordinator.netdisk = nil
        coordinator.accountUK = nil
    }

    private func apply(_ client: BaiduClient, credential: Credential, account: Account) {
        replaceClient(client)
        self.credential = credential
        self.account = account
        isLoginExpired = false
        coordinator.accountUK = account.uk
    }

    /// 只换客户端，不改变账号和登录状态。
    private func replaceClient(_ client: BaiduClient) {
        self.client = client
        source.setClient(client)
        coordinator.netdisk = client
    }

    private func makeClient(credential: Credential) -> BaiduClient {
        BaiduClient(credential: credential, configuration: Self.applying(activeProxy, to: BaiduClient.defaultConfiguration()))
    }

    /// 网络错误不算失效，只有百度明确说登录失效才提示。
    private func revalidate() async {
        guard let client, let credential else { return }
        do {
            let account = try await client.validate()
            // 校验期间退出登录或换了账号。
            guard credential == self.credential else { return }
            self.account = account
            coordinator.accountUK = account.uk
            try? CredentialStore.save(StoredLogin(credential: credential, account: account))
        } catch BaiduError.loginExpired {
            if credential == self.credential { isLoginExpired = true }
        } catch {}
    }

    // MARK: - 设置

    private func settingsDidChange() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        let settings = settings
        Task { await coordinator.updateSettings(settings) }
        updateProxy()
    }

    // MARK: - 代理

    /// 实际生效的代理。使用系统设置或设置不完整时为 nil，这时会话使用系统的代理设置。
    private struct ActiveProxy: Equatable {
        var settings: ProxySettings
        var password: String

        init?(_ settings: ProxySettings, password: String) {
            guard settings.mode == .socks5, settings.problem(password: password) == nil else { return nil }
            self.settings = settings
            self.password = password
        }
    }

    /// 设置页显示的代理设置不完整的原因。
    var proxyProblem: String? {
        settings.proxy.problem(password: proxyPassword)
    }

    /// 网页登录的数据存储使用的代理。为空时使用系统设置。
    var proxyConfigurations: [ProxyConfiguration] {
        Self.proxyConfigurations(activeProxy)
    }

    /// 设置页一次提交代理设置和密码，所以两者都变化时只换一次会话。
    func setProxy(_ proxy: ProxySettings, password: String) {
        if password != proxyPassword {
            proxyPassword = password
            do {
                try ProxyPasswordStore.save(password)
                proxyPasswordProblem = nil
            } catch {
                proxyPasswordProblem = error.localizedDescription
            }
        }
        if proxy != settings.proxy {
            settings.proxy = proxy
        } else {
            updateProxy()
        }
    }

    /// 生效的代理变化时，引擎换会话，进行中的下载从断点继续；已登录时用同一个凭据换客户端。
    /// 已经发出的 API 请求在旧客户端上完成。
    private func updateProxy() {
        let proxy = ActiveProxy(settings.proxy, password: proxyPassword)
        guard proxy != activeProxy else { return }
        activeProxy = proxy
        let configuration = Self.applying(proxy, to: DownloadEngine.defaultSessionConfiguration())
        let previous = sessionReplacement
        sessionReplacement = Task {
            await previous?.value
            await engine.replaceSession(configuration: configuration)
        }
        if let credential {
            replaceClient(makeClient(credential: credential))
        }
    }

    private static func proxyConfigurations(_ proxy: ActiveProxy?) -> [ProxyConfiguration] {
        proxy.map { $0.settings.proxyConfigurations(password: $0.password) } ?? []
    }

    private static func applying(_ proxy: ActiveProxy?, to configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.proxyConfigurations = proxyConfigurations(proxy)
        return configuration
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

    /// 应用变为活跃时调用。剪贴板中有新复制的分享链接时，打开添加链接，由 sheet 填入。
    /// 未登录、已有 sheet、剪贴板已经读过（包括手动打开添加链接时），或链接已经是一个任务的来源时不打开。
    func detectCopiedLink() async {
        guard settings.detectsCopiedLinks, coordinator.isStarted, account != nil, sheet == nil,
              pasteboardCheck?.changeCount != NSPasteboard.general.changeCount else { return }
        guard let link = await shareLinkOnPasteboard(), sheet == nil,
              !coordinator.jobs.contains(where: { $0.link.surl == link.surl }) else { return }
        openMainWindow?()
        sheet = .addLink
    }

    /// 先只检测剪贴板中有没有网址（不会弹出隐私提示），有网址才读取内容。
    func shareLinkOnPasteboard() async -> ShareLink? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        if let pasteboardCheck, pasteboardCheck.changeCount == changeCount {
            return pasteboardCheck.link
        }
        var link: ShareLink?
        if pasteboard.accessBehavior != .alwaysDeny,
           let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL]),
           patterns.contains(\.probableWebURL),
           let text = pasteboard.string(forType: .string) {
            link = ShareLink.parse(text)
        }
        pasteboardCheck = (changeCount, link)
        return link
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

    /// 其中可以执行 `action` 的任务。
    func jobs(in jobs: [Job], allowing action: JobAction) -> [Job] {
        jobs.filter { $0.allows(action) && canOperate(on: $0) }
    }

    /// 其中下载中且未暂停、可以暂停的任务。
    func pausableJobs(in jobs: [Job]) -> [Job] {
        self.jobs(in: jobs, allowing: .pause)
    }

    /// 其中已暂停、可以继续的任务。
    func resumableJobs(in jobs: [Job]) -> [Job] {
        self.jobs(in: jobs, allowing: .resume)
    }

    /// 调用方先用 `jobs(in:allowing:)` 筛选任务。
    func perform(_ action: JobAction, on jobs: [Job]) {
        switch action {
        case .pause: jobs.forEach(pause)
        case .resume: jobs.forEach(resume)
        case .retry: jobs.forEach(retry)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(jobs.flatMap(\.revealURLs))
        }
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

    /// 有可以操作、且有已下载文件的任务。
    func canTrashFiles(of jobs: [Job]) -> Bool {
        jobs.contains { canOperate(on: $0) && $0.files.contains(where: \.isCompleted) }
    }

    func remove(_ job: Job, trashingFiles: Bool = false) {
        Task {
            let failed = await coordinator.remove(job.id, trashingFiles: trashingFiles)
            untrashedItems += failed
        }
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
