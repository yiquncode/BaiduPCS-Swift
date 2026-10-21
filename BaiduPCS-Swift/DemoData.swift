#if DEBUG
import AppKit
import BaiduKit
import DownloadKit
import FerryCore
import Foundation

/// 截图用的演示数据。用 `-FerryDemo YES` 启动时，应用显示这些任务和账号，使用默认设置，
/// 不读取 Keychain 中的登录信息和任务列表，也不访问网络。
enum DemoData {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "FerryDemo") }

    /// `-FerryDemoScene loggedOut` 显示未登录、没有任务的列表，`empty` 显示已登录、没有任务的列表。不传时显示演示任务。
    private static var scene: String? { UserDefaults.standard.string(forKey: "FerryDemoScene") }
    static var isLoggedIn: Bool { scene != "loggedOut" }
    static var hasJobs: Bool { scene == nil }
    /// `-FerryDemoCategory`：侧边栏选中的分类，值是 `JobCategory` 的 rawValue。
    static var category: String? { UserDefaults.standard.string(forKey: "FerryDemoCategory") }
    /// `-FerryDemoSelect`：选中这个标题的任务，并显示详情栏。
    static var selectedTitle: String? { UserDefaults.standard.string(forKey: "FerryDemoSelect") }
    /// `-FerryDemoAppearance dark` 或 `light`：不跟随系统外观。
    static var appearance: NSAppearance? {
        switch UserDefaults.standard.string(forKey: "FerryDemoAppearance") {
        case "dark": NSAppearance(named: .darkAqua)
        case "light": NSAppearance(named: .aqua)
        default: nil
        }
    }
    /// `-FerryDemoSettingsTab`：启动后打开设置窗口，显示这个标签页（0 到 3）。
    static var settingsTab: Int? {
        UserDefaults.standard.object(forKey: "FerryDemoSettingsTab") == nil
            ? nil : UserDefaults.standard.integer(forKey: "FerryDemoSettingsTab")
    }

    static let account = Account(username: "Ferry", uk: 1, uid: nil, bdstoken: "")

    /// 演示用的临时目录，代替 Application Support 中的任务列表和下载进度。
    static var directory: URL { URL.temporaryDirectory.appendingPathComponent("FerryDemo", isDirectory: true) }

    /// 不用真实的下载目录：详情栏会显示它的路径，路径中有本机的用户名。
    private static let downloads = URL(filePath: "/Users/ferry/Downloads", directoryHint: .isDirectory)
    private static let mb: Int64 = 1_000_000

    static func make() -> (jobs: [Job], downloads: [DownloadSnapshot]) {
        let now = Date.now
        var snapshots: [DownloadSnapshot] = []

        var wwdc = job("WWDC25 Sessions", surl: "qYZEsSc", minutesAgo: 12, now: now)
        wwdc.phase = .downloading
        let sessions: [(String, Int64)] = [
            ("108 Meet Liquid Glass.mp4", 1_400 * mb), ("101 Keynote.mp4", 2_100 * mb),
            ("102 Platforms State of the Union.mp4", 1_800 * mb), ("201 What’s new in SwiftUI.mp4", 640 * mb),
            ("202 SwiftUI essentials.mp4", 1_200 * mb), ("203 Build a SwiftUI app with the new design.mp4", 980 * mb),
        ]
        wwdc.files = sessions.enumerated().map { index, item in
            file(item.0, size: item.1, in: "WWDC25 Sessions", completed: index < 2)
        }
        snapshots.append(DownloadSnapshot(id: wwdc.files[2].id, state: .running, totalBytes: wwdc.files[2].size,
                                          receivedBytes: 1_116 * mb, bytesPerSecond: 8_600_000))
        snapshots += wwdc.files[3...].map {
            DownloadSnapshot(id: $0.id, state: .queued, totalBytes: $0.size, receivedBytes: 0, bytesPerSecond: 0)
        }

        var earth = job("地球脉动 第三季", surl: "Ax7kP2mQ", minutesAgo: 3, now: now)
        earth.phase = .transferring

        var thesis = job("毕业设计素材.zip", surl: "Rm3vT8wZ", minutesAgo: 20, now: now)
        thesis.phase = .downloading
        thesis.files = [file("毕业设计素材.zip", size: 2_400 * mb, in: nil, completed: false)]
        snapshots.append(DownloadSnapshot(id: thesis.files[0].id, state: .queued, totalBytes: thesis.files[0].size,
                                          receivedBytes: 0, bytesPerSecond: 0))

        var ubuntu = job("ubuntu-24.04.2-desktop-amd64.iso", surl: "Lp9cW4nE", minutesAgo: 45, now: now)
        ubuntu.phase = .failed(.download)
        ubuntu.files = [file("ubuntu-24.04.2-desktop-amd64.iso", size: 5_900 * mb, in: nil, completed: false)]
        ubuntu.error = "分享者已经删除了这个文件。"

        var papers = job("论文参考资料", surl: "Hd2sY6bK", minutesAgo: 90, now: now)
        papers.phase = .completed
        papers.files = [
            ("Attention Is All You Need.pdf", 2 * mb), ("综述 · 大模型推理优化.pdf", 8 * mb),
            ("实验数据.xlsx", 41 * mb), ("答辩.key", 212 * mb), ("参考文献.bib", 1 * mb),
        ].map { file($0.0, size: $0.1, in: "论文参考资料", completed: true) }

        var photos = job("Photos-2024.tar", surl: "Ve5gN1tJ", minutesAgo: 180, now: now)
        photos.phase = .completed
        photos.files = [file("Photos-2024.tar", size: 4_700 * mb, in: nil, completed: true)]

        return ([earth, wwdc, thesis, ubuntu, papers, photos], snapshots)
    }

    private static func job(_ name: String, surl: String, minutesAgo: Double, now: Date) -> Job {
        let isDirectory = !name.contains(".")
        let entry = ShareEntry(fsID: Int64(abs(name.hashValue % 1_000_000)), name: name, path: "/" + name,
                               isDirectory: isDirectory, size: 0)
        var job = Job(link: ShareLink(surl: surl)!, password: nil, entries: [entry], transferFolder: "/Ferry",
                      createdAt: now.addingTimeInterval(-minutesAgo * 60))
        job.accountUK = account.uk
        job.downloadFolder = DownloadFolder(url: downloads)
        return job
    }

    private static func file(_ name: String, size: Int64, in directory: String?, completed: Bool) -> JobFile {
        let relativePath = directory.map { "\($0)/\(name)" } ?? name
        return JobFile(remotePath: "/Ferry/" + relativePath, relativePath: relativePath, size: size,
                       localURL: completed ? downloads.appendingPathComponent(relativePath) : nil)
    }
}
#endif
