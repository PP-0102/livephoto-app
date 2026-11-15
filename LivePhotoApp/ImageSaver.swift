import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

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

/// Downloads one image (WebP) and saves it to Photos as a plain static
/// photo. No video, no pairing, no content identifier — a single .photo
/// resource, the simplest and most reliable save.
struct ImageSaver {

    /// Request add-only Photo Library access. This app only adds photos
    /// to the library, so add-only is the correct level.
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Save one image item to the Photos library as a static photo.
    /// Tries the original-quality URL first; if that download fails or
    /// does not decode as an image, falls back to the 1080px web version.
    static func saveImage(item: ImageItem) async throws {
        let imageData: Data
        do {
            imageData = try await downloadImageData(from: item.imageURL)
        } catch {
            do {
                imageData = try await downloadImageData(from: item.fallbackURL)
            } catch {
                throw SaverError.downloadFailed
            }
        }
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
            throw SaverError.invalidImage
        }
        let tempDir = FileManager.default.temporaryDirectory
        let jpgURL = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: jpgURL) }
        guard let dest = CGImageDestinationCreateWithURL(
            jpgURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SaverError.jpegEncodeFailed
        }
        CGImageDestinationSetProperties(
            dest, [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary)
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SaverError.jpegEncodeFailed
        }
        let jpgData: Data
        do {
            jpgData = try Data(contentsOf: jpgURL)
        } catch {
            throw SaverError.saveFailed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpgData, options: nil)
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

    /// Save one video item to the Photos library.
    /// Downloads the mp4 to a temp file (videos are too large to hold in
    /// memory), then saves it as a .video resource. Tries the
    /// original-quality URL first; falls back to the stream URL.
    static func saveVideo(item: VideoItem) async throws {
        let videoFile: URL
        do {
            videoFile = try await downloadVideoFile(from: item.videoURL)
        } catch {
            do {
                videoFile = try await downloadVideoFile(from: item.fallbackURL)
            } catch {
                throw SaverError.downloadFailed
            }
        }
        defer { try? FileManager.default.removeItem(at: videoFile) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: videoFile, options: nil)
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

    /// Download a video to a temp .mp4 file and return its URL.
    private static func downloadVideoFile(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SaverError.downloadFailed
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            throw SaverError.downloadFailed
        }
        return dest
    }

    /// Download image data from a URL and verify it decodes as an image.
    /// Throws when the request fails or the bytes are not a valid image,
    /// so the caller can fall back to the other URL.
    private static func downloadImageData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SaverError.downloadFailed
        }
        guard UIImage(data: data) != nil else {
            throw SaverError.invalidImage
        }
        return data
    }
}
