import AppKit
import Foundation

let bg = NSColor(calibratedRed: 0.969, green: 0.949, blue: 0.906, alpha: 1.0)
let ink = NSColor(calibratedRed: 0.129, green: 0.122, blue: 0.102, alpha: 1.0)
let muted = NSColor(calibratedRed: 0.427, green: 0.400, blue: 0.349, alpha: 1.0)
let line = NSColor(calibratedRed: 0.847, green: 0.816, blue: 0.741, alpha: 1.0)
let green = NSColor(calibratedRed: 0.388, green: 0.706, blue: 0.424, alpha: 1.0)
let yellow = NSColor(calibratedRed: 0.851, green: 0.643, blue: 0.255, alpha: 1.0)
let red = NSColor(calibratedRed: 0.851, green: 0.357, blue: 0.310, alpha: 1.0)
let blue = NSColor(calibratedRed: 0.247, green: 0.498, blue: 0.749, alpha: 1.0)
let cream = NSColor(calibratedRed: 1.0, green: 0.953, blue: 0.792, alpha: 1.0)
let glass = NSColor(calibratedRed: 0.996, green: 0.973, blue: 0.914, alpha: 0.92)

struct UsageSnapshot {
    let providerId: String
    let providerName: String
    let inputTokens: Int
    let outputTokens: Int
    let requests: Int
    let costUsd: Double?
    let updatedAt: Date
    let status: String
    let message: String
    let codexStatus: CodexStatus?

    var totalTokens: Int {
        inputTokens + outputTokens
    }
}

struct CodexStatus {
    let cliVersion: String
    let model: String
    let reasoning: String
    let directory: String
    let account: String
    let plan: String
    let sessionId: String
    let contextUsed: Int
    let contextWindow: Int
    let primaryUsedPercent: Double?
    let primaryResetAt: Date?
    let secondaryUsedPercent: Double?
    let secondaryResetAt: Date?
}

final class ProviderStore {
    private let configUrl: URL
    private var config: [String: Any] = [:]
    private var codexAccumulators: [String: CodexUsageAccumulator] = [:]

    init(configUrl: URL) {
        self.configUrl = configUrl
        self.config = Self.loadConfig(configUrl: configUrl)
    }

    var refreshSeconds: TimeInterval {
        TimeInterval(config["refresh_seconds"] as? Int ?? 3)
    }

    func fetchAll() -> [UsageSnapshot] {
        guard let providers = config["providers"] as? [[String: Any]] else {
            return Self.defaultProviders().map { fetchProvider($0) }
        }
        return providers.map { fetchProvider($0) }
    }

    private func fetchProvider(_ provider: [String: Any]) -> UsageSnapshot {
        do {
            let type = provider["type"] as? String ?? "mock"
            switch type {
            case "mock":
                return mockProvider(provider)
            case "local_json":
                return try localJsonProvider(provider)
            case "http_json":
                return try httpJsonProvider(provider)
            case "openai":
                return try openAIProvider(provider)
            case "codex_local":
                return try codexLocalProvider(provider)
            default:
                throw RuntimeError("unsupported provider type: \(type)")
            }
        } catch {
            return errorSnapshot(provider, message: error.localizedDescription)
        }
    }

    private func mockProvider(_ provider: [String: Any]) -> UsageSnapshot {
        let jitter = Int(Date().timeIntervalSince1970 / 30) % 17
        var payload = provider
        payload["input_tokens"] = intValue(provider["input_tokens"]) + jitter * 1200
        payload["output_tokens"] = intValue(provider["output_tokens"]) + jitter * 420
        payload["requests"] = intValue(provider["requests"]) + jitter
        return snapshot(provider, payload: payload)
    }

    private func localJsonProvider(_ provider: [String: Any]) throws -> UsageSnapshot {
        guard let path = provider["path"] as? String else {
            throw RuntimeError("local_json provider requires path")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let data = try Data(contentsOf: url)
        let payload = try jsonObject(data)
        return snapshot(provider, payload: payload)
    }

    private func httpJsonProvider(_ provider: [String: Any]) throws -> UsageSnapshot {
        guard let urlString = provider["url"] as? String, let url = URL(string: urlString) else {
            throw RuntimeError("http_json provider requires url")
        }
        var request = URLRequest(url: url, timeoutInterval: doubleValue(provider["timeout"], fallback: 12))
        if let headers = provider["headers"] as? [String: String] {
            for (key, value) in headers {
                request.addValue(expandEnv(value), forHTTPHeaderField: key)
            }
        }
        let data = try syncRequest(request)
        return snapshot(provider, payload: try jsonObject(data))
    }

    private func openAIProvider(_ provider: [String: Any]) throws -> UsageSnapshot {
        let envName = provider["api_key_env"] as? String ?? "OPENAI_ADMIN_KEY"
        guard let apiKey = ProcessInfo.processInfo.environment[envName], !apiKey.isEmpty else {
            throw RuntimeError("missing env var \(envName)")
        }
        let days = intValue(provider["days"], fallback: 7)
        let end = Int(Date().timeIntervalSince1970)
        let start = end - days * 86_400
        var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: "\(start)"),
            URLQueryItem(name: "end_time", value: "\(end)"),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: doubleValue(provider["timeout"], fallback: 20))
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try syncRequest(request)
        let payload = try jsonObject(data)

        var inputTokens = 0
        var outputTokens = 0
        var requestCount = 0
        if let buckets = payload["data"] as? [[String: Any]] {
            for bucket in buckets {
                guard let results = bucket["results"] as? [[String: Any]] else { continue }
                for result in results {
                    inputTokens += intValue(result["input_tokens"])
                    outputTokens += intValue(result["output_tokens"])
                    requestCount += intValue(result["num_model_requests"])
                }
            }
        }

        return UsageSnapshot(
            providerId: provider["id"] as? String ?? "openai",
            providerName: provider["name"] as? String ?? "OpenAI",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            requests: requestCount,
            costUsd: nil,
            updatedAt: Date(),
            status: "ok",
            message: "",
            codexStatus: nil
        )
    }

    private func codexLocalProvider(_ provider: [String: Any]) throws -> UsageSnapshot {
        let codexHome = provider["codex_home"] as? String ?? "~/.codex"
        let expandedHome = NSString(string: codexHome).expandingTildeInPath
        let homeUrl = URL(fileURLWithPath: expandedHome)
        let days = intValue(provider["days"], fallback: 7)
        let key = "\(expandedHome)|\(days)"
        let accumulator = codexAccumulators[key] ?? CodexUsageAccumulator(homeUrl: homeUrl, days: days)
        codexAccumulators[key] = accumulator
        let summary = accumulator.refresh()

        if summary.sessionCount == 0 {
            throw RuntimeError("no Codex token_count records found in last \(days)d")
        }

        let limitText: String
        if let primary = summary.primaryLimit, let secondary = summary.secondaryLimit {
            limitText = "rate \(Int(primary))% / \(Int(secondary))%"
        } else {
            limitText = "\(summary.sessionCount) sessions"
        }
        let mode = summary.changedFiles > 0 ? "live +\(summary.changedFiles)" : "live"

        let status = makeCodexStatus(provider: provider, summary: summary, homeUrl: homeUrl)
        return UsageSnapshot(
            providerId: provider["id"] as? String ?? "codex-local",
            providerName: provider["name"] as? String ?? "Codex Local",
            inputTokens: summary.inputTokens,
            outputTokens: summary.outputTokens,
            requests: summary.requestCount,
            costUsd: nil,
            updatedAt: summary.updatedAt,
            status: "ok",
            message: "last \(days)d · \(mode) · \(limitText)",
            codexStatus: status
        )
    }

    private func makeCodexStatus(provider: [String: Any], summary: CodexUsageSummary, homeUrl: URL) -> CodexStatus {
        let config = readCodexConfig(homeUrl: homeUrl)
        let account = readCodexAccount(homeUrl: homeUrl)
        let meta = summary.latestMeta
        let model = nonEmpty(meta?.model) ?? nonEmpty(config.model) ?? "unknown"
        let reasoning = nonEmpty(meta?.effort) ?? nonEmpty(config.reasoning) ?? "unknown"
        let directory = nonEmpty(meta?.cwd) ?? FileManager.default.currentDirectoryPath
        let version = nonEmpty(meta?.cliVersion) ?? "unknown"
        let sessionId = nonEmpty(meta?.sessionId) ?? "-"
        return CodexStatus(
            cliVersion: version,
            model: model,
            reasoning: reasoning,
            directory: abbreviateHome(directory),
            account: account.email,
            plan: account.plan,
            sessionId: sessionId,
            contextUsed: latestContextUsed(summary: summary),
            contextWindow: summary.contextWindow,
            primaryUsedPercent: summary.primaryLimit,
            primaryResetAt: summary.primaryResetAt,
            secondaryUsedPercent: summary.secondaryLimit,
            secondaryResetAt: summary.secondaryResetAt
        )
    }

    private func snapshot(_ provider: [String: Any], payload: [String: Any]) -> UsageSnapshot {
        UsageSnapshot(
            providerId: provider["id"] as? String ?? provider["name"] as? String ?? "provider",
            providerName: provider["name"] as? String ?? provider["id"] as? String ?? "Provider",
            inputTokens: intValue(payload["input_tokens"] ?? payload["prompt_tokens"]),
            outputTokens: intValue(payload["output_tokens"] ?? payload["completion_tokens"]),
            requests: intValue(payload["requests"] ?? payload["request_count"]),
            costUsd: optionalDouble(payload["cost_usd"] ?? payload["cost"]),
            updatedAt: Date(),
            status: payload["status"] as? String ?? "ok",
            message: payload["message"] as? String ?? "",
            codexStatus: nil
        )
    }

    private func errorSnapshot(_ provider: [String: Any], message: String) -> UsageSnapshot {
        UsageSnapshot(
            providerId: provider["id"] as? String ?? provider["name"] as? String ?? "provider",
            providerName: provider["name"] as? String ?? provider["id"] as? String ?? "Provider",
            inputTokens: 0,
            outputTokens: 0,
            requests: 0,
            costUsd: nil,
            updatedAt: Date(),
            status: "error",
            message: message,
            codexStatus: nil
        )
    }

    private static func loadConfig(configUrl: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: configUrl),
              let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any] else {
            return [
                "refresh_seconds": 3,
                "providers": defaultProviders()
            ]
        }
        return config
    }

    private static func defaultProviders() -> [[String: Any]] {
        [
            ["id": "codex-local", "name": "Codex Live", "type": "codex_local", "codex_home": "~/.codex", "days": 7]
        ]
    }
}

enum PetAction: CaseIterable {
    case idle
    case wander
    case slash
    case jump
    case stretch
    case lookAround
}

struct PetPose {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let scaleX: CGFloat
    let scaleY: CGFloat
    let rotation: CGFloat
    let shadowScaleX: CGFloat
    let shadowScaleY: CGFloat
    let shadowAlpha: CGFloat
    let flipHorizontally: Bool

    static let neutral = PetPose(
        offsetX: 0,
        offsetY: 0,
        scaleX: 1,
        scaleY: 1,
        rotation: 0,
        shadowScaleX: 1,
        shadowScaleY: 1,
        shadowAlpha: 0.20,
        flipHorizontally: false
    )
}

private struct CodexSessionUsage {
    let inputTokens: Int
    let outputTokens: Int
    let requestCount: Int
    let updatedAt: Date
    let contextUsed: Int
    let contextWindow: Int
    let primaryLimit: Double?
    let primaryResetAt: Date?
    let secondaryLimit: Double?
    let secondaryResetAt: Date?
}

private struct CodexSessionMeta {
    let sessionId: String
    let cwd: String
    let model: String
    let effort: String
    let cliVersion: String
}

private struct CodexUsageSummary {
    let inputTokens: Int
    let outputTokens: Int
    let requestCount: Int
    let sessionCount: Int
    let updatedAt: Date
    let contextUsed: Int
    let contextWindow: Int
    let primaryLimit: Double?
    let primaryResetAt: Date?
    let secondaryLimit: Double?
    let secondaryResetAt: Date?
    let changedFiles: Int
    let latestMeta: CodexSessionMeta?
}

private final class CodexFileState {
    var offset: UInt64 = 0
    var remainder = ""
    var usage: CodexSessionUsage?
    var seenTotals = Set<Int>()
    var initialized = false
    var meta: CodexSessionMeta?
}

private final class CodexUsageAccumulator {
    private let homeUrl: URL
    private let days: Int
    private var files: [String: CodexFileState] = [:]
    private var lastDiscovery = Date.distantPast
    private var knownFileUrls: [URL] = []

    init(homeUrl: URL, days: Int) {
        self.homeUrl = homeUrl
        self.days = days
    }

    func refresh() -> CodexUsageSummary {
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 86_400))
        let fileUrls = discoverIfNeeded()
        var changedFiles = 0

        for fileUrl in fileUrls {
            if refreshFile(fileUrl, cutoff: cutoff) {
                changedFiles += 1
            }
        }

        pruneBefore(cutoff)
        return summary(changedFiles: changedFiles)
    }

    private func discoverIfNeeded() -> [URL] {
        if Date().timeIntervalSince(lastDiscovery) < 30, !knownFileUrls.isEmpty {
            return knownFileUrls
        }

        let scanUrls = [
            homeUrl.appendingPathComponent("sessions"),
            homeUrl.appendingPathComponent("archived_sessions")
        ]
        var urls: [URL] = []
        for scanUrl in scanUrls {
            guard let enumerator = FileManager.default.enumerator(
                at: scanUrl,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileUrl as URL in enumerator where fileUrl.pathExtension == "jsonl" {
                urls.append(fileUrl)
            }
        }
        knownFileUrls = urls
        lastDiscovery = Date()
        return urls
    }

    private func refreshFile(_ fileUrl: URL, cutoff: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        let key = fileUrl.path
        let state = files[key] ?? CodexFileState()
        files[key] = state

        let size = fileSize.uint64Value
        if size < state.offset {
            state.offset = 0
            state.remainder = ""
            state.usage = nil
            state.seenTotals.removeAll()
        }
        guard size > state.offset else {
            return false
        }

        guard let handle = try? FileHandle(forReadingFrom: fileUrl) else {
            return false
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: state.offset)
            let data = try handle.readToEnd() ?? Data()
            state.offset = size
            guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
                return false
            }
        parseChunk(state.remainder + chunk, into: state, cutoff: cutoff)
        let wasInitialized = state.initialized
        state.initialized = true
        return wasInitialized
        } catch {
            return false
        }
    }

    private func parseChunk(_ text: String, into state: CodexFileState, cutoff: Date) {
        let endsWithNewline = text.hasSuffix("\n")
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !endsWithNewline {
            state.remainder = parts.popLast() ?? ""
        } else {
            state.remainder = ""
        }

        for line in parts where !line.isEmpty {
            parseLine(line, into: state, cutoff: cutoff)
        }
    }

    private func parseLine(_ line: String, into state: CodexFileState, cutoff: Date) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if object["type"] as? String == "session_meta",
           let payload = object["payload"] as? [String: Any] {
            state.meta = CodexSessionMeta(
                sessionId: payload["id"] as? String ?? "",
                cwd: payload["cwd"] as? String ?? "",
                model: payload["model"] as? String ?? "",
                effort: payload["effort"] as? String ?? "",
                cliVersion: payload["cli_version"] as? String ?? ""
            )
            return
        }

        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestampText = object["timestamp"] as? String,
              let timestamp = parseCodexTimestamp(timestampText),
              let info = payload["info"] as? [String: Any],
              let totalUsage = info["total_token_usage"] as? [String: Any] else {
            return
        }
        let lastUsage = info["last_token_usage"] as? [String: Any]

        let totalTokens = intValue(totalUsage["total_tokens"])
        state.seenTotals.insert(totalTokens)
        guard timestamp >= cutoff else {
            return
        }

        let rateLimits = payload["rate_limits"] as? [String: Any]
        let primary = rateLimits?["primary"] as? [String: Any]
        let secondary = rateLimits?["secondary"] as? [String: Any]
        state.usage = CodexSessionUsage(
            inputTokens: intValue(totalUsage["input_tokens"]),
            outputTokens: intValue(totalUsage["output_tokens"]),
            requestCount: max(state.seenTotals.count, 1),
            updatedAt: timestamp,
            contextUsed: intValue(lastUsage?["total_tokens"], fallback: intValue(totalUsage["total_tokens"])),
            contextWindow: intValue(info["model_context_window"]),
            primaryLimit: optionalDouble(primary?["used_percent"]),
            primaryResetAt: unixDate(primary?["resets_at"]),
            secondaryLimit: optionalDouble(secondary?["used_percent"]),
            secondaryResetAt: unixDate(secondary?["resets_at"])
        )
    }

    private func pruneBefore(_ cutoff: Date) {
        for state in files.values {
            if let usage = state.usage, usage.updatedAt < cutoff {
                state.usage = nil
            }
        }
    }

    private func summary(changedFiles: Int) -> CodexUsageSummary {
        var inputTokens = 0
        var outputTokens = 0
        var requestCount = 0
        var sessionCount = 0
        var latest = Date.distantPast
        var contextUsed = 0
        var contextWindow = 0
        var primaryLimit: Double?
        var primaryResetAt: Date?
        var secondaryLimit: Double?
        var secondaryResetAt: Date?
        var latestMeta: CodexSessionMeta?

        for state in files.values {
            guard let usage = state.usage else {
                continue
            }
            inputTokens += usage.inputTokens
            outputTokens += usage.outputTokens
            requestCount += usage.requestCount
            sessionCount += 1
            if usage.updatedAt > latest {
                latest = usage.updatedAt
                contextUsed = usage.contextUsed
                contextWindow = usage.contextWindow
                primaryLimit = usage.primaryLimit
                primaryResetAt = usage.primaryResetAt
                secondaryLimit = usage.secondaryLimit
                secondaryResetAt = usage.secondaryResetAt
                latestMeta = state.meta
            }
        }

        return CodexUsageSummary(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            requestCount: requestCount,
            sessionCount: sessionCount,
            updatedAt: latest,
            contextUsed: contextUsed,
            contextWindow: contextWindow,
            primaryLimit: primaryLimit,
            primaryResetAt: primaryResetAt,
            secondaryLimit: secondaryLimit,
            secondaryResetAt: secondaryResetAt,
            changedFiles: changedFiles,
            latestMeta: latestMeta
        )
    }
}

final class PetView: NSView {
    var snapshots: [UsageSnapshot] = []
    var selectedProviderId = "all"
    var panelVisible = false
    var expression = "idle"
    var animationFrame = 0
    var action = PetAction.idle
    var onSelectProvider: ((String) -> Void)?
    var onTogglePanel: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?

    private var dragStart: NSPoint?
    private var draggedDistance: CGFloat = 0
    private var actionFrame = 0
    private var actionDurationFrames = 40
    private let pixelPetImage: NSImage? = {
        let path = FileManager.default.currentDirectoryPath + "/assets/pixel-pet.png"
        return NSImage(contentsOfFile: path)
    }()

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPet(in: NSRect(x: 6, y: 8, width: 178, height: bounds.height - 16))
        if panelVisible {
            drawPanel(in: NSRect(x: 190, y: 18, width: bounds.width - 210, height: bounds.height - 36))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        draggedDistance = 0
        if event.clickCount == 2 {
            onRefresh?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window, let dragStart = dragStart else { return }
        let current = event.locationInWindow
        draggedDistance += abs(current.x - dragStart.x) + abs(current.y - dragStart.y)
        var origin = window.frame.origin
        origin.x += current.x - dragStart.x
        origin.y += current.y - dragStart.y
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if draggedDistance < 5 && event.clickCount == 1 {
            onTogglePanel?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(menuItem("全部厂商") { self.onSelectProvider?("all") })
        for snapshot in snapshots {
            menu.addItem(menuItem(snapshot.providerName) { self.onSelectProvider?(snapshot.providerId) })
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("刷新") { self.onRefresh?() })
        menu.addItem(menuItem(panelVisible ? "收起" : "展开") { self.onTogglePanel?() })
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("退出") { self.onQuit?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func menuItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, actionBlock: action)
    }

    private func selectedSnapshots() -> [UsageSnapshot] {
        if selectedProviderId == "all" { return snapshots }
        return snapshots.filter { $0.providerId == selectedProviderId }
    }

    private func drawPet(in rect: NSRect) {
        let selected = selectedSnapshots()
        let total = selected.reduce(0) { $0 + $1.totalTokens }
        let hasError = selected.contains { $0.status == "error" }
        let bob = CGFloat(sin(Double(animationFrame) / 10.0) * 3.0)
        let scale = selectedProviderId == "all" ? 1.0 : 1.03
        let petSize = CGSize(width: 156 * scale, height: 156 * scale)
        let pose = poseForCurrentAction(baseBob: bob)
        let petX = rect.midX - petSize.width / 2 + pose.offsetX
        let petY = rect.minY + 18 + pose.offsetY

        let shadowWidth = 112 * pose.shadowScaleX
        let shadowHeight = 18 * pose.shadowScaleY
        let shadow = NSBezierPath(ovalIn: NSRect(
            x: rect.midX - shadowWidth / 2 + pose.offsetX * 0.45,
            y: rect.minY + 10,
            width: shadowWidth,
            height: shadowHeight
        ))
        NSColor(calibratedWhite: 0.0, alpha: pose.shadowAlpha).setFill()
        shadow.fill()

        if let image = pixelPetImage {
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext.current
            context?.imageInterpolation = .none
            let imageRect = NSRect(
                origin: NSPoint(x: petX, y: petY),
                size: CGSize(width: petSize.width * abs(pose.scaleX), height: petSize.height * abs(pose.scaleY))
            )
            let transform = NSAffineTransform()
            transform.translateX(by: imageRect.midX, yBy: imageRect.midY)
            if pose.flipHorizontally {
                transform.scaleX(by: -1, yBy: 1)
            }
            transform.rotate(byDegrees: pose.rotation)
            transform.translateX(by: -imageRect.midX, yBy: -imageRect.midY)
            transform.concat()
            image.draw(in: imageRect,
                       from: .zero,
                       operation: .sourceOver,
                       fraction: hasError ? 0.88 : 1.0,
                       respectFlipped: true,
                       hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            if action == .slash {
                drawSlashEffect(center: NSPoint(x: imageRect.midX + 20, y: imageRect.midY + 12))
            }
        } else {
            drawText("pet asset missing", rect: rect, fontSize: 10, color: red, bold: true, alignment: .center)
        }

        if let codexStatus = selected.first?.codexStatus {
            drawLimitBadge(
                topText: "5h: \(limitPercentText(usedPercent: codexStatus.primaryUsedPercent))",
                bottomText: "7d: \(limitPercentText(usedPercent: codexStatus.secondaryUsedPercent))",
                center: NSPoint(x: rect.midX + 56, y: rect.minY + 148)
            )
        } else if expression == "working" {
            drawStatusPip("...", center: NSPoint(x: rect.midX + 56, y: rect.minY + 148), color: green)
        } else if hasError {
            drawStatusPip("!", center: NSPoint(x: rect.midX + 56, y: rect.minY + 148), color: red)
        } else {
            drawStatusPip(compactNumber(total), center: NSPoint(x: rect.midX + 56, y: rect.minY + 148), color: usageColor(total))
        }
    }

    private func drawPanel(in rect: NSRect) {
        let selected = selectedSnapshots()
        if let codexStatus = selected.first?.codexStatus {
            drawCodexStatusPanel(codexStatus, snapshot: selected.first!, in: rect)
            return
        }

        let totalInput = selected.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = selected.reduce(0) { $0 + $1.outputTokens }
        let totalRequests = selected.reduce(0) { $0 + $1.requests }
        let totalCost = selected.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
        let hasCost = selected.contains { $0.costUsd != nil }
        let hasError = selected.contains { $0.status == "error" }
        let title = selectedProviderId == "all" ? "全部厂商" : selected.first?.providerName ?? "无数据"

        drawSpeechBubble(rect)
        drawText(title, rect: NSRect(x: rect.minX + 18, y: rect.maxY - 32, width: rect.width - 30, height: 20), fontSize: 15, color: ink, bold: true)
        let status = hasError ? "有厂商查询失败" : "已更新 \(timeString(selected.map { $0.updatedAt }.max() ?? Date()))"
        drawText(status, rect: NSRect(x: rect.minX + 18, y: rect.maxY - 51, width: rect.width - 30, height: 16), fontSize: 10, color: hasError ? red : muted)
        drawText(compactNumber(totalInput + totalOutput), rect: NSRect(x: rect.minX + 18, y: rect.maxY - 89, width: rect.width - 30, height: 30), fontSize: 25, color: ink, bold: true)
        let costText = hasCost ? " · $\(String(format: "%.2f", totalCost))" : ""
        drawText("输入 \(compactNumber(totalInput)) · 输出 \(compactNumber(totalOutput)) · 记录 \(compactNumber(totalRequests))\(costText)", rect: NSRect(x: rect.minX + 18, y: rect.maxY - 108, width: rect.width - 30, height: 15), fontSize: 10, color: muted)

        var rowY = rect.maxY - 137
        for snapshot in snapshots {
            drawProviderRow(snapshot, x: rect.minX + 18, y: rowY, width: rect.width - 34)
            rowY -= 34
        }
        drawText("拖动移动 · 双击刷新 · 右键菜单", rect: NSRect(x: rect.minX + 18, y: rect.minY + 13, width: rect.width - 30, height: 14), fontSize: 9, color: muted)
    }

    private func drawCodexStatusPanel(_ status: CodexStatus, snapshot: UsageSnapshot, in rect: NSRect) {
        drawSpeechBubble(rect)
        let x = rect.minX + 18
        var y = rect.maxY - 28
        let width = rect.width - 34

        drawText(">_ OpenAI Codex", rect: NSRect(x: x, y: y, width: width - 60, height: 18), fontSize: 13, color: ink, bold: true)
        drawText("v\(status.cliVersion)", rect: NSRect(x: rect.maxX - 84, y: y, width: 66, height: 18), fontSize: 10, color: muted, alignment: .right)
        y -= 24
        drawText("Visit chatgpt.com/codex/settings/usage for official limits.", rect: NSRect(x: x, y: y, width: width, height: 15), fontSize: 9, color: NSColor(calibratedRed: 0.235, green: 0.510, blue: 0.494, alpha: 1))
        y -= 24

        drawStatusRow("Model:", "\(status.model) (reasoning \(status.reasoning))", x: x, y: y, width: width)
        y -= 17
        drawStatusRow("Directory:", status.directory, x: x, y: y, width: width)
        y -= 17
        drawStatusRow("Account:", "\(status.account) (\(status.plan))", x: x, y: y, width: width)
        y -= 17
        drawStatusRow("Session:", shortSession(status.sessionId), x: x, y: y, width: width)
        y -= 24

        let contextLeft = max(0, status.contextWindow - status.contextUsed)
        let contextPercent = status.contextWindow > 0 ? Double(contextLeft) / Double(status.contextWindow) : 0
        drawStatusRow("Context:", "\(Int(contextPercent * 100))% left (\(compactNumber(contextLeft)) left / \(compactNumber(status.contextWindow)))", x: x, y: y, width: width)
        y -= 21

        drawLimitRow(
            "5h remaining:",
            usedPercent: status.primaryUsedPercent,
            resetAt: status.primaryResetAt,
            x: x,
            y: y,
            width: width
        )
        y -= 21
        drawLimitRow(
            "Weekly:",
            usedPercent: status.secondaryUsedPercent,
            resetAt: status.secondaryResetAt,
            x: x,
            y: y,
            width: width
        )
        y -= 24

        let fiveHourRemaining = remainingPercent(usedPercent: status.primaryUsedPercent)
        let fiveHourText = status.primaryUsedPercent == nil ? "unknown" : "\(Int(fiveHourRemaining))%"
        drawText("5h remaining: \(fiveHourText) · records \(compactNumber(snapshot.requests)) · \(snapshot.message)", rect: NSRect(x: x, y: y, width: width, height: 15), fontSize: 9, color: muted)
    }

    private func drawStatusRow(_ label: String, _ value: String, x: CGFloat, y: CGFloat, width: CGFloat) {
        drawText(label, rect: NSRect(x: x, y: y, width: 78, height: 15), fontSize: 10, color: muted)
        drawText(value, rect: NSRect(x: x + 86, y: y, width: width - 86, height: 15), fontSize: 10, color: ink)
    }

    private func drawLimitRow(_ label: String, usedPercent: Double?, resetAt: Date?, x: CGFloat, y: CGFloat, width: CGFloat) {
        let left = remainingPercent(usedPercent: usedPercent)
        drawText(label, rect: NSRect(x: x, y: y, width: 78, height: 15), fontSize: 10, color: muted)
        drawProgressBar(leftPercent: left, rect: NSRect(x: x + 86, y: y + 2, width: 88, height: 10))
        let reset = resetAt.map { " (resets \(timeString($0)))" } ?? ""
        drawText("\(Int(left))% remaining\(reset)", rect: NSRect(x: x + 184, y: y, width: width - 184, height: 15), fontSize: 10, color: ink)
    }

    private func drawProgressBar(leftPercent: Double, rect: NSRect) {
        let track = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        NSColor(calibratedWhite: 0.78, alpha: 0.75).setFill()
        track.fill()
        let fillWidth = rect.width * CGFloat(max(0, min(100, leftPercent)) / 100)
        let fill = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height), xRadius: 2, yRadius: 2)
        NSColor(calibratedWhite: 0.24, alpha: 0.90).setFill()
        fill.fill()
    }

    private func drawProviderRow(_ snapshot: UsageSnapshot, x: CGFloat, y: CGFloat, width: CGFloat) {
        if snapshot.providerId == selectedProviderId {
            NSColor(calibratedRed: 1.0, green: 0.982, blue: 0.930, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 7, y: y - 4, width: width + 10, height: 31), xRadius: 9, yRadius: 9).fill()
        }
        let dotColor = snapshot.status == "error" ? red : usageColor(snapshot.totalTokens)
        let dot = NSBezierPath(ovalIn: NSRect(x: x, y: y + 9, width: 9, height: 9))
        dotColor.setFill()
        dot.fill()
        drawText(snapshot.providerName, rect: NSRect(x: x + 17, y: y + 12, width: width - 20, height: 15), fontSize: 11, color: ink)
        let suffix = snapshot.message.isEmpty ? "" : " · \(snapshot.message)"
        let detail = snapshot.status == "error" ? snapshot.message : "\(compactNumber(snapshot.totalTokens)) tokens · \(compactNumber(snapshot.requests)) records\(suffix)"
        drawText(detail, rect: NSRect(x: x + 17, y: y - 1, width: width - 20, height: 13), fontSize: 9, color: muted)
    }

    private func drawSpeechBubble(_ rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.22)
        shadow.set()
        let bubble = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        glass.setFill()
        bubble.fill()
        NSGraphicsContext.restoreGraphicsState()

        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 58))
        tail.line(to: NSPoint(x: rect.minX - 18, y: rect.maxY - 70))
        tail.line(to: NSPoint(x: rect.minX + 5, y: rect.maxY - 84))
        tail.close()
        glass.setFill()
        tail.fill()

        line.withAlphaComponent(0.55).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()
    }

    private func drawSoftLimb(from: NSPoint, to: NSPoint, accent: NSColor) {
        let path = NSBezierPath()
        path.move(to: from)
        path.curve(to: to, controlPoint1: NSPoint(x: from.x - 10, y: from.y + 10), controlPoint2: NSPoint(x: to.x + 4, y: to.y - 6))
        darken(accent, amount: 0.28).setStroke()
        path.lineWidth = 13
        path.lineCapStyle = .round
        path.stroke()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: from.x - 1, y: from.y + 2))
        highlight.curve(to: NSPoint(x: to.x - 2, y: to.y + 2), controlPoint1: NSPoint(x: from.x - 9, y: from.y + 12), controlPoint2: NSPoint(x: to.x + 2, y: to.y - 2))
        lighten(accent, amount: 0.25).withAlphaComponent(0.82).setStroke()
        highlight.lineWidth = 5
        highlight.lineCapStyle = .round
        highlight.stroke()
    }

    private func drawGlossyOval(_ rect: NSRect, top: NSColor, bottom: NSColor, stroke: NSColor, width: CGFloat) {
        let path = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 9
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.16)
        shadow.set()
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        stroke.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    private func drawCore(in rect: NSRect, accent: NSColor, total: Int) {
        let outer = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
        NSColor(calibratedWhite: 1, alpha: 0.84).setFill()
        outer.fill()
        darken(accent, amount: 0.18).withAlphaComponent(0.55).setStroke()
        outer.lineWidth = 1.4
        outer.stroke()

        let fillHeight = max(8, min(rect.height - 8, rect.height * CGFloat(min(Double(total) / 2_000_000.0, 1.0))))
        let fillRect = NSRect(x: rect.minX + 7, y: rect.minY + 7, width: rect.width - 14, height: fillHeight)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 14, yRadius: 14)
        NSGradient(starting: lighten(accent, amount: 0.42), ending: accent)?.draw(in: fillPath, angle: 90)

        drawText("TOK", rect: NSRect(x: rect.minX, y: rect.midY - 7, width: rect.width, height: 14), fontSize: 10, color: darken(accent, amount: 0.45), bold: true, alignment: .center)
    }

    private func drawFace(center: NSPoint, error: Bool) {
        let leftEye = NSBezierPath(ovalIn: NSRect(x: center.x - 29, y: center.y + 1, width: 16, height: 18))
        let rightEye = NSBezierPath(ovalIn: NSRect(x: center.x + 13, y: center.y + 1, width: 16, height: 18))
        ink.setFill()
        leftEye.fill()
        rightEye.fill()
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 24, y: center.y + 11, width: 5, height: 5)).fill()
        NSBezierPath(ovalIn: NSRect(x: center.x + 18, y: center.y + 11, width: 5, height: 5)).fill()

        let mouth = NSBezierPath()
        if error {
            mouth.move(to: NSPoint(x: center.x - 10, y: center.y - 12))
            mouth.line(to: NSPoint(x: center.x + 10, y: center.y - 12))
        } else {
            mouth.appendArc(withCenter: NSPoint(x: center.x, y: center.y - 8), radius: 11, startAngle: 205, endAngle: 335, clockwise: false)
        }
        ink.setStroke()
        mouth.lineWidth = 2.2
        mouth.stroke()
    }

    private func drawGloss(in rect: NSRect) {
        let gloss = NSBezierPath(ovalIn: NSRect(x: rect.minX + 26, y: rect.minY + 46, width: 52, height: 18))
        NSColor.white.withAlphaComponent(0.34).setFill()
        gloss.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: rect.minX + 88, y: rect.minY + 50, width: 14, height: 7))
        NSColor.white.withAlphaComponent(0.22).setFill()
        dot.fill()
    }

    private func drawStatusPip(_ text: String, center: NSPoint, color: NSColor) {
        let rect = NSRect(x: center.x - 24, y: center.y - 13, width: 48, height: 26)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 8
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.20)
        shadow.set()
        NSColor.white.withAlphaComponent(0.92).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        color.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        drawText(text, rect: NSRect(x: rect.minX + 4, y: rect.minY + 6, width: rect.width - 8, height: 14), fontSize: 10, color: darken(color, amount: 0.38), bold: true, alignment: .center)
    }

    private func drawLimitBadge(topText: String, bottomText: String, center: NSPoint) {
        let rect = NSRect(x: center.x - 30, y: center.y - 18, width: 60, height: 38)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 8
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.18)
        shadow.set()
        NSColor.white.withAlphaComponent(0.96).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        line.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        drawText(topText, rect: NSRect(x: rect.minX + 4, y: rect.minY + 20, width: rect.width - 8, height: 10), fontSize: 8.5, color: muted, bold: true, alignment: .center)
        drawText(bottomText, rect: NSRect(x: rect.minX + 4, y: rect.minY + 8, width: rect.width - 8, height: 10), fontSize: 8.5, color: muted, bold: true, alignment: .center)
    }

    private func poseForCurrentAction(baseBob: CGFloat) -> PetPose {
        let progress = min(max(CGFloat(actionFrame) / CGFloat(max(actionDurationFrames, 1)), 0), 1)
        switch action {
        case .idle:
            let drift = CGFloat(sin(Double(animationFrame) / 16.0) * 2.0)
            return PetPose(
                offsetX: drift,
                offsetY: baseBob,
                scaleX: 1,
                scaleY: 1,
                rotation: drift * 0.7,
                shadowScaleX: 1,
                shadowScaleY: 1,
                shadowAlpha: 0.20,
                flipHorizontally: false
            )
        case .wander:
            let step = sin(progress * .pi * 2)
            let lift = abs(sin(progress * .pi * 4)) * 5
            return PetPose(
                offsetX: step * 26,
                offsetY: baseBob + lift,
                scaleX: 1,
                scaleY: 1,
                rotation: step * 3.5,
                shadowScaleX: 0.90,
                shadowScaleY: 0.92,
                shadowAlpha: 0.18,
                flipHorizontally: step < 0
            )
        case .slash:
            let swing = sin(progress * .pi)
            return PetPose(
                offsetX: swing * 18,
                offsetY: baseBob + swing * 10,
                scaleX: 1.08,
                scaleY: 1.08,
                rotation: -28 + swing * 36,
                shadowScaleX: 0.82,
                shadowScaleY: 0.85,
                shadowAlpha: 0.16,
                flipHorizontally: false
            )
        case .jump:
            let arc = sin(progress * .pi)
            return PetPose(
                offsetX: 0,
                offsetY: baseBob + arc * 34,
                scaleX: 0.96 + arc * 0.10,
                scaleY: 1.02 + arc * 0.06,
                rotation: sin(progress * .pi * 2) * 4,
                shadowScaleX: 1 - arc * 0.30,
                shadowScaleY: 1 - arc * 0.25,
                shadowAlpha: 0.12 + (1 - arc) * 0.06,
                flipHorizontally: false
            )
        case .stretch:
            let stretch = sin(progress * .pi)
            return PetPose(
                offsetX: 0,
                offsetY: baseBob - stretch * 6,
                scaleX: 1 - stretch * 0.12,
                scaleY: 1 + stretch * 0.22,
                rotation: 0,
                shadowScaleX: 1 + stretch * 0.12,
                shadowScaleY: 1 - stretch * 0.12,
                shadowAlpha: 0.19,
                flipHorizontally: false
            )
        case .lookAround:
            let glance = sin(progress * .pi * 2)
            return PetPose(
                offsetX: glance * 8,
                offsetY: baseBob,
                scaleX: 1,
                scaleY: 1,
                rotation: glance * 6,
                shadowScaleX: 1,
                shadowScaleY: 1,
                shadowAlpha: 0.20,
                flipHorizontally: false
            )
        }
    }

    private func drawSlashEffect(center: NSPoint) {
        let progress = min(max(CGFloat(actionFrame) / CGFloat(max(actionDurationFrames, 1)), 0), 1)
        let alpha = max(0, sin(progress * .pi)) * 0.7
        guard alpha > 0.01 else { return }

        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - 56, y: center.y - 18))
        path.curve(
            to: NSPoint(x: center.x + 42, y: center.y + 26),
            controlPoint1: NSPoint(x: center.x - 18, y: center.y - 36),
            controlPoint2: NSPoint(x: center.x + 18, y: center.y + 18)
        )
        NSColor(calibratedRed: 0.585, green: 0.882, blue: 0.478, alpha: alpha).setStroke()
        path.lineWidth = 8
        path.lineCapStyle = .round
        path.stroke()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: center.x - 48, y: center.y - 12))
        highlight.curve(
            to: NSPoint(x: center.x + 34, y: center.y + 22),
            controlPoint1: NSPoint(x: center.x - 14, y: center.y - 26),
            controlPoint2: NSPoint(x: center.x + 14, y: center.y + 14)
        )
        NSColor.white.withAlphaComponent(alpha * 0.65).setStroke()
        highlight.lineWidth = 3
        highlight.lineCapStyle = .round
        highlight.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func tickAnimation() {
        animationFrame += 1
        actionFrame += 1
        if actionFrame >= actionDurationFrames {
            chooseNextAction()
        }
        needsDisplay = true
    }

    private func chooseNextAction() {
        let pool = PetAction.allCases.filter { $0 != action }
        action = pool.randomElement() ?? .idle
        actionFrame = 0
        switch action {
        case .idle:
            actionDurationFrames = Int.random(in: 24...42)
        case .wander:
            actionDurationFrames = Int.random(in: 30...44)
        case .slash:
            actionDurationFrames = Int.random(in: 16...24)
        case .jump:
            actionDurationFrames = Int.random(in: 18...26)
        case .stretch:
            actionDurationFrames = Int.random(in: 20...30)
        case .lookAround:
            actionDurationFrames = Int.random(in: 22...34)
        }
    }

    private func drawLine(from: NSPoint, to: NSPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        ink.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawSmile(centerX: CGFloat, centerY: CGFloat, error: Bool) {
        let path = NSBezierPath()
        if error {
            path.move(to: NSPoint(x: centerX - 7, y: centerY))
            path.line(to: NSPoint(x: centerX + 7, y: centerY))
        } else {
            path.appendArc(withCenter: NSPoint(x: centerX, y: centerY + 2), radius: 9, startAngle: 205, endAngle: 335, clockwise: false)
        }
        ink.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawSpinner(center: NSPoint) {
        for i in 0..<6 {
            let angle = Double(animationFrame) / 3.0 + Double(i)
            let x = center.x + CGFloat(cos(angle) * 14)
            let y = center.y + CGFloat(sin(angle) * 7)
            let shade = CGFloat(80 + i * 22) / 255.0
            NSColor(calibratedWhite: shade, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 2, y: y - 2, width: 4, height: 4)).fill()
        }
    }

    private func drawText(_ text: String, rect: NSRect, fontSize: CGFloat, color: NSColor, bold: Bool = false, alignment: NSTextAlignment = .left) {
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        NSString(string: text).draw(in: rect, withAttributes: attrs)
    }

    override func mouseMoved(with event: NSEvent) {}
}

final class ClosureMenuItem: NSMenuItem {
    private let actionBlock: () -> Void

    init(title: String, actionBlock: @escaping () -> Void) {
        self.actionBlock = actionBlock
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runAction() {
        actionBlock()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var petView: PetView!
    private var store: ProviderStore!
    private var refreshTimer: Timer?
    private var animationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        store = ProviderStore(configUrl: cwd.appendingPathComponent("providers.json"))
        petView = PetView(frame: NSRect(x: 0, y: 0, width: 210, height: 230))
        petView.onSelectProvider = { [weak self] providerId in self?.selectProvider(providerId) }
        petView.onTogglePanel = { [weak self] in self?.togglePanel() }
        petView.onRefresh = { [weak self] in self?.refresh() }
        petView.onQuit = { NSApp.terminate(nil) }

        window = NSWindow(
            contentRect: NSRect(x: 80, y: 720, width: 210, height: 230),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = petView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(store.refreshSeconds, 1), repeats: true) { [weak self] _ in
            self?.refresh()
        }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.petView.tickAnimation()
        }
    }

    private func refresh() {
        petView.expression = "working"
        petView.needsDisplay = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshots = self.store.fetchAll()
            DispatchQueue.main.async {
                self.petView.snapshots = snapshots
                if self.petView.selectedProviderId != "all" &&
                    !snapshots.contains(where: { $0.providerId == self.petView.selectedProviderId }) {
                    self.petView.selectedProviderId = "all"
                }
                self.petView.expression = snapshots.contains(where: { $0.status == "error" }) ? "alert" : "idle"
                self.petView.needsDisplay = true
            }
        }
    }

    private func selectProvider(_ providerId: String) {
        petView.selectedProviderId = providerId
        petView.needsDisplay = true
    }

    private func togglePanel() {
        petView.panelVisible.toggle()
        let width: CGFloat = petView.panelVisible ? 560 : 210
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true, animate: true)
        petView.frame.size.width = width
        petView.needsDisplay = true
    }
}

struct RuntimeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

func syncRequest(_ request: URLRequest) throws -> Data {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Data, Error>!
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            result = .failure(error)
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            result = .failure(RuntimeError("HTTP \(http.statusCode) \(String(body.prefix(240)))"))
        } else {
            result = .success(data ?? Data())
        }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return try result.get()
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RuntimeError("expected JSON object")
    }
    return object
}

func readCodexConfig(homeUrl: URL) -> (model: String, reasoning: String) {
    let url = homeUrl.appendingPathComponent("config.toml")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        return ("", "")
    }
    var model = ""
    var reasoning = ""
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("model =") && model.isEmpty {
            model = tomlStringValue(line)
        } else if line.hasPrefix("model_reasoning_effort =") && reasoning.isEmpty {
            reasoning = tomlStringValue(line)
        }
    }
    return (model, reasoning)
}

func readCodexAccount(homeUrl: URL) -> (email: String, plan: String) {
    let url = homeUrl.appendingPathComponent("auth.json")
    guard let data = try? Data(contentsOf: url),
          let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = auth["tokens"] as? [String: Any],
          let idToken = tokens["id_token"] as? String,
          let payload = decodeJwtPayload(idToken) else {
        return ("unknown", "unknown")
    }
    let email = payload["email"] as? String ?? payloadValue(payload, path: ["https://api.openai.com/profile", "email"]) ?? "unknown"
    let plan = payloadValue(payload, path: ["https://api.openai.com/auth", "chatgpt_plan_type"]) ?? "unknown"
    return (email, plan)
}

func decodeJwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let padding = payload.count % 4
    if padding > 0 {
        payload += String(repeating: "=", count: 4 - padding)
    }
    guard let data = Data(base64Encoded: payload),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

func payloadValue(_ payload: [String: Any], path: [String]) -> String? {
    var current: Any? = payload
    for key in path {
        current = (current as? [String: Any])?[key]
    }
    return current as? String
}

func tomlStringValue(_ line: String) -> String {
    guard let equal = line.firstIndex(of: "=") else { return "" }
    let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
    return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
}

func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

private func latestContextUsed(summary: CodexUsageSummary) -> Int {
    guard summary.contextWindow > 0 else { return summary.contextUsed }
    return min(summary.contextUsed, summary.contextWindow)
}

func parseCodexTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

func printUsageForCli() {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let store = ProviderStore(configUrl: cwd.appendingPathComponent("providers.json"))
    printUsageForCli(store: store)
}

func printUsageForCli(store: ProviderStore) {
    for snapshot in store.fetchAll() {
        let cost = snapshot.costUsd.map { String(format: "$%.2f", $0) } ?? "-"
        print("\(timeString(Date())) \(snapshot.providerName): \(snapshot.totalTokens) tokens, input=\(snapshot.inputTokens), output=\(snapshot.outputTokens), records=\(snapshot.requests), cost=\(cost), status=\(snapshot.status), message=\(snapshot.message)")
    }
}

func watchUsageForCli() {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let store = ProviderStore(configUrl: cwd.appendingPathComponent("providers.json"))
    repeat {
        printUsageForCli(store: store)
        fflush(stdout)
        Thread.sleep(forTimeInterval: 3)
    } while true
}

func printStatusForCli() {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let store = ProviderStore(configUrl: cwd.appendingPathComponent("providers.json"))
    guard let snapshot = store.fetchAll().first, let status = snapshot.codexStatus else {
        print("No Codex status available")
        return
    }

    let contextLeft = max(0, status.contextWindow - status.contextUsed)
    let contextPercent = status.contextWindow > 0 ? Int(Double(contextLeft) / Double(status.contextWindow) * 100) : 0
    print(">_ OpenAI Codex (v\(status.cliVersion))")
    print("")
    print("Model:          \(status.model) (reasoning \(status.reasoning))")
    print("Directory:      \(status.directory)")
    print("Account:        \(status.account) (\(status.plan))")
    print("Session:        \(shortSession(status.sessionId))")
    print("")
    print("Context window: \(contextPercent)% left (\(compactNumber(contextLeft)) left / \(compactNumber(status.contextWindow)))")
    print("5h remaining:   \(limitLine(usedPercent: status.primaryUsedPercent, resetAt: status.primaryResetAt))")
    print("Weekly limit:   \(limitLine(usedPercent: status.secondaryUsedPercent, resetAt: status.secondaryResetAt))")
    print("Tokens:         \(compactNumber(snapshot.totalTokens)) total · input \(compactNumber(snapshot.inputTokens)) · output \(compactNumber(snapshot.outputTokens))")
    print("Source:         local Codex token_count events · \(snapshot.message)")
}

func expandEnv(_ value: String) -> String {
    var result = value
    for (key, envValue) in ProcessInfo.processInfo.environment {
        result = result.replacingOccurrences(of: "${\(key)}", with: envValue)
    }
    return result
}

func intValue(_ value: Any?, fallback: Int = 0) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? Double { return Int(value) }
    if let value = value as? String { return Int(value) ?? fallback }
    return fallback
}

func doubleValue(_ value: Any?, fallback: Double = 0) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? String { return Double(value) ?? fallback }
    return fallback
}

func optionalDouble(_ value: Any?) -> Double? {
    if value == nil { return nil }
    return doubleValue(value, fallback: 0)
}

func unixDate(_ value: Any?) -> Date? {
    let seconds = doubleValue(value, fallback: -1)
    if seconds < 0 { return nil }
    return Date(timeIntervalSince1970: seconds)
}

func shortSession(_ value: String) -> String {
    if value.count <= 36 { return value }
    return String(value.prefix(8)) + "..." + String(value.suffix(8))
}

func remainingPercent(usedPercent: Double?) -> Double {
    let used = max(0, min(100, usedPercent ?? 0))
    return 100 - used
}

func limitPercentText(usedPercent: Double?) -> String {
    guard usedPercent != nil else { return "unknown" }
    return "\(Int(remainingPercent(usedPercent: usedPercent)))%"
}

func limitLine(usedPercent: Double?, resetAt: Date?) -> String {
    guard let usedPercent else { return "unknown" }
    let left = remainingPercent(usedPercent: usedPercent)
    let reset = resetAt.map { " (resets \(timeString($0)))" } ?? ""
    return "\(Int(left))% remaining\(reset)"
}

func usageColor(_ totalTokens: Int) -> NSColor {
    if totalTokens >= 2_000_000 { return red }
    if totalTokens >= 900_000 { return yellow }
    if totalTokens <= 0 { return blue }
    return green
}

func lighten(_ color: NSColor, amount: CGFloat) -> NSColor {
    mix(color, with: .white, amount: amount)
}

func darken(_ color: NSColor, amount: CGFloat) -> NSColor {
    mix(color, with: .black, amount: amount)
}

func mix(_ color: NSColor, with other: NSColor, amount: CGFloat) -> NSColor {
    let base = color.usingColorSpace(.deviceRGB) ?? color
    let target = other.usingColorSpace(.deviceRGB) ?? other
    let t = max(0, min(1, amount))
    return NSColor(
        calibratedRed: base.redComponent * (1 - t) + target.redComponent * t,
        green: base.greenComponent * (1 - t) + target.greenComponent * t,
        blue: base.blueComponent * (1 - t) + target.blueComponent * t,
        alpha: base.alphaComponent
    )
}

func compactNumber(_ value: Int) -> String {
    let doubleValue = Double(value)
    if abs(doubleValue) >= 1_000_000 {
        return String(format: "%.1fM", doubleValue / 1_000_000)
    }
    if abs(doubleValue) >= 1_000 {
        return String(format: "%.1fK", doubleValue / 1_000)
    }
    return "\(value)"
}

func timeString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

let app = NSApplication.shared
let delegate = AppDelegate()
if CommandLine.arguments.contains("--status") {
    printStatusForCli()
} else if CommandLine.arguments.contains("--watch") {
    watchUsageForCli()
} else if CommandLine.arguments.contains("--print-usage") {
    printUsageForCli()
} else {
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
