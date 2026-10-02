import SwiftUI

@main
struct ArkDownloaderApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .onAppear {
                    container.repository.initialize()
                }
        }
    }
}

/// Holds shared services (engine, settings, RPC, repository).
final class AppContainer: ObservableObject {
    let engine = DownloadEngine()
    let settingsRepo = SettingsRepository.shared
    let rpcServer = RpcServer()
    let repository: DownloadRepository

    init() {
        self.repository = DownloadRepository(engine: engine, settingsRepo: settingsRepo, rpcServer: rpcServer)
    }
}

struct RootView: View {
    @EnvironmentObject var container: AppContainer
    @State private var viewModel: MainViewModel?
    @State private var showCreate: Bool = false
    @State private var showSettings: Bool = false
    @State private var selectedTab: Int = 1 // 0 = 链接解析, 1 = 下载任务

    var body: some View {
        Group {
            if let vm = viewModel {
                TabView(selection: $selectedTab) {
                    LinkParseView(vm: vm)
                        .tabItem { Label("链接解析", systemImage: "link") }
                        .tag(0)
                    HomeView(vm: vm, onCreate: { showCreate = true }, onSettings: { showSettings = true })
                        .tabItem { Label("下载任务", systemImage: "arrow.down.circle") }
                        .tag(1)
                }
                .tint(ArkColors.primary)
                .sheet(isPresented: $showCreate) {
                    CreateTaskView(vm: vm, onBack: { showCreate = false })
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(vm: vm, onBack: { showSettings = false })
                }
            } else {
                ProgressView().onAppear { viewModel = MainViewModel(repository: container.repository) }
            }
        }
    }
}
