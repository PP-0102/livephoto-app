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
/// (errors -1 and 3300). The first build inside this app used the
/// glitter-live recipe (HEVC + writer.metadata + live-photo-info /
/// still-image-time tracks) and STILL failed with 3300 on all 7 photos
/// of the test note (2026-11-16). What changed for this build:
///  1. The content identifier is still written with the official API —
///     `AVAssetWriter.metadata` with a `.quickTimeMetadataContentIdentifier`
///     item — not byte-injected.
///  2. NO timed-metadata tracks. The iOS 17 camera reference values the
///     tracks were built from are the prime suspect for 3300 on iOS 15.1:
///     Photos' video converter has to process every track, and plain
///     Photos only needs the shared identifier to pair still + video.
///  3. H.264 first (the "Most Compatible" format), HEVC only as a
///     fallback if H.264 encoding fails on the device. The H.264
///     profile/level MUST fit the frame: the source clip is 1080x1440
///     High 5.0, and Main 3.1 (used in the previous build) caps at
///     3600 macroblocks — a 1080x1440 frame is 6075, so that re-encode
///     was non-conformant and Photos' converter rejected it with 3300
///     (confirmed on the VM: libx264 reports "frame MB size (68x90) >
///     level limit (3600)"). High 4.1 is used instead.
///  4. The save passes both files as Data. File URLs were tried in
///     every build and always failed with -1, so they are not attempted.
///  5. The still's MakerNote is written byte by byte (binary plist
///     {17: <uuid>}) — verified on the VM to parse back correctly, and
///     verified on a real file the old app exported.
struct LivePhotoSaver {

    /// Request add-only Photo Library access. This app only adds photos
    /// to the library, so add-only is the correct level; asking for full
    /// read-write access made Photos reject the paired save (-1).
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Save one Live Photo item to the Photos library.
    /// The still is downloaded at original quality first (falling back to
    /// the 1080px web version); the motion clip is the note's mp4.
    static func saveLivePhoto(item: ImageItem) async throws {
        guard let clipURL = item.livePhotoClipURL else {
            throw LivePhotoError.notLivePhoto
        }
        // 1. Download the still (original first, 1080px fallback).
        let stillData: Data
        do {
            stillData = try await downloadImageData(from: item.imageURL)
        } catch {
            do {
                stillData = try await downloadImageData(from: item.fallbackURL)
            } catch {
                throw LivePhotoError.downloadFailed
            }
        }
        guard let image = UIImage(data: stillData), let cgImage = image.cgImage else {
            throw LivePhotoError.invalidImage
        }
        // 2. Download the motion clip to a temp .mp4 file.
        let mp4URL: URL
        do {
            mp4URL = try await downloadVideoFile(from: clipURL)
        } catch {
            throw LivePhotoError.downloadFailed
        }

        // 3. One shared content identifier for the still and the clip.
        let contentIdentifier = UUID().uuidString.uppercased()

        // 4. Write the tagged JPEG still and the transcoded + tagged .mov.
        let tempDir = FileManager.default.temporaryDirectory
        let base = UUID().uuidString
        let jpgURL = tempDir.appendingPathComponent(base + ".jpg")
        let movURL = tempDir.appendingPathComponent(base + ".mov")
        defer {
            try? FileManager.default.removeItem(at: jpgURL)
            try? FileManager.default.removeItem(at: mp4URL)
            try? FileManager.default.removeItem(at: movURL)
        }
        do {
            try writeJPEG(image: image, cgImage: cgImage, to: jpgURL,
                          contentIdentifier: contentIdentifier)
            try await transcodeLivePhotoVideo(inputURL: mp4URL, outputURL: movURL,
                                              contentIdentifier: contentIdentifier)
        } catch let error as LivePhotoError {
            throw error
        } catch {
            throw LivePhotoError.saveFailed
        }

        // 5. Save as one Live Photo asset (.photo + .pairedVideo), passing
        // the file contents as Data so Photos can read the identifiers.
        // (File URLs made Photos reject the pair with error -1.)
        try await performSave(jpgURL: jpgURL, movURL: movURL)
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
    /// metadata is not reliably written into the file, which left Photos
    /// unable to pair the still with the clip (PHPhotosErrorDomain -1).
    private static func writeJPEG(image: UIImage, cgImage: CGImage, to url: URL,
                                  contentIdentifier: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LivePhotoError.jpegEncodeFailed
        }
        CGImageDestinationSetProperties(
            dest, [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary)
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw LivePhotoError.jpegEncodeFailed
        }
        try injectEXIFMakerNote(jpgURL: url, contentIdentifier: contentIdentifier,
                                orientation: exifOrientation(for: image.imageOrientation))
    }

    /// Inject a minimal EXIF APP1 segment (little-endian TIFF) right after
    /// the JPEG SOI marker. Contains Orientation + MakerNote (binary plist
    /// {17: <uuid>}). Any pre-existing EXIF APP1 segment is stripped first
    /// so the file never ends up with two.
    private static func injectEXIFMakerNote(jpgURL: URL, contentIdentifier: String,
                                            orientation: Int) throws {
        var data: Data
        do {
            data = try Data(contentsOf: jpgURL)
        } catch {
            throw LivePhotoError.jpegEncodeFailed
        }
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw LivePhotoError.jpegEncodeFailed
        }
        // Strip any existing APP1/Exif segment, keep everything else.
        // Stop at SOS (0xDA): after it comes compressed scan data, which
        // can contain 0xFF bytes that are not segment markers, so the rest
        // of the file (SOS header + scan + EOI) is copied verbatim.
        var body = Data()
        var pos = 2
        while pos < data.count {
            if data[pos] != 0xFF {
                body.append(data[pos...])
                break
            }
            let marker = data[pos + 1]
            if marker == 0xD8 || marker == 0xD9 || marker == 0xDA
                || (0xD0...0xD7).contains(marker) {
                body.append(data[pos...])
                break
            }
            guard pos + 4 <= data.count else { break }
            let segLen = Int(readBE16(data, at: pos + 2))
            guard segLen >= 2, pos + 2 + segLen <= data.count else { break }
            let isExif = marker == 0xE1 && segLen >= 8
                && data[pos + 4] == 0x45 && data[pos + 5] == 0x78
                && data[pos + 6] == 0x69 && data[pos + 7] == 0x66
            if !isExif {
                body.append(data[pos..<(pos + 2 + segLen)])
            }
            pos += 2 + segLen
        }
        let exifSeg = buildEXIFSegment(contentIdentifier: contentIdentifier,
                                       orientation: orientation)
        var out = Data()
        out.append(contentsOf: [0xFF, 0xD8])
        out.append(exifSeg)
        out.append(body)
        do {
            try out.write(to: jpgURL, options: [.atomic])
        } catch {
            throw LivePhotoError.jpegEncodeFailed
        }
    }

    /// Full APP1 segment bytes (FF E1 marker + length + "Exif\0\0" + TIFF).
    /// TIFF is little-endian. The MakerNote MUST live in the Exif
    /// sub-IFD (IFD0 -> tag 0x8769 ExifOffset -> Exif IFD -> tag 0x927C),
    /// exactly as a real iPhone JPEG does, and IFD0 must carry
    /// Make "Apple" so parsers interpret the note as Apple's binary
    /// plist. The previous build put the MakerNote directly in IFD0
    /// with no Make tag: the bytes were valid (the binary plist parsed
    /// back to {17: uuid}), but exiftool reported it as "Unrecognized
    /// MakerNotes" and Photos could not read the content identifier
    /// from the still at all — so the still and the clip never paired,
    /// and every Live Photo save failed with 3300.
    private static func buildEXIFSegment(contentIdentifier: String,
                                         orientation: Int) -> Data {
        let plist = makerNotePlist(contentIdentifier: contentIdentifier)
        let makeData = Data("Apple\0".utf8)    // 6 bytes, stored out of line
        let modelData = Data("iPhone\0".utf8)  // 7 bytes, stored out of line
        // Layout (offsets from TIFF start):
        // header 8; IFD0 at 8 with 4 entries (2 + 48 + 4 = 54) -> ends 62;
        // Exif IFD at 62 with 1 entry (2 + 12 + 4 = 18) -> ends 80;
        // MakerNote data at 80; Make string after it; Model string last.
        let exifIFDOffset = UInt32(8 + 2 + 4 * 12 + 4)
        let makerNoteOffset = exifIFDOffset + UInt32(2 + 12 + 4)
        let makeOffset = makerNoteOffset + UInt32(plist.count)
        let modelOffset = makeOffset + UInt32(makeData.count)
        var tiff = Data()
        tiff.append(contentsOf: [0x49, 0x49])              // "II" little-endian
        tiff.append(contentsOf: [0x2A, 0x00])              // magic 42
        appendLE32(8, to: &tiff)                           // IFD0 offset
        // IFD0: 4 entries.
        appendLE16(4, to: &tiff)
        // Orientation: tag 0x0112, type SHORT(3), count 1, value inline.
        appendLE16(0x0112, to: &tiff)
        appendLE16(3, to: &tiff)
        appendLE32(1, to: &tiff)
        appendLE32(UInt32(orientation), to: &tiff)
        // Make: tag 0x010F, type ASCII(2), count 6, value = offset.
        appendLE16(0x010F, to: &tiff)
        appendLE16(2, to: &tiff)
        appendLE32(UInt32(makeData.count), to: &tiff)
        appendLE32(makeOffset, to: &tiff)
        // Model: tag 0x0110, type ASCII(2), count 7, value = offset.
        appendLE16(0x0110, to: &tiff)
        appendLE16(2, to: &tiff)
        appendLE32(UInt32(modelData.count), to: &tiff)
        appendLE32(modelOffset, to: &tiff)
        // ExifOffset: tag 0x8769, type LONG(4), count 1, value = Exif IFD offset.
        appendLE16(0x8769, to: &tiff)
        appendLE16(4, to: &tiff)
        appendLE32(1, to: &tiff)
        appendLE32(exifIFDOffset, to: &tiff)
        appendLE32(0, to: &tiff)                           // next IFD = 0
        // Exif IFD: 1 entry.
        appendLE16(1, to: &tiff)
        // MakerNote: tag 0x927C, type UNDEFINED(7), count=len, value=offset.
        appendLE16(0x927C, to: &tiff)
        appendLE16(7, to: &tiff)
        appendLE32(UInt32(plist.count), to: &tiff)
        appendLE32(makerNoteOffset, to: &tiff)
        appendLE32(0, to: &tiff)                           // next IFD = 0
        tiff.append(plist)
        tiff.append(makeData)
        tiff.append(modelData)
        var payload = Data()
        payload.append(contentsOf: [0x45, 0x78, 0x69, 0x66, 0x00, 0x00])  // "Exif\0\0"
        payload.append(tiff)
        var seg = Data()
        seg.append(contentsOf: [0xFF, 0xE1])
        appendBE16(UInt16(payload.count + 2), to: &seg)    // length incl. itself
        seg.append(payload)
        return seg
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

    private static func appendBE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

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

    private static func readBE16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    // MARK: - Save to Photos

    /// Save the still + clip as one Live Photo asset, passing both
    /// files as Data. File URLs were tried in every build and always
    /// failed with PHPhotosErrorDomain -1 (Photos cannot validate the
    /// shared content identifier from file URLs), so only Data is used.
    /// The temp files are read here and can be removed by the caller
    /// afterwards.
    private static func performSave(jpgURL: URL, movURL: URL) async throws {
        let jpgData: Data
        let movData: Data
        do {
            jpgData = try Data(contentsOf: jpgURL)
            movData = try Data(contentsOf: movURL)
        } catch {
            throw LivePhotoError.saveFailed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpgData, options: nil)
                request.addResource(with: .pairedVideo, data: movData, options: nil)
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
    /// Tries H.264 first (the most widely accepted format — what the
    /// iPhone writes in "Most Compatible" mode); falls back to HEVC if
    /// H.264 fails on the device.
    private static func transcodeLivePhotoVideo(inputURL: URL, outputURL: URL,
                                                contentIdentifier: String) async throws {
        do {
            try await transcodeVideo(inputURL: inputURL, outputURL: outputURL,
                                     contentIdentifier: contentIdentifier,
                                     codec: .h264)
        } catch {
            // H.264 failed on this device; retry once with HEVC.
            try? FileManager.default.removeItem(at: outputURL)
            do {
                try await transcodeVideo(inputURL: inputURL, outputURL: outputURL,
                                         contentIdentifier: contentIdentifier,
                                         codec: .hevc)
            } catch {
                throw LivePhotoError.videoEncodeFailed
            }
        }
    }

    /// Re-encode the clip with AVAssetWriter, writing the content
    /// identifier through the official `writer.metadata` API.
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
        writer.metadata = [contentIdentifierItem(contentIdentifier)]

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
    }

    /// The content identifier as an official QuickTime metadata item.
    private static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = identifier as NSString
        return item
    }
}

