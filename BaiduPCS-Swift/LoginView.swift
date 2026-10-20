import SwiftUI

/// 粘贴 Cookie 登录。
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Cookie", text: $cookie, prompt: Text("BDUSS=…; STOKEN=…"), axis: .vertical)
                        .lineLimit(6...10)
                        .font(.body.monospaced())
                        .labelsHidden()
                        .disabled(isLoggingIn)
                } header: {
                    Text("百度网盘 Cookie")
                } footer: {
                    Text("在浏览器中登录 pan.baidu.com，打开开发者工具的“网络”面板并刷新页面，选中第一条请求，复制请求头中 Cookie 的值。Cookie 需要包含 BDUSS 和 STOKEN。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                if isLoggingIn {
                    ProgressView().controlSize(.small)
                    Text("正在校验…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("登录") { Task { await logIn() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoggingIn)
            }
            .padding()
        }
        .frame(width: 500)
    }

    private func logIn() async {
        isLoggingIn = true
        errorMessage = nil
        defer { isLoggingIn = false }
        do {
            try await model.logIn(cookie: cookie)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
