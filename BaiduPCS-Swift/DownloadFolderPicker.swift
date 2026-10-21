import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// 新任务的“保存到”菜单。默认是设置中的下载目录。用“其他…”选择的目录只用于这个任务，不修改设置。
///
/// 选择目录时立即创建 bookmark。创建失败时不选中这个目录，由调用方显示 `error`。
struct DownloadFolderPicker: View {
    /// nil 表示设置中的下载目录。
    @Binding var selection: DownloadFolder?
    @Binding var error: String?
    @Environment(AppModel.self) private var model
    /// 用“其他…”选择的目录。
    @State private var chosenFolders: [DownloadFolder] = []
    @State private var isChoosingFolder = false

    /// 菜单中的一项。
    private enum Destination: Hashable {
        /// 设置中的下载目录。
        case settings
        case chosen(DownloadFolder)
        /// “其他…”：打开面板选择目录，不改变当前选择。
        case other
    }

    var body: some View {
        Picker("保存到", selection: destination) {
            FolderLabel(url: model.currentFolder.url).tag(Destination.settings)
            ForEach(chosenFolders, id: \.self) { folder in
                FolderLabel(url: folder.url).tag(Destination.chosen(folder))
            }
            Divider()
            Text("其他…").tag(Destination.other)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help((selection ?? model.currentFolder).url.path(percentEncoded: false))
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                chooseFolder(url)
            }
        }
    }

    private var destination: Binding<Destination> {
        Binding {
            selection.map(Destination.chosen) ?? .settings
        } set: { destination in
            switch destination {
            case .settings: selection = nil
            case .chosen(let folder): selection = folder
            case .other: isChoosingFolder = true
            }
        }
    }

    /// 选择的目录加入菜单并选中。它和菜单中已有的目录是同一位置时，选中已有的那一项。
    private func chooseFolder(_ url: URL) {
        error = nil
        func isSameLocation(_ folder: DownloadFolder) -> Bool {
            folder.url.standardizedFileURL.path == url.standardizedFileURL.path
        }
        if isSameLocation(model.currentFolder) {
            selection = nil
        } else if let existing = chosenFolders.first(where: isSameLocation) {
            selection = existing
        } else {
            do {
                let folder = try model.makeDownloadFolder(for: url)
                chosenFolders.append(folder)
                selection = folder
            } catch {
                self.error = "无法取得“\(url.lastPathComponent)”的访问权限：\(error.localizedDescription)"
            }
        }
    }
}
