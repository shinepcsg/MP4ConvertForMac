import Foundation
import CoreGraphics
@preconcurrency import AVFoundation

public struct ConversionOptions {
    public let inputURL: URL
    public let outputURL: URL
    public let removeAudio: Bool
    public let resizePreset: ResizePreset
    public let customWidth: Int?
    public let customHeight: Int?
    public let compressionQuality: CompressionQuality
    public let frameRateMode: FrameRateMode

    public init(
        inputURL: URL,
        outputURL: URL,
        removeAudio: Bool,
        resizePreset: ResizePreset,
        customWidth: Int? = nil,
        customHeight: Int? = nil,
        compressionQuality: CompressionQuality,
        frameRateMode: FrameRateMode
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.removeAudio = removeAudio
        self.resizePreset = resizePreset
        self.customWidth = customWidth
        self.customHeight = customHeight
        self.compressionQuality = compressionQuality
        self.frameRateMode = frameRateMode
    }
}

public enum ResizePreset: String, CaseIterable, Identifiable {
    case original
    case p1080
    case p720
    case p480
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original:
            return "원본 유지"
        case .p1080:
            return "최대 1080p"
        case .p720:
            return "최대 720p"
        case .p480:
            return "최대 480p"
        case .custom:
            return "사용자 지정"
        }
    }

    public func targetSize(for sourceSize: CGSize, customWidth: Int?, customHeight: Int?) -> CGSize {
        let boundingSize: CGSize
        switch self {
        case .original:
            return sourceSize.evenSize
        case .p1080:
            boundingSize = CGSize(width: 1920, height: 1080)
        case .p720:
            boundingSize = CGSize(width: 1280, height: 720)
        case .p480:
            boundingSize = CGSize(width: 854, height: 480)
        case .custom:
            let width = CGFloat(customWidth ?? Int(sourceSize.width))
            let height = CGFloat(customHeight ?? Int(sourceSize.height))
            boundingSize = CGSize(width: width, height: height)
        }

        return sourceSize.fittedInside(boundingSize).evenSize
    }
}

public enum CompressionQuality: String, CaseIterable, Identifiable {
    case high
    case balanced
    case small

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .high:
            return "화질 우선"
        case .balanced:
            return "균형"
        case .small:
            return "용량 우선"
        }
    }

    public var detail: String {
        switch self {
        case .high:
            return "화질 보존"
        case .balanced:
            return "자동 최적화"
        case .small:
            return "용량 최소화"
        }
    }

    var bitsPerPixel: Double {
        switch self {
        case .high:
            return 0.105
        case .balanced:
            return 0.072
        case .small:
            return 0.048
        }
    }

    var sourceBitrateRatioLimit: Double {
        switch self {
        case .high:
            return 0.72
        case .balanced:
            return 0.48
        case .small:
            return 0.32
        }
    }

    var audioBitrate: Int {
        switch self {
        case .high:
            return 128_000
        case .balanced:
            return 96_000
        case .small:
            return 64_000
        }
    }
}

public enum FrameRateMode: String, CaseIterable, Identifiable {
    case original
    case fps30
    case fps24
    case fps15

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original:
            return "원본"
        case .fps30:
            return "30fps"
        case .fps24:
            return "24fps"
        case .fps15:
            return "15fps"
        }
    }

    public var detail: String {
        switch self {
        case .original:
            return "프레임 유지"
        case .fps30:
            return "일반 영상용"
        case .fps24:
            return "용량 절감"
        case .fps15:
            return "강한 절감"
        }
    }

    public func outputFrameRate(for sourceFrameRate: Float) -> Float {
        let normalizedSource = sourceFrameRate > 0 ? sourceFrameRate : 30
        let cap: Float
        switch self {
        case .original:
            return normalizedSource
        case .fps30:
            cap = 30
        case .fps24:
            cap = 24
        case .fps15:
            cap = 15
        }
        return min(normalizedSource, cap)
    }
}

public final class VideoConverter {
    private let accessQueue = DispatchQueue(label: "kr.trollgames.MP4Convertor.converter.state")
    private var activeReader: AVAssetReader?
    private var activeWriter: AVAssetWriter?
    private var activeCancellationToken: CancellationToken?

    public init() {}

    public func convert(
        options: ConversionOptions,
        progressHandler: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let cancellationToken = CancellationToken()
        accessQueue.sync {
            activeCancellationToken = cancellationToken
        }

        Task {
            do {
                let transcodeState = try await makeTranscodeState(for: options)
                accessQueue.sync {
                    activeReader = transcodeState.reader
                    activeWriter = transcodeState.writer
                }
                runTranscode(
                    state: transcodeState,
                    cancellationToken: cancellationToken,
                    progressHandler: progressHandler,
                    completion: completion
                )
            } catch {
                cleanupActiveConversion()
                completion(.failure(error))
            }
        }
    }

    public func cancel() {
        accessQueue.sync {
            activeCancellationToken?.cancel()
            activeReader?.cancelReading()
            activeWriter?.cancelWriting()
        }
    }

    public static func trackSummary(for videoTrack: AVAssetTrack) async throws -> VideoTrackSummary {
        let properties = try await loadProperties(for: videoTrack)
        return VideoTrackSummary(
            orientedSize: properties.orientedSize,
            frameRate: properties.effectiveFrameRate,
            estimatedDataRate: properties.estimatedDataRate
        )
    }

    private func makeTranscodeState(for options: ConversionOptions) async throws -> TranscodeState {
        guard FileManager.default.fileExists(atPath: options.inputURL.path) else {
            throw ConversionError.inputNotFound
        }

        guard options.inputURL.standardizedFileURL.path != options.outputURL.standardizedFileURL.path else {
            throw ConversionError.outputMatchesInput
        }

        if FileManager.default.fileExists(atPath: options.outputURL.path) {
            try FileManager.default.removeItem(at: options.outputURL)
        }

        let asset = AVURLAsset(url: options.inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw ConversionError.missingVideoTrack
        }

        let sourceProperties = try await Self.loadProperties(for: sourceVideoTrack)
        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: options.outputURL, fileType: .mp4)

        let sourceSize = sourceProperties.orientedSize
        let targetSize = options.resizePreset.targetSize(
            for: sourceSize,
            customWidth: options.customWidth,
            customHeight: options.customHeight
        )
        let outputFrameRate = options.frameRateMode.outputFrameRate(for: sourceProperties.effectiveFrameRate)
        let videoComposition = Self.makeVideoComposition(
            sourceProperties: sourceProperties,
            duration: duration,
            renderSize: targetSize,
            frameRate: outputFrameRate
        )

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [sourceVideoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(videoOutput) else {
            throw ConversionError.cannotCreateVideoTrack
        }
        reader.add(videoOutput)

        let videoBitrate = Self.targetVideoBitrate(
            targetSize: targetSize,
            frameRate: outputFrameRate,
            sourceEstimatedDataRate: sourceProperties.estimatedDataRate,
            quality: options.compressionQuality
        )
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(targetSize.width),
            AVVideoHeightKey: Int(targetSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoExpectedSourceFrameRateKey: Int(outputFrameRate.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int((outputFrameRate * 2).rounded()),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else {
            throw ConversionError.cannotCreateExportSession
        }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?

        if !options.removeAudio {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let sourceAudioTrack = audioTracks.first {
                let audioProperties = try await Self.loadAudioProperties(for: sourceAudioTrack)
                let output = AVAssetReaderTrackOutput(track: sourceAudioTrack, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
                output.alwaysCopiesSampleData = false

                if reader.canAdd(output) {
                    reader.add(output)
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVNumberOfChannelsKey: audioProperties.channelCount,
                        AVSampleRateKey: audioProperties.sampleRate,
                        AVEncoderBitRateKey: options.compressionQuality.audioBitrate
                    ])
                    input.expectsMediaDataInRealTime = false

                    if writer.canAdd(input) {
                        writer.add(input)
                        audioOutput = output
                        audioInput = input
                    }
                }
            }
        }

        writer.shouldOptimizeForNetworkUse = true

        return TranscodeState(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            audioOutput: audioOutput,
            audioInput: audioInput,
            duration: duration,
            outputURL: options.outputURL
        )
    }

    private func runTranscode(
        state: TranscodeState,
        cancellationToken: CancellationToken,
        progressHandler: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard state.reader.startReading() else {
            cleanupActiveConversion()
            completion(.failure(state.reader.error ?? ConversionError.exportFailed))
            return
        }

        guard state.writer.startWriting() else {
            state.reader.cancelReading()
            cleanupActiveConversion()
            completion(.failure(state.writer.error ?? ConversionError.exportFailed))
            return
        }

        state.writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let failureBox = FailureBox()

        appendSamples(
            output: state.videoOutput,
            input: state.videoInput,
            queueLabel: "kr.trollgames.MP4Convertor.converter.video",
            duration: state.duration,
            cancellationToken: cancellationToken,
            failureBox: failureBox,
            group: group,
            progressHandler: progressHandler
        )

        if let audioOutput = state.audioOutput, let audioInput = state.audioInput {
            appendSamples(
                output: audioOutput,
                input: audioInput,
                queueLabel: "kr.trollgames.MP4Convertor.converter.audio",
                duration: state.duration,
                cancellationToken: cancellationToken,
                failureBox: failureBox,
                group: group,
                progressHandler: nil
            )
        }

        group.notify(queue: DispatchQueue(label: "kr.trollgames.MP4Convertor.converter.finish")) {
            if cancellationToken.isCancelled {
                state.reader.cancelReading()
                state.writer.cancelWriting()
                self.cleanupActiveConversion()
                completion(.failure(ConversionError.cancelled))
                return
            }

            if let failure = failureBox.error {
                state.reader.cancelReading()
                state.writer.cancelWriting()
                self.cleanupActiveConversion()
                completion(.failure(failure))
                return
            }

            if state.reader.status == .failed {
                state.writer.cancelWriting()
                self.cleanupActiveConversion()
                completion(.failure(state.reader.error ?? ConversionError.exportFailed))
                return
            }

            state.writer.finishWriting {
                self.cleanupActiveConversion()
                if state.writer.status == .completed {
                    progressHandler(1)
                    completion(.success(state.outputURL))
                } else {
                    completion(.failure(state.writer.error ?? ConversionError.exportFailed))
                }
            }
        }
    }

    private static func makeVideoComposition(
        sourceProperties: VideoTrackProperties,
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Float
    ) -> AVMutableVideoComposition {
        let transformedRect = CGRect(origin: .zero, size: sourceProperties.naturalSize)
            .applying(sourceProperties.preferredTransform)
        let orientedSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        let scale = min(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let centeringTransform = CGAffineTransform(
            translationX: (renderSize.width - scaledSize.width) / 2,
            y: (renderSize.height - scaledSize.height) / 2
        )

        let transform = sourceProperties.preferredTransform
            .concatenating(CGAffineTransform(translationX: -transformedRect.origin.x, y: -transformedRect.origin.y))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(centeringTransform)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceProperties.track)
        layerInstruction.setTransform(transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration(for: frameRate)
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    private func appendSamples(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        queueLabel: String,
        duration: CMTime,
        cancellationToken: CancellationToken,
        failureBox: FailureBox,
        group: DispatchGroup,
        progressHandler: ((Double) -> Void)?
    ) {
        let queue = DispatchQueue(label: queueLabel)
        let mediaPipe = MediaPipe(output: output, input: input)
        var isFinished = false

        group.enter()
        mediaPipe.input.requestMediaDataWhenReady(on: queue) {
            guard !isFinished else {
                return
            }

            while mediaPipe.input.isReadyForMoreMediaData {
                if cancellationToken.isCancelled {
                    isFinished = true
                    mediaPipe.input.markAsFinished()
                    group.leave()
                    return
                }

                if failureBox.error != nil {
                    isFinished = true
                    mediaPipe.input.markAsFinished()
                    group.leave()
                    return
                }

                guard let sampleBuffer = mediaPipe.output.copyNextSampleBuffer() else {
                    isFinished = true
                    mediaPipe.input.markAsFinished()
                    group.leave()
                    return
                }

                guard mediaPipe.input.append(sampleBuffer) else {
                    failureBox.error = ConversionError.exportFailed
                    isFinished = true
                    mediaPipe.input.markAsFinished()
                    group.leave()
                    return
                }

                if let progressHandler {
                    let seconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                    if seconds.isFinite, duration.seconds > 0 {
                        progressHandler(min(max(seconds / duration.seconds, 0), 0.99))
                    }
                }
            }
        }
    }

    private func cleanupActiveConversion() {
        accessQueue.sync {
            activeReader = nil
            activeWriter = nil
            activeCancellationToken = nil
        }
    }

    private static func loadProperties(for videoTrack: AVAssetTrack) async throws -> VideoTrackProperties {
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let estimatedDataRate = try await videoTrack.load(.estimatedDataRate)
        return VideoTrackProperties(
            track: videoTrack,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            nominalFrameRate: nominalFrameRate,
            estimatedDataRate: estimatedDataRate
        )
    }

    private static func loadAudioProperties(for audioTrack: AVAssetTrack) async throws -> AudioTrackProperties {
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return AudioTrackProperties(channelCount: 2, sampleRate: 44_100)
        }

        let channelCount = max(1, min(Int(streamDescription.mChannelsPerFrame), 2))
        let sampleRate = streamDescription.mSampleRate > 0 ? streamDescription.mSampleRate : 44_100
        return AudioTrackProperties(channelCount: channelCount, sampleRate: sampleRate)
    }

    public static func targetVideoBitrate(
        targetSize: CGSize,
        frameRate: Float,
        sourceEstimatedDataRate: Float,
        quality: CompressionQuality
    ) -> Int {
        let pixels = Double(targetSize.width * targetSize.height)
        let frameRateValue = Double(max(frameRate, 24))
        let qualityTarget = pixels * frameRateValue * quality.bitsPerPixel
        let sourceRate = Double(sourceEstimatedDataRate)
        let sourceLimitedTarget = sourceRate > 0 ? sourceRate * quality.sourceBitrateRatioLimit : qualityTarget
        let selectedTarget = min(qualityTarget, sourceLimitedTarget)
        let minimumTarget = min(900_000.0, max(260_000.0, pixels * 0.45))
        return Int(max(minimumTarget, selectedTarget))
    }

    private static func frameDuration(for frameRate: Float) -> CMTime {
        if frameRate > 0 {
            return CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        }
        return CMTime(value: 1, timescale: 30)
    }
}

public struct VideoTrackSummary {
    public let orientedSize: CGSize
    public let frameRate: Float
    public let estimatedDataRate: Float

    public init(orientedSize: CGSize, frameRate: Float, estimatedDataRate: Float) {
        self.orientedSize = orientedSize
        self.frameRate = frameRate
        self.estimatedDataRate = estimatedDataRate
    }
}

private struct VideoTrackProperties {
    let track: AVAssetTrack
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let nominalFrameRate: Float
    let estimatedDataRate: Float

    var effectiveFrameRate: Float {
        nominalFrameRate > 0 ? nominalFrameRate : 30
    }

    var orientedSize: CGSize {
        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
        return CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height)).evenSize
    }
}

private struct AudioTrackProperties {
    let channelCount: Int
    let sampleRate: Double
}

private struct TranscodeState: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOutput: AVAssetReaderOutput
    let videoInput: AVAssetWriterInput
    let audioOutput: AVAssetReaderOutput?
    let audioInput: AVAssetWriterInput?
    let duration: CMTime
    let outputURL: URL
}

private final class MediaPipe: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }
}

private final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private final class FailureBox {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }
}

public enum ConversionError: LocalizedError, Equatable {
    case inputNotFound
    case outputMatchesInput
    case missingVideoTrack
    case cannotCreateVideoTrack
    case cannotCreateExportSession
    case noCompatiblePreset
    case unsupportedMP4Export
    case exportFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .inputNotFound:
            return "입력 파일을 찾을 수 없습니다."
        case .outputMatchesInput:
            return "출력 파일은 입력 파일과 다른 위치 또는 다른 이름으로 지정하세요."
        case .missingVideoTrack:
            return "MP4 안에서 영상 트랙을 찾을 수 없습니다."
        case .cannotCreateVideoTrack:
            return "영상 트랙을 준비하지 못했습니다."
        case .cannotCreateExportSession:
            return "변환 세션을 만들지 못했습니다."
        case .noCompatiblePreset:
            return "이 파일에 사용할 수 있는 압축 프리셋이 없습니다."
        case .unsupportedMP4Export:
            return "이 파일은 MP4 출력으로 변환할 수 없습니다."
        case .exportFailed:
            return "변환 중 오류가 발생했습니다."
        case .cancelled:
            return "변환이 취소되었습니다."
        }
    }
}

private extension CGSize {
    var evenSize: CGSize {
        CGSize(width: width.evenDimension, height: height.evenDimension)
    }

    func fittedInside(_ boundingSize: CGSize) -> CGSize {
        guard width > 0, height > 0, boundingSize.width > 0, boundingSize.height > 0 else {
            return CGSize(width: 2, height: 2)
        }

        let scale = min(boundingSize.width / width, boundingSize.height / height, 1)
        return CGSize(width: width * scale, height: height * scale)
    }
}

private extension CGFloat {
    var evenDimension: CGFloat {
        let roundedValue = Swift.max(2, Int(self.rounded(.down)))
        return CGFloat(roundedValue - (roundedValue % 2))
    }
}
