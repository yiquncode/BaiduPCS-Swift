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
    /// `-FerryDemoSheet`：启动后显示这个 sheet，值是 `AppModel.Sheet` 的 rawValue。
    static var sheet: String? { UserDefaults.standard.string(forKey: "FerryDemoSheet") }
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

        // 任务名用明显可以合法分享的内容。不用影视、音乐等容易被看成盗版的内容，也不用真实的品牌和作品名。
        var course = job("操作系统课程录像", surl: "qYZEsSc", minutesAgo: 12, now: now)
        course.phase = .downloading
        let lectures: [(String, Int64)] = [
            ("第 01 讲 课程介绍.mp4", 1_400 * mb), ("第 02 讲 进程与线程.mp4", 2_100 * mb),
            ("第 03 讲 CPU 调度.mp4", 1_800 * mb), ("第 04 讲 内存管理.mp4", 640 * mb),
            ("第 05 讲 文件系统.mp4", 1_200 * mb), ("第 06 讲 期中复习.mp4", 980 * mb),
        ]
        course.files = lectures.enumerated().map { index, item in
            file(item.0, size: item.1, in: "操作系统课程录像", completed: index < 2)
        }
        snapshots.append(DownloadSnapshot(id: course.files[2].id, state: .running, totalBytes: course.files[2].size,
                                          receivedBytes: 1_116 * mb, bytesPerSecond: 8_600_000))
        snapshots += course.files[3...].map {
            DownloadSnapshot(id: $0.id, state: .queued, totalBytes: $0.size, receivedBytes: 0, bytesPerSecond: 0)
        }

        var trip = job("家庭旅行视频 2026 夏", surl: "Ax7kP2mQ", minutesAgo: 3, now: now)
        trip.phase = .transferring

        // 网盘任务。勾选的条目在网盘中的上层目录不出现在本地路径中。
        var home = netdiskJob([("/视频/家庭录像", true)], minutesAgo: 8, now: now)
        home.phase = .downloading
        home.files = [("2025 春节.mov", 3_400 * mb), ("2025 海边.mov", 5_100 * mb), ("生日会.mp4", 860 * mb)].map {
            file($0.0, size: $0.1, in: "家庭录像", remoteDirectory: "/视频", completed: $0.0 == "2025 春节.mov")
        }
        snapshots += home.files[1...].map {
            DownloadSnapshot(id: $0.id, state: .queued, totalBytes: $0.size, receivedBytes: 0, bytesPerSecond: 0)
        }

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
            ("开题报告.docx", 2 * mb), ("文献综述.pdf", 8 * mb),
            ("实验数据.xlsx", 41 * mb), ("答辩.key", 212 * mb), ("参考文献.bib", 1 * mb),
        ].map { file($0.0, size: $0.1, in: "论文参考资料", completed: true) }

        var notes = netdiskJob([("/我的资料/简历.pdf", false), ("/我的资料/读书笔记.md", false)], minutesAgo: 120, now: now)
        notes.phase = .completed
        notes.files = [("简历.pdf", 1_200_000), ("读书笔记.md", 24_000)].map {
            file($0.0, size: $0.1, in: nil, remoteDirectory: "/我的资料", completed: true)
        }

        var photos = job("Photos-2024.tar", surl: "Ve5gN1tJ", minutesAgo: 180, now: now)
        photos.phase = .completed
        photos.files = [file("Photos-2024.tar", size: 4_700 * mb, in: nil, completed: true)]

        return ([trip, course, home, thesis, ubuntu, papers, notes, photos], snapshots)
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

    private static func netdiskJob(_ entries: [(path: String, isDirectory: Bool)], minutesAgo: Double, now: Date) -> Job {
        var job = Job(netdiskEntries: entries.map { netdiskEntry($0.path, isDirectory: $0.isDirectory) },
                      createdAt: now.addingTimeInterval(-minutesAgo * 60))
        job.accountUK = account.uk
        job.downloadFolder = DownloadFolder(url: downloads)
        return job
    }

    /// `remoteDirectory`：分享任务是转存目录，网盘任务是勾选条目的上层目录。
    private static func file(_ name: String, size: Int64, in directory: String?, remoteDirectory: String = "/Ferry",
                             completed: Bool) -> JobFile {
        let relativePath = directory.map { "\($0)/\(name)" } ?? name
        return JobFile(remotePath: remoteDirectory + "/" + relativePath, relativePath: relativePath, size: size,
                       localURL: completed ? downloads.appendingPathComponent(relativePath) : nil)
    }

    // MARK: - 网盘

    /// “从我的网盘下载”中显示的目录。键是目录的路径；值是它的子项（名字、字节数，目录为 nil）和修改日期。
    private static let netdisk: [String: [(name: String, size: Int64?, date: String)]] = [
        "/": [("视频", nil, "2026-03-02"), ("我的资料", nil, "2026-01-06"), ("手机备份", nil, "2026-03-01"),
              ("Ferry", nil, "2026-03-02"), ("安装包.dmg", 820 * mb, "2025-10-15"), ("简历.pdf", 1_200_000, "2026-02-20")],
        "/视频": [("家庭录像", nil, "2026-02-14"), ("课程", nil, "2025-09-20")],
        "/视频/家庭录像": [("2025 春节.mov", 3_400 * mb, "2026-02-01"), ("2025 海边.mov", 5_100 * mb, "2026-02-14"),
                     ("生日会.mp4", 860 * mb, "2025-11-08")],
        "/视频/课程": [("第 01 讲 入门.mp4", 420 * mb, "2025-09-20"), ("第 02 讲 基础.mp4", 510 * mb, "2025-09-20")],
        "/我的资料": [("2025", nil, "2025-12-30"), ("草稿", nil, "2025-07-03"), ("读书笔记.md", 24_000, "2026-01-06")],
        "/我的资料/2025": [("年度总结.pdf", 3_200_000, "2025-12-30"), ("预算.xlsx", 180_000, "2025-12-12")],
        "/手机备份": [("相册 2025.zip", 12_600 * mb, "2026-01-02")],
        "/Ferry": [("3F9A21C0", nil, "2026-03-02")],
    ]

    static func netdiskListing(_ directory: String) -> [NetdiskEntry] {
        (netdisk[directory] ?? []).map { item in
            let path = RemotePath.join(directory, item.name)
            var entry = netdiskEntry(path, isDirectory: item.size == nil, size: item.size ?? 0)
            entry.modifiedAt = try? Date(item.date, strategy: .iso8601.year().month().day())
            return entry
        }
    }

    private static func netdiskEntry(_ path: String, isDirectory: Bool, size: Int64 = 0) -> NetdiskEntry {
        NetdiskEntry(fsID: Int64(abs(path.hashValue % 1_000_000_000)), name: (path as NSString).lastPathComponent,
                     path: path, isDirectory: isDirectory, size: size)
    }
}
#endif
