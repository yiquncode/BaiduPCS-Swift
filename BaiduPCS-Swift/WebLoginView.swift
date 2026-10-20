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

            if let errorMessage {
                Banner(message: errorMessage) {
                    Button("重试", action: retry)
                }
            } else if session?.isMissingNetdiskSTOKEN == true {
                Banner(message: "已登录百度账号，但没有取得网盘的 STOKEN，无法转存。请改用粘贴 Cookie 登录。") {
                    Button("粘贴 Cookie 登录…", action: useCookieLogin)
                }
            }

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
    @ObservationIgnored private var diskMainNavigation: WKNavigation?
    @ObservationIgnored private var hasLoadedDiskMain = false
    @ObservationIgnored private var hasFinishedDiskMain = false
    @ObservationIgnored private var failedURL: URL?
    @ObservationIgnored private var loadingObservation: NSKeyValueObservation?

    /// 只记录 Cookie 的名字、域名和属性，不记录值。用 `log show --info --predicate 'category == "WebLogin"'` 查看。
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Ferry", category: "WebLogin")
    private static let startURL = URL(string: "https://pan.baidu.com/")!
    /// 只有 BDUSS 时加载它。网盘的 STOKEN 在这一步写入。
    private static let diskMainURL = URL(string: "https://pan.baidu.com/disk/main")!

    override init() {
        let configuration = WKWebViewConfiguration()
        // 每次登录都是新的环境。关闭 sheet 后网页的 Cookie 全部丢弃，凭据只存在 Keychain 中。
        configuration.websiteDataStore = .nonPersistent()
        // WKWebView 的默认 UA 没有 `Version/… Safari/…`，部分网站会把它当成未知浏览器。
        // Safari 的版本号和 macOS 的主版本号相同；`Safari/605.1.15` 在 Safari 中是固定值。
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: configuration)
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
    }

    func stop() {
        guard isActive else { return }
        isActive = false
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
        checkCookies()
    }

    /// 有 BDUSS 和网盘的 STOKEN 时交出凭据；只有 BDUSS 时加载一次网盘主页。
    /// - Parameter pageFinished: 网盘的页面刚加载完成。只在这时加载网盘主页：BDUSS 可能在
    ///   passport 的安全验证或绑定手机等步骤之前就已写入，这时跳转会打断登录。
    private func checkCookies(pageFinished: Bool = false) {
        Task {
            guard isActive, !hasDeliveredCredential else { return }
            let cookies = await cookieStore.allCookies()
            // 等待期间可能已经交出凭据，或 sheet 已经关闭。
            guard isActive, !hasDeliveredCredential else { return }
            Self.logCheck(cookies, page: webView.url, pageFinished: pageFinished)
            do {
                let credential = try Credential.parse(cookies)
                Self.log.info("credential found")
                hasDeliveredCredential = true
                isMissingNetdiskSTOKEN = false
                onCredential?(credential)
            } catch BaiduError.missingSTOKEN {
                Self.log.info("missing STOKEN, diskMainLoaded=\(self.hasLoadedDiskMain, privacy: .public) diskMainFinished=\(self.hasFinishedDiskMain, privacy: .public)")
                if !hasLoadedDiskMain {
                    guard pageFinished, webView.url?.host() == Self.diskMainURL.host() else { return }
                    hasLoadedDiskMain = true
                    diskMainNavigation = webView.load(URLRequest(url: Self.diskMainURL))
                } else if hasFinishedDiskMain {
                    isMissingNetdiskSTOKEN = true
                }
            } catch {
                // 还没有登录。
                Self.log.info("no credential: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func logCheck(_ cookies: [HTTPCookie], page: URL?, pageFinished: Bool) {
        let summary = cookies
            .map { "\($0.name) domain=\($0.domain) path=\($0.path) secure=\($0.isSecure) expires=\($0.expiresDate.map { "\($0)" } ?? "session")" }
            .sorted()
            .joined(separator: "; ")
        log.info("check page=\(page?.host() ?? "-", privacy: .public)\(page?.path() ?? "", privacy: .public) finished=\(pageFinished, privacy: .public) cookies=[\(summary, privacy: .public)]")
    }
}

extension WebLoginSession: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        checkCookies()
    }
}

extension WebLoginSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        failedURL = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === diskMainNavigation { hasFinishedDiskMain = true }
        checkCookies(pageFinished: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if navigation === diskMainNavigation { hasFinishedDiskMain = true }
        show(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if navigation === diskMainNavigation { hasFinishedDiskMain = true }
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
