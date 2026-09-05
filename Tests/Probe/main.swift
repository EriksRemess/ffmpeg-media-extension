import AVFoundation
import CoreMedia
import Darwin
import ExtensionFoundation
import Foundation
import MediaToolbox
import VideoToolbox

// This API is marked CF_REFINED_FOR_SWIFT but the SDK does not currently
// expose a Swift overlay spelling for it.  Its C ABI is stable and public.
@_silgen_name("VTCopyVideoDecoderExtensionProperties")
private func copyVideoDecoderExtensionProperties(
    _ formatDescription: CMFormatDescription,
    _ properties: UnsafeMutablePointer<CFDictionary?>
) -> OSStatus

setbuf(stdout, nil)
MTRegisterProfessionalVideoWorkflowFormatReaders()
VTRegisterProfessionalVideoWorkflowVideoDecoders()
Thread.sleep(forTimeInterval: 0.5)

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: media-probe FILE...\n".utf8))
    exit(64)
}

func fourCC(_ value: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
    ]
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08x", value)
}

func decoderExtensionStatus(_ description: CMFormatDescription) -> String {
    var extensionProperties: CFDictionary?
    let status = copyVideoDecoderExtensionProperties(description, &extensionProperties)
    return "status=\(status) properties=\(String(describing: extensionProperties))"
}

let ffmpegVP9CodecType = FourCharCode(0x46565039) // FVP9
for codecType in [ffmpegVP9CodecType, kCMVideoCodecType_VP9, kCMVideoCodecType_AV1, kCMVideoCodecType_MPEG2Video] {
    var description: CMVideoFormatDescription?
    let createStatus = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codecType,
        width: 16,
        height: 16,
        extensions: nil,
        formatDescriptionOut: &description)
    if createStatus == noErr, let description {
        print("DECODER subtype=\(fourCC(codecType)) \(decoderExtensionStatus(description))")
    } else {
        print("DECODER subtype=\(fourCC(codecType)) description-status=\(createStatus)")
    }
}

func probe(_ path: String) async throws {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.load(.tracks)
    var probeStart = Double(ProcessInfo.processInfo.environment["FME_PROBE_START"] ?? "0") ?? 0
    let isEndProbe = ProcessInfo.processInfo.environment["FME_PROBE_END_OFFSET"] != nil
    if let endOffsetText = ProcessInfo.processInfo.environment["FME_PROBE_END_OFFSET"],
       let endOffset = Double(endOffsetText), endOffset >= 0,
       let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
        let videoRange = try await videoTrack.load(.timeRange)
        probeStart = max(CMTimeGetSeconds(videoRange.end) - endOffset, 0)
    }
    let requestedMediaType = ProcessInfo.processInfo.environment["FME_PROBE_MEDIA_TYPE"]
    let explicitWindow = ProcessInfo.processInfo.environment["FME_PROBE_SECONDS"].flatMap(Double.init)
    print("ASSET \(url.lastPathComponent) duration=\(String(format: "%.3f", CMTimeGetSeconds(duration))) tracks=\(tracks.count)")

    for mediaType in [AVMediaType.video, AVMediaType.audio] {
        let matchingTracks = tracks.filter { $0.mediaType == mediaType }
        var enabledCount = 0
        for track in matchingTracks {
            if try await track.load(.isEnabled) { enabledCount += 1 }
        }
        guard matchingTracks.isEmpty || enabledCount == 1 else {
            throw NSError(domain: "MediaProbe", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Expected exactly one enabled \(mediaType.rawValue) track, found \(enabledCount)"
            ])
        }
    }

    for track in tracks {
        if let requestedMediaType {
            let matchesRequestedType = requestedMediaType == track.mediaType.rawValue ||
                (requestedMediaType == "audio" && track.mediaType == .audio) ||
                (requestedMediaType == "video" && track.mediaType == .video)
            if !matchesRequestedType { continue }
        }
        let descriptions = try await track.load(.formatDescriptions)
        let subtype = descriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "----"
        let enabled = try await track.load(.isEnabled)
        print("  TRACK id=\(track.trackID) type=\(track.mediaType.rawValue) subtype=\(subtype) enabled=\(enabled)")

        if track.mediaType == .video, let description = descriptions.first {
            let naturalSize = try await track.load(.naturalSize)
            let presentationSize = CMVideoFormatDescriptionGetPresentationDimensions(
                description, usePixelAspectRatio: true, useCleanAperture: true)
            print("    natural-size=\(naturalSize.width)x\(naturalSize.height) presentation-size=\(presentationSize.width)x\(presentationSize.height)")
            print("    decoder-extension \(decoderExtensionStatus(description))")

            let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? NSDictionary()
            let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] ?? "none"
            let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] ?? "none"
            let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix] ?? "none"
            let fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo] ?? "unspecified"
            let masteringBytes = (extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] as? Data)?.count ?? 0
            let contentLightBytes = (extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] as? Data)?.count ?? 0
            print("    color primaries=\(primaries) transfer=\(transfer) matrix=\(matrix) full-range=\(fullRange) mastering-bytes=\(masteringBytes) content-light-bytes=\(contentLightBytes)")

            let isHDR = (transfer as? String) == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) ||
                (transfer as? String) == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            if isHDR && !isEndProbe {
                guard masteringBytes == 0 || masteringBytes == 24 else {
                    throw NSError(domain: "MediaProbe", code: 7, userInfo: [
                        NSLocalizedDescriptionKey: "HDR mastering-display metadata has \(masteringBytes) bytes; expected 24"
                    ])
                }
                let decodedReader = try AVAssetReader(asset: asset)
                if probeStart > 0 || explicitWindow != nil {
                    let rangeStart = CMTime(seconds: probeStart, preferredTimescale: 1000)
                    let windowSeconds = isEndProbe ? 0.25 : (explicitWindow ?? 30)
                    let requestedEnd = CMTimeAdd(rangeStart, CMTime(seconds: windowSeconds, preferredTimescale: 1000))
                    let rangeEnd = CMTimeMinimum(requestedEnd, duration)
                    decodedReader.timeRange = CMTimeRange(
                        start: rangeStart,
                        duration: CMTimeSubtract(rangeEnd, rangeStart))
                }
                let hdrPixelFormat = (fullRange as? Bool) == true
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                let decodedOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: hdrPixelFormat)
                ])
                guard decodedReader.canAdd(decodedOutput) else {
                    throw NSError(domain: "MediaProbe", code: 8, userInfo: [
                        NSLocalizedDescriptionKey: "Cannot add the HDR decoded-video output"
                    ])
                }
                decodedReader.add(decodedOutput)
                guard decodedReader.startReading(),
                      let decodedSample = decodedOutput.copyNextSampleBuffer(),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(decodedSample) else {
                    throw decodedReader.error ?? NSError(domain: "MediaProbe", code: 9, userInfo: [
                        NSLocalizedDescriptionKey: "No decoded HDR pixel buffer was returned"
                    ])
                }
                let outputPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
                let outputAttachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as NSDictionary?
                let outputPrimaries = outputAttachments?[kCVImageBufferColorPrimariesKey] ?? "none"
                let outputTransfer = outputAttachments?[kCVImageBufferTransferFunctionKey] ?? "none"
                let outputMatrix = outputAttachments?[kCVImageBufferYCbCrMatrixKey] ?? "none"
                let outputMasteringBytes = (outputAttachments?[kCVImageBufferMasteringDisplayColorVolumeKey] as? Data)?.count ?? 0
                let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                guard lockStatus == kCVReturnSuccess else {
                    throw NSError(domain: "MediaProbe", code: 11, userInfo: [
                        NSLocalizedDescriptionKey: "Could not lock the decoded HDR pixel buffer: \(lockStatus)"
                    ])
                }
                var minimumCode = UInt16.max
                var maximumCode: UInt16 = 0
                var mispackedComponentCount = 0
                for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                    guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
                    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                    let componentsPerRow = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) * (plane == 0 ? 1 : 2)
                    for rowIndex in 0..<height {
                        let row = baseAddress.advanced(by: rowIndex * rowBytes).assumingMemoryBound(to: UInt16.self)
                        for componentIndex in 0..<componentsPerRow {
                            let packed = UInt16(littleEndian: row[componentIndex])
                            if packed & 0x003f != 0 { mispackedComponentCount += 1 }
                            let code = packed >> 6
                            minimumCode = min(minimumCode, code)
                            maximumCode = max(maximumCode, code)
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                print("    hdr-frame pixel-format=\(fourCC(outputPixelFormat)) primaries=\(outputPrimaries) transfer=\(outputTransfer) matrix=\(outputMatrix) mastering-bytes=\(outputMasteringBytes) planes=\(CVPixelBufferGetPlaneCount(pixelBuffer)) codes=\(minimumCode)...\(maximumCode) mispacked=\(mispackedComponentCount)")
                guard outputPixelFormat == hdrPixelFormat,
                      (outputPrimaries as? String) == (primaries as? String),
                      (outputTransfer as? String) == (transfer as? String),
                      (outputMatrix as? String) == (matrix as? String),
                      outputMasteringBytes == masteringBytes,
                      CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
                      minimumCode <= maximumCode,
                      maximumCode <= 1023,
                      mispackedComponentCount == 0 else {
                    throw NSError(domain: "MediaProbe", code: 10, userInfo: [
                        NSLocalizedDescriptionKey: "Decoded HDR output did not preserve 10-bit bi-planar PQ/HLG video"
                    ])
                }
                decodedReader.cancelReading()
            }
        }

        let reader = try AVAssetReader(asset: asset)
        if probeStart > 0 || explicitWindow != nil {
            let rangeStart = CMTime(seconds: probeStart, preferredTimescale: 1000)
            let windowSeconds = isEndProbe ? 0.25 : (explicitWindow ?? 30)
            let requestedEnd = CMTimeAdd(rangeStart, CMTime(seconds: windowSeconds, preferredTimescale: 1000))
            let rangeEnd = CMTimeMinimum(requestedEnd, duration)
            reader.timeRange = CMTimeRange(
                start: rangeStart,
                duration: CMTimeSubtract(rangeEnd, rangeStart))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw NSError(domain: "MediaProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add reader output"])}
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "MediaProbe", code: 3) }
        let requestedSampleCount = Int(ProcessInfo.processInfo.environment["FME_PROBE_SAMPLES"] ?? "3") ?? 3
        var pcmDumpHandle: FileHandle?
        if track.trackID == 2,
           let dumpPath = ProcessInfo.processInfo.environment["FME_PROBE_PCM_DUMP"] {
            FileManager.default.createFile(atPath: dumpPath, contents: nil)
            pcmDumpHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: dumpPath))
        }
        var sampleCount = 0
        var audioFrameCount = 0
        var audioByteCount = 0
        var audioNonzeroByteCount = 0
        var pcmPeak: Float = 0
        var pcmNonfiniteCount = 0
        var pcmClippedCount = 0
        var pcmBoundaryDeltaTotal: Double = 0
        var pcmBoundaryDeltaCount = 0
        var pcmBoundaryDeltaPeak: Float = 0
        var pcmInteriorDeltaTotal: Double = 0
        var pcmInteriorDeltaCount = 0
        var previousPCMLastFrame: [Float]? = nil
        let audioDescription = descriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)
        }
        while sampleCount < requestedSampleCount, let sample = output.copyNextSampleBuffer() {
            sampleCount += 1
            if !CMSampleBufferIsValid(sample) { throw NSError(domain: "MediaProbe", code: 4) }
            if track.mediaType == .audio, let blockBuffer = CMSampleBufferGetDataBuffer(sample) {
                audioFrameCount += CMSampleBufferGetNumSamples(sample)
                let sampleByteCount = CMBlockBufferGetDataLength(blockBuffer)
                audioByteCount += sampleByteCount
                var bytes = [UInt8](repeating: 0, count: sampleByteCount)
                let copyStatus = bytes.withUnsafeMutableBytes { buffer in
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: sampleByteCount,
                        destination: buffer.baseAddress!)
                }
                if copyStatus == noErr {
                    if let pcmDumpHandle { try pcmDumpHandle.write(contentsOf: Data(bytes)) }
                    audioNonzeroByteCount += bytes.reduce(into: 0) { count, byte in
                        if byte != 0 { count += 1 }
                    }
                    if subtype == "lpcm", let audioDescription,
                       (audioDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
                        let channels = Int(audioDescription.pointee.mChannelsPerFrame)
                        bytes.withUnsafeBytes { rawBuffer in
                            let samples = rawBuffer.bindMemory(to: Float.self)
                            let frameCount = channels > 0 ? samples.count / channels : 0
                            if frameCount > 0, let previousPCMLastFrame {
                                for channel in 0..<channels {
                                    let delta = abs(samples[channel] - previousPCMLastFrame[channel])
                                    pcmBoundaryDeltaPeak = max(pcmBoundaryDeltaPeak, delta)
                                    pcmBoundaryDeltaTotal += Double(delta)
                                    pcmBoundaryDeltaCount += 1
                                }
                            }
                            if frameCount > 0 {
                                for frame in 0..<frameCount {
                                    for channel in 0..<channels {
                                        let value = samples[frame * channels + channel]
                                        if value.isFinite {
                                            pcmPeak = max(pcmPeak, abs(value))
                                            if abs(value) > 1 { pcmClippedCount += 1 }
                                        } else {
                                            pcmNonfiniteCount += 1
                                        }
                                        if frame > 0 {
                                            let previous = samples[(frame - 1) * channels + channel]
                                            let delta = abs(value - previous)
                                            if delta.isFinite {
                                                pcmInteriorDeltaTotal += Double(delta)
                                                pcmInteriorDeltaCount += 1
                                            }
                                        }
                                    }
                                }
                                previousPCMLastFrame = (0..<channels).map {
                                    samples[(frameCount - 1) * channels + $0]
                                }
                            }
                        }
                    }
                }
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "MediaProbe", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "Reader failed after returning \(sampleCount) sample buffers"
            ])
        }
        guard sampleCount > 0 else {
            throw reader.error ?? NSError(domain: "MediaProbe", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "No samples returned (reader status: \(reader.status.rawValue))"
            ])
        }
        try pcmDumpHandle?.close()
        reader.cancelReading()
        print("    compressed-samples=\(sampleCount)")
        if track.mediaType == .audio {
            guard audioByteCount > 0 else {
                throw NSError(domain: "MediaProbe", code: 12, userInfo: [
                    NSLocalizedDescriptionKey: "Audio samples contained no data"
                ])
            }
            print("    audio-data frames=\(audioFrameCount) bytes=\(audioByteCount) nonzero-bytes=\(audioNonzeroByteCount)")
            if subtype == "lpcm", let audioDescription,
               (audioDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
                let boundaryMean = pcmBoundaryDeltaCount > 0
                    ? pcmBoundaryDeltaTotal / Double(pcmBoundaryDeltaCount) : 0
                let interiorMean = pcmInteriorDeltaCount > 0
                    ? pcmInteriorDeltaTotal / Double(pcmInteriorDeltaCount) : 0
                print("    pcm peak=\(pcmPeak) clipped=\(pcmClippedCount) nonfinite=\(pcmNonfiniteCount) boundary-delta-mean=\(boundaryMean) boundary-delta-peak=\(pcmBoundaryDeltaPeak) interior-delta-mean=\(interiorMean)")
            } else if subtype == "lpcm", let audioDescription {
                print("    pcm signed-integer bits=\(audioDescription.pointee.mBitsPerChannel) channels=\(audioDescription.pointee.mChannelsPerFrame)")
            }
        }
    }

    if requestedMediaType != "audio",
       let video = tracks.first(where: { $0.mediaType == .video }) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        var actual = CMTime.invalid
        let imageTime = CMTime(seconds: max(probeStart, 1), preferredTimescale: 600)
        let image = try generator.copyCGImage(at: imageTime, actualTime: &actual)
        print("    decoded-frame=\(image.width)x\(image.height) at=\(String(format: "%.3f", CMTimeGetSeconds(actual))) track=\(video.trackID)")
    }
}

Task {
    var failed = false
    do {
        for await availability in AppExtensionIdentity.availabilityUpdates {
            print("VIDEO-EXTENSION availability=\(availability)")
            break
        }
        let updates = try AppExtensionIdentity.matching(
            appExtensionPointIDs: "com.apple.mediaextension.videodecoder")
        for await identities in updates {
            for identity in identities {
                print("VIDEO-EXTENSION id=\(identity.id) bundle=\(identity.bundleIdentifier) name=\(identity.localizedName)")
                do {
                    let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity))
                    print("VIDEO-EXTENSION direct-launch=success bundle=\(identity.bundleIdentifier)")
                    process.invalidate()
                } catch {
                    print("VIDEO-EXTENSION direct-launch=failed bundle=\(identity.bundleIdentifier) error=\(error)")
                }
            }
            break
        }
    } catch {
        print("VIDEO-EXTENSION enumeration-failed: \(error)")
    }
    for path in paths {
        do { try await probe(path) }
        catch {
            failed = true
            print("FAIL \((path as NSString).lastPathComponent): \(error)")
        }
    }
    exit(failed ? 1 : 0)
}

dispatchMain()
