import BaiduKit
import OSLog
import SwiftUI
import WebKit

/// 网页登录：显示百度的官方登录页，从网页的 Cookie 中取得凭据，再交给 `AppModel` 校验。
struct WebLoginView: View {
    /// 切换到粘贴 Cookie 登录。
    let useCookieLogin: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// 在 `onAppear` 中创建：`@State` 的初始值每次构造视图都会求值，不在那里创建网页。
    @State private var session: WebLoginSession?
    @State private var loginTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let session {
                    WebViewContainer(webView: session.webView)
                }
                if let session, let loadError = session.loadError {
                    ContentUnavailableView {
                        Label("无法加载登录页", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("重新加载") { session.reload() }
                    }
                    .background(.background)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 网页不是 SwiftUI 的滚动视图，没有滚动边缘效果，所以提示条自己加背景。
            Group {
                if let errorMessage {
                    Banner(message: errorMessage) {
                        Button("重试", action: retry)
                    }
                } else if session?.isMissingNetdiskSTOKEN == true {
                    Banner(message: "已登录百度账号，但没有取得网盘的 STOKEN，无法转存。请改用粘贴 Cookie 登录。") {
                        Button("粘贴 Cookie 登录…", action: useCookieLogin)
                    }
                }
            }
            .background(.bar)

            Divider()
            HStack {
                Button("粘贴 Cookie 登录…", action: useCookieLogin)
                    .disabled(loginTask != nil)
                if loginTask != nil {
                    ProgressView().controlSize(.small)
                    Text("正在校验…").foregroundStyle(.secondary)
                } else if session?.isLoading == true {
                    ProgressView().controlSize(.small)
                    Text("正在加载…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        // 百度的登录框约 680 pt 宽。
        .frame(minWidth: 720, idealWidth: 800, maxWidth: .infinity, minHeight: 600, idealHeight: 700, maxHeight: .infinity)
        .onAppear {
            guard session == nil else { return }
            let session = WebLoginSession()
            session.onCredential = { logIn($0) }
            self.session = session
            session.start()
        }
        // 关闭 sheet 或切换到粘贴登录时停止网页并取消校验，取消后的登录不会生效。
        .onDisappear {
            session?.stop()
            session = nil
            loginTask?.cancel()
        }
    }

    /// 会话每次只交出一个凭据，所以同一时间只有一个校验。
    private func logIn(_ credential: Credential) {
        errorMessage = nil
        loginTask = Task {
            defer { loginTask = nil }
            do {
                try await model.logIn(credential: credential)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func retry() {
        errorMessage = nil
        session?.checkAgain()
    }
}

/// 登录页的网页和 Cookie 检查。Ferry 不向页面注入脚本，不读取页面内容，只读取数据存储中的 Cookie。
@Observable
final class WebLoginSession: NSObject {
    private(set) var isLoading = false
    /// 网页加载失败（网络错误）时的说明。
    private(set) var loadError: String?
    /// 加载网盘主页后仍然没有网盘的 STOKEN。之后 Cookie 变化时仍然检查。
    private(set) var isMissingNetdiskSTOKEN = false
    /// 取得凭据时调用。之后不再检查，直到调用 `checkAgain()`。
    @ObservationIgnored var onCredential: ((Credential) -> Void)?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let cookieStore: WKHTTPCookieStore
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var hasDeliveredCredential = false
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// 第一次看到 BDUSS 但没有网盘 STOKEN 的时间。
    @ObservationIgnored private var bdussSeenAt: ContinuousClock.Instant?
    @ObservationIgnored private var diskMainLoadedAt: ContinuousClock.Instant?
    @ObservationIgnored private var failedURL: URL?
    @ObservationIgnored private var loadingObservation: NSKeyValueObservation?

    /// 只记录 Cookie 的名字、域名和属性，不记录值。用 `log show --info --predicate 'category == "WebLogin"'` 查看。
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Ferry", category: "WebLogin")
    /// 和 macOS 上的 Chrome 相同。Chrome 的 UA 是精简格式：系统版本固定为 `10_15_7`，
    /// 只有主版本号，其余为 0。Chrome 更新后，改这里的主版本号。
    private static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"
    private static let startURL = URL(string: "https://pan.baidu.com/")!
    /// 只有 BDUSS 时加载它。网盘的 STOKEN 在这一步写入。
    private static let diskMainURL = URL(string: "https://pan.baidu.com/disk/main")!
    /// 看到 BDUSS 后等这么久再加载网盘主页，不打断 passport 的安全验证等后续步骤。
    private static let settleDelay: Duration = .seconds(5)
    /// 加载网盘主页后等这么久仍然没有网盘 STOKEN，就提示改用粘贴 Cookie。
    private static let diskMainTimeout: Duration = .seconds(10)

    override init() {
        let configuration = WKWebViewConfiguration()
        // 每次登录都是新的环境。关闭 sheet 后网页的 Cookie 全部丢弃，凭据只存在 Keychain 中。
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.chromeUserAgent
        cookieStore = configuration.websiteDataStore.httpCookieStore
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        loadingObservation = webView.observe(\.isLoading) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        cookieStore.add(self)
        webView.load(URLRequest(url: Self.startURL))
        // 登录后 Cookie 变化的通知不一定到达，网盘页面也可能一直不触发加载完成，所以还要定时检查。
        pollTask = Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(1))) != nil {
                guard let self, self.isActive else { return }
                self.checkCookies(trigger: "poll")
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        pollTask?.cancel()
        onCredential = nil
        cookieStore.remove(self)
        webView.stopLoading()
    }

    func reload() {
        loadError = nil
        if let failedURL {
            webView.load(URLRequest(url: failedURL))
        } else {
            webView.reload()
        }
    }

    /// 校验失败后，用户要求再试一次。
    func checkAgain() {
        hasDeliveredCredential = false
        checkCookies(trigger: "retry")
    }

    /// 有 BDUSS 和网盘的 STOKEN 时交出凭据；只有 BDUSS 时加载一次网盘主页。同一时间只有一次检查。
    private func checkCookies(trigger: String) {
        guard isActive, !hasDeliveredCredential, !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            let started = ContinuousClock.now
            let cookies = await cookieStore.allCookies()
            // 等待期间可能已经交出凭据，或 sheet 已经关闭。
            guard isActive, !hasDeliveredCredential else { return }
            Self.logCheck(cookies, page: webView.url, trigger: trigger, duration: .now - started)
            do {
                let credential = try Credential.parse(cookies)
                Self.log.info("credential found")
                hasDeliveredCredential = true
                isMissingNetdiskSTOKEN = false
                onCredential?(credential)
            } catch BaiduError.missingSTOKEN {
                handleMissingSTOKEN()
            } catch {
                // 还没有登录。
                bdussSeenAt = nil
                Self.log.info("no credential: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func handleMissingSTOKEN() {
        let now = ContinuousClock.now
        let seenAt = bdussSeenAt ?? now
        bdussSeenAt = seenAt
        if let diskMainLoadedAt {
            if now - diskMainLoadedAt >= Self.diskMainTimeout { isMissingNetdiskSTOKEN = true }
            return
        }
        guard now - seenAt >= Self.settleDelay, webView.url?.host() == Self.diskMainURL.host() else { return }
        diskMainLoadedAt = now
        Self.log.info("missing STOKEN, loading /disk/main")
        webView.load(URLRequest(url: Self.diskMainURL))
    }

    private static func logCheck(_ cookies: [HTTPCookie], page: URL?, trigger: String, duration: Duration) {
        let summary = cookies
            .map { "\($0.name) domain=\($0.domain) path=\($0.path) secure=\($0.isSecure) expires=\($0.expiresDate.map { "\($0)" } ?? "session")" }
            .sorted()
            .joined(separator: "; ")
        log.info("check trigger=\(trigger, privacy: .public) took=\(duration, privacy: .public) page=\(page?.host() ?? "-", privacy: .public)\(page?.path() ?? "", privacy: .public) cookies=[\(summary, privacy: .public)]")
    }
}

extension WebLoginSession: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        checkCookies(trigger: "cookiesChanged")
    }
}

extension WebLoginSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        failedURL = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkCookies(trigger: "pageFinished")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        show(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        show(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadError = "网页意外停止。"
    }

    private func show(_ error: any Error) {
        let error = error as NSError
        // 新的导航取代了这次导航，或页面自己停止了加载。这些不是加载失败。
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return } // 帧加载被导航策略中断
        failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        loadError = error.localizedDescription
    }
}

extension WebLoginSession: WKUIDelegate {
    /// 页面要打开新窗口时（`window.open`、`target=_blank`），在同一个网页中加载这个请求。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// 显示 `WebLoginSession` 的网页。SwiftUI 的 `WebView` 不能处理 `window.open`，所以包装 `WKWebView`。
private struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
