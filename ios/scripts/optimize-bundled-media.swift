// Re-encodes the oversized bundled exercise clips before the app is built (build Mac only).
// The repo keeps the original files. A clip is touched only when its H.264 video runs above
// 2 Mbps (the 1080p studio clips); the lean 960 px clips are left alone. Each one becomes HEVC
// at the same size, frame rate and orientation, and replaces the original only when the new file
// opens, lasts as long, has the same size and is at least 25% smaller. Never fails the build.
//
// Usage: xcrun swift ios/scripts/optimize-bundled-media.swift [ExerciseVideos directory]
import AVFoundation
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "ios/Sources/ZeroOne/Resources/ExerciseVideos")
let thresholdBitsPerSecond: Float = 2_000_000
// HEVC at 1.8 Mbps matches H.264 at roughly 3 to 3.5 Mbps for this kind of footage.
let targetBitsPerSecond = 1_800_000

enum Skip: Error { case notOversized, hasAudio, noVideo, failed(String) }

func bytes(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

func transcode(_ source: URL, to output: URL) async throws -> (CGSize, Double) {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Skip.noVideo }
    let audio = try await asset.loadTracks(withMediaType: .audio)
    if !audio.isEmpty { throw Skip.hasAudio }
    let (size, transform, rate, fps) = try await track.load(.naturalSize, .preferredTransform,
                                                            .estimatedDataRate, .nominalFrameRate)
    let duration = try await asset.load(.duration).seconds
    guard rate > thresholdBitsPerSecond else { throw Skip.notOversized }

    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ])
    readerOutput.alwaysCopiesSampleData = false
    reader.add(readerOutput)

    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: targetBitsPerSecond,
            AVVideoExpectedSourceFrameRateKey: max(1, Int(fps.rounded())),
        ],
    ])
    input.expectsMediaDataInRealTime = false
    input.transform = transform
    writer.add(input)

    guard reader.startReading() else { throw Skip.failed("reader: \(String(describing: reader.error))") }
    guard writer.startWriting() else { throw Skip.failed("writer: \(String(describing: writer.error))") }
    var started = false
    while let sample = readerOutput.copyNextSampleBuffer() {
        if !started {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
            started = true
        }
        while !input.isReadyForMoreMediaData { usleep(2_000) }
        guard input.append(sample) else { throw Skip.failed("append: \(String(describing: writer.error))") }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard reader.status == .completed, writer.status == .completed else {
        throw Skip.failed("status: \(String(describing: reader.error ?? writer.error))")
    }
    return (size, duration)
}

func verify(_ output: URL, size: CGSize, duration: Double) async throws -> Bool {
    let asset = AVURLAsset(url: output)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
    let (outSize, formats) = try await track.load(.naturalSize, .formatDescriptions)
    let outDuration = try await asset.load(.duration).seconds
    let isHEVC = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
    return isHEVC && outSize == size && abs(outDuration - duration) <= 0.2
}

// --self-test: writes a 2 s 1920x1080 H.264 clip at 8 Mbps and checks that it gets re-encoded.
// Used by the public compile check, which has only empty placeholder clips.
func writeTestClip(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw Skip.failed("test writer") }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<60 {
        while !input.isReadyForMoreMediaData { usleep(2_000) }
        guard let pool = adaptor.pixelBufferPool else { throw Skip.failed("test pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw Skip.failed("test buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        arc4random_buf(CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
            throw Skip.failed("test append: \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw Skip.failed("test finish: \(String(describing: writer.error))") }
}

if CommandLine.arguments.contains("--self-test") {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let clip = folder.appendingPathComponent("test.mp4"), output = folder.appendingPathComponent("out.mp4")
    try await writeTestClip(to: clip)
    let (size, duration) = try await transcode(clip, to: output)
    let ok = try await verify(output, size: size, duration: duration)
    print("self-test: \(bytes(clip)) -> \(bytes(output)) bytes, HEVC and checks \(ok ? "pass" : "FAIL")")
    exit(ok && bytes(output) < bytes(clip) ? 0 : 1)
}

let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
    .filter { $0.pathExtension.lowercased() == "mp4" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
var totalBefore = 0, totalAfter = 0, replaced = 0, kept = 0
for file in files {
    let before = bytes(file)
    totalBefore += before
    guard before > 0 else { totalAfter += before; continue }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
        let (size, duration) = try await transcode(file, to: temporary)
        let after = bytes(temporary)
        guard try await verify(temporary, size: size, duration: duration), after > 0,
              Double(after) <= Double(before) * 0.75 else {
            print("kept \(file.lastPathComponent): new file failed the checks (\(before) -> \(after) bytes)")
            kept += 1; totalAfter += before; continue
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        print("hevc \(file.lastPathComponent): \(before / 1024) KB -> \(after / 1024) KB")
        replaced += 1; totalAfter += after
    } catch Skip.notOversized {
        totalAfter += before
    } catch {
        print("kept \(file.lastPathComponent): \(error)")
        kept += 1; totalAfter += before
    }
}
print("Exercise videos: \(replaced) re-encoded, \(kept) kept as they were; "
    + "\(totalBefore / 1_048_576) MB -> \(totalAfter / 1_048_576) MB")
