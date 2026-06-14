import Foundation
import Darwin
import AVFoundation
import MP4ConvertorCore

@main
struct MP4MattermostBot {
    static func main() async {
        do {
            let config = try BotConfig.fromEnvironment()
            await requestAudioAccessIfNeeded()
            let bot = MattermostCompressionBot(config: config)
            try await bot.run()
        } catch {
            Logger.error("실행 실패: \(error.localizedDescription)")
            Darwin.exit(1)
        }
    }

    /// 오디오 재인코딩 시 macOS가 변환 도중 마이크 권한 창을 띄우는 것을 막기 위해,
    /// 봇 시작 시점에 한 번만 권한을 요청한다. 한 번 허용하면 고정 서명 덕분에 재실행/재빌드해도 유지된다.
    private static func requestAudioAccessIfNeeded() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .denied, .restricted:
            Logger.error("오디오 권한이 거부되어 있습니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 허용해야 오디오 재인코딩이 가능합니다.")
            return
        case .notDetermined:
            Logger.info("오디오 처리 권한을 요청합니다. 표시되는 안내창에서 한 번만 허용하면 이후에는 다시 묻지 않습니다.")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                Logger.info("오디오 권한이 허용되었습니다.")
            } else {
                Logger.error("오디오 권한이 거부되었습니다. 오디오 유지 압축 시 문제가 생길 수 있습니다.")
            }
        @unknown default:
            return
        }
    }
}

private struct BotConfig {
    let baseURL: URL
    let token: String
    let channelID: String?
    let teamName: String?
    let channelName: String?
    let botUserID: String?
    let pollIntervalSeconds: Double

    static func fromEnvironment() throws -> BotConfig {
        let environment = ProcessInfo.processInfo.environment

        let baseURLText = environment["MATTERMOST_BASE_URL"] ?? "http://office.trollgames.co.kr:8065"
        guard let baseURL = URL(string: baseURLText) else {
            throw BotError.invalidConfiguration("MATTERMOST_BASE_URL 값이 올바른 URL이 아닙니다.")
        }

        guard let token = environment["MATTERMOST_TOKEN"], !token.isEmpty else {
            throw BotError.invalidConfiguration("MATTERMOST_TOKEN 환경 변수가 필요합니다.")
        }

        let channelID = environment["MATTERMOST_CHANNEL_ID"].flatMap { $0.nonEmpty }
        var teamName: String?
        var channelName: String?

        if channelID == nil, let channelURL = environment["MATTERMOST_CHANNEL_URL"].flatMap({ $0.nonEmpty }) {
            guard let parsed = parseChannelPath(from: channelURL) else {
                throw BotError.invalidConfiguration("MATTERMOST_CHANNEL_URL에서 팀/채널 이름을 추출할 수 없습니다.")
            }
            teamName = parsed.team
            channelName = parsed.channel
        }

        guard channelID != nil || (teamName != nil && channelName != nil) else {
            throw BotError.invalidConfiguration("MATTERMOST_CHANNEL_ID 또는 MATTERMOST_CHANNEL_URL 설정이 필요합니다.")
        }

        let pollInterval = Double(environment["MATTERMOST_POLL_INTERVAL"] ?? "") ?? 5
        if pollInterval < 1 {
            throw BotError.invalidConfiguration("MATTERMOST_POLL_INTERVAL은 1초 이상이어야 합니다.")
        }

        return BotConfig(
            baseURL: baseURL,
            token: token,
            channelID: channelID,
            teamName: teamName,
            channelName: channelName,
            botUserID: environment["MATTERMOST_BOT_USER_ID"].flatMap { $0.nonEmpty },
            pollIntervalSeconds: pollInterval
        )
    }

    private static func parseChannelPath(from urlString: String) -> (team: String, channel: String)? {
        guard let url = URL(string: urlString) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let channelIndex = parts.firstIndex(of: "channels"), channelIndex >= 1, channelIndex + 1 < parts.count else {
            return nil
        }
        return (parts[channelIndex - 1], parts[channelIndex + 1])
    }
}

private final class MattermostCompressionBot {
    private let config: BotConfig
    private let client: MattermostClient
    private let compressor = AutoCompressor()
    private var handledPostIDs = Set<String>()
    private var newestSeenCreateAt: Int64

    init(config: BotConfig) {
        self.config = config
        self.client = MattermostClient(baseURL: config.baseURL, token: config.token)
        self.newestSeenCreateAt = Int64(Date().timeIntervalSince1970 * 1_000)
    }

    func run() async throws {
        var resolvedChannelID: String?

        while true {
            do {
                if resolvedChannelID == nil {
                    resolvedChannelID = try await resolveChannelID()
                    if let resolvedChannelID {
                        Logger.info("모니터링 시작: channel_id=\(resolvedChannelID)")
                    }
                }

                if let channelID = resolvedChannelID {
                    try await poll(channelID: channelID)
                }
            } catch {
                Logger.error("폴링 실패: \(error.localizedDescription)")
                resolvedChannelID = nil
            }

            let sleepNs = UInt64(config.pollIntervalSeconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: sleepNs)
        }
    }

    private func resolveChannelID() async throws -> String {
        if let channelID = config.channelID {
            return channelID
        }
        guard let teamName = config.teamName, let channelName = config.channelName else {
            throw BotError.invalidConfiguration("채널 정보가 없습니다.")
        }
        return try await client.lookupChannelID(teamName: teamName, channelName: channelName)
    }

    private func poll(channelID: String) async throws {
        let response = try await client.fetchRecentPosts(channelID: channelID, page: 0, perPage: 30)
        var newest = newestSeenCreateAt

        let posts = response.order.compactMap { response.posts[$0] }.sorted(by: { $0.createAt < $1.createAt })
        for post in posts where shouldHandle(post: post) {
            do {
                try await process(post: post, channelID: channelID)
            } catch {
                Logger.error("게시물 처리 실패(\(post.id)): \(error.localizedDescription)")
            }

            handledPostIDs.insert(post.id)
            newest = max(newest, post.createAt)
        }

        newestSeenCreateAt = max(newestSeenCreateAt, newest)
    }

    private func shouldHandle(post: MattermostPost) -> Bool {
        guard post.createAt >= newestSeenCreateAt else { return false }
        guard !handledPostIDs.contains(post.id) else { return false }
        guard post.userID != config.botUserID else { return false }
        if isPingRequest(message: post.message) { return true }
        if isHelpRequest(message: post.message) { return true }
        return !post.fileIDs.isEmpty
    }

    private func isPingRequest(message: String) -> Bool {
        let normalized = message.lowercased()
        let keywords = ["ping", "pong?", "응답테스트", "응답 테스트", "봇테스트", "봇 테스트"]
        return keywords.contains { normalized.contains($0) }
    }

    private func isHelpRequest(message: String) -> Bool {
        let normalized = message.lowercased()
        let keywords = ["help", "도움말", "사용법", "사용 법", "헬프", "?"]
        return keywords.contains { normalized.contains($0) }
    }

    private func process(post: MattermostPost, channelID: String) async throws {
        if post.fileIDs.isEmpty, isPingRequest(message: post.message) {
            try await client.reply(channelID: channelID, rootID: post.id, message: Self.pingMessage, fileIDs: [])
            Logger.info("응답 테스트 회신 전송: post=\(post.id)")
            return
        }

        if post.fileIDs.isEmpty, isHelpRequest(message: post.message) {
            try await client.reply(channelID: channelID, rootID: post.id, message: Self.helpMessage, fileIDs: [])
            Logger.info("사용법 안내 전송: post=\(post.id)")
            return
        }

        let directive = CompressionDirective.parse(from: post.message)

        for fileID in post.fileIDs {
            let info = try await client.fetchFileInfo(fileID: fileID)
            guard info.isMP4 else { continue }

            Logger.info("압축 시작: post=\(post.id), file=\(info.name)")

            let ackMessage = makeAckMessage(fileName: info.name, directive: directive)
            try await client.reply(channelID: channelID, rootID: post.id, message: ackMessage, fileIDs: [])

            let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("MP4Bot-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            let inputURL = workDir.appendingPathComponent(info.name)
            try await client.downloadFile(fileID: fileID, to: inputURL)

            let result = try await compressor.compress(inputURL: inputURL, directive: directive, in: workDir)
            let uploadedFileID = try await client.uploadFile(channelID: channelID, fileURL: result.outputURL)

            let message = makeReplyMessage(fileName: info.name, result: result, directive: directive)
            try await client.reply(channelID: channelID, rootID: post.id, message: message, fileIDs: [uploadedFileID])

            Logger.info("압축 완료: \(info.name) -> \(result.outputURL.lastPathComponent)")
        }
    }

    private func makeAckMessage(fileName: String, directive: CompressionDirective) -> String {
        var lines = ["⏳ 압축 작업을 시작합니다: \(fileName)"]

        if let maxBytes = directive.maxBytes {
            let target = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
            lines.append("요청 최대 용량: \(target)")
        } else if let quality = directive.quality {
            lines.append("요청 화질: \(quality.title)")
        }

        lines.append("완료되면 이 스레드에 결과를 올려드릴게요. 잠시만 기다려 주세요.")
        return lines.joined(separator: "\n")
    }

    private func makeReplyMessage(fileName: String, result: CompressionResult, directive: CompressionDirective) -> String {
        let original = ByteCountFormatter.string(fromByteCount: result.originalBytes, countStyle: .file)
        let compressed = ByteCountFormatter.string(fromByteCount: result.compressedBytes, countStyle: .file)

        var lines = ["자동 압축 완료: \(fileName)"]
        lines.append("크기: \(original) → \(compressed)")

        if let maxBytes = directive.maxBytes {
            let target = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
            lines.append("요청 최대 용량: \(target)")
        } else if let quality = directive.quality {
            lines.append("요청 화질: \(quality.title)")
        }

        lines.append("적용 옵션: \(result.profile.resizePreset.title), \(result.profile.compressionQuality.title), \(result.profile.frameRateMode.title), \(result.profile.removeAudio ? "오디오 제거" : "오디오 유지")")
        return lines.joined(separator: "\n")
    }

    private static let helpMessage = """
    📦 **MP4 자동 압축 봇 사용법**

    이 채널에 MP4 동영상 파일을 첨부하면 자동으로 압축해서 답글로 돌려드립니다.
    봇을 멘션(@태그)할 필요는 없습니다. 파일만 올리면 됩니다.

    **기본 사용법**
    • MP4 파일을 그냥 첨부 → 기본값(균형 모드)으로 자동 압축
    • 메시지를 비워도 됩니다. 옵션을 생략하면 균형(balanced) 화질로 압축합니다.

    **화질 옵션** (파일과 함께 메시지에 입력)
    • `화질우선` 또는 `high` → 화질을 우선합니다.
    • `균형` 또는 `balanced` → 화질과 용량의 균형 (기본값)
    • `용량우선` 또는 `small` → 용량을 최대한 줄입니다.

    **최대 용량 지정** (목표 용량 이하가 될 때까지 단계적으로 압축)
    • `최대용량 50MB`, `max size 50mb`, 또는 단순히 `50mb` 처럼 입력
    • 지원 단위: B, KB, MB, GB, KiB, MiB, GiB

    **사용 예시**
    • (메시지 없이 파일만 첨부) → 기본 압축
    • `화질우선` + 파일 → 고화질 압축
    • `용량우선 20MB` + 파일 → 20MB 이하를 목표로 압축

    **도움말 보기**
    • `help`, `사용법`, `도움말` 중 하나를 입력하면 이 안내가 표시됩니다.

    **응답 테스트**
    • 영상 없이 `응답테스트` 또는 `ping`을 입력하면 봇이 정상 응답 메시지를 보냅니다.
    """

    private static let pingMessage = """
    ✅ MP4 자동 압축 봇이 정상 동작 중입니다.
    영상 없이도 응답 테스트가 성공했습니다.
    """
}

private struct CompressionDirective {
    let quality: CompressionQuality?
    let maxBytes: Int64?

    static func parse(from message: String) -> CompressionDirective {
        let normalized = message.lowercased()
        let quality: CompressionQuality?
        if normalized.contains("high") || normalized.contains("화질우선") || normalized.contains("화질 우선") {
            quality = .high
        } else if normalized.contains("small") || normalized.contains("용량우선") || normalized.contains("용량 우선") {
            quality = .small
        } else if normalized.contains("balanced") || normalized.contains("균형") {
            quality = .balanced
        } else {
            quality = nil
        }

        let maxBytes = parseMaxBytes(from: normalized)
        return CompressionDirective(quality: quality, maxBytes: maxBytes)
    }

    private static func parseMaxBytes(from message: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(?:최대\s*용량|max\s*size)?\s*[:=]?\s*([0-9]+(?:\.[0-9]+)?)\s*(b|kb|mb|gb|kib|mib|gib)"#) else {
            return nil
        }

        let nsMessage = message as NSString
        let matches = regex.matches(in: message, range: NSRange(location: 0, length: nsMessage.length))
        guard let match = matches.last, match.numberOfRanges >= 3 else {
            return nil
        }

        let numberText = nsMessage.substring(with: match.range(at: 1))
        let unitText = nsMessage.substring(with: match.range(at: 2)).lowercased()
        guard let value = Double(numberText), value > 0 else {
            return nil
        }

        let multiplier: Double
        switch unitText {
        case "b":
            multiplier = 1
        case "kb":
            multiplier = 1_000
        case "mb":
            multiplier = 1_000_000
        case "gb":
            multiplier = 1_000_000_000
        case "kib":
            multiplier = 1_024
        case "mib":
            multiplier = 1_048_576
        case "gib":
            multiplier = 1_073_741_824
        default:
            return nil
        }

        return Int64((value * multiplier).rounded())
    }
}

private struct CompressionProfile: Hashable {
    let resizePreset: ResizePreset
    let compressionQuality: CompressionQuality
    let frameRateMode: FrameRateMode
    let removeAudio: Bool
}

private struct CompressionResult {
    let outputURL: URL
    let profile: CompressionProfile
    let originalBytes: Int64
    let compressedBytes: Int64
}

private final class AutoCompressor {
    private let converter = VideoConverter()

    func compress(inputURL: URL, directive: CompressionDirective, in workDir: URL) async throws -> CompressionResult {
        let originalBytes = try fileSize(for: inputURL)
        let profiles = makeProfiles(from: directive)

        var lastResult: CompressionResult?
        for (index, profile) in profiles.enumerated() {
            let outputURL = workDir.appendingPathComponent("compressed-\(index).mp4")
            let options = ConversionOptions(
                inputURL: inputURL,
                outputURL: outputURL,
                removeAudio: profile.removeAudio,
                resizePreset: profile.resizePreset,
                compressionQuality: profile.compressionQuality,
                frameRateMode: profile.frameRateMode
            )

            _ = try await convert(options: options)
            let compressedBytes = try fileSize(for: outputURL)
            let result = CompressionResult(
                outputURL: outputURL,
                profile: profile,
                originalBytes: originalBytes,
                compressedBytes: compressedBytes
            )
            lastResult = result

            if let maxBytes = directive.maxBytes {
                if compressedBytes <= maxBytes {
                    return result
                }
            } else {
                return result
            }
        }

        if let maxBytes = directive.maxBytes, let lastResult {
            throw BotError.targetSizeNotReached(maxBytes: maxBytes, lastSize: lastResult.compressedBytes)
        }
        throw BotError.conversionFailed("압축 결과를 생성하지 못했습니다.")
    }

    private func convert(options: ConversionOptions) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            converter.convert(options: options, progressHandler: { _ in }) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func makeProfiles(from directive: CompressionDirective) -> [CompressionProfile] {
        if directive.maxBytes == nil {
            return [
                CompressionProfile(
                    resizePreset: .p720,
                    compressionQuality: directive.quality ?? .balanced,
                    frameRateMode: .fps24,
                    removeAudio: false
                )
            ]
        }

        let qualityOrder: [CompressionQuality]
        switch directive.quality ?? .balanced {
        case .high:
            qualityOrder = [.high, .balanced, .small]
        case .balanced:
            qualityOrder = [.balanced, .small]
        case .small:
            qualityOrder = [.small]
        }

        let presets: [ResizePreset] = [.p1080, .p720, .p480]
        let frameRates: [FrameRateMode] = [.original, .fps24, .fps15]
        let audioModes = [false, true]

        var profiles: [CompressionProfile] = []
        var seen = Set<CompressionProfile>()

        for quality in qualityOrder {
            for preset in presets {
                for frameRate in frameRates {
                    for removeAudio in audioModes {
                        let profile = CompressionProfile(
                            resizePreset: preset,
                            compressionQuality: quality,
                            frameRateMode: frameRate,
                            removeAudio: removeAudio
                        )
                        if seen.insert(profile).inserted {
                            profiles.append(profile)
                        }
                    }
                }
            }
        }

        return profiles
    }

    private func fileSize(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw BotError.conversionFailed("파일 크기를 읽지 못했습니다.")
        }
        return Int64(size)
    }
}

private final class MattermostClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        self.session = URLSession(configuration: .default)
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func lookupChannelID(teamName: String, channelName: String) async throws -> String {
        let escapedTeam = teamName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? teamName
        let escapedChannel = channelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? channelName
        let endpoint = "/api/v4/teams/name/\(escapedTeam)/channels/name/\(escapedChannel)"
        let channel: MattermostChannel = try await requestJSON(method: "GET", endpoint: endpoint)
        return channel.id
    }

    func fetchRecentPosts(channelID: String, page: Int, perPage: Int) async throws -> MattermostPostsResponse {
        let endpoint = "/api/v4/channels/\(channelID)/posts?page=\(page)&per_page=\(perPage)"
        return try await requestJSON(method: "GET", endpoint: endpoint)
    }

    func fetchFileInfo(fileID: String) async throws -> MattermostFileInfo {
        try await requestJSON(method: "GET", endpoint: "/api/v4/files/\(fileID)/info")
    }

    func downloadFile(fileID: String, to destinationURL: URL) async throws {
        let request = try makeRequest(method: "GET", endpoint: "/api/v4/files/\(fileID)", body: nil, contentType: nil)
        let (data, _) = try await perform(request)
        try data.write(to: destinationURL, options: .atomic)
    }

    func uploadFile(channelID: String, fileURL: URL) async throws -> String {
        var form = MultipartFormData()
        form.appendField(name: "channel_id", value: channelID)
        let data = try Data(contentsOf: fileURL)
        form.appendFile(name: "files", filename: fileURL.lastPathComponent, mimeType: "video/mp4", data: data)

        let request = try makeRequest(
            method: "POST",
            endpoint: "/api/v4/files",
            body: form.data,
            contentType: "multipart/form-data; boundary=\(form.boundary)"
        )

        let (responseData, _) = try await perform(request)
        let response = try decoder.decode(MattermostUploadResponse.self, from: responseData)
        guard let fileID = response.fileInfos.first?.id else {
            throw BotError.api("파일 업로드 응답에서 file_id를 찾지 못했습니다.")
        }
        return fileID
    }

    func reply(channelID: String, rootID: String, message: String, fileIDs: [String]) async throws {
        let body = MattermostCreatePostRequest(channelID: channelID, rootID: rootID, message: message, fileIDs: fileIDs)
        _ = try await requestJSON(method: "POST", endpoint: "/api/v4/posts", body: body) as MattermostPost
    }

    private func requestJSON<T: Decodable, Body: Encodable>(
        method: String,
        endpoint: String,
        body: Body?
    ) async throws -> T {
        let bodyData = try body.map { try encoder.encode($0) }
        let request = try makeRequest(method: method, endpoint: endpoint, body: bodyData, contentType: body == nil ? nil : "application/json")
        let (data, _) = try await perform(request)
        return try decoder.decode(T.self, from: data)
    }

    private func requestJSON<T: Decodable>(
        method: String,
        endpoint: String
    ) async throws -> T {
        let request = try makeRequest(method: method, endpoint: endpoint, body: nil, contentType: nil)
        let (data, _) = try await perform(request)
        return try decoder.decode(T.self, from: data)
    }

    private func makeRequest(method: String, endpoint: String, body: Data?, contentType: String?) throws -> URLRequest {
        guard let url = URL(string: endpoint, relativeTo: baseURL) else {
            throw BotError.invalidConfiguration("요청 URL을 만들 수 없습니다: \(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BotError.api("HTTP 응답을 받지 못했습니다.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "응답 본문 없음"
            throw BotError.api("Mattermost API 실패 (\(httpResponse.statusCode)): \(text)")
        }
        return (data, httpResponse)
    }
}

private struct MultipartFormData {
    let boundary = "Boundary-\(UUID().uuidString)"
    private(set) var data = Data()

    mutating func appendField(name: String, value: String) {
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append("\(value)\r\n")
    }

    mutating func appendFile(name: String, filename: String, mimeType: String, data: Data) {
        self.data.append("--\(boundary)\r\n")
        self.data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        self.data.append("Content-Type: \(mimeType)\r\n\r\n")
        self.data.append(data)
        self.data.append("\r\n")
        self.data.append("--\(boundary)--\r\n")
    }
}

private struct MattermostPostsResponse: Decodable {
    let order: [String]
    let posts: [String: MattermostPost]
}

private struct MattermostPost: Decodable {
    let id: String
    let userID: String
    let createAt: Int64
    let message: String
    let fileIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "userId"
        case createAt
        case message
        case fileIDs = "fileIds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userID = try container.decode(String.self, forKey: .userID)
        createAt = try container.decode(Int64.self, forKey: .createAt)
        message = (try container.decodeIfPresent(String.self, forKey: .message)) ?? ""
        fileIDs = (try container.decodeIfPresent([String].self, forKey: .fileIDs)) ?? []
    }
}

private struct MattermostChannel: Decodable {
    let id: String
}

private struct MattermostFileInfo: Decodable {
    let id: String
    let name: String
    let fileExtension: String
    let mimeType: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case fileExtension = "extension"
        case mimeType
    }

    var isMP4: Bool {
        fileExtension.lowercased() == "mp4" || mimeType?.lowercased() == "video/mp4"
    }
}

private struct MattermostUploadResponse: Decodable {
    let fileInfos: [MattermostFileRef]
}

private struct MattermostFileRef: Decodable {
    let id: String
}

private struct MattermostCreatePostRequest: Encodable {
    let channelID: String
    let rootID: String
    let message: String
    let fileIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case rootID = "root_id"
        case message
        case fileIDs = "file_ids"
    }
}

private enum BotError: LocalizedError {
    case invalidConfiguration(String)
    case conversionFailed(String)
    case targetSizeNotReached(maxBytes: Int64, lastSize: Int64)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .conversionFailed(let message):
            return message
        case .targetSizeNotReached(let maxBytes, let lastSize):
            let target = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
            let final = ByteCountFormatter.string(fromByteCount: lastSize, countStyle: .file)
            return "최대 용량 \(target) 이하로 줄이지 못했습니다. 마지막 결과: \(final)"
        case .api(let message):
            return message
        }
    }
}

private enum Logger {
    static func info(_ message: String) {
        print("[INFO] \(timestamp()) \(message)")
    }

    static func error(_ message: String) {
        fputs("[ERROR] \(timestamp()) \(message)\n", stderr)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let encoded = string.data(using: .utf8) {
            append(encoded)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return value
    }
}
