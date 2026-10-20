import DownloadKit
import Observation

/// 一个任务的汇总进度。界面的任务行只观察自己任务的这个对象。
@MainActor @Observable
public final class JobActivity {
    public internal(set) var progress = JobProgress(receivedBytes: 0, totalBytes: 0, bytesPerSecond: 0)
    /// 有正在下载（不是排队）的文件。
    public internal(set) var isRunning = false

    init() {}
}

/// 一个文件下载在引擎中的状态。只有详情栏中的文件行观察它。
@MainActor @Observable
public final class FileActivity {
    public internal(set) var snapshot: DownloadSnapshot?

    init(snapshot: DownloadSnapshot?) {
        self.snapshot = snapshot
    }
}
