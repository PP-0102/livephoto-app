import SwiftUI
import UIKit

// MARK: - View Model

@MainActor
final class ImageViewModel: ObservableObject {
    @Published var linkText = ""
    @Published var items: [ImageItem] = []
    @Published var status = ""
    @Published var isParsing = false
    @Published var isSavingAll = false
    @Published var savedIDs: Set<String> = []
    @Published var savingIDs: Set<String> = []

    /// Parse the pasted link and list the images in the note.
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
            let found = try await ImageResolver.resolve(link: link)
            items = found
            status = "找到 \(found.count) 张图片"
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isParsing = false
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
    func saveAll() async {
        guard !items.isEmpty, !isSavingAll else { return }
        guard await ImageSaver.requestAccess() else {
            status = SaverError.photoAccessDenied.errorDescription ?? "没有相册权限"
            return
        }
        isSavingAll = true
        var count = savedIDs.count
        for item in items where !savedIDs.contains(item.id) {
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
        status = ""
        savedIDs = []
        savingIDs = []
    }

    /// One-tap download: parse the link (if not parsed yet) and save every
    /// image to the Photos library.
    func downloadAll() async {
        guard !isParsing, !isSavingAll else { return }
        if items.isEmpty {
            await parse()
        }
        guard !items.isEmpty else { return }
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

                // Image list
                List(viewModel.items) { item in
                    ImageRow(
                        item: item,
                        isSaved: viewModel.savedIDs.contains(item.id),
                        isSaving: viewModel.savingIDs.contains(item.id),
                        onSave: {
                            Task { await viewModel.save(item: item) }
                        }
                    )
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("图片下载")
            .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Row

struct ImageRow: View {
    let item: ImageItem
    let isSaved: Bool
    let isSaving: Bool
    let onSave: () -> Void

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
                Text("图片 \(item.id)")
                    .font(.headline)
                if item.width > 0 && item.height > 0 {
                    Text("\(item.width) × \(item.height)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text(isSaved ? "已保存到相册" : "")
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
