import AppKit
@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct MP4ConvertorApplication: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ConverterViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            fileSection
            Divider()
            optionSection
            Divider()
            progressSection
            actionSection
        }
        .padding(22)
        .frame(minWidth: 840, minHeight: 520)
        .alert("처리 실패", isPresented: alertBinding) {
            Button("확인", role: .cancel) { viewModel.alertMessage = nil }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 28, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("MP4 영상 압축기 v2")
                    .font(.title2.weight(.semibold))
                Text("비트레이트 제어 엔진 v2 · \(viewModel.statusText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FilePickerRow(
                title: "입력 파일",
                iconName: "film",
                path: viewModel.inputPathText,
                detail: viewModel.inputDetailText,
                buttonTitle: "MP4 선택",
                buttonIcon: "plus",
                action: viewModel.chooseInputFile
            )
            FilePickerRow(
                title: "출력 파일",
                iconName: "square.and.arrow.down",
                path: viewModel.outputPathText,
                detail: viewModel.outputDetailText,
                buttonTitle: "위치 선택",
                buttonIcon: "folder",
                action: viewModel.chooseOutputFile
            )
        }
    }

    private var optionSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Text("엔진")
                    .frame(width: 92, alignment: .leading)
                Label("H.264 비트레이트 제어", systemImage: "speedometer")
                    .font(.callout.weight(.medium))
                Text("프리셋 방식 아님")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            GridRow {
                Text("화면 크기")
                    .frame(width: 92, alignment: .leading)
                Picker("화면 크기", selection: $viewModel.resizePreset) {
                    ForEach(ResizePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 190)

                if viewModel.resizePreset == .custom {
                    HStack(spacing: 8) {
                        TextField("너비", text: $viewModel.customWidth)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 78)
                        Text("x")
                            .foregroundStyle(.secondary)
                        TextField("높이", text: $viewModel.customHeight)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 78)
                    }
                } else {
                    Text(viewModel.estimatedOutputSizeText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            GridRow {
                Text("압축")
                    .frame(width: 92, alignment: .leading)
                Picker("압축", selection: $viewModel.compressionQuality) {
                    ForEach(CompressionQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
                Text(viewModel.compressionQuality.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            GridRow {
                Text("프레임")
                    .frame(width: 92, alignment: .leading)
                Picker("프레임", selection: $viewModel.frameRateMode) {
                    ForEach(FrameRateMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 310)
                Text(viewModel.frameRateMode.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            GridRow {
                Text("오디오")
                    .frame(width: 92, alignment: .leading)
                Toggle("소리 제거", isOn: $viewModel.removeAudio)
                    .toggleStyle(.checkbox)
                Text(viewModel.removeAudio ? "영상만 저장" : "원본 오디오 유지")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView(value: viewModel.progress)
                    .frame(maxWidth: .infinity)
                Text(viewModel.progressPercentText)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            Text(viewModel.resultText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var actionSection: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.revealOutputInFinder()
            } label: {
                Label("Finder", systemImage: "magnifyingglass")
            }
            .disabled(viewModel.lastOutputURL == nil)

            Spacer()

            if viewModel.isConverting {
                Button(role: .cancel) {
                    viewModel.cancelConversion()
                } label: {
                    Label("취소", systemImage: "xmark.circle")
                }
            }

            Button {
                viewModel.startConversion()
            } label: {
                Label("변환 시작", systemImage: "play.circle")
                    .frame(minWidth: 112)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canStartConversion)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.alertMessage = nil
                }
            }
        )
    }
}

private struct FilePickerRow: View {
    let title: String
    let iconName: String
    let path: String
    let detail: String
    let buttonTitle: String
    let buttonIcon: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button(action: action) {
                Label(buttonTitle, systemImage: buttonIcon)
                    .frame(minWidth: 104)
            }
        }
    }
}

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published var inputURL: URL?
    @Published var outputURL: URL?
    @Published var lastOutputURL: URL?
    @Published var inputDetailText = "선택 안 됨"
    @Published var outputDetailText = "선택 안 됨"
    @Published var statusText = "대기"
    @Published var resultText = ""
    @Published var alertMessage: String?
    @Published var resizePreset: ResizePreset = .p720 {
        didSet { refreshEstimatedOutputSize() }
    }
    @Published var compressionQuality: CompressionQuality = .balanced {
        didSet { refreshEstimatedOutputSize() }
    }
    @Published var frameRateMode: FrameRateMode = .fps24 {
        didSet { refreshEstimatedOutputSize() }
    }
    @Published var removeAudio = true {
        didSet { refreshEstimatedOutputSize() }
    }
    @Published var customWidth = "1280" {
        didSet { refreshEstimatedOutputSize() }
    }
    @Published var customHeight = "720" {
        didSet { refreshEstimatedOutputSize() }
    }
    @Published var progress = 0.0
    @Published var isConverting = false
    @Published var estimatedOutputSizeText = ""

    private let converter = VideoConverter()
    private var sourceSize: CGSize?
    private var sourceFrameRate: Float = 30
    private var sourceEstimatedDataRate: Float = 0

    var inputPathText: String {
        inputURL?.path(percentEncoded: false) ?? "MP4 파일 없음"
    }

    var outputPathText: String {
        outputURL?.path(percentEncoded: false) ?? "출력 위치 없음"
    }

    var canStartConversion: Bool {
        inputURL != nil && outputURL != nil && !isConverting
    }

    var progressPercentText: String {
        isConverting ? "\(Int(progress * 100))%" : "--"
    }

    func chooseInputFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mpeg4Movie]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        inputURL = url
        outputURL = defaultOutputURL(for: url)
        lastOutputURL = nil
        progress = 0
        resultText = ""
        statusText = "대기"
        loadInputMetadata(from: url)
        outputDetailText = "저장 전"
    }

    func chooseOutputFile() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = outputURL?.lastPathComponent ?? "compressed.mp4"

        if let outputURL {
            panel.directoryURL = outputURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        outputURL = url.pathExtension.lowercased() == "mp4" ? url : url.appendingPathExtension("mp4")
        outputDetailText = "저장 전"
        lastOutputURL = nil
    }

    func startConversion() {
        guard let inputURL, let outputURL else {
            alertMessage = "입력 파일과 출력 위치를 먼저 선택하세요."
            return
        }

        guard !Self.isSameFile(inputURL, outputURL) else {
            alertMessage = "출력 파일은 입력 파일과 다른 위치 또는 다른 이름으로 지정하세요."
            return
        }

        let customSize = validatedCustomSize()
        if resizePreset == .custom && customSize == nil {
            alertMessage = "사용자 지정 크기는 2 이상의 숫자로 입력하세요."
            return
        }

        isConverting = true
        progress = 0
        resultText = "변환 중"
        statusText = "변환 중"
        lastOutputURL = nil

        let options = ConversionOptions(
            inputURL: inputURL,
            outputURL: outputURL,
            removeAudio: removeAudio,
            resizePreset: resizePreset,
            customWidth: customSize?.width,
            customHeight: customSize?.height,
            compressionQuality: compressionQuality,
            frameRateMode: frameRateMode
        )

        converter.convert(
            options: options,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    self?.progress = progress
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    self?.finishConversion(result)
                }
            }
        )
    }

    func cancelConversion() {
        converter.cancel()
        statusText = "취소 중"
    }

    func revealOutputInFinder() {
        guard let lastOutputURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutputURL])
    }

    private func finishConversion(_ result: Result<URL, Error>) {
        isConverting = false

        switch result {
        case .success(let url):
            progress = 1
            lastOutputURL = url
            statusText = "완료"
            let inputSize = Self.fileSizeText(for: inputURL)
            let outputSize = Self.fileSizeText(for: url)
            resultText = "완료: \(inputSize)에서 \(outputSize)로 저장"
            outputDetailText = "\(outputSize)"
        case .failure(let error):
            progress = 0
            if (error as? ConversionError) == .cancelled {
                statusText = "취소됨"
                resultText = ""
                return
            }
            statusText = "실패"
            resultText = ""
            alertMessage = error.localizedDescription
        }
    }

    private func loadInputMetadata(from url: URL) {
        inputDetailText = "파일 정보 읽는 중"
        sourceSize = nil
        sourceFrameRate = 30
        sourceEstimatedDataRate = 0
        refreshEstimatedOutputSize()

        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: url)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first else {
                    guard inputURL == url else { return }
                    inputDetailText = "영상 트랙 없음"
                    sourceSize = nil
                    sourceFrameRate = 30
                    sourceEstimatedDataRate = 0
                    refreshEstimatedOutputSize()
                    return
                }

                let summary = try await VideoConverter.trackSummary(for: videoTrack)
                let duration = try await asset.load(.duration)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)

                guard inputURL == url else { return }

                sourceSize = summary.orientedSize
                sourceFrameRate = summary.frameRate
                sourceEstimatedDataRate = summary.estimatedDataRate
                let durationText = Self.durationText(for: duration.seconds)
                let fileSizeText = Self.fileSizeText(for: url)
                let audioText = audioTracks.isEmpty ? "오디오 없음" : "오디오 있음"
                let bitrateText = Self.bitrateText(for: Int(summary.estimatedDataRate))
                inputDetailText = "\(Int(summary.orientedSize.width)) x \(Int(summary.orientedSize.height)) · \(durationText) · \(fileSizeText) · \(bitrateText) · \(audioText)"
                refreshEstimatedOutputSize()
            } catch {
                guard inputURL == url else { return }
                inputDetailText = "파일 정보를 읽지 못함"
                sourceSize = nil
                sourceFrameRate = 30
                sourceEstimatedDataRate = 0
                refreshEstimatedOutputSize()
            }
        }
    }

    private func refreshEstimatedOutputSize() {
        guard let sourceSize else {
            estimatedOutputSizeText = ""
            return
        }

        let customSize = validatedCustomSize()
        let targetSize = resizePreset.targetSize(
            for: sourceSize,
            customWidth: customSize?.width,
            customHeight: customSize?.height
        )
        let outputFrameRate = frameRateMode.outputFrameRate(for: sourceFrameRate)
        let videoBitrate = VideoConverter.targetVideoBitrate(
            targetSize: targetSize,
            frameRate: outputFrameRate,
            sourceEstimatedDataRate: sourceEstimatedDataRate,
            quality: compressionQuality
        )
        let audioText = removeAudio ? "오디오 제거" : "AAC \(compressionQuality.audioBitrate / 1_000)kbps"
        estimatedOutputSizeText = "예상 출력: \(Int(targetSize.width)) x \(Int(targetSize.height)) · \(Self.frameRateText(for: outputFrameRate)) · 영상 \(Self.bitrateText(for: videoBitrate)) · \(audioText)"
    }

    private func validatedCustomSize() -> (width: Int, height: Int)? {
        guard let width = Int(customWidth), let height = Int(customHeight), width >= 2, height >= 2 else {
            return nil
        }
        return (width, height)
    }

    private func defaultOutputURL(for inputURL: URL) -> URL {
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        return inputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-compressed")
            .appendingPathExtension("mp4")
    }

    private static func durationText(for seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else {
            return "0:00"
        }

        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private static func fileSizeText(for url: URL?) -> String {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return "알 수 없음"
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }

    private static func bitrateText(for bitsPerSecond: Int) -> String {
        guard bitsPerSecond > 0 else {
            return "비트레이트 알 수 없음"
        }

        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1fMbps", Double(bitsPerSecond) / 1_000_000)
        }
        return "\(max(1, bitsPerSecond / 1_000))kbps"
    }

    private static func frameRateText(for frameRate: Float) -> String {
        if frameRate.rounded() == frameRate {
            return "\(Int(frameRate))fps"
        }
        return String(format: "%.1ffps", frameRate)
    }

    private static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}

struct ConversionOptions {
    let inputURL: URL
    let outputURL: URL
    let removeAudio: Bool
    let resizePreset: ResizePreset
    let customWidth: Int?
    let customHeight: Int?
    let compressionQuality: CompressionQuality
    let frameRateMode: FrameRateMode
}

enum ResizePreset: String, CaseIterable, Identifiable {
    case original
    case p1080
    case p720
    case p480
    case custom

    var id: String { rawValue }

    var title: String {
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

    func targetSize(for sourceSize: CGSize, customWidth: Int?, customHeight: Int?) -> CGSize {
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

enum CompressionQuality: String, CaseIterable, Identifiable {
    case high
    case balanced
    case small

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high:
            return "화질 우선"
        case .balanced:
            return "균형"
        case .small:
            return "용량 우선"
        }
    }

    var detail: String {
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

enum FrameRateMode: String, CaseIterable, Identifiable {
    case original
    case fps30
    case fps24
    case fps15

    var id: String { rawValue }

    var title: String {
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

    var detail: String {
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

    func outputFrameRate(for sourceFrameRate: Float) -> Float {
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

final class VideoConverter {
    private let accessQueue = DispatchQueue(label: "kr.trollgames.MP4ConvertorApp.converter.state")
    private var activeReader: AVAssetReader?
    private var activeWriter: AVAssetWriter?
    private var activeCancellationToken: CancellationToken?

    func convert(
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

    func cancel() {
        accessQueue.sync {
            activeCancellationToken?.cancel()
            activeReader?.cancelReading()
            activeWriter?.cancelWriting()
        }
    }

    static func trackSummary(for videoTrack: AVAssetTrack) async throws -> VideoTrackSummary {
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
            queueLabel: "kr.trollgames.MP4ConvertorApp.converter.video",
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
                queueLabel: "kr.trollgames.MP4ConvertorApp.converter.audio",
                duration: state.duration,
                cancellationToken: cancellationToken,
                failureBox: failureBox,
                group: group,
                progressHandler: nil
            )
        }

        group.notify(queue: DispatchQueue(label: "kr.trollgames.MP4ConvertorApp.converter.finish")) {
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

    static func targetVideoBitrate(
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

struct VideoTrackSummary {
    let orientedSize: CGSize
    let frameRate: Float
    let estimatedDataRate: Float
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

enum ConversionError: LocalizedError, Equatable {
    case inputNotFound
    case outputMatchesInput
    case missingVideoTrack
    case cannotCreateVideoTrack
    case cannotCreateExportSession
    case noCompatiblePreset
    case unsupportedMP4Export
    case exportFailed
    case cancelled

    var errorDescription: String? {
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
