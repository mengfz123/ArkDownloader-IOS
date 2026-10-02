import SwiftUI

struct TaskCard: View {
    let task: DownloadTask
    let onPause: () -> Void
    let onResume: () -> Void
    let onRestart: () -> Void
    let onCopy: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var kindLabel: String {
        if task.isFolder { return "文件夹" }
        return UrlResolve.isBaiduUrl(task.url) ? "百度直链" : "HTTP"
    }

    private var statusColor: Color {
        switch task.status {
        case .completed: return ArkColors.success
        case .failed: return ArkColors.error
        case .paused, .pending, .merging: return ArkColors.warn
        case .downloading: return ArkColors.primary
        case .canceled: return ArkColors.muted
        }
    }

    private var statusSoft: Color {
        switch task.status {
        case .completed: return ArkColors.successSoft
        case .failed: return ArkColors.errorSoft
        case .paused, .pending, .merging: return ArkColors.warnSoft
        case .downloading: return ArkColors.primarySoft
        case .canceled: return ArkColors.card2
        }
    }

    private var statusLabel: String {
        switch task.status {
        case .pending: return "等待"
        case .downloading: return "下载中"
        case .merging: return "收尾"
        case .paused: return "暂停"
        case .completed: return "完成"
        case .failed: return "失败"
        case .canceled: return "取消"
        }
    }

    private var displayName: String {
        if task.isFolder { return task.fileName.isEmpty ? "文件夹" : task.fileName }
        return UrlResolve.displayFileName(task.fileName, task.url)
    }

    private var progressColor: Color {
        switch task.status {
        case .completed: return ArkColors.success
        case .failed, .canceled: return ArkColors.error
        default: return ArkColors.primary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ArkColors.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusSoft)
                    .cornerRadius(6)
            }

            if task.isFolder {
                Text(folderSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(ArkColors.muted)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                TagChip(text: kindLabel)
                TagChip(text: FormatUtil.formatBytes(task.totalSize), muted: true)
            }

            let location = task.filePath.isEmpty ? task.saveDir : task.filePath
            if !location.isEmpty {
                Text("位置：\(location)")
                    .font(.system(size: 12))
                    .foregroundColor(ArkColors.muted)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ArkColors.card2)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressColor)
                            .frame(width: geo.size.width * task.progress / 100.0, height: 6)
                    }
                }
                .frame(height: 6)
                Text(String(format: task.status == .downloading ? "%.1f%%" : "%.0f%%", task.progress))
                    .font(.system(size: 12))
                    .foregroundColor(ArkColors.muted)
                    .frame(width: 50, alignment: .trailing)
            }

            HStack {
                Text("\(FormatUtil.formatBytes(task.loaded)) / \(FormatUtil.formatBytes(task.totalSize))")
                    .font(.system(size: 12))
                    .foregroundColor(ArkColors.muted)
                    .lineLimit(1)
                Spacer()
                if task.status == .downloading && task.speed > 0 {
                    let left = Double(max(task.totalSize - task.loaded, 0)) / Double(task.speed)
                    Text("\(FormatUtil.formatSpeed(task.speed)) · \(FormatUtil.formatEta(left))")
                        .font(.system(size: 12))
                        .foregroundColor(ArkColors.muted)
                } else if task.status == .merging {
                    Text("正在收尾…")
                        .font(.system(size: 12))
                        .foregroundColor(ArkColors.muted)
                }
            }

            if let err = task.errorMsg, !err.isEmpty {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(ArkColors.error)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ArkColors.errorSoft)
                    .cornerRadius(6)
                    .lineLimit(2)
            }

            Divider().background(ArkColors.border)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    switch task.status {
                    case .downloading, .merging:
                        PillButton("暂停", action: onPause)
                    case .paused, .pending:
                        PillButton("继续", action: onResume, primary: true)
                    case .failed:
                        PillButton("重试", action: onRestart, primary: true)
                    case .completed:
                        PillButton("打开", action: onOpen, primary: true)
                    default:
                        EmptyView()
                    }
                    PillButton("复制", action: onCopy, ghost: true)
                    PillButton("删除", action: onDelete, danger: true)
                }
            }
        }
        .padding(12)
        .background(ArkColors.card)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ArkColors.border, lineWidth: 1))
        .cornerRadius(10)
    }

    private var folderSubtitle: String {
        if task.status == .completed { return "共 \(task.filesTotal) 个文件" }
        if let cur = task.currentFileName, !cur.isEmpty {
            return "正在下载：\(cur)（\(task.filesCompleted)/\(task.filesTotal)）"
        }
        return "\(task.filesCompleted)/\(task.filesTotal) 个文件"
    }
}

struct TagChip: View {
    let text: String
    var muted: Bool = false
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(muted ? ArkColors.muted : ArkColors.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(ArkColors.card2)
            .cornerRadius(5)
    }
}

struct PillButton: View {
    let title: String
    let action: () -> Void
    var primary: Bool = false
    var ghost: Bool = false
    var danger: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(foregroundColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(backgroundColor)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        if primary { return .white }
        if danger { return ArkColors.error }
        return ArkColors.text
    }

    private var backgroundColor: Color {
        if primary { return ArkColors.primary }
        if danger { return ArkColors.errorSoft }
        if ghost { return Color.clear }
        return ArkColors.card2
    }
}
