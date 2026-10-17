import Foundation
import LocalFlowCore

enum TranscriptionError: LocalizedError {
    case modelMissing(String)
    case serverMissing
    case serverFailedToStart(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let p): "Speech model not found at \(p). Run scripts/download-model.sh."
        case .serverMissing: "whisper-server not found. Install it with: brew install whisper-cpp"
        case .serverFailedToStart(let why): "The local speech engine did not start: \(why)"
        case .requestFailed(let why): "Transcription failed: \(why)"
        }
    }
}

/// Owns one whisper.cpp server child process bound to 127.0.0.1, so the model
/// stays loaded between dictations. Audio never leaves the machine.
final class WhisperServer {
    static let modelURL = Paths.support.appendingPathComponent("models/ggml-large-v3-turbo.bin")
    static let candidateBinaries = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]

    private var process: Process?
    private var port: Int = 0
    private let queue = DispatchQueue(label: "whisper.server")
    private var startTask: Task<Void, Error>?
    private let logURL = Paths.support.appendingPathComponent("whisper-server.log")
    /// Written by an earlier version; removed on start.
    private let pidURL = Paths.support.appendingPathComponent("whisper-server.pid")

    var isRunning: Bool { process?.isRunning ?? false }
    var isStarting: Bool { startTask != nil }

    /// Starts the server if needed and waits until it accepts requests.
    func ensureStarted() async throws {
        if let p = process, p.isRunning, port != 0 { return }
        if let task = startTask { return try await task.value }
        let task = Task { try await self.start() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func start() async throws {
        guard FileManager.default.fileExists(atPath: Self.modelURL.path) else {
            throw TranscriptionError.modelMissing(Self.modelURL.path)
        }
        guard let binary = Self.candidateBinaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TranscriptionError.serverMissing
        }
        reapOrphans()
        let port = try Self.freeLoopbackPort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount / 2)
        p.arguments = ["-m", Self.modelURL.path, "--host", "127.0.0.1", "--port", String(port),
                       "-t", String(threads), "--no-timestamps",
                       // Per-language probabilities cost a second detection pass
                       // (~0.7 s per dictation); the detected language is enough.
                       "--no-language-probabilities"]
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] _ in self?.queue.async { self?.process = nil } }
        try p.run()
        process = p
        self.port = port

        // Loading a 1.6 GB model can take a while on first launch.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            guard p.isRunning else {
                throw TranscriptionError.serverFailedToStart(Self.tail(of: logURL))
            }
            if await healthy() { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        p.terminate()
        throw TranscriptionError.serverFailedToStart("timed out loading the model")
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// Servers left behind when LocalFlow crashed are stopped on the next
    /// start: only orphaned whisper-server processes (parent is launchd)
    /// started with LocalFlow's own model path and loopback host.
    private func reapOrphans() {
        try? FileManager.default.removeItem(at: pidURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), parts[1] == "1" else { continue }
            let command = String(parts[2])
            if command.contains("whisper-server"), command.contains("-m \(Self.modelURL.path) "),
               command.contains("--host 127.0.0.1") {
                kill(pid, SIGTERM)
            }
        }
    }

    /// Transcribes `wav`. `language` is a Whisper code, "auto", or "hinglish":
    /// auto-detect limited to English/Hindi, with Hindi written in Roman letters.
    func transcribe(wav: Data, language: String, prompt: String) async throws -> String {
        guard language == "hinglish" else {
            return try await request(wav: wav, language: language, prompt: prompt).text
        }
        var result = try await request(wav: wav, language: "auto", prompt: prompt)
        if let retry = Hinglish.retryLanguage(detected: result.detected, probabilities: result.probabilities) {
            result = try await request(wav: wav, language: retry, prompt: prompt)
        }
        return Hinglish.romanize(result.text)
    }

    private struct Reply: Decodable {
        let text: String?
        let error: String?
        let detected_language: String?
        let language: String?
        let language_probabilities: [String: Double]?
    }

    private func request(wav: Data, language: String, prompt: String) async throws
        -> (text: String, detected: String?, probabilities: [String: Double]) {
        try await ensureStarted()
        let boundary = "LocalFlow-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "verbose_json")
        field("temperature", "0.0")
        field("language", language)
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw TranscriptionError.requestFailed(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if let e = reply.error { throw TranscriptionError.requestFailed(e) }
        return (reply.text ?? "", reply.detected_language ?? reply.language, reply.language_probabilities ?? [:])
    }

    private static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TranscriptionError.serverFailedToStart("no socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw TranscriptionError.serverFailedToStart("no free port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func tail(of url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return String(text.suffix(400))
    }
}
