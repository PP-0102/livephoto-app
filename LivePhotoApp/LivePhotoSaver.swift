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
/// JPEG, then inject the EXIF MakerNote at the byte level. The motion clip
/// is an h264 mp4. It is RE-ENCODED with AVAssetWriter using the same
/// conservative parameters 红薯秀's FFmpeg pipeline uses (h264, Main
/// profile level 3.1, yuv420p, explicit 30 fps target): AVAssetExportSession
/// output was rejected by Photos' video converter (PHPhotosErrorDomain
/// 3300 = videoConversionFailed), while a clean libx264-style re-encode
/// is accepted. No audio track is added: 红薯秀's transcode has none
/// either, and its saves work, so a missing audio track is not the cause
/// of 3300. The content identifier is then injected at the byte level.
/// Both identifiers are written byte by byte (not via the system metadata
/// APIs, which do not reliably persist them), so Photos can pair the still
/// and the clip into one Live Photo asset.
struct LivePhotoSaver {

    /// Request add-only Photo Library access. This app only adds Live
    /// Photos to the library, so add-only is the correct level; asking
    /// for full read-write access made Photos reject the paired save
    /// (PHPhotosErrorDomain -1).
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

        // 5. Save as one Live Photo asset (.photo + .pairedVideo), passing
        // the file contents as Data so Photos can read the identifiers.
        try await performSave(jpgURL: jpgURL, movURL: movURL)
    }

    /// Save one item's still as a plain static photo (no Live Photo
    /// pairing, no video). This is the reliable fallback: a single .photo
    /// resource needs no content identifier and no video conversion, so
    /// it saves where the paired Live Photo save keeps failing.
    static func saveStaticImage(item: LivePhotoItem) async throws {
        let stillData: Data
        do {
            stillData = try await downloadData(from: item.stillURL)
        } catch {
            throw SaverError.downloadFailed
        }
        guard let image = UIImage(data: stillData), let cgImage = image.cgImage else {
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

    /// Build a .livp file (ZIP of the tagged JPEG still + tagged MOV clip
    /// sharing one content identifier) and return it as Data. A .livp is
    /// the format iOS itself uses for Live Photos; opening one in Files
    /// imports it as a real Live Photo. This is the fallback when the
    /// direct Photos save keeps failing.
    static func makeLivpData(item: LivePhotoItem) async throws -> Data {
        let (stillData, videoData) = try await download(item: item)
        guard let image = UIImage(data: stillData), let cgImage = image.cgImage else {
            throw SaverError.invalidImage
        }
        let contentIdentifier = UUID().uuidString.uppercased()
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
        let jpgData = try Data(contentsOf: jpgURL)
        let movData = try Data(contentsOf: movURL)
        let stem = "IMG_\(item.id)"
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

    /// Write the still as a plain JPEG (no EXIF metadata), then inject the
    /// EXIF MakerNote carrying the content identifier at the byte level.
    /// Byte-level injection is used because CGImageDestination's MakerNote
    /// metadata is not reliably written into the file, which left Photos
    /// unable to pair the still with the clip (PHPhotosErrorDomain -1).
    private static func writeJPEG(image: UIImage, cgImage: CGImage, to url: URL,
                                  contentIdentifier: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SaverError.jpegEncodeFailed
        }
        CGImageDestinationSetProperties(
            dest, [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary)
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SaverError.jpegEncodeFailed
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
            throw SaverError.jpegEncodeFailed
        }
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw SaverError.jpegEncodeFailed
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
            throw SaverError.jpegEncodeFailed
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

    /// Build the .mov for a Live Photo by RE-ENCODING the motion clip with
    /// AVAssetWriter, using the same conservative parameters 红薯秀's
    /// FFmpeg pipeline uses: h264, Main profile level 3.1, yuv420p pixel
    /// format, explicit 30 fps target, no audio track. AVAssetExportSession
    /// output (HighestQuality re-encode or Passthrough) was rejected by
    /// Photos' video converter (PHPhotosErrorDomain 3300 =
    /// videoConversionFailed); a clean re-encode with these parameters is
    /// what the working reference app produces. The content identifier is
    /// then injected at the byte level.
    private static func transcodeAndTagVideo(inputURL: URL, outputURL: URL,
                                             contentIdentifier: String) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw SaverError.videoRemuxFailed
        }
        // h264 needs even dimensions; round down if the source is odd.
        let naturalSize = videoTrack.naturalSize
        let width = (Int(naturalSize.width) / 2) * 2
        let height = (Int(naturalSize.height) / 2) * 2
        guard width > 0, height > 0 else { throw SaverError.videoRemuxFailed }

        // Reader: decode the source to yuv420p pixel buffers.
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw SaverError.videoRemuxFailed
        }
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(readerOutput)

        // Writer: h264, Main profile level 3.1, yuv420p, 30 fps target.
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw SaverError.videoRemuxFailed
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264Main31,
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = videoTrack.preferredTransform
        writer.add(writerInput)

        writer.startWriting()
        reader.startReading()
        writer.startSession(atSourceTime: .zero)

        // Copy frames from the reader to the writer until the clip ends.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "livephoto.writer")
            var finished = false
            writerInput.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(sample) {
                            finished = true
                            writer.cancelWriting()
                            continuation.resume(throwing: writer.error ?? SaverError.videoRemuxFailed)
                            return
                        }
                    } else {
                        // No more samples: end of clip, or the reader failed.
                        finished = true
                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(throwing: reader.error ?? SaverError.videoRemuxFailed)
                            return
                        }
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: writer.error ?? SaverError.videoRemuxFailed)
                            }
                        }
                        return
                    }
                }
                if reader.status == .failed {
                    finished = true
                    writer.cancelWriting()
                    continuation.resume(throwing: reader.error ?? SaverError.videoRemuxFailed)
                }
            }
        }
        try injectMOVContentIdentifier(movURL: outputURL,
                                       contentIdentifier: contentIdentifier)
    }

    /// Insert the content identifier as moov > meta > keys + ilst (the
    /// iTunes/keys format exiftool and iOS expect). The meta atom is a
    /// direct child of moov. If moov already has a meta, the identifier is
    /// merged into its keys/ilst instead.
    /// Before injecting, any `udta` atom is removed from moov: the export
    /// session writes one carrying its own `meta` (encoder info), leaving
    /// two meta atoms in the file, which confuses Photos' video converter
    /// (PHPhotosErrorDomain 3300). A real iPhone Live Photo .mov has only
    /// the single moov-level meta.
    private static func injectMOVContentIdentifier(movURL: URL,
                                                   contentIdentifier: String) throws {
        var data: Data
        do {
            data = try Data(contentsOf: movURL)
        } catch {
            throw SaverError.videoRemuxFailed
        }
        guard var moov = findChildAtom(in: data, range: 0..<data.count, type: "moov") else {
            throw SaverError.videoRemuxFailed
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
            throw SaverError.videoRemuxFailed
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
        var meta = Data()
        appendBE32(UInt32(8 + hdlr.count + keys.count + ilst.count), to: &meta)
        meta.append(contentsOf: Array("meta".utf8))
        meta.append(hdlr)
        meta.append(keys)
        meta.append(ilst)
        return meta
    }

    /// One indexed ilst item: size + 4-byte key index + data atom
    /// (type=1 UTF-8, locale=0, uuid string).
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
            throw SaverError.saveFailed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpgData, options: nil)
                request.addResource(with: .pairedVideo, data: movData, options: nil)
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
