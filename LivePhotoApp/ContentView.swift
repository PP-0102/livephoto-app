import SwiftUI
import UIKit

// MARK: - View Model

@MainActor
final class ImageViewModel: ObservableObject {
    @Published var linkText = ""
    @Published var items: [ImageItem] = []
    @Published var video: VideoItem? = nil
    @Published var status = ""
    @Published var isParsing = false
    @Published var isSavingAll = false
    @Published var savedIDs: Set<String> = []
    @Published var savingIDs: Set<String> = []
    @Published var isVideoSaved = false
    @Published var isVideoSaving = false
    @Published var liveSavedIDs: Set<String> = []
    @Published var liveSavingIDs: Set<String> = []
    @Published var isSavingAllLive = false
    /// The .livp file to share (set when an export finishes).
    @Published var livpShareURL: URL? = nil
    @Published var exportingLivpIDs: Set<String> = []

    /// The items in this note that are Live Photos (have a motion clip).
    var liveItems: [ImageItem] {
        items.filter { $0.livePhotoClipURL != nil }
    }

    /// Parse the pasted link and list the images (and video) in the note.
    /// Douyin links go to the Douyin resolver; everything else goes to
    /// the Xiaohongshu resolver.
    func parse() async {
        let link = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            status = "请先粘贴小红书或抖音笔记链接"
            return
        }
        isParsing = true
        items = []
        video = nil
        savedIDs = []
        liveSavedIDs = []
        liveSavingIDs = []
        isVideoSaved = false
        status = "正在解析…"
        do {
            let lower = link.lowercased()
            let isDouyin = lower.contains("douyin.com") || lower.contains("v.douyin.com")
            let media = isDouyin
                ? try await DouyinResolver.resolve(link: link)
                : try await ImageResolver.resolve(link: link)
            items = media.images
            video = media.video
            if media.video != nil {
                status = items.isEmpty
                    ? "找到 1 个视频"
                    : "找到 1 个视频和 \(items.count) 张图片"
            } else {
                status = "找到 \(items.count) 张图片"
            }
            let liveCount = liveItems.count
            if liveCount > 0 {
                status += "（其中 \(liveCount) 张是实况）"
            }
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isParsing = false
    }

    /// Save one Live Photo to the Photos library as a real Live Photo.
    /// If the Live Photo save fails, fall back to saving the still as a
    /// static photo so the image is not lost.
    func saveLivePhoto(item: ImageItem) async {
        guard item.livePhotoClipURL != nil,
              !liveSavedIDs.contains(item.id), !liveSavingIDs.contains(item.id) else { return }
        liveSavingIDs.insert(item.id)
        do {
            guard await LivePhotoSaver.requestAccess() else {
                status = LivePhotoError.photoAccessDenied.errorDescription ?? "没有相册权限"
                liveSavingIDs.remove(item.id)
                return
            }
            try await LivePhotoSaver.saveLivePhoto(item: item)
            liveSavedIDs.insert(item.id)
            status = "实况已保存 \(liveSavedIDs.count)/\(liveItems.count)"
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = "第 \(item.id) 张实况保存失败（\(reason)），已改为保存静态图片"
            // Fallback: save the still as a plain photo.
            do {
                try await ImageSaver.saveImage(item: item)
                savedIDs.insert(item.id)
                status = "第 \(item.id) 张实况保存失败（\(reason)），已保存为静态图片"
            } catch {
                status = "第 \(item.id) 张保存失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
        liveSavingIDs.remove(item.id)
    }

    /// Export one Live Photo as a .livp file and open the share sheet.
    /// The .livp holds exactly the JPEG + MOV the app produces, so its
    /// bytes can be inspected when the direct save keeps failing.
    func exportLivp(item: ImageItem) async {
        guard item.livePhotoClipURL != nil,
              !exportingLivpIDs.contains(item.id) else { return }
        exportingLivpIDs.insert(item.id)
        status = "正在生成第 \(item.id) 张实况文件…"
        do {
            let data = try await LivePhotoSaver.makeLivpData(item: item)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("IMG_\(item.id).livp")
            try data.write(to: url, options: [.atomic])
            livpShareURL = url
            status = "第 \(item.id) 张实况文件已生成，请在分享里发给我检查"
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = "第 \(item.id) 张实况文件生成失败：\(reason)"
        }
        exportingLivpIDs.remove(item.id)
    }

    /// Save every Live Photo in the list, one after another.
    /// Items that fail as Live Photos fall back to static photos.
    func saveAllLivePhotos() async {
        let live = liveItems.filter { !liveSavedIDs.contains($0.id) }
        guard !live.isEmpty, !isSavingAllLive else { return }
        guard await LivePhotoSaver.requestAccess() else {
            status = LivePhotoError.photoAccessDenied.errorDescription ?? "没有相册权限"
            return
        }
        isSavingAllLive = true
        var count = liveSavedIDs.count
        for item in live {
            do {
                try await LivePhotoSaver.saveLivePhoto(item: item)
                liveSavedIDs.insert(item.id)
                count += 1
                status = "实况已保存 \(count)/\(liveItems.count)"
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = "第 \(item.id) 张实况保存失败（\(reason)），已改为保存静态图片"
                do {
                    try await ImageSaver.saveImage(item: item)
                    savedIDs.insert(item.id)
                } catch {
                    status = "第 \(item.id) 张保存失败，已跳过（已保存实况 \(count)/\(liveItems.count)）"
                }
            }
        }
        isSavingAllLive = false
        if liveSavedIDs.count == liveItems.count {
            status = "实况全部保存完成，共 \(liveItems.count) 张"
        }
    }

    /// Save the video to the Photos library.
    func saveVideo() async {
        guard let video, !isVideoSaved, !isVideoSaving else { return }
        isVideoSaving = true
        do {
            guard await ImageSaver.requestAccess() else {
                status = SaverError.photoAccessDenied.errorDescription ?? "没有相册权限"
                isVideoSaving = false
                return
            }
            try await ImageSaver.saveVideo(item: video)
            isVideoSaved = true
            status = "视频已保存到相册"
        } catch {
            status = "视频保存失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        isVideoSaving = false
    }

    /// Save one image to the Photos library.
    func save(item: ImageItem) async {
        guard !savedIDs.contains(item.id), !savingIDs.contains(item.id) else { return }
        savingIDs.insert(item.id)
        do {
            guard await ImageSaver.requestAccess() else {
                status = SaverError.photoAccessDenied.errorDescription ?? "没有相册权限"
                savingIDs.remove(item.id)
                return
            }
            try await ImageSaver.saveImage(item: item)
            savedIDs.insert(item.id)
            status = "已保存 \(savedIDs.count)/\(items.count)"
        } catch {
            status = "第 \(item.id) 张保存失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        savingIDs.remove(item.id)
    }

    /// Save every image in the list, one after another.
    /// Items already saved as Live Photos are skipped (no duplicate).
    func saveAll() async {
        guard !items.isEmpty, !isSavingAll else { return }
        guard await ImageSaver.requestAccess() else {
            status = SaverError.photoAccessDenied.errorDescription ?? "没有相册权限"
            return
        }
        isSavingAll = true
        var count = savedIDs.count
        for item in items where !savedIDs.contains(item.id) && !liveSavedIDs.contains(item.id) {
            do {
                try await ImageSaver.saveImage(item: item)
                savedIDs.insert(item.id)
                count += 1
                status = "已保存 \(count)/\(items.count)"
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = "第 \(item.id) 张保存失败（\(reason)），已跳过（已保存 \(count)/\(items.count)）"
            }
        }
        isSavingAll = false
        if savedIDs.count == items.count {
            status = "全部保存完成，共 \(items.count) 张"
        }
    }

    /// Paste the link from the clipboard into the text field.
    func pasteFromClipboard() {
        if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            linkText = text
        }
    }

    /// Clear the link field and the parsed results.
    func clear() {
        linkText = ""
        items = []
        video = nil
        status = ""
        savedIDs = []
        savingIDs = []
        liveSavedIDs = []
        liveSavingIDs = []
        isVideoSaved = false
        isVideoSaving = false
        isSavingAllLive = false
    }

    /// One-tap download: parse the link (if not parsed yet) and save the
    /// video and every image to the Photos library. Live Photos are saved
    /// as real Live Photos; ordinary images are saved as static photos.
    func downloadAll() async {
        guard !isParsing, !isSavingAll, !isSavingAllLive else { return }
        if items.isEmpty && video == nil {
            await parse()
        }
        guard !items.isEmpty || video != nil else { return }
        if video != nil {
            await saveVideo()
        }
        if !liveItems.isEmpty {
            await saveAllLivePhotos()
        }
        await saveAll()
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var viewModel = ImageViewModel()
    @FocusState private var linkFieldFocused: Bool

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                // Link input
                HStack(spacing: 8) {
                    TextField("粘贴小红书或抖音笔记链接", text: $viewModel.linkText)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .focused($linkFieldFocused)
                    Button("粘贴") {
                        viewModel.pasteFromClipboard()
                    }
                    .buttonStyle(.bordered)
                    Button("一键清空") {
                        viewModel.clear()
                    }
                    .buttonStyle(.bordered)
                }

                // Parse + one-tap download
                HStack(spacing: 8) {
                    Button(action: {
                        linkFieldFocused = false
                        Task { await viewModel.parse() }
                    }) {
                        HStack {
                            if viewModel.isParsing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                            Text(viewModel.isParsing ? "正在解析…" : "解析")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isParsing || viewModel.isSavingAll || viewModel.linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(action: {
                        linkFieldFocused = false
                        Task { await viewModel.downloadAll() }
                    }) {
                        HStack {
                            if viewModel.isSavingAll {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                            Text(viewModel.isSavingAll ? "正在下载…" : "一键下载")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isParsing || viewModel.isSavingAll || viewModel.linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Status line
                if !viewModel.status.isEmpty {
                    Text(viewModel.status)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // Video card (for a video note)
                if let video = viewModel.video {
                    VideoRow(
                        item: video,
                        isSaved: viewModel.isVideoSaved,
                        isSaving: viewModel.isVideoSaving,
                        onSave: {
                            Task { await viewModel.saveVideo() }
                        }
                    )
                }

                // Save all
                if !viewModel.items.isEmpty {
                    Button(action: {
                        linkFieldFocused = false
                        Task { await viewModel.saveAll() }
                    }) {
                        Text(viewModel.isSavingAll ? "正在保存…" : "全部保存（\(viewModel.items.count) 张）")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isSavingAll)
                }

                // Save all Live Photos (only when the note has any)
                if !viewModel.liveItems.isEmpty {
                    Button(action: {
                        linkFieldFocused = false
                        Task { await viewModel.saveAllLivePhotos() }
                    }) {
                        Text(viewModel.isSavingAllLive ? "正在保存实况…" : "全部保存为实况（\(viewModel.liveItems.count) 张）")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isSavingAllLive)
                }

                // Image list
                List(viewModel.items) { item in
                    ImageRow(
                        item: item,
                        isSaved: viewModel.savedIDs.contains(item.id),
                        isSaving: viewModel.savingIDs.contains(item.id),
                        isLiveSaved: viewModel.liveSavedIDs.contains(item.id),
                        isLiveSaving: viewModel.liveSavingIDs.contains(item.id),
                        isExportingLivp: viewModel.exportingLivpIDs.contains(item.id),
                        onSave: {
                            Task { await viewModel.save(item: item) }
                        },
                        onSaveLive: {
                            Task { await viewModel.saveLivePhoto(item: item) }
                        },
                        onExportLivp: {
                            Task { await viewModel.exportLivp(item: item) }
                        }
                    )
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("图片下载")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(
                get: { viewModel.livpShareURL != nil },
                set: { if !$0 { viewModel.livpShareURL = nil } }
            )) {
                if let url = viewModel.livpShareURL {
                    ShareSheet(url: url)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        linkFieldFocused = false
                    }
                }
            }
        }
    }
}

// MARK: - Video row

struct VideoRow: View {
    let item: VideoItem
    let isSaved: Bool
    let isSaving: Bool
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Cover thumbnail with a play badge.
            ZStack(alignment: .center) {
                AsyncImage(url: item.coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Color.gray.opacity(0.3)
                            .overlay(Image(systemName: "video").foregroundColor(.secondary))
                    default:
                        ProgressView()
                    }
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .shadow(radius: 2)
            }
            .frame(width: 72, height: 96)
            .clipped()
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if item.durationMs > 0 {
                    Text("时长 \(item.durationMs / 1000) 秒")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text(isSaved ? "已保存到相册" : "原画视频")
                    .font(.caption)
                    .foregroundColor(isSaved ? .green : .secondary)
            }

            Spacer()

            Button(action: onSave) {
                if isSaving {
                    ProgressView()
                } else if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Text("保存视频")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isSaved || isSaving)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Row

struct ImageRow: View {
    let item: ImageItem
    let isSaved: Bool
    let isSaving: Bool
    let isLiveSaved: Bool
    let isLiveSaving: Bool
    let isExportingLivp: Bool
    let onSave: () -> Void
    let onSaveLive: () -> Void
    let onExportLivp: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail (WebP; UIImage decodes it on iOS 14+).
            AsyncImage(url: item.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    Color.gray.opacity(0.3)
                        .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                default:
                    ProgressView()
                }
            }
            .frame(width: 72, height: 96)
            .clipped()
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("图片 \(item.id)")
                        .font(.headline)
                    if item.livePhotoClipURL != nil {
                        Text("实况")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
                if item.width > 0 && item.height > 0 {
                    Text("\(item.width) × \(item.height)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text(isLiveSaved ? "实况已保存到相册" : (isSaved ? "已保存到相册" : ""))
                    .font(.caption)
                    .foregroundColor(isLiveSaved || isSaved ? .green : .secondary)
            }

            Spacer()

            // Save as Live Photo (only for Live Photo items).
            if item.livePhotoClipURL != nil {
                Button(action: onSaveLive) {
                    if isLiveSaving {
                        ProgressView()
                    } else if isLiveSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Text("保存实况")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLiveSaved || isLiveSaving)

                // Export the exact JPEG + MOV as a .livp file, for
                // inspection when the direct save keeps failing.
                Button(action: onExportLivp) {
                    if isExportingLivp {
                        ProgressView()
                    } else {
                        Text("导出")
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isExportingLivp)
            }

            Button(action: onSave) {
                if isSaving {
                    ProgressView()
                } else if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Text("保存")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isSaved || isSaving)
        }
        .padding(.vertical, 4)
    }
}

/// Share sheet for the exported .livp file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
