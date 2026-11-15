import SwiftUI
import UIKit

// MARK: - View Model

@MainActor
final class LivePhotoViewModel: ObservableObject {
    @Published var linkText = ""
    @Published var items: [LivePhotoItem] = []
    @Published var status = ""
    @Published var isParsing = false
    @Published var isSavingAll = false
    @Published var savedIDs: Set<String> = []
    @Published var savingIDs: Set<String> = []
    @Published var savedStaticIDs: Set<String> = []
    @Published var savingStaticIDs: Set<String> = []

    /// Parse the pasted link and list the Live Photos in the note.
    func parse() async {
        let link = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            status = "请先粘贴小红书笔记链接"
            return
        }
        isParsing = true
        items = []
        savedIDs = []
        status = "正在解析…"
        do {
            let found = try await XiaohongshuResolver.resolve(link: link)
            items = found
            status = "找到 \(found.count) 张实况照片"
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isParsing = false
    }

    /// Save one Live Photo to the Photos library.
    func save(item: LivePhotoItem) async {
        guard !savedIDs.contains(item.id), !savingIDs.contains(item.id) else { return }
        savingIDs.insert(item.id)
        do {
            guard await LivePhotoSaver.requestAccess() else {
                status = SaverError.photoAccessDenied.errorDescription ?? "没有相册权限"
                savingIDs.remove(item.id)
                return
            }
            try await LivePhotoSaver.save(item: item)
            savedIDs.insert(item.id)
            status = "已保存 \(savedIDs.count)/\(items.count)"
        } catch {
            status = "第 \(item.id) 张保存失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        savingIDs.remove(item.id)
    }

    /// Save every Live Photo in the list, one after another.
    func saveAll() async {
        guard !items.isEmpty, !isSavingAll else { return }
        guard await LivePhotoSaver.requestAccess() else {
            status = SaverError.photoAccessDenied.errorDescription ?? "没有相册权限"
            return
        }
        isSavingAll = true
        var count = savedIDs.count
        for item in items where !savedIDs.contains(item.id) {
            do {
                try await LivePhotoSaver.save(item: item)
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

    /// Save one item's still as a plain static photo to the Photos library.
    func saveStatic(item: LivePhotoItem) async {
        guard !savedStaticIDs.contains(item.id), !savingStaticIDs.contains(item.id) else { return }
        savingStaticIDs.insert(item.id)
        do {
            guard await LivePhotoSaver.requestAccess() else {
                status = SaverError.photoAccessDenied.errorDescription ?? "没有相册权限"
                savingStaticIDs.remove(item.id)
                return
            }
            try await LivePhotoSaver.saveStaticImage(item: item)
            savedStaticIDs.insert(item.id)
            status = "已保存图片 \(savedStaticIDs.count)/\(items.count)"
        } catch {
            status = "第 \(item.id) 张图片保存失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        savingStaticIDs.remove(item.id)
    }

    /// Save every item's still as a plain static photo, one after another.
    func saveAllStatic() async {
        guard !items.isEmpty, !isSavingAll else { return }
        guard await LivePhotoSaver.requestAccess() else {
            status = SaverError.photoAccessDenied.errorDescription ?? "没有相册权限"
            return
        }
        isSavingAll = true
        var count = savedStaticIDs.count
        for item in items where !savedStaticIDs.contains(item.id) {
            do {
                try await LivePhotoSaver.saveStaticImage(item: item)
                savedStaticIDs.insert(item.id)
                count += 1
                status = "已保存图片 \(count)/\(items.count)"
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = "第 \(item.id) 张图片保存失败（\(reason)），已跳过（已保存图片 \(count)/\(items.count)）"
            }
        }
        isSavingAll = false
        if savedStaticIDs.count == items.count {
            status = "全部图片保存完成，共 \(items.count) 张"
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
        status = ""
        savedIDs = []
        savingIDs = []
        savedStaticIDs = []
        savingStaticIDs = []
    }

    /// One-tap download: parse the link (if not parsed yet) and save every
    /// Live Photo to the Photos library.
    func downloadAll() async {
        guard !isParsing, !isSavingAll else { return }
        if items.isEmpty {
            await parse()
        }
        guard !items.isEmpty else { return }
        await saveAll()
    }

    /// Build a .livp file for one item and return its temp file URL.
    /// The .livp is iOS's own Live Photo container; opening it in Files
    /// imports it as a real Live Photo. Used when the direct Photos save
    /// keeps failing.
    func exportLivp(item: LivePhotoItem) async -> URL? {
        do {
            let data = try await LivePhotoSaver.makeLivpData(item: item)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("IMG_\(item.id).livp")
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            status = "第 \(item.id) 张导出失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return nil
        }
    }

    /// Build .livp files for every item and return their temp file URLs.
    func exportAllLivps() async -> [URL] {
        var urls: [URL] = []
        for item in items {
            if let url = await exportLivp(item: item) {
                urls.append(url)
            }
        }
        if urls.isEmpty {
            status = "导出失败，请重试"
        } else {
            status = "已导出 \(urls.count) 个实况文件，点分享存到“文件”里打开即可导入相册"
        }
        return urls
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var viewModel = LivePhotoViewModel()
    @FocusState private var linkFieldFocused: Bool
    @State private var shareURLs: [URL] = []
    @State private var showingShare = false
    @State private var isExporting = false

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                // Link input
                HStack(spacing: 8) {
                    TextField("粘贴小红书笔记链接", text: $viewModel.linkText)
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

                // Save all + save all as static images + export all as .livp files
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
                    .disabled(viewModel.isSavingAll || isExporting)

                    Button(action: {
                        linkFieldFocused = false
                        Task { await viewModel.saveAllStatic() }
                    }) {
                        Text(viewModel.isSavingAll ? "正在保存…" : "全部保存为图片（\(viewModel.items.count) 张）")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isSavingAll || isExporting)

                    Button(action: {
                        linkFieldFocused = false
                        Task {
                            isExporting = true
                            let urls = await viewModel.exportAllLivps()
                            isExporting = false
                            if !urls.isEmpty {
                                shareURLs = urls
                                showingShare = true
                            }
                        }
                    }) {
                        Text(isExporting ? "正在导出…" : "导出全部实况文件（\(viewModel.items.count) 个 .livp）")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isSavingAll || isExporting)
                    Text("直接保存失败时用导出：把 .livp 存到“文件”，在“文件”里打开就能导入相册成为实况照片。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Live Photo list
                List(viewModel.items) { item in
                    LivePhotoRow(
                        item: item,
                        isSaved: viewModel.savedIDs.contains(item.id),
                        isSaving: viewModel.savingIDs.contains(item.id),
                        isStaticSaved: viewModel.savedStaticIDs.contains(item.id),
                        isStaticSaving: viewModel.savingStaticIDs.contains(item.id),
                        onSave: {
                            Task { await viewModel.save(item: item) }
                        },
                        onSaveStatic: {
                            Task { await viewModel.saveStatic(item: item) }
                        },
                        onExport: {
                            Task {
                                if let url = await viewModel.exportLivp(item: item) {
                                    shareURLs = [url]
                                    showingShare = true
                                }
                            }
                        }
                    )
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("实况下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        linkFieldFocused = false
                    }
                }
            }
            .sheet(isPresented: $showingShare) {
                ShareSheet(activityItems: shareURLs)
            }
        }
    }
}

// MARK: - Share sheet (UIActivityViewController for iOS 15)

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Row

struct LivePhotoRow: View {
    let item: LivePhotoItem
    let isSaved: Bool
    let isSaving: Bool
    let isStaticSaved: Bool
    let isStaticSaving: Bool
    let onSave: () -> Void
    let onSaveStatic: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Still-image thumbnail (WebP; UIImage decodes it on iOS 14+).
            AsyncImage(url: item.stillURL) { phase in
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
                Text("实况照片 \(item.id)")
                    .font(.headline)
                if item.width > 0 && item.height > 0 {
                    Text("\(item.width) × \(item.height)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text(isSaved ? "已保存到相册" : isStaticSaved ? "已保存为图片" : "长按可播放")
                    .font(.caption)
                    .foregroundColor(isSaved || isStaticSaved ? .green : .secondary)
            }

            Spacer()

            VStack(spacing: 6) {
                Button(action: onSave) {
                    if isSaving {
                        ProgressView()
                    } else if isSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Text("保存到相册")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isSaved || isSaving)

                Button(action: onSaveStatic) {
                    if isStaticSaving {
                        ProgressView()
                    } else if isStaticSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Text("保存图片")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isStaticSaved || isStaticSaving)

                Button(action: onExport) {
                    Text("导出实况文件")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
