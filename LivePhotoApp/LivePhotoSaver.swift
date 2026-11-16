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
/// This is the part that failed in the standalone 实况下载 app (v1–v14).
/// The difference here, taken from the open-source glitter-live recipe
/// (which ships a working Live Photo writer):
///  1. The content identifier is written with the official API —
///     `AVAssetWriter.metadata` with a `.quickTimeMetadataContentIdentifier`
///     item — instead of byte-injecting a meta atom after the encode.
///     The byte-injected meta is what Photos' video converter kept
///     rejecting (PHPhotosErrorDomain 3300 = videoConversionFailed).
///  2. The video is HEVC (8-bit SDR, BT.709), not H.264 — the Lock Screen
///     rejects H.264 Live Photos, and HEVC matches what the iPhone camera
///     writes. Falls back to H.264 if HEVC fails on the device.
///  3. Two timed-metadata tracks are written into the .mov, exactly as
///     the camera does: `live-photo-info` (one sample per frame) and
///     `still-image-time` + `live-photo-still-image-transform` (one sample
///     at the cover frame, in the 600 timescale, never at 0 s). Without
///     them the file is a plain video with an identifier, not a Live Photo.
///  4. The still's MakerNote is written byte by byte (binary plist
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
    /// TIFF is little-endian, IFD0 has Orientation + MakerNote.
    private static func buildEXIFSegment(contentIdentifier: String,
                                         orientation: Int) -> Data {
        let plist = makerNotePlist(contentIdentifier: contentIdentifier)
        var tiff = Data()
        tiff.append(contentsOf: [0x49, 0x49])              // "II" little-endian
        tiff.append(contentsOf: [0x2A, 0x00])              // magic 42
        appendLE32(8, to: &tiff)                           // IFD0 offset
        let ifdSize = 2 + 2 * 12 + 4
        let makerOffset = UInt32(8 + ifdSize)              // offset from TIFF start
        appendLE16(2, to: &tiff)                           // 2 entries
        // Orientation: tag 0x0112, type SHORT(3), count 1, value inline.
        appendLE16(0x0112, to: &tiff)
        appendLE16(3, to: &tiff)
        appendLE32(1, to: &tiff)
        appendLE32(UInt32(orientation), to: &tiff)
        // MakerNote: tag 0x927C, type UNDEFINED(7), count=len, value=offset.
        appendLE16(0x927C, to: &tiff)
        appendLE16(7, to: &tiff)
        appendLE32(UInt32(plist.count), to: &tiff)
        appendLE32(makerOffset, to: &tiff)
        appendLE32(0, to: &tiff)                           // next IFD = 0
        tiff.append(plist)
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

    /// One creation request with both resources, passed as Data.
    /// Data is used (not file URLs) because with file URLs Photos could
    /// not validate the shared content identifier (PHPhotosErrorDomain
    /// -1); passing the bytes as Data lets Photos read the identifiers
    /// and pair the still with the clip. The temp files are read here
    /// and can be removed by the caller afterwards.
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
    /// Tries HEVC first (what the iPhone camera writes); falls back to
    /// H.264 if HEVC fails on the device.
    private static func transcodeLivePhotoVideo(inputURL: URL, outputURL: URL,
                                                contentIdentifier: String) async throws {
        do {
            try await transcodeVideo(inputURL: inputURL, outputURL: outputURL,
                                     contentIdentifier: contentIdentifier,
                                     codec: .hevc)
        } catch {
            // HEVC failed on this device; retry once with H.264.
            try? FileManager.default.removeItem(at: outputURL)
            do {
                try await transcodeVideo(inputURL: inputURL, outputURL: outputURL,
                                         contentIdentifier: contentIdentifier,
                                         codec: .h264)
            } catch {
                throw LivePhotoError.videoEncodeFailed
            }
        }
    }

    /// Re-encode the clip with AVAssetWriter, writing the content
    /// identifier through the official `writer.metadata` API and adding
    /// the two timed-metadata tracks the camera writes (see
    /// LivePhotoMetadata below). The still time is the middle of the
    /// clip, snapped to a frame, in the 600 timescale, never at 0 s.
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
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264Main31,
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                ],
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = videoTrack.preferredTransform

        // Timed-metadata tracks (see LivePhotoMetadata).
        let infoFormat = try LivePhotoMetadata.infoFormatDescription()
        let stillFormat = try LivePhotoMetadata.stillFormatDescription()
        let infoInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                           sourceFormatHint: infoFormat)
        let stillInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                            sourceFormatHint: stillFormat)
        for input in [videoInput, infoInput, stillInput] {
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw LivePhotoError.videoEncodeFailed }
            writer.add(input)
        }

        let frameDuration = CMTime(value: 1, timescale: 30)
        let stillTime = stillTimeForClip(duration: duration)

        guard writer.startWriting() else { throw LivePhotoError.videoEncodeFailed }
        writer.startSession(atSourceTime: .zero)

        // The still-image-time sample goes in first, at the cover frame.
        guard stillInput.append(try LivePhotoMetadata.stillSample(
            format: stillFormat, at: stillTime)) else {
            throw LivePhotoError.videoEncodeFailed
        }
        stillInput.markAsFinished()

        reader.startReading()
        while let sample = readerOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard videoInput.append(sample) else {
                throw LivePhotoError.videoEncodeFailed
            }
            // One live-photo-info sample per frame, at the frame's time.
            let info = try LivePhotoMetadata.infoSample(
                format: infoFormat, at: pts, duration: frameDuration)
            while !infoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard infoInput.append(info) else {
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
    }

    /// Cover-frame time: the middle of the clip, at least 0.5 s in (the
    /// Lock Screen rejects a cover earlier than ~0.33 s), snapped down to
    /// a frame boundary, in the 600 timescale Apple uses, never at 0.
    private static func stillTimeForClip(duration: CMTime) -> CMTime {
        let frameRate: Double = 30
        var seconds = max(0.5, duration.seconds / 2)
        seconds = min(seconds, duration.seconds - 1.0 / frameRate)
        let totalFrames = Int((duration.seconds * frameRate).rounded(.down))
        let frameIndex = max(1, min(Int((seconds * frameRate).rounded(.down)),
                                    totalFrames - 1))
        return CMTimeConvertScale(CMTime(value: CMTimeValue(frameIndex), timescale: 30),
                                  timescale: 600, method: .roundHalfAwayFromZero)
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

// MARK: - Timed metadata tracks
//
// The two timed-metadata tracks a real iPhone Live Photo .mov carries.
// Ported from glitter-live (github.com/BuddhaNag12/glitter-live), whose
// layout and camera reference values come from LivePaper's measurements
// on a real iPhone (github.com/Yuyang16Z/LivePaper, MIT). Apple doesn't
// document these; iOS rejects files whose setup values or per-frame
// payload differ from the camera's, so both are reproduced verbatim.

enum LivePhotoMetadata {
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

    /// `still-image-time` + `live-photo-still-image-transform`: one sample at the cover frame.
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

    // MARK: Encoding

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

    /// A `mebx` sample description: 6 reserved bytes, data reference index 1, then the key table.
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

    // MARK: Camera reference values

    /// The camera's own capture size, kept as is whatever the actual video size.
    private static let cameraDimensions = (width: UInt32(1920), height: UInt32(1440))

    /// Binary plist naming iPhone OS 17.0 (21A5277h) and the capture framework versions.
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

    /// One camera-info record, repeated in every frame as the camera does.
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

    /// Key tables and metadata samples use the local key ID in place of a four-character type.
    static func make(keyID: UInt32, _ payload: Data) -> Data {
        var atom = Data()
        atom.appendBigEndian(UInt32(8 + payload.count))
        atom.appendBigEndian(keyID)
        atom.append(payload)
        return atom
    }
}

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
