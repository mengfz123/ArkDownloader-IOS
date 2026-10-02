# ArkDownloader iOS

面向 iOS 的**原生**多线程分片下载器（Swift + SwiftUI），与 [ArkDownloader Android](https://github.com/mengfz123/ArkDownloader) 功能集对齐：百度网盘直链友好、断点续传、后台保活，并提供 Gopeed 风格本地 RPC。

**当前版本：** 1.0.0

---

## 为什么选原生版

| 特色 | 说明 |
|------|------|
| Swift + SwiftUI | 暗黑主题，iOS 15+ |
| 分片多线程 | URLSession Range；连接数 1–16，分片 1–5 MB |
| 断点续传 | sidecar checkpoint + 直接写入预分配文件 |
| 本地 RPC | Network 框架，默认端口 `18766`，路径与桌面一致 |
| 链接解析 | 内嵌云端页 `https://clouds.arkdream.top/c?embed=1` |

---

## 功能一览

- 标签：正在下载 / 已完成 / 失败
- 全部暂停、全部继续、清空已完成
- 多行粘贴 URL 批量建任务
- **链接解析**：底部 Tab 入口
- 设置：下载目录、连接数、最大同时下载、分片、自动开始、完成通知、解析页 URL
- 双 UA：百度 User-Agent / HTTP User-Agent
- RPC：可选令牌；可选绑定 `0.0.0.0` 供局域网调用

---

## 构建

用 Xcode 打开 `ArkDownloader.xcodeproj`，选择目标 iOS 设备或模拟器，按 `⌘R` 运行。

要求：iOS 15.0+，Xcode 15+。

---

## 默认配置

| 项 | 默认 | 范围 |
|----|------|------|
| 连接数（connections） | 8 | 1–16 |
| 分片大小（chunkSizeMb） | 1 MB | 1–5 MB |
| 最大同时下载（maxRunning） | 3 | 1–10 |
| RPC 端口（rpcPort） | 18766 | 空令牌 = 不鉴权 |
| 解析页（parsePageUrl） | `https://clouds.arkdream.top/c?embed=1` | 需带 `embed=1` |

---

## RPC

- `GET /health`、`GET /api/v1/info`
- `GET/PUT /api/v1/config`
- `GET/POST /api/v1/tasks`、`POST /api/v1/tasks/batch`
- `PUT /api/v1/tasks/:id/pause|continue`
- `POST /api/v1/resolve`

旧路径 `/api/*` 仍作别名。鉴权：`Authorization: Bearer <token>` 或 `X-ArkDownloader-Token`（`/health` 无需鉴权）。

---

## 项目结构

```
ArkDownloader/
├── ArkDownloaderApp.swift     # App 入口 + 依赖容器
├── Models/                    # TaskStatus / DownloadTask / AppSettings / FolderChildFile
├── Database/                  # SQLite 持久化（AppDatabase actor）
├── Download/                  # ChunkDownloader / DownloadEngine / SpeedMeter / DownloadRepository
├── Settings/                  # SettingsRepository（UserDefaults）
├── RPC/                       # RpcServer（Network 框架）
├── Util/                      # UrlResolve / FormatUtil / FilePublish
└── UI/
    ├── MainViewModel.swift
    ├── Theme/ArkColors.swift
    ├── Screens/               # HomeView / CreateTaskView / LinkParseView / SettingsView
    └── Components/TaskCard.swift
```

---

## 相关项目

- [ArkDownloader Android](https://github.com/mengfz123/ArkDownloader) — Android 版
- [ArkDownloader](https://github.com/mengfz123/ArkDownloader) — Windows 桌面版

---

## 许可证

暂未指定开源许可证。发布或二次分发前请确认作者授权。
