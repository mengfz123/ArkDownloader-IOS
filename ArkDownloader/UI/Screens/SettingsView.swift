import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: MainViewModel
    let onBack: () -> Void

    @State private var downloadDir: String = ""
    @State private var connections: Double = 8
    @State private var chunkMb: Double = 1
    @State private var maxRunning: Double = 3
    @State private var autoStart: Bool = true
    @State private var notifyOnComplete: Bool = true
    @State private var userAgent: String = ""
    @State private var httpUserAgent: String = ""
    @State private var rpcEnabled: Bool = true
    @State private var rpcRemote: Bool = true
    @State private var rpcPort: String = ""
    @State private var rpcToken: String = ""
    @State private var parsePageUrl: String = ""
    @State private var savedToast: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                ArkColors.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 12) {
                        SurfacePanel {
                            SectionTitle("下载")
                            ArkField(label: "默认保存目录", value: $downloadDir, multiLine: true, placeholder: "留空使用 Documents/ArkDownloads")
                            sliderRow(title: "默认连接数（1–\(AppSettings.maxThreads)）", value: $connections, range: 1...Double(AppSettings.maxThreads), label: "\(Int(connections))")
                            sliderRow(title: "分片大小（1–5 MB，默认 1）", value: $chunkMb, range: Double(AppSettings.minChunkMb)...Double(AppSettings.maxChunkMb), label: "\(Int(chunkMb))M")
                            sliderRow(title: "最大同时下载（1–\(AppSettings.maxRunning)）", value: $maxRunning, range: 1...Double(AppSettings.maxRunning), label: "\(Int(maxRunning))")
                            ToggleRow(title: "添加后自动开始", isOn: $autoStart)
                            ToggleRow(title: "下载完成时通知", isOn: $notifyOnComplete)
                        }
                        SurfacePanel {
                            SectionTitle("User-Agent")
                            ArkField(label: "百度直链 User-Agent", value: $userAgent, multiLine: true)
                            ArkField(label: "普通 HTTP User-Agent", value: $httpUserAgent)
                        }
                        SurfacePanel {
                            SectionTitle("链接解析")
                            ArkField(label: "解析页面地址", value: $parsePageUrl, multiLine: true, placeholder: AppSettings.defaultParsePageUrl)
                            Text("须为 http(s) 地址；留空恢复默认")
                                .font(.system(size: 11))
                                .foregroundColor(ArkColors.muted)
                        }
                        SurfacePanel {
                            SectionTitle("RPC 远程服务")
                            ToggleRow(title: "启用 RPC 服务", isOn: $rpcEnabled)
                            ToggleRow(title: "允许局域网/远程访问", isOn: $rpcRemote)
                            ArkField(label: "RPC 端口（默认 \(AppSettings.defaultRpcPort)）", value: $rpcPort)
                            ArkField(label: "RPC 访问令牌", value: $rpcToken, placeholder: "留空不启用")
                        }
                        Text("版本 \(AppSettings.version) · 配置保存在本机")
                            .font(.system(size: 12))
                            .foregroundColor(ArkColors.muted)
                            .padding(.bottom, 24)
                    }
                    .padding(14)
                }
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider().background(ArkColors.border)
                    Button(action: save) {
                        Text("保存设置")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(ArkColors.primary)
                            .cornerRadius(10)
                    }
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
            ToolbarItem(placement: .principal) {
                Text("设置").font(.system(size: 17, weight: .semibold)).foregroundColor(ArkColors.text)
            }
        }
        .overlay(
            Group {
                if savedToast {
                    Text("已保存")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: savedToast),
            alignment: .center
        )
        .onAppear { loadFromSettings() }
    }

    private func loadFromSettings() {
        let s = vm.settings
        downloadDir = s.defaultSaveDir
        connections = Double(s.maxThreads)
        chunkMb = Double(s.chunkSizeMb)
        maxRunning = Double(s.maxConcurrentTasks)
        autoStart = s.autoStart
        notifyOnComplete = s.notifyOnComplete
        userAgent = s.userAgent
        httpUserAgent = s.httpUserAgent
        rpcEnabled = s.rpcEnabled
        rpcRemote = s.rpcRemote
        rpcPort = String(s.rpcPort)
        rpcToken = s.rpcToken
        parsePageUrl = s.parsePageUrl
    }

    private func save() {
        let port = Int(rpcPort) ?? AppSettings.defaultRpcPort
        vm.updateSettings { s in
            var next = s
            next.defaultSaveDir = downloadDir.trimmingCharacters(in: .whitespaces)
            next.maxThreads = Int(connections)
            next.chunkSize = AppSettings.chunkBytesFromMb(Int(chunkMb))
            next.maxConcurrentTasks = Int(maxRunning)
            next.autoStart = autoStart
            next.notifyOnComplete = notifyOnComplete
            next.userAgent = userAgent.trimmingCharacters(in: .whitespaces).isEmpty ? AppSettings.baiduUA : userAgent
            next.httpUserAgent = httpUserAgent.trimmingCharacters(in: .whitespaces).isEmpty ? AppSettings.defaultHttpUserAgent : httpUserAgent
            next.rpcEnabled = rpcEnabled
            next.rpcRemote = rpcRemote
            next.rpcPort = port
            next.rpcToken = rpcToken.trimmingCharacters(in: .whitespaces)
            next.parsePageUrl = AppSettings.normalizeParsePageUrl(parsePageUrl)
            return next
        }
        savedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { savedToast = false }
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundColor(ArkColors.text)
                Spacer()
                Text(label).font(.system(size: 14)).foregroundColor(ArkColors.primary)
            }
            Slider(value: value, in: range, step: 1).tint(ArkColors.primary)
        }
    }
}

struct SectionTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(ArkColors.text)
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn)
            .font(.system(size: 14))
            .foregroundColor(ArkColors.text)
            .tint(ArkColors.primary)
    }
}
