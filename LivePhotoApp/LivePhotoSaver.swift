import AVFoundation
import CoreMedia
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - Errors

enum LivePhotoError: LocalizedError {
    case notLivePhoto
    case photoAccessDenied
    case downloadFailed
    case invalidImage
    case noVideoTrack
    case videoEncodeFailed
    case jpegEncodeFailed
    case saveFailed
    /// The exact Photos error (domain + code), so a failure can be
    /// diagnosed from the status line instead of guessed at.
    case photosError(domain: String, code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notLivePhoto: return "这张不是实况照片"
        case .photoAccessDenied: return "没有相册权限，请在设置里允许本 App 保存照片"
        case .downloadFailed: return "下载失败，请检查网络后重试"
        case .invalidImage: return "图片解码失败"
        case .noVideoTrack: return "实况视频里没有画面"
        case .videoEncodeFailed: return "实况视频转换失败"
        case .jpegEncodeFailed: return "图片转换失败"
        case .saveFailed: return "保存到相册失败，请重试"
        case .photosError(let domain, let code, let message):
            return "保存失败（\(domain) \(code)：\(message)）"
        }
    }
}

// MARK: - Saver

/// Saves one Xiaohongshu Live Photo (实况) to the Photos library as a real
/// Live Photo (.photo + .pairedVideo sharing one content identifier).
///
/// History: the standalone 实况下载 app (v1–v14) never got a save to work
/// (errors -1 and 3300), and the first builds inside this app failed
/// with 3300 too. What the current build does differently, and why:
///  1. The still's content identifier is written by the system
///     ImageIO writer (CGImageDestination with
///     kCGImagePropertyMakerAppleDictionary ["17": uuid]), the same
///     approach the open-source glitter-live app uses — NOT by
///     hand-built EXIF bytes. The hand-built minimal EXIF (used
///     through run #39) read back correctly in exiftool and in a
///     Python parser, but was never verified to be readable by
///     Photos' own ImageIO, and an unreadable still identifier
///     would leave the pair unpaired (3300) no matter how correct
///     the video is. The clip's identifier is still injected as a
///     moov-level meta atom (iTunes/keys format, byte-identical in
///     structure to an exiftool-written .livp .mov), because the
///     official `writer.metadata` API was never verified to land
///     the identifier in the file.
///  2. NO timed-metadata tracks. The iOS 17 camera reference values the
///     tracks were built from are the prime suspect for 3300 on iOS 15.1:
///     Photos' video converter has to process every track, and plain
///     Photos only needs the shared identifier to pair still + video.
///  3. H.264 High 4.1 (the "Most Compatible" format), HEVC only as a
///     fallback if H.264 encoding fails on the device. The H.264
///     profile/level MUST fit the frame: the source clip is 1080x1440
///     High 5.0, and Main 3.1 (used in an earlier build) caps at
///     3600 macroblocks — a 1080x1440 frame is 6075, so that re-encode
///     was non-conformant and Photos' converter rejected it with 3300
///     (confirmed on the VM: libx264 reports "frame MB size (68x90) >
///     level limit (3600)"). High 4.1 is used instead. A straight
///     remux (Passthrough, no re-encode) was tried in run #39 and was
///     WORSE: Photos rejected the untouched original bitstream
///     instantly (3300 in 2–50 ms), while the re-encoded video got as
///     far as ~8s of conversion work in run #38.
///  4. The save tries file URLs first, then Data as a fallback, and
///     logs both results. The working open-source recipe (glitter-live)
///     saves with file URLs — and that combination, file URLs + the
///     system-written MakerNote still, was never tried: every earlier
///     file-URL attempt used the hand-built EXIF still, and every
///     Data attempt since the still was fixed used Data.
///  5. Before saving, the pair is validated locally with
///     PHLivePhoto.request (the same check glitter-live uses):
///     Photos only returns a Live Photo for a correctly paired still
///     and movie. A passing validation with a failing save points at
///     the save path/environment; a failing validation points at the
///     files themselves. The validation never blocks the save — both
///     results are logged either way.
///  6. makeLivpData() exports the exact same pair as a .livp file, so
///     the bytes the app produces can be inspected when the direct
///     save still fails.
struct LivePhotoSaver {

    /// Request add-only Photo Library access. This app only adds photos
    /// to the library, so add-only is the correct level; asking for full
    /// read-write access made Photos reject the paired save (-1).
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Save one Live Photo item to the Photos library.
    static func saveLivePhoto(item: ImageItem) async throws {
        let (jpgURL, movURL, mp4URL) = try await buildPairFiles(item: item)
        defer {
            try? FileManager.default.removeItem(at: jpgURL)
            try? FileManager.default.removeItem(at: mp4URL)
            try? FileManager.default.removeItem(at: movURL)
        }
        // Validate the pair locally first (never blocks the save).
        await validatePair(jpgURL: jpgURL, movURL: movURL)
        // Save as one Live Photo asset (.photo + .pairedVideo).
        // Try file URLs first, then Data as a fallback (see performSave).
        try await performSave(jpgURL: jpgURL, movURL: movURL)
    }

    /// Build a .livp file (ZIP of the tagged JPEG still + tagged MOV clip
    /// sharing one content identifier) and return it as Data. A .livp is
    /// the format iOS itself uses for Live Photos. This is the diagnostic
    /// export: if the direct Photos save keeps failing, the user can send
    /// this file back and its exact bytes can be inspected.
    static func makeLivpData(item: ImageItem) async throws -> Data {
        let (jpgURL, movURL, mp4URL) = try await buildPairFiles(item: item)
        defer {
            try? FileManager.default.removeItem(at: jpgURL)
            try? FileManager.default.removeItem(at: mp4URL)
            try? FileManager.default.removeItem(at: movURL)
        }
        let jpgData = try Data(contentsOf: jpgURL)
        let movData = try Data(contentsOf: movURL)
        let stem = "IMG_\(item.id)"
        LivePhotoLog.shared.append("实况文件已生成：\(stem).livp（照片 \(jpgData.count / 1024) KB + 视频 \(movData.count / 1024) KB）")
        return zipStored(files: [(stem + ".JPG", jpgData), (stem + ".MOV", movData)])
    }

    /// Minimal ZIP writer (stored entries, no compression). Sufficient for
    /// .livp, which iOS reads as a Live Photo container.
    private static func zipStored(files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for file in files {
            let nameBytes = Array(file.name.utf8)
            let crc = crc32(file.data)
            let localOffset = UInt32(out.count)
            // Local file header.
            appendLE32(0x04034b50, to: &out)
            appendLE16(20, to: &out)              // version needed
            appendLE16(0x0800, to: &out)          // flags: UTF-8 filenames
            appendLE16(0, to: &out)               // method: stored
            appendLE16(0, to: &out)               // mod time
            appendLE16(0x21, to: &out)            // mod date (1980-01-01)
            appendLE32(crc, to: &out)
            appendLE32(UInt32(file.data.count), to: &out)
            appendLE32(UInt32(file.data.count), to: &out)
            appendLE16(UInt16(nameBytes.count), to: &out)
            appendLE16(0, to: &out)               // extra length
            out.append(contentsOf: nameBytes)
            out.append(file.data)
            // Central directory entry.
            appendLE32(0x02014b50, to: &central)
            appendLE16(20, to: &central)          // version made by
            appendLE16(20, to: &central)          // version needed
            appendLE16(0x0800, to: &central)      // flags: UTF-8
            appendLE16(0, to: &central)           // method: stored
            appendLE16(0, to: &central)           // mod time
            appendLE16(0x21, to: &central)        // mod date
            appendLE32(crc, to: &central)
            appendLE32(UInt32(file.data.count), to: &central)
            appendLE32(UInt32(file.data.count), to: &central)
            appendLE16(UInt16(nameBytes.count), to: &central)
            appendLE16(0, to: &central)           // extra
            appendLE16(0, to: &central)           // comment
            appendLE16(0, to: &central)           // disk number
            appendLE16(0, to: &central)           // internal attrs
            appendLE32(0, to: &central)           // external attrs
            appendLE32(localOffset, to: &central)
            central.append(contentsOf: nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory.
        appendLE32(0x06054b50, to: &out)
        appendLE16(0, to: &out)                   // disk number
        appendLE16(0, to: &out)                   // central dir disk
        appendLE16(UInt16(files.count), to: &out)
        appendLE16(UInt16(files.count), to: &out)
        appendLE32(UInt32(central.count), to: &out)
        appendLE32(centralOffset, to: &out)
        appendLE16(0, to: &out)                   // comment length
        return out
    }

    /// CRC-32 (IEEE, polynomial 0xEDB88320) for the ZIP entries.
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Download the still + motion clip and write the tagged JPEG still
    /// and the transcoded + tagged .mov. Returns the temp file URLs;
    /// the caller removes them. Shared by saveLivePhoto and makeLivpData
    /// so both work on exactly the same files.
    private static func buildPairFiles(item: ImageItem) async throws -> (jpgURL: URL, movURL: URL, mp4URL: URL) {
        guard let clipURL = item.livePhotoClipURL else {
            throw LivePhotoError.notLivePhoto
        }
        LivePhotoLog.shared.append("—— 开始处理第 \(item.id) 张实况 ——")
        // 1. Download the still (original first, 1080px fallback).
        let stillData: Data
        do {
            stillData = try await downloadImageData(from: item.imageURL)
            LivePhotoLog.shared.append("原图下载完成：\(stillData.count / 1024) KB")
        } catch {
            LivePhotoLog.shared.append("原图下载失败，改用 1080px 版本")
            do {
                stillData = try await downloadImageData(from: item.fallbackURL)
                LivePhotoLog.shared.append("1080px 图下载完成：\(stillData.count / 1024) KB")
            } catch {
                LivePhotoLog.shared.append("图片下载失败")
                throw LivePhotoError.downloadFailed
            }
        }
        guard let image = UIImage(data: stillData), let cgImage = image.cgImage else {
            LivePhotoLog.shared.append("图片解码失败")
            throw LivePhotoError.invalidImage
        }
        LivePhotoLog.shared.append("照片尺寸：\(cgImage.width)×\(cgImage.height)")
        // 2. Download the motion clip to a temp .mp4 file.
        let mp4URL: URL
        do {
            mp4URL = try await downloadVideoFile(from: clipURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: mp4URL.path)[.size] as? Int) ?? 0
            LivePhotoLog.shared.append("动图下载完成：\(size / 1024) KB")
        } catch {
            LivePhotoLog.shared.append("动图下载失败")
            throw LivePhotoError.downloadFailed
        }

        // 3. One shared content identifier for the still and the clip.
        let contentIdentifier = UUID().uuidString.uppercased()
        LivePhotoLog.shared.append("配对标识：\(contentIdentifier)")

        // 4. Write the tagged JPEG still and the transcoded + tagged .mov.
        let tempDir = FileManager.default.temporaryDirectory
        let base = UUID().uuidString
        let jpgURL = tempDir.appendingPathComponent(base + ".jpg")
        let movURL = tempDir.appendingPathComponent(base + ".mov")
        do {
            try writeJPEG(image: image, cgImage: cgImage, to: jpgURL,
                          contentIdentifier: contentIdentifier)
            LivePhotoLog.shared.append("照片已写入（系统写入 MakerNote）")
            try await transcodeLivePhotoVideo(inputURL: mp4URL, outputURL: movURL,
                                              contentIdentifier: contentIdentifier)
            let movSize = (try? FileManager.default.attributesOfItem(atPath: movURL.path)[.size] as? Int) ?? 0
            LivePhotoLog.shared.append("视频已生成：\(movSize / 1024) KB，标识已写入 moov>meta")
        } catch let error as LivePhotoError {
            LivePhotoLog.shared.append("处理失败：\(error.errorDescription ?? error.localizedDescription)")
            throw error
        } catch {
            LivePhotoLog.shared.append("处理失败：\(error.localizedDescription)")
            throw LivePhotoError.saveFailed
        }
        return (jpgURL, movURL, mp4URL)
    }

    // MARK: - Downloads

    /// Download image data from a URL and verify it decodes as an image.
    private static func downloadImageData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LivePhotoError.downloadFailed
        }
        guard UIImage(data: data) != nil else {
            throw LivePhotoError.invalidImage
        }
        return data
    }

    /// Download a video to a temp .mp4 file and return its URL.
    private static func downloadVideoFile(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LivePhotoError.downloadFailed
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            throw LivePhotoError.downloadFailed
        }
        return dest
    }

    // MARK: - Still (JPEG + MakerNote)

    /// Write the still as a plain JPEG (no EXIF metadata), then inject the
    /// EXIF MakerNote carrying the content identifier at the byte level.
    /// Byte-level injection is used because CGImageDestination's MakerNote
    /// Write the still as a JPEG and tag it with the shared content
    /// identifier, using the system ImageIO writer (CGImageDestination)
    /// instead of hand-built EXIF bytes. The properties dictionary
    /// carries the MakerNote in the official form —
    /// `kCGImagePropertyMakerAppleDictionary: ["17": <uuid>]` — and
    /// ImageIO writes the full EXIF itself (MakerNote as a binary
    /// plist in the Exif sub-IFD, plus PixelXDimension/PixelYDimension
    /// and the rest of the standard tags). This is the same approach
    /// the open-source glitter-live app uses, and it is the form
    /// Photos' own ImageIO is guaranteed to read. The previous builds
    /// hand-built a minimal EXIF APP1 segment byte by byte: exiftool
    /// and a Python parser read the MakerNote back correctly, but the
    /// minimal structure (only Orientation/Make/Model/ExifOffset/
    /// MakerNote) was never verified to be readable by Photos itself,
    /// and an unreadable still identifier would leave the still and
    /// the clip unpaired (3300) no matter how correct the video is.
    private static func writeJPEG(image: UIImage, cgImage: CGImage, to url: URL,
                                  contentIdentifier: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LivePhotoError.jpegEncodeFailed
        }
        let properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: 0.92,
            kCGImagePropertyOrientation as String: exifOrientation(for: image.imageOrientation),
            kCGImagePropertyMakerAppleDictionary as String: ["17": contentIdentifier],
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw LivePhotoError.jpegEncodeFailed
        }
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

    // MARK: - Byte helpers (big/little-endian)

    private static func appendBE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    /// Ask Photos itself whether the still + clip form a valid Live
    /// Photo, WITHOUT touching the library. PHLivePhoto.request only
    /// returns a Live Photo for a correctly paired still and movie
    /// (this is the validation the open-source glitter-live app uses:
    /// "Photos only returns a Live Photo for a correctly paired still
    /// and movie"). The result is logged and never blocks the save
    /// attempt: a passing validation with a failing save points at the
    /// save path/environment, while a failing validation points at the
    /// files themselves.
    private static func validatePair(jpgURL: URL, movURL: URL) async {
        let asset = AVURLAsset(url: movURL)
        let size = asset.tracks(withMediaType: .video).first?.naturalSize
            ?? CGSize(width: 1080, height: 1440)
        let gate = OnceGate()
        let result: String = await withCheckedContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [jpgURL, movURL],
                                placeholderImage: nil,
                                targetSize: size,
                                contentMode: .aspectFill) { livePhoto, info in
                // The handler can fire first with a degraded preview;
                // wait for the full result.
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                guard gate.claim() else { return }
                if let error = info[PHLivePhotoInfoErrorKey] as? NSError {
                    continuation.resume(returning: "失败：\(error.domain) \(error.code)：\(error.localizedDescription)")
                } else if livePhoto != nil {
                    continuation.resume(returning: "通过：相册认出这是一张实况照片")
                } else {
                    continuation.resume(returning: "失败：相册没有认出实况照片（无错误信息）")
                }
            }
            // Safety net: if Photos never calls back, don't hang the save.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard gate.claim() else { return }
                continuation.resume(returning: "超时：10 秒内相册没有回应")
            }
        }
        LivePhotoLog.shared.append("实况校验：\(result)")
    }

    /// One-shot gate: the result handler can fire several times, so only
    /// the first claim resumes the continuation.
    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }

    // MARK: - Save to Photos

    /// Save the still + clip as one Live Photo asset.
    /// Tries file URLs first, then Data as a fallback, and logs both
    /// results. The working open-source recipe (glitter-live) saves
    /// with file URLs — and that combination, file URLs + the
    /// system-written MakerNote still, was never tried: every earlier
    /// file-URL attempt used the hand-built EXIF still, and every Data
    /// attempt since the still was fixed used Data. The temp files are
    /// removed by the caller afterwards.
    private static func performSave(jpgURL: URL, movURL: URL) async throws {
        // Attempt 1: file URLs.
        do {
            LivePhotoLog.shared.append("正在保存到相册（文件方式）…")
            try await saveOnce(jpgURL: jpgURL, movURL: movURL, asData: false)
            LivePhotoLog.shared.append("相册保存成功 ✓（文件方式）")
            return
        } catch {
            LivePhotoLog.shared.append("文件方式失败：\(error.localizedDescription)")
        }
        // Attempt 2: Data.
        do {
            LivePhotoLog.shared.append("改用数据方式重试…")
            try await saveOnce(jpgURL: jpgURL, movURL: movURL, asData: true)
            LivePhotoLog.shared.append("相册保存成功 ✓（数据方式）")
        } catch {
            LivePhotoLog.shared.append("数据方式失败：\(error.localizedDescription)")
            throw error
        }
    }

    /// One performChanges save attempt, either with file URLs or with
    /// the files read into Data. Throws the exact Photos error.
    private static func saveOnce(jpgURL: URL, movURL: URL, asData: Bool) async throws {
        let jpgData: Data?
        let movData: Data?
        if asData {
            do {
                jpgData = try Data(contentsOf: jpgURL)
                movData = try Data(contentsOf: movURL)
            } catch {
                LivePhotoLog.shared.append("读取照片/视频文件失败")
                throw LivePhotoError.saveFailed
            }
            LivePhotoLog.shared.append("正在保存到相册（照片 \(jpgData!.count / 1024) KB + 视频 \(movData!.count / 1024) KB）…")
        } else {
            jpgData = nil
            movData = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                if asData {
                    request.addResource(with: .photo, data: jpgData!, options: nil)
                    request.addResource(with: .pairedVideo, data: movData!, options: nil)
                } else {
                    request.addResource(with: .photo, fileURL: jpgURL, options: nil)
                    request.addResource(with: .pairedVideo, fileURL: movURL, options: nil)
                }
            }, completionHandler: { success, error in
                if let error = error as NSError? {
                    continuation.resume(throwing: LivePhotoError.photosError(
                        domain: error.domain, code: error.code,
                        message: error.localizedDescription))
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LivePhotoError.saveFailed)
                }
            })
        }
    }
}

// MARK: - Video (.mov with content identifier + timed metadata)

extension LivePhotoSaver {

    /// Transcode the motion clip into a Live Photo .mov.
    /// Re-encodes with AVAssetWriter: H.264 High 4.1 first (the "Most
    /// Compatible" format), HEVC as a fallback if H.264 fails on the
    /// device. A straight remux (AVAssetExportSession Passthrough) was
    /// tried in run #39: the untouched original bitstream was rejected
    /// by Photos instantly (3300 in 2–50 ms), while the re-encoded
    /// video got as far as ~8s of conversion work in run #38 — so the
    /// re-encode is the better path and the remux is not used.
    private static func transcodeLivePhotoVideo(inputURL: URL, outputURL: URL,
                                                contentIdentifier: String) async throws {
        LivePhotoLog.shared.append("开始转码视频（H.264）…")
        do {
            try await transcodeVideo(inputURL: inputURL, outputURL: outputURL,
                                     contentIdentifier: contentIdentifier,
                                     codec: .h264)
            LivePhotoLog.shared.append("H.264 转码完成")
        } catch {
            // H.264 failed on this device; retry once with HEVC.
            LivePhotoLog.shared.append("H.264 转码失败，改用 HEVC 重试")
            try? FileManager.default.removeItem(at: outputURL)
            do {
                try await transcodeVideo(inputURL: inputURL, outputURL: outputURL,
                                         contentIdentifier: contentIdentifier,
                                         codec: .hevc)
                LivePhotoLog.shared.append("HEVC 转码完成")
            } catch {
                LivePhotoLog.shared.append("HEVC 转码也失败")
                throw LivePhotoError.videoEncodeFailed
            }
        }
    }

    /// Re-encode the clip with AVAssetWriter, then write the content
    /// identifier into the .mov byte by byte (moov > meta, iTunes/keys
    /// format — the same structure exiftool writes). The official
    /// `writer.metadata` API was used in the previous builds and was
    /// never verified to actually land the identifier in the file;
    /// the byte-injected form was verified on the VM to read back
    /// correctly with exiftool, so it is used instead.
    ///
    /// Deliberately NO timed-metadata tracks (live-photo-info /
    /// still-image-time): the previous build wrote them from iOS 17
    /// camera reference values, and Photos on iOS 15.1 still rejected
    /// the video with 3300 (videoConversionFailed). Plain Photos only
    /// needs the still and the video to share a content identifier;
    /// the tracks are a Lock Screen extra, not a pairing requirement.
    private static func transcodeVideo(inputURL: URL, outputURL: URL,
                                       contentIdentifier: String,
                                       codec: AVVideoCodecType) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw LivePhotoError.noVideoTrack
        }
        // h264/hevc need even dimensions; round down if the source is odd.
        let naturalSize = videoTrack.naturalSize
        let width = (Int(naturalSize.width) / 2) * 2
        let height = (Int(naturalSize.height) / 2) * 2
        guard width > 0, height > 0 else { throw LivePhotoError.noVideoTrack }
        let duration = videoTrack.timeRange.duration
        guard duration > .zero else { throw LivePhotoError.noVideoTrack }
        let fps = videoTrack.nominalFrameRate
        LivePhotoLog.shared.append("原动图：\(Int(naturalSize.width))×\(Int(naturalSize.height))，时长 \(String(format: "%.2f", duration.seconds)) 秒，帧率 \(String(format: "%.1f", fps))")

        // Reader: decode the source to yuv420p pixel buffers.
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LivePhotoError.videoEncodeFailed
        }
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(readerOutput)

        // Writer: content identifier via the official metadata API.
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw LivePhotoError.videoEncodeFailed
        }
        // NOTE: no writer.metadata here — the content identifier is
        // injected byte by byte after the write (see below).

        let bt709: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let videoSettings: [String: Any]
        if codec == .hevc {
            // 8-bit SDR HEVC Main: the Lock Screen rejects H.264, and
            // Photos flags 10-bit HDR output.
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: bt709,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]
        } else {
            // H.264 High profile, level 4.1. The source clip is 1080x1440
            // High 5.0; the previous build used Main 3.1, whose level
            // limit is 3600 macroblocks (1280x720) — a 1080x1440 frame
            // is 6075 macroblocks, so the re-encode was non-conformant
            // and Photos' converter rejected it (3300). Level 4.1
            // allows 8192 macroblocks and matches what the iPhone
            // camera writes for 1080p video.
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264High41,
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                ],
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = videoTrack.preferredTransform
        guard writer.canAdd(videoInput) else { throw LivePhotoError.videoEncodeFailed }
        writer.add(videoInput)

        guard writer.startWriting() else { throw LivePhotoError.videoEncodeFailed }
        writer.startSession(atSourceTime: .zero)

        reader.startReading()
        while let sample = readerOutput.copyNextSampleBuffer() {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard videoInput.append(sample) else {
                throw LivePhotoError.videoEncodeFailed
            }
        }
        if reader.status == .failed { throw LivePhotoError.videoEncodeFailed }
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LivePhotoError.videoEncodeFailed
        }
        // Write the content identifier into the finished .mov, byte by
        // byte, as a moov-level meta atom (see below).
        try injectMOVContentIdentifier(movURL: outputURL,
                                       contentIdentifier: contentIdentifier)
    }
}

// MARK: - MOV content identifier (byte-level)
//
// The identifier is injected into the .mov as moov > meta > keys + ilst
// (the iTunes/keys format exiftool and iOS expect), as a direct child of
// moov. Ported from the standalone 实况下载 app (v6/v14), where this
// exact byte layout was verified on the VM to read back with exiftool
// and to be byte-identical in structure to an exiftool-written .livp .mov.

extension LivePhotoSaver {

    /// Insert the content identifier as moov > meta > keys + ilst.
    /// If moov already has a meta, the identifier is merged into its
    /// keys/ilst instead. Before injecting, any `udta` atom is removed
    /// from moov: the writer leaves one carrying its own `meta`
    /// (encoder info), leaving two meta atoms in the file, which
    /// confuses Photos' video converter (PHPhotosErrorDomain 3300).
    /// A real iPhone Live Photo .mov has only the single moov-level meta.
    private static func injectMOVContentIdentifier(movURL: URL,
                                                   contentIdentifier: String) throws {
        var data: Data
        do {
            data = try Data(contentsOf: movURL)
        } catch {
            throw LivePhotoError.videoEncodeFailed
        }
        guard var moov = findChildAtom(in: data, range: 0..<data.count, type: "moov") else {
            throw LivePhotoError.videoEncodeFailed
        }
        // Remove any udta atom inside moov (and shrink moov accordingly).
        if let udta = findChildAtom(in: data, range: (moov.offset + 8)..<(moov.offset + moov.size), type: "udta") {
            data.removeSubrange(udta.offset..<(udta.offset + udta.size))
            setBE32(&data, at: moov.offset, value: UInt32(moov.size - udta.size))
            moov = (moov.offset, moov.size - udta.size)
        }
        let moovOff = moov.offset
        let moovSize = moov.size
        let moovEnd = moovOff + moovSize
        if let meta = findChildAtom(in: data, range: (moovOff + 8)..<moovEnd, type: "meta") {
            try mergeMOVIdentifier(&data, moovOff: moovOff, moovSize: moovSize,
                                   metaOff: meta.offset, metaSize: meta.size,
                                   contentIdentifier: contentIdentifier)
        } else {
            let metaAtom = buildMetaAtom(contentIdentifier: contentIdentifier)
            data.insert(contentsOf: metaAtom, at: moovEnd)
            setBE32(&data, at: moovOff, value: UInt32(moovSize + metaAtom.count))
        }
        do {
            try data.write(to: movURL, options: [.atomic])
        } catch {
            throw LivePhotoError.videoEncodeFailed
        }
    }

    /// Merge the identifier into an existing moov > meta atom.
    private static func mergeMOVIdentifier(_ data: inout Data, moovOff: Int, moovSize: Int,
                                           metaOff: Int, metaSize: Int,
                                           contentIdentifier: String) throws {
        let key = Array("com.apple.quicktime.content.identifier".utf8)
        let metaEnd = metaOff + metaSize
        // Resolve the 1-based key index for the content identifier.
        var index: UInt32 = 1
        var grownByKeys = 0
        if let keys = findChildAtom(in: data, range: (metaOff + 8)..<metaEnd, type: "keys") {
            let kOff = keys.offset
            let kSize = keys.size
            let kEnd = kOff + kSize
            let count = readBE32(data, at: kOff + 12)
            var p = kOff + 16
            var found: UInt32?
            for i in 0..<Int(count) {
                guard p + 8 <= kEnd else { break }
                let eSize = Int(readBE32(data, at: p))
                guard eSize >= 8, p + eSize <= kEnd else { break }
                let ns = Array(data[(p + 4)..<(p + 8)])
                let kstr = Array(data[(p + 8)..<(p + eSize)])
                if ns == Array("mdta".utf8) && kstr == key {
                    found = UInt32(i + 1)
                    break
                }
                p += eSize
            }
            if let found {
                index = found
            } else {
                index = count + 1
                var entry = Data()
                appendBE32(UInt32(8 + key.count), to: &entry)
                entry.append(contentsOf: Array("mdta".utf8))
                entry.append(contentsOf: key)
                data.insert(contentsOf: entry, at: kEnd)
                grownByKeys = entry.count
                setBE32(&data, at: kOff + 12, value: count + 1)
                setBE32(&data, at: kOff, value: UInt32(kSize + grownByKeys))
            }
        } else {
            // No keys atom: create one (our key as entry 1) after hdlr.
            var entry = Data()
            appendBE32(UInt32(8 + key.count), to: &entry)
            entry.append(contentsOf: Array("mdta".utf8))
            entry.append(contentsOf: key)
            var keysAtom = Data()
            appendBE32(UInt32(8 + 4 + 4 + entry.count), to: &keysAtom)
            keysAtom.append(contentsOf: Array("keys".utf8))
            appendBE32(0, to: &keysAtom)
            appendBE32(1, to: &keysAtom)
            keysAtom.append(entry)
            var insertAt = metaOff + 8
            if let hdlr = findChildAtom(in: data, range: (metaOff + 8)..<metaEnd, type: "hdlr") {
                insertAt = hdlr.offset + hdlr.size
            }
            data.insert(contentsOf: keysAtom, at: insertAt)
            grownByKeys = keysAtom.count
        }
        let item = buildIlstItem(contentIdentifier: contentIdentifier, index: index)
        let newMetaEnd = metaEnd + grownByKeys
        // Re-find ilst in the (possibly grown) data, so its offset is fresh.
        if let ilst = findChildAtom(in: data, range: (metaOff + 8)..<newMetaEnd, type: "ilst") {
            let iOff = ilst.offset
            let iSize = ilst.size
            let iEnd = iOff + iSize
            data.insert(contentsOf: item, at: iEnd)
            setBE32(&data, at: iOff, value: UInt32(iSize + item.count))
            setBE32(&data, at: metaOff, value: UInt32(metaSize + grownByKeys + item.count))
            setBE32(&data, at: moovOff, value: UInt32(moovSize + grownByKeys + item.count))
        } else {
            var ilstAtom = Data()
            appendBE32(UInt32(8 + item.count), to: &ilstAtom)
            ilstAtom.append(contentsOf: Array("ilst".utf8))
            ilstAtom.append(item)
            data.insert(contentsOf: ilstAtom, at: newMetaEnd)
            let grown = grownByKeys + ilstAtom.count
            setBE32(&data, at: metaOff, value: UInt32(metaSize + grown))
            setBE32(&data, at: moovOff, value: UInt32(moovSize + grown))
        }
    }

    /// meta atom in the iTunes/keys format (no version/flags word after the
    /// header): hdlr(32) + keys(62) + ilst(68) for a 36-char UUID.
    private static func buildMetaAtom(contentIdentifier: String) -> Data {
        let key = Array("com.apple.quicktime.content.identifier".utf8)
        // hdlr: 8 header + 4 ver/flags + 4 pre_defined + 4 "mdta" + 12 reserved.
        var hdlr = Data()
        appendBE32(32, to: &hdlr)
        hdlr.append(contentsOf: Array("hdlr".utf8))
        appendBE32(0, to: &hdlr)
        appendBE32(0, to: &hdlr)
        hdlr.append(contentsOf: Array("mdta".utf8))
        hdlr.append(contentsOf: [UInt8](repeating: 0, count: 12))
        // keys entry: size + "mdta" + key string.
        var entry = Data()
        appendBE32(UInt32(8 + key.count), to: &entry)
        entry.append(contentsOf: Array("mdta".utf8))
        entry.append(contentsOf: key)
        var keys = Data()
        appendBE32(UInt32(8 + 4 + 4 + entry.count), to: &keys)
        keys.append(contentsOf: Array("keys".utf8))
        appendBE32(0, to: &keys)
        appendBE32(1, to: &keys)
        keys.append(entry)
        // ilst with one indexed item.
        let item = buildIlstItem(contentIdentifier: contentIdentifier, index: 1)
        var ilst = Data()
        appendBE32(UInt32(8 + item.count), to: &ilst)
        ilst.append(contentsOf: Array("ilst".utf8))
        ilst.append(item)
        // meta: no version/flags word (unlike most atoms).
        var meta = Data()
        appendBE32(UInt32(8 + hdlr.count + keys.count + ilst.count), to: &meta)
        meta.append(contentsOf: Array("meta".utf8))
        meta.append(hdlr)
        meta.append(keys)
        meta.append(ilst)
        return meta
    }

    /// One indexed ilst item holding the identifier as UTF-8 text.
    private static func buildIlstItem(contentIdentifier: String, index: UInt32) -> Data {
        let uuid = Array(contentIdentifier.utf8)
        var dataAtom = Data()
        appendBE32(UInt32(8 + 4 + 4 + uuid.count), to: &dataAtom)
        dataAtom.append(contentsOf: Array("data".utf8))
        appendBE32(1, to: &dataAtom)
        appendBE32(0, to: &dataAtom)
        dataAtom.append(contentsOf: uuid)
        var item = Data()
        appendBE32(UInt32(8 + dataAtom.count), to: &item)
        appendBE32(index, to: &item)
        item.append(dataAtom)
        return item
    }

    /// Find the first child atom named `type` in `data[range]`.
    /// Returns (offset, size) or nil.
    private static func findChildAtom(in data: Data, range: Range<Int>,
                                      type: String) -> (offset: Int, size: Int)? {
        let typeBytes = Array(type.utf8)
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let size = Int(readBE32(data, at: p))
            guard size >= 8, p + size <= range.upperBound else { return nil }
            if Array(data[(p + 4)..<(p + 8)]) == typeBytes {
                return (p, size)
            }
            p += size
        }
        return nil
    }

    private static func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private static func setBE32(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }
}


/// 运行过程日志：实况保存/导出每一步都记一行（带时间），出错时
/// 把完整错误也记下来。App 内可以查看，也可以导出成 .txt 发出来检查。
/// 线程安全：保存流程在后台任务里跑，UI 在主线程读。
final class LivePhotoLog {
    static let shared = LivePhotoLog()

    private let lock = NSLock()
    private var lines: [String] = []

    private init() {}

    /// 记一行，前面带时:分:秒.毫秒。
    func append(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let stamp = formatter.string(from: Date())
        lock.lock()
        lines.append("[\(stamp)] \(message)")
        lock.unlock()
    }

    /// 清空全部日志。
    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    /// 全部日志文本（每行一条）。
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    /// 是否有内容。
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty
    }

    /// 把日志写成一个临时 .txt 文件，返回它的地址（供分享导出）。
    func exportURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("实况保存日志.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
