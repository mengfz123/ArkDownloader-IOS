import SwiftUI

struct CreateTaskView: View {
    @ObservedObject var vm: MainViewModel
    let onBack: () -> Void

    @State private var urls: String = ""
    @State private var fileName: String = ""
    @State private var threads: Double = Double(AppSettings.defaultConnections)
    @State private var dir: String = ""
    @State private var resolveMsg: String = ""
    @State private var resolveOk: Bool = false
    @State private var busy: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                ArkColors.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 12) {
                        SurfacePanel {
                            ArkField(label: "下载链接", value: $urls, multiLine: true, placeholder: "每行一个 URL，支持百度直链 / HTTP")
                            HStack(alignment: .top) {
                                Button("检测链接") {
                                    let first = MainViewModel.parseUrlPaste(urls).first
                                    guard let first = first else {
                                        resolveMsg = "请先填写链接"; resolveOk = false; return
                                    }
                                    do {
                                        let r = UrlResolve.resolve(url: first, nameHint: nil, sizeHint: 0)
                                        let name = UrlResolve.canonicalFileName(url: r.url, nameHint: fileName.isEmpty ? nil : fileName)
                                        resolveMsg = "\(r.kind == .baidu ? "百度" : "HTTP") · \(name)" + (r.size > 0 ? " · \(FormatUtil.formatBytes(r.size))" : "")
                                        resolveOk = true
                                        if fileName.isEmpty && MainViewModel.parseUrlPaste(urls).count == 1 {
                                            fileName = name
                                        }
                                    } catch {
                                        resolveMsg = error.localizedDescription
                                        resolveOk = false
                                    }
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(ArkColors.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(ArkColors.card2)
                                .cornerRadius(8)
                                if !resolveMsg.isEmpty {
                                    Text(resolveMsg)
                                        .font(.system(size: 13))
                                        .foregroundColor(resolveOk ? ArkColors.success : ArkColors.error)
                                        .padding(.top, 6)
                                }
                            }
                        }
                        SurfacePanel {
                            ArkField(label: "文件名（可选，单任务生效）", value: $fileName, placeholder: "留空自动识别")
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("连接数").font(.system(size: 14)).foregroundColor(ArkColors.text)
                                    Spacer()
                                    Text("\(Int(threads))").font(.system(size: 14)).foregroundColor(ArkColors.primary)
                                }
                                Slider(value: $threads, in: 1...Double(AppSettings.maxThreads), step: 1)
                                    .tint(ArkColors.primary)
                            }
                            ArkField(label: "保存目录（绝对路径）", value: $dir, multiLine: true)
                        }
                        Spacer(minLength: 20)
                    }
                    .padding(14)
                }
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider().background(ArkColors.border)
                    Button(action: submit) {
                        Text(busy ? "提交中…" : "开始下载")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(urls.trimmingCharacters(in: .whitespaces).isEmpty || busy ? ArkColors.primary.opacity(0.5) : ArkColors.primary)
                            .cornerRadius(10)
                    }
                    .disabled(urls.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(ArkColors.card)
                }
            }
        }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").foregroundColor(ArkColors.text)
                }
            }
        }
        .onAppear {
            if dir.isEmpty {
                dir = vm.settings.defaultSaveDir.isEmpty ? FilePublish.defaultDownloadDir().path : vm.settings.defaultSaveDir
            }
            threads = Double(vm.settings.maxThreads)
        }
    }

    private func submit() {
        let list = MainViewModel.parseUrlPaste(urls)
        guard !list.isEmpty else { return }
        busy = true
        vm.updateSettings { s in
            var next = s
            next.defaultSaveDir = dir.trimmingCharacters(in: .whitespaces)
            return next
        }
        vm.createTasks(list, fileName: fileName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fileName,
            threads: Int(threads), chunkSize: vm.settings.chunkSize, headersJson: "{}")
        onBack()
    }
}

struct SurfacePanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(12)
        .background(ArkColors.card)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ArkColors.border, lineWidth: 1))
    }
}

struct ArkField: View {
    let label: String
    @Binding var value: String
    var multiLine: Bool = false
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(ArkColors.muted)
            if multiLine {
                ZStack(alignment: .topLeading) {
                    if value.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 14))
                            .foregroundColor(ArkColors.muted.opacity(0.5))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                    TextEditor(text: $value)
                        .font(.system(size: 14))
                        .foregroundColor(ArkColors.text)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 80)
                }
                .background(ArkColors.bg)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ArkColors.border, lineWidth: 1))
            } else {
                ZStack(alignment: .leading) {
                    if value.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 14))
                            .foregroundColor(ArkColors.muted.opacity(0.5))
                    }
                    TextField("", text: $value)
                        .font(.system(size: 14))
                        .foregroundColor(ArkColors.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(ArkColors.bg)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ArkColors.border, lineWidth: 1))
            }
        }
    }
}
