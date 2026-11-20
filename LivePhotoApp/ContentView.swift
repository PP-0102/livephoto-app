import SwiftUI
import UIKit

// MARK: - View Model

@MainActor
final class ImageViewModel: ObservableObject {
    @Published var linkText = ""
    @Published var items: [ImageItem] = []
    @Published var video: VideoItem? = nil
    /// Headline and full body text of the parsed note, for the Ctrip hand-off.
    @Published var noteTitle = ""
    @Published var noteBody = ""
    @Published var isSendingToCtrip = false
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
    /// The run log text shown in the log sheet.
    @Published var logText = ""
    @Published var isShowingLog = false
    /// The exported log .txt file to share.
    @Published var logShareURL: URL? = nil

    /// Reload the run log from the saver.
    func refreshLog() {
        logText = LivePhotoLog.shared.text
        if logText.isEmpty {
            logText = "（还没有日志。解析并保存一张实况后，这里会显示每一步的运行过程。）"
        }
    }

    /// Export the run log as a .txt file and open the share sheet.
    func exportLog() {
        if let url = LivePhotoLog.shared.exportURL() {
            logShareURL = url
        } else {
            status = "日志导出失败"
        }
    }

    /// Clear the run log.
    func clearLog() {
        LivePhotoLog.shared.clear()
        refreshLog()
    }

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
        noteTitle = ""
        noteBody = ""
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
            noteTitle = media.title
            noteBody = media.bodyText
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
    /// Share text copied from Xiaohongshu or Douyin often starts with
    /// the note title, so pasting it raw fills the field with the title
    /// and hides the link. Keep only the link when one is in the text,
    /// so the field shows the link itself.
    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        if let url = ImageResolver.extractLinkURL(from: text) {
            linkText = url.absoluteString
        } else {
            linkText = text
        }
    }

    /// Clear the link field and the parsed results.
    func clear() {
        linkText = ""
        items = []
        video = nil
        noteTitle = ""
        noteBody = ""
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

    /// The text copied for Ctrip: title + body, without duplicating the
    /// title when the body already starts with it (Douyin uses desc for
    /// both title and body). Hashtags are removed entirely: Ctrip's
    /// editor turns every "#xxx" into a topic chip on its own, and the
    /// closing "#" Xiaohongshu puts after each tag is left over as stray
    /// text ("#xxx[话题]#"), so keeping the tags can never come out
    /// clean. Removing a tag also removes one space before it, and the
    /// spacing left behind is tidied up.
    var ctripText: String {
        let title = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = noteBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        if title.isEmpty {
            combined = body
        } else if body.isEmpty {
            combined = title
        } else if body == title || body.hasPrefix(title) {
            combined = body
        } else {
            combined = title + "\n\n" + body
        }
        let noTags = combined.replacingOccurrences(
            of: #" ?#[^\s#。，、；：！？,.!?;:]+#?"#,
            with: "",
            options: .regularExpression
        )
        let tidy1 = noTags.replacingOccurrences(
            of: #" +\n"#,
            with: "\n",
            options: .regularExpression
        )
        let tidy2 = tidy1.replacingOccurrences(
            of: #"\n +"#,
            with: "\n",
            options: .regularExpression
        )
        let tidy3 = tidy2.replacingOccurrences(
            of: #" {2,}"#,
            with: " ",
            options: .regularExpression
        )
        return tidy3.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hand the whole article to Ctrip: copy title + body to the
    /// clipboard, save the images/video to Photos, then open the Ctrip
    /// app. Ctrip offers no public publish API and no deep link that
    /// accepts a prefilled post, so the last step stays manual: in Ctrip
    /// tap 发布笔记, pick the photos just saved, paste the text.
    /// Live Photo items are saved as their stills here (that is what
    /// Ctrip picks up); video notes save the video.
    func sendToCtrip() async {
        guard !isSendingToCtrip, !isParsing, !isSavingAll, !isSavingAllLive else { return }
        if items.isEmpty && video == nil {
            await parse()
        }
        guard !items.isEmpty || video != nil else { return }
        isSendingToCtrip = true
        status = "正在准备转到携程…"
        LivePhotoLog.shared.append("转到携程：开始准备")
        // 1. Copy the whole article (title + body) to the clipboard.
        let text = ctripText
        if !text.isEmpty {
            UIPasteboard.general.string = text
            LivePhotoLog.shared.append("转到携程：已复制标题+正文（\(text.count) 字）")
        }
        // 2. Save the media to Photos so Ctrip can pick it.
        if video != nil {
            await saveVideo()
        }
        if !items.isEmpty {
            await saveAll()
        }
        let savedCount = savedIDs.count + liveSavedIDs.count
        LivePhotoLog.shared.append("转到携程：已保存 \(savedCount) 张图片到相册" + (isVideoSaved ? "，视频已保存" : ""))
        // 3. Open the Ctrip app. If it is not installed (or the scheme
        // is blocked), the text and photos are already ready — tell the
        // user to open Ctrip by hand instead of failing silently.
        if let url = URL(string: "ctrip://"), UIApplication.shared.canOpenURL(url) {
            let opened = await UIApplication.shared.open(url)
            if opened {
                status = "已复制好文字，图片已存到相册，正在打开携程…在携程里点「发布笔记」，选图、粘贴文字即可"
                LivePhotoLog.shared.append("转到携程：已打开携程 App")
            } else {
                status = "已复制好文字，图片已存到相册（\(savedCount) 张），请手动打开携程 App 点「发布笔记」"
                LivePhotoLog.shared.append("转到携程：打开携程失败，请手动打开")
            }
        } else {
            status = "已复制好文字，图片已存到相册（\(savedCount) 张）。没有装携程 App 的话请先安装，再点「发布笔记」"
            LivePhotoLog.shared.append("转到携程：未装携程 App 或无法打开")
        }
        isSendingToCtrip = false
    }

}

// MARK: - View

struct ContentView: View {
    @StateObject private var viewModel = ImageViewModel()
    @FocusState private var linkFieldFocused: Bool
    /// The image currently shown in the full-screen preview (tap a thumbnail).
    @State private var previewItem: ImageItem? = nil

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

                // Status line + log button
                HStack(alignment: .top, spacing: 8) {
                    if !viewModel.status.isEmpty {
                        Text(viewModel.status)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("日志") {
                        viewModel.refreshLog()
                        viewModel.isShowingLog = true
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
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

                // Hand the whole article to Ctrip (only when something was parsed)
                if !viewModel.items.isEmpty || viewModel.video != nil {
                    Button(action: {
                        linkFieldFocused = false
                        Task { await viewModel.sendToCtrip() }
                    }) {
                        HStack {
                            if viewModel.isSendingToCtrip {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                            Text(viewModel.isSendingToCtrip ? "正在准备…" : "转到携程发布")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isSendingToCtrip || viewModel.isParsing || viewModel.isSavingAll || viewModel.isSavingAllLive)
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
                        },
                        onPreview: {
                            previewItem = item
                        }
                    )
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("图片视频下载")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $previewItem) { item in
                ImagePreviewView(item: item)
            }
            .sheet(isPresented: Binding(
                get: { viewModel.livpShareURL != nil },
                set: { if !$0 { viewModel.livpShareURL = nil } }
            )) {
                if let url = viewModel.livpShareURL {
                    ShareSheet(url: url)
                }
            }
            .sheet(isPresented: $viewModel.isShowingLog) {
                LogView(viewModel: viewModel)
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
    /// Tap the thumbnail to open the full-screen preview.
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail (WebP; UIImage decodes it on iOS 14+).
            // Tap it to open the full-screen preview (original quality,
            // pinch to zoom).
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
            .onTapGesture(perform: onPreview)

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

/// Full-screen image preview: tap a thumbnail in the list to open it.
/// Shows the original-quality image. Pinch to zoom (1x–5x), drag to pan
/// while zoomed, double-tap to toggle between 1x and 2x, tap the × at
/// the top right to close.
struct ImagePreviewView: View {
    let item: ImageItem
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: item.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.white.opacity(0.6))
                default:
                    ProgressView()
                        .tint(.white)
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(1, min(lastScale * value, 5))
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale == 1 {
                            offset = .zero
                            lastOffset = .zero
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
            )
            .onTapGesture(count: 2) {
                if scale > 1 {
                    scale = 1
                    lastScale = 1
                    offset = .zero
                    lastOffset = .zero
                } else {
                    scale = 2
                    lastScale = 2
                }
            }

            VStack {
                HStack {
                    Text("图片 \(item.id)")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding()
                Spacer()
                Text("双指捏合放大缩小 · 双击放大 · 拖动移动")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.bottom, 28)
            }
        }
    }
}

/// Run log sheet: shows every step of the Live Photo save/export with
/// timestamps, so a failure can be pinpointed — and the log can be
/// exported as a .txt file and sent for inspection.
struct LogView: View {
    @ObservedObject var viewModel: ImageViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                Text(viewModel.logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("清空") {
                        viewModel.clearLog()
                    }
                    Button("导出日志") {
                        viewModel.exportLog()
                    }
                }
            }
            .onAppear {
                viewModel.refreshLog()
            }
            .sheet(isPresented: Binding(
                get: { viewModel.logShareURL != nil },
                set: { if !$0 { viewModel.logShareURL = nil } }
            )) {
                if let url = viewModel.logShareURL {
                    ShareSheet(url: url)
                }
            }
        }
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
