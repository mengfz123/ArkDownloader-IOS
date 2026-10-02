import SwiftUI

struct HomeView: View {
    @ObservedObject var vm: MainViewModel
    let onCreate: () -> Void
    let onSettings: () -> Void

    @State private var selectedTab: HomeTab = .downloading
    @State private var deleteTarget: DownloadTask? = nil
    @State private var deleteFiles: Bool = false
    @State private var showContact: Bool = false

    enum HomeTab: String, CaseIterable {
        case downloading = "正在下载"
        case completed = "已完成"
        case failed = "失败"
    }

    private var counts: (Int, Int, Int) {
        let downloading = vm.tasks.filter { $0.status == .downloading || $0.status == .merging || $0.status == .pending || $0.status == .paused }.count
        let completed = vm.tasks.filter { $0.status == .completed }.count
        let failed = vm.tasks.filter { $0.status == .failed || $0.status == .canceled }.count
        return (downloading, completed, failed)
    }

    private var filtered: [DownloadTask] {
        let list: [DownloadTask]
        switch selectedTab {
        case .downloading:
            list = vm.tasks.filter { $0.status == .downloading || $0.status == .merging || $0.status == .pending || $0.status == .paused }
        case .completed:
            list = vm.tasks.filter { $0.status == .completed }
        case .failed:
            list = vm.tasks.filter { $0.status == .failed || $0.status == .canceled }
        }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    private var runningCount: Int { vm.tasks.filter { $0.status == .downloading }.count }
    private var pendingCount: Int { vm.tasks.filter { $0.status == .pending }.count }
    private var totalSpeed: Int64 { vm.tasks.filter { $0.status == .downloading }.reduce(0) { $0 + $1.speed } }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ArkColors.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Divider().background(ArkColors.border)
                    rpcBar
                    Divider().background(ArkColors.border)
                    tabs
                    Divider().background(ArkColors.border)
                    statsBar
                    Divider().background(ArkColors.border)

                    if filtered.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(filtered) { task in
                                    TaskCard(
                                        task: task,
                                        onPause: { vm.pauseTask(task) },
                                        onResume: { vm.resumeTask(task) },
                                        onRestart: { vm.restartTask(task) },
                                        onCopy: { copyText(task.url) },
                                        onOpen: { openFile(task) },
                                        onDelete: { deleteFiles = false; deleteTarget = task }
                                    )
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .padding(.bottom, 80)
                        }
                    }
                }

                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(ArkColors.primary)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
        .alert("删除任务", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let t = deleteTarget { vm.deleteTask(t, deleteFiles: deleteFiles) }
                deleteTarget = nil
            }
        } message: {
            VStack {
                Text(deleteTarget.map { UrlResolve.displayFileName($0.fileName, $0.url) } ?? "")
                Toggle("同时删除已下载的文件", isOn: $deleteFiles)
                    .padding(.top, 8)
            }
        }
        .sheet(isPresented: $showContact) {
            ContactView()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(ArkColors.primary)
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "square.and.arrow.down").foregroundColor(.white).font(.system(size: 18, weight: .bold)))
            VStack(alignment: .leading, spacing: 1) {
                Text(AppSettings.appName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(ArkColors.text)
                Text("下载器")
                    .font(.system(size: 12))
                    .foregroundColor(ArkColors.muted)
            }
            Spacer()
            Button("联系我们") { showContact = true }
                .font(.system(size: 13))
                .foregroundColor(ArkColors.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ArkColors.card)
                .cornerRadius(14)
            Button("设置") { onSettings() }
                .font(.system(size: 13))
                .foregroundColor(ArkColors.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ArkColors.card)
                .cornerRadius(14)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ArkColors.sidebar)
    }

    private var rpcBar: some View {
        Button(action: onSettings) {
            HStack(spacing: 8) {
                Circle()
                    .fill((vm.rpcRunning && vm.settings.rpcEnabled) ? ArkColors.success : ArkColors.muted)
                    .frame(width: 8, height: 8)
                Text("RPC").font(.system(size: 12)).foregroundColor(ArkColors.muted)
                Text(rpcStatusText)
                    .font(.system(size: 12))
                    .foregroundColor(ArkColors.text)
                    .lineLimit(1)
                Spacer()
                Text("›").foregroundColor(ArkColors.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(ArkColors.card)
    }

    private var rpcStatusText: String {
        if !vm.settings.rpcEnabled { return "已关闭" }
        if vm.rpcRunning && vm.settings.rpcRemote { return "运行中 · 0.0.0.0:\(vm.settings.rpcPort)" }
        if vm.rpcRunning { return "运行中 · 127.0.0.1:\(vm.settings.rpcPort)" }
        return "未运行"
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(HomeTab.allCases, id: \.self) { tab in
                let idx = HomeTab.allCases.firstIndex(of: tab)!
                let count = [counts.0, counts.1, counts.2][idx]
                let on = selectedTab == tab
                Button {
                    withAnimation { selectedTab = tab }
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                            .font(.system(size: 14, weight: on ? .semibold : .regular))
                            .foregroundColor(on ? ArkColors.primary : ArkColors.muted)
                        Text("\(count)")
                            .font(.system(size: 11))
                            .foregroundColor(on ? ArkColors.primary : ArkColors.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(on ? ArkColors.primary.opacity(0.28) : ArkColors.card2)
                            .cornerRadius(8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(on ? ArkColors.primarySoft : Color.clear)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ArkColors.sidebar)
    }

    private var statsBar: some View {
        HStack(spacing: 16) {
            StatItem(label: "总速度", value: FormatUtil.formatSpeed(totalSpeed))
            StatItem(label: "进行中", value: "\(runningCount)")
            StatItem(label: "排队", value: "\(pendingCount)")
            Spacer()
            Menu {
                Button("全部暂停") { vm.pauseAll() }
                Button("全部继续") { vm.resumeAll() }
                Button("清空已完成") { vm.clearCompleted() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(ArkColors.muted)
                    .font(.system(size: 20))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("暂无\(selectedTab.rawValue)任务")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(ArkColors.text)
            Text("点击右下角 ＋ 添加百度直链或 HTTP 下载")
                .font(.system(size: 13))
                .foregroundColor(ArkColors.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyText(_ text: String) {
        UIPasteboard.general.string = text
    }

    private func openFile(_ task: DownloadTask) {
        let url = URL(fileURLWithPath: task.filePath)
        _ = FilePublish.openFile(url)
    }
}

struct StatItem: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundColor(ArkColors.muted)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundColor(ArkColors.text)
        }
    }
}

struct ContactView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("联系我们")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(ArkColors.text)
                Text("扫码关注微信公众号")
                    .font(.system(size: 13))
                    .foregroundColor(ArkColors.muted)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                    .frame(width: 240, height: 240)
                    .overlay(
                        Image(systemName: "qrcode")
                            .resizable()
                            .scaledToFit()
                            .padding(20)
                            .foregroundColor(.black)
                    )
                Text("获取更新与使用帮助")
                    .font(.system(size: 13))
                    .foregroundColor(ArkColors.muted)
                Button("关闭") { dismiss() }
                    .foregroundColor(ArkColors.primary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ArkColors.bg)
            .navigationBarHidden(true)
        }
    }
}
