import Foundation
import Photos
import UIKit

// MARK: - Errors

enum SaverError: LocalizedError {
    case photoAccessDenied
    case downloadFailed
    case invalidImage
    case jpegEncodeFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .photoAccessDenied: return "没有相册权限，请在设置里允许本 App 保存照片"
        case .downloadFailed: return "下载失败，请检查网络后重试"
        case .invalidImage: return "图片解码失败"
        case .jpegEncodeFailed: return "图片转换失败"
        case .saveFailed: return "保存到相册失败，请重试"
        }
    }
}

// MARK: - Saver

/// Downloads one Live Photo (still + motion clip) and saves it to Photos
/// as a real Live Photo (long-press to play, LIVE badge).
///
/// The still is a WebP image: decode it with UIImage and re-encode as JPEG.
/// The motion clip is an h264 mp4: its bytes are written to a .mov path
/// (the h264 stream is compatible with the QuickTime container).
/// Both resources are added to a single PHAssetCreationRequest, which is
/// how Photos pairs them into one Live Photo asset.
struct LivePhotoSaver {

    /// Request add-only Photo Library access. Returns true if granted.
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Save one Live Photo item to the Photos library.
    static func save(item: LivePhotoItem) async throws {
        // 1. Download the still (WebP) and the motion clip (mp4).
        let (stillData, videoData) = try await download(item: item)

        // 2. Decode the WebP still and re-encode it as JPEG.
        guard let image = UIImage(data: stillData) else {
            throw SaverError.invalidImage
        }
        guard let jpegData = image.jpegData(compressionQuality: 0.92) else {
            throw SaverError.jpegEncodeFailed
        }

        // 3. Write both parts to temp files.
        let tempDir = FileManager.default.temporaryDirectory
        let base = UUID().uuidString
        let jpgURL = tempDir.appendingPathComponent(base + ".jpg")
        let movURL = tempDir.appendingPathComponent(base + ".mov")
        do {
            try jpegData.write(to: jpgURL, options: [.atomic])
            try videoData.write(to: movURL, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: jpgURL)
            try? FileManager.default.removeItem(at: movURL)
            throw SaverError.saveFailed
        }

        // 4. Save as one Live Photo asset (.photo + .pairedVideo).
        do {
            try await performSave(jpgURL: jpgURL, movURL: movURL)
        } catch {
            try? FileManager.default.removeItem(at: jpgURL)
            try? FileManager.default.removeItem(at: movURL)
            throw error
        }

        // 5. Clean up temp files.
        try? FileManager.default.removeItem(at: jpgURL)
        try? FileManager.default.removeItem(at: movURL)
    }

    // MARK: - Helpers

    private static func download(item: LivePhotoItem) async throws -> (Data, Data) {
        async let still = downloadData(from: item.stillURL)
        async let video = downloadData(from: item.videoURL)
        do {
            return try await (still, video)
        } catch {
            throw SaverError.downloadFailed
        }
    }

    private static func downloadData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SaverError.downloadFailed
        }
        return data
    }

    /// One creation request with both resources; Photos pairs them into a
    /// single Live Photo asset.
    private static func performSave(jpgURL: URL, movURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: jpgURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movURL, options: nil)
            }, completionHandler: { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SaverError.saveFailed)
                }
            })
        }
    }
}
