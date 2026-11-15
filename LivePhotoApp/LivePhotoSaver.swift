import AVFoundation
import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

// MARK: - Errors

enum SaverError: LocalizedError {
    case photoAccessDenied
    case downloadFailed
    case invalidImage
    case jpegEncodeFailed
    case videoRemuxFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .photoAccessDenied: return "没有相册权限，请在设置里允许本 App 保存照片"
        case .downloadFailed: return "下载失败，请检查网络后重试"
        case .invalidImage: return "图片解码失败"
        case .jpegEncodeFailed: return "图片转换失败"
        case .videoRemuxFailed: return "视频转换失败"
        case .saveFailed: return "保存到相册失败，请重试"
        }
    }
}

// MARK: - Saver

/// Downloads one Live Photo (still + motion clip) and saves it to Photos
/// as a real Live Photo (long-press to play, LIVE badge).
///
/// A real Live Photo needs the still and the clip to share ONE content
/// identifier, or Photos will not pair them (and may reject the save):
///   - JPEG: EXIF MakerNote = binary plist {17: <uuid>}
///   - MOV:  QuickTime metadata com.apple.quicktime.content.identifier
///
/// The still is a WebP image: decode it with UIImage and write it out as
/// JPEG with the MakerNote. The motion clip is an h264 mp4: remux it to a
/// proper QuickTime .mov (passthrough, no re-encode) and write the content
/// identifier into it. Both are then added to a single
/// PHAssetCreationRequest, which is how Photos pairs them into one asset.
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

        // 2. Decode the WebP still.
        guard let image = UIImage(data: stillData), let cgImage = image.cgImage else {
            throw SaverError.invalidImage
        }

        // 3. One shared content identifier for the still and the clip.
        let contentIdentifier = UUID().uuidString.uppercased()

        // 4. Write the tagged JPEG still and the remuxed + tagged .mov clip.
        let tempDir = FileManager.default.temporaryDirectory
        let base = UUID().uuidString
        let jpgURL = tempDir.appendingPathComponent(base + ".jpg")
        let mp4URL = tempDir.appendingPathComponent(base + ".mp4")
        let movURL = tempDir.appendingPathComponent(base + ".mov")
        defer {
            try? FileManager.default.removeItem(at: jpgURL)
            try? FileManager.default.removeItem(at: mp4URL)
            try? FileManager.default.removeItem(at: movURL)
        }
        do {
            try writeJPEG(image: image, cgImage: cgImage, to: jpgURL,
                          contentIdentifier: contentIdentifier)
            try videoData.write(to: mp4URL, options: [.atomic])
            try await transcodeAndTagVideo(inputURL: mp4URL, outputURL: movURL,
                                       contentIdentifier: contentIdentifier)
        } catch let error as SaverError {
            throw error
        } catch {
            throw SaverError.saveFailed
        }

        // 5. Save as one Live Photo asset (.photo + .pairedVideo).
        try await performSave(jpgURL: jpgURL, movURL: movURL)
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

    /// Write the still as JPEG with the EXIF MakerNote carrying the content
    /// identifier (binary plist {17: <uuid>}).
    private static func writeJPEG(image: UIImage, cgImage: CGImage, to url: URL,
                                  contentIdentifier: String) throws {
        let plistData = makerNotePlist(contentIdentifier: contentIdentifier)
        let exif: [String: Any] = [kCGImagePropertyExifMakerNote as String: plistData]
        let tiff: [String: Any] = [
            kCGImagePropertyTIFFOrientation as String: exifOrientation(for: image.imageOrientation)
        ]
        let metadata: [String: Any] = [
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff
        ]
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SaverError.jpegEncodeFailed
        }
        CGImageDestinationSetProperties(
            dest, [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary)
        CGImageDestinationAddImage(dest, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw SaverError.jpegEncodeFailed
        }
    }

    /// Transcode the mp4 clip to a proper QuickTime .mov (full re-encode,
    /// not passthrough) and write the content identifier into it as
    /// QuickTime metadata (com.apple.quicktime.content.identifier).
    /// Re-encoding (instead of passthrough) is what makes the export
    /// session actually write the metadata and produce a clean .mov
    /// that Photos accepts — passthrough copies the stream without
    /// rewriting it, so the content identifier never lands in the file.
    /// This mirrors the reference app (红薯秀), which FFmpeg-transcodes
    /// the clip to .mov before handing it to its Live Photo converter.
    private static func transcodeAndTagVideo(inputURL: URL, outputURL: URL,
                                             contentIdentifier: String) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw SaverError.videoRemuxFailed
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier.quickTimeMetadataContentIdentifier
        item.value = contentIdentifier as NSString
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        exportSession.metadata = [item]
        await exportSession.export()
        guard exportSession.status == .completed else {
            throw exportSession.error ?? SaverError.videoRemuxFailed
        }
    }

    /// Binary plist {17: <uuid>} for the JPEG MakerNote. Built byte by byte
    /// because PropertyListSerialization refuses integer dictionary keys.
    private static func makerNotePlist(contentIdentifier: String) -> Data {
        let uuidData = contentIdentifier.data(using: .ascii) ?? Data()
        var data = Data()
        data.append(contentsOf: [UInt8]("bplist00".utf8))
        data.append(contentsOf: [0xD1, 0x01, 0x02])   // dict, 1 entry
        data.append(contentsOf: [0x10, 0x11])         // int 17
        data.append(contentsOf: [0x5F, 0x10, UInt8(uuidData.count)])  // ascii string
        data.append(uuidData)
        let off0 = 8
        let off1 = off0 + 3
        let off2 = off1 + 2
        let offTab = off2 + 3 + uuidData.count
        data.append(contentsOf: [UInt8(off0), UInt8(off1), UInt8(off2)])  // offset table
        data.append(contentsOf: [UInt8](repeating: 0, count: 6))
        data.append(contentsOf: [1, 1])
        data.append(contentsOf: bigEndianBytes(UInt64(3)))       // object count
        data.append(contentsOf: bigEndianBytes(UInt64(0)))       // top object
        data.append(contentsOf: bigEndianBytes(UInt64(offTab)))  // offset table offset
        return data
    }

    private static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    /// EXIF orientation (1-8) for a UIImage orientation.
    private static func exifOrientation(for orientation: UIImage.Orientation) -> Int {
        switch orientation {
        case .up: return 1
        case .down: return 3
        case .left: return 8
        case .right: return 6
        case .upMirrored: return 2
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .rightMirrored: return 7
        @unknown default: return 1
        }
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
