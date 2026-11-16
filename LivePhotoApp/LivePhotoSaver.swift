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
///  2. The two timed-metadata tracks a real iPhone Live Photo video
///     carries: `live-photo-info` (one sample per video frame) and
///     `still-image-time` + `live-photo-still-image-transform` (one
///     sample at the cover frame). They were removed in run #31 on the
///     theory that Photos only needs the shared identifier — but that
///     was never tested with a verified still, and the validator kept
///     rejecting the pair with 3302 even after the still, the content
///     identifier and the video timing (no B-frames, no ctts) were all
///     verified correct. So the tracks are back: a plain video without
///     them may simply not count as a Live Photo video to Photos.
///     Layout and camera reference values come from the open-source
///     glitter-live app (measured on a real iPhone).
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
///     far as ~8s of conversion work in run #38. NO B-frames
///     (AllowFrameReordering false): with B-frames the encoder wrote
///     a ctts version 0 table with NEGATIVE composition offsets
///     (-23/-22 ticks, stored as 4294967273/4294967274), which any
///     strict reader sees as frames ~71 million seconds in the
///     future — the video was invalid, and Photos' validator rejected
///     it with 3302 in run #41 (found by inspecting the run #41 .livp
///     export on the VM; the source clip's own ctts has only positive
///     offsets, so the negative ones came from our re-encode). The
///     still was verified correct in that same inspection: the
///     CGImageDestination writes a genuine Apple iOS MakerNote
///     ("Apple iOS\0" + IFD, tag 17 = the UUID), matching the MOV's
///     content identifier exactly.
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
    /// The video also carries the two timed-metadata tracks a real
    /// iPhone Live Photo has (see LivePhotoMetadata): one
    /// live-photo-info sample per video frame, and one still-image-time
    /// sample at the cover frame (the middle of the clip). They were
    /// removed in run #31 and restored in run #43: the validator kept
    /// rejecting the pair with 3302 even after the still, the
    /// identifier and the video timing were all verified correct, so
    /// a plain video without these tracks may simply not count as a
    /// Live Photo video to Photos.
    ///
    /// The two timed-metadata tracks are written by LivePhotoMetadata
    /// below (adapted from the open-source glitter-live app).

    // MARK: - Live Photo timed-metadata tracks

    /// The two timed-metadata tracks a real iPhone Live Photo video
    /// carries. Layout and camera reference values come from
    /// glitter-live, which measured them on a real iPhone (via
    /// LivePaper). iOS rejects files whose setup values or per-frame
    /// payload differ from the camera's, so both are reproduced
    /// verbatim. Errors here are reported as videoEncodeFailed.
    private enum LivePhotoMetadata {
        private static let infoKey = "com.apple.quicktime.live-photo-info"
        // The doubled prefix matches what the camera writes.
        private static let infoDataType = "com.apple.quicktime.com.apple.quicktime.live-photo-info"
        private static let stillImageTimeKey = "com.apple.quicktime.still-image-time"
        private static let stillImageTransformKey = "com.apple.quicktime.live-photo-still-image-transform"

        /// QuickTime well-known data types.
        private static let rawDataType: UInt32 = 0
        private static let int8DataType: UInt32 = 0x41
        private static let float64MatrixDataType: UInt32 = 0x53

        /// `live-photo-info`: one sample per video frame.
        static func infoFormatDescription() throws -> CMFormatDescription {
            var dimensions = Data()
            dimensions.appendBigEndian(cameraDimensions.width)
            dimensions.appendBigEndian(cameraDimensions.height)
            let setup = Atom.make("cfgv", cameraSetupPlist) + Atom.make("dims", dimensions)
            let key = keyDeclaration(infoKey)
                + Atom.make("dtyp", reverseDNSType(infoDataType))
                + Atom.make("setu", setup)
                + Atom.make("ctps", Atom.make("dtyp", wellKnownType(rawDataType)))
            return try formatDescription(keys: Atom.make(keyID: 1, key))
        }

        /// `still-image-time` + `live-photo-still-image-transform`:
        /// one sample at the cover frame.
        static func stillFormatDescription() throws -> CMFormatDescription {
            let time = keyDeclaration(stillImageTimeKey) + Atom.make("dtyp", wellKnownType(int8DataType))
            let transform = keyDeclaration(stillImageTransformKey) + Atom.make("dtyp", wellKnownType(float64MatrixDataType))
            return try formatDescription(keys: Atom.make(keyID: 1, time) + Atom.make(keyID: 2, transform))
        }

        static func infoSample(format: CMFormatDescription, at time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
            try sample(Atom.make(keyID: 1, cameraInfoPayload), format: format, time: time, duration: duration)
        }

        /// `still-image-time` = -1 plus an identity transform.
        static func stillSample(format: CMFormatDescription, at time: CMTime) throws -> CMSampleBuffer {
            var identity = Data()
            for value in [1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0] { identity.appendBigEndian(value) }
            let payload = Atom.make(keyID: 1, Data([0xFF])) + Atom.make(keyID: 2, identity)
            return try sample(payload, format: format, time: time, duration: CMTime(value: 1, timescale: 600))
        }

        private static func keyDeclaration(_ key: String) -> Data {
            Atom.make("keyd", Data("mdta".utf8) + Data(key.utf8))
        }

        private static func wellKnownType(_ type: UInt32) -> Data {
            var data = Data()
            data.appendBigEndian(UInt32(0))
            data.appendBigEndian(type)
            return data
        }

        private static func reverseDNSType(_ type: String) -> Data {
            var data = Data()
            data.appendBigEndian(UInt32(1))
            data.append(Data(type.utf8))
            return data
        }

        /// A `mebx` sample description: 6 reserved bytes, data
        /// reference index 1, then the key table.
        private static func formatDescription(keys: Data) throws -> CMFormatDescription {
            var body = Data(count: 6)
            body.appendBigEndian(UInt16(1))
            body.append(Atom.make("keys", keys))
            let data = Atom.make("mebx", body)

            var description: CMFormatDescription?
            let status = data.withUnsafeBytes { buffer in
                CMMetadataFormatDescriptionCreateFromBigEndianMetadataDescriptionData(
                    allocator: kCFAllocatorDefault,
                    bigEndianMetadataDescriptionData: buffer.bindMemory(to: UInt8.self).baseAddress!,
                    size: data.count,
                    flavor: nil,
                    formatDescriptionOut: &description
                )
            }
            guard status == noErr, let description else { throw LivePhotoError.videoEncodeFailed }
            return description
        }

        private static func sample(_ bytes: Data, format: CMFormatDescription, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
            )
            guard status == noErr, let block else { throw LivePhotoError.videoEncodeFailed }
            status = bytes.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
            }
            guard status == noErr else { throw LivePhotoError.videoEncodeFailed }

            var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var size = bytes.count
            var sample: CMSampleBuffer?
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
            )
            guard status == noErr, let sample else { throw LivePhotoError.videoEncodeFailed }
            return sample
        }

        /// The camera's own capture size, kept as is whatever the
        /// actual video size.
        private static let cameraDimensions = (width: UInt32(1920), height: UInt32(1440))

        /// Binary plist naming iPhone OS 17.0 (21A5277h) and the
        /// capture framework versions.
        private static let cameraSetupPlist = Data(hex:
            "62706c6973743030d301020304050c5f10214c69766550686f746f4d65746164" +
            "61746153657475704461746156657273696f6e5d53797374656d56657273696f" +
            "6e5f10114672616d65776f726b56657273696f6e731001d3060708090a0b5f10" +
            "1350726f647563744275696c6456657273696f6e5b50726f647563744e616d65" +
            "5e50726f6475637456657273696f6e583231413532373768596950686f6e6520" +
            "4f535431372e30d40d0e0f10111213145a436f72654d6f74696f6e5d434d4361" +
            "7074757265436f72655e483130495350536572766963657359436f72654d6564" +
            "696158323836382e302e32573434362e352e335432302e325e333034352e3639" +
            "2e322e31312e340008000f0033004100550057005e00740080008f009800a200" +
            "a700b000bb00c900d800e200eb00f300f8000000000000020100000000000000" +
            "1500000000000000000000000000000107")

        /// One camera-info record, repeated in every frame as the
        /// camera does.
        private static let cameraInfoPayload = Data(hex:
            "03000000bdc36d3ce3b5eb6d800000007b80ad425a2d64410a08cb3e7feea6bd" +
            "79e9f63f000080400400ff000000000000000000000000000000000000000000" +
            "07000000525e873ee66e52bf1b2a6ac4d37862bf761ed23dde3f8ec313f52f39" +
            "b2f04439ff309dbf1a17f1ed1b070000206796ed1b0700000000000000000000" +
            "0000000000000000")
    }

    /// QuickTime atoms are `[size: UInt32][type: 4 bytes][payload]`.
    private enum Atom {
        static func make(_ fourCC: String, _ payload: Data) -> Data {
            var atom = Data()
            atom.appendBigEndian(UInt32(8 + payload.count))
            atom.append(Data(fourCC.utf8))
            atom.append(payload)
            return atom
        }

        /// Key tables and metadata samples use the local key ID in
        /// place of a four-character type.
        static func make(keyID: UInt32, _ payload: Data) -> Data {
            var atom = Data()
            atom.appendBigEndian(UInt32(8 + payload.count))
            atom.appendBigEndian(keyID)
            atom.append(payload)
            return atom
        }
    }

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
            // NO B-frames (AllowFrameReordering false): with B-frames
            // the encoder wrote a ctts version 0 table containing
            // NEGATIVE composition offsets (-23/-22 ticks, stored as
            // 4294967273/4294967274 — unsigned 32-bit), so any strict
            // reader sees frames scheduled ~71 million seconds in the
            // future and the video is invalid (this is what Photos'
            // validator rejected with 3302 in run #41, after the
            // still was verified correct). The source clip's own
            // ctts has only positive offsets — the negative ones were
            // introduced by our re-encode. Without B-frames there is
            // no reordering and no ctts at all.
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264High41,
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = videoTrack.preferredTransform
        guard writer.canAdd(videoInput) else { throw LivePhotoError.videoEncodeFailed }
        writer.add(videoInput)

        // Timed-metadata tracks (see LivePhotoMetadata): one
        // live-photo-info sample per video frame, and one
        // still-image-time sample at the cover frame.
        let infoFormat = try LivePhotoMetadata.infoFormatDescription()
        let stillFormat = try LivePhotoMetadata.stillFormatDescription()
        let infoInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: infoFormat)
        let stillInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: stillFormat)
        for input in [infoInput, stillInput] {
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw LivePhotoError.videoEncodeFailed }
            writer.add(input)
        }

        guard writer.startWriting() else { throw LivePhotoError.videoEncodeFailed }
        writer.startSession(atSourceTime: .zero)

        // Cover frame: the middle of the clip, in the 600 timescale
        // the camera uses. Never at 0 s (Photos rejects a still time
        // of 0) and never before 0.5 s.
        let stillSeconds = max(0.5, min(duration.seconds / 2, duration.seconds - 1.0 / 30.0))
        let stillTime = CMTime(seconds: stillSeconds, preferredTimescale: 600)
        guard stillInput.append(try LivePhotoMetadata.stillSample(format: stillFormat, at: stillTime)) else {
            throw LivePhotoError.videoEncodeFailed
        }
        stillInput.markAsFinished()

        reader.startReading()
        while let sample = readerOutput.copyNextSampleBuffer() {
            // Capture the frame's time before appending (the sample
            // is consumed by the video input).
            let frameTime = CMTimeConvertScale(
                CMSampleBufferGetPresentationTimeStamp(sample),
                timescale: 600, method: .roundHalfAwayFromZero)
            var frameDuration = CMSampleBufferGetDuration(sample)
            if frameDuration <= .zero || frameDuration == .invalid {
                frameDuration = CMTime(value: 1, timescale: 30)
            }
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard videoInput.append(sample) else {
                throw LivePhotoError.videoEncodeFailed
            }
            while !infoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard infoInput.append(try LivePhotoMetadata.infoSample(
                format: infoFormat, at: frameTime, duration: frameDuration)) else {
                throw LivePhotoError.videoEncodeFailed
            }
        }
        if reader.status == .failed { throw LivePhotoError.videoEncodeFailed }
        videoInput.markAsFinished()
        infoInput.markAsFinished()
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

/// Big-endian byte helpers for the Live Photo metadata atoms.
/// (Separate from LivePhotoSaver's own appendBE32 etc., which are
/// static methods on that struct.)
private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: Double) {
        Swift.withUnsafeBytes(of: value.bitPattern.bigEndian) { append(contentsOf: $0) }
    }
}
