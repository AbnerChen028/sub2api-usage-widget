import Cocoa
import Darwin
import Security

struct UsagePayload: Decodable {
    let ok: Bool
    let day: String?
    let fetchedAt: String?
    let totalRequests: Double?
    let totalTokens: Double?
    let totalCacheTokens: Double?
    let totalActualCost: Double?
    let needsCredentials: Bool?
    let error: String?
}

struct UsageStats {
    let totalRequests: Double
    let totalTokens: Double
    let totalCacheTokens: Double
    let totalActualCost: Double
}

struct AuthResult {
    let accessToken: String?
    let refreshToken: String?
    let requires2FA: Bool
}

enum UsageClientError: LocalizedError {
    case needsCredentials(String)
    case invalidBaseUrl
    case requestFailed(Int, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .needsCredentials(let message):
            return message
        case .invalidBaseUrl:
            return "服务地址格式不正确，请重新输入。"
        case .requestFailed(let status, let body):
            if body.isEmpty {
                return "接口返回 \(status)。"
            }
            return "接口返回 \(status)：\(String(body.prefix(160)))"
        case .invalidResponse(let message):
            return message
        }
    }

    var needsCredentials: Bool {
        if case .needsCredentials = self { return true }
        return false
    }
}

enum WidgetDisplayMode {
    case expanded
    case collapsed
}

final class WidgetStateStore {
    private enum Keys {
        static let isCollapsed = "isCollapsed"
        static let expandedFrame = "expandedFrame"
        static let collapsedFrame = "collapsedFrame"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
    }

    static let shared = WidgetStateStore()
    private let defaults = UserDefaults.standard

    var isCollapsed: Bool {
        get { defaults.bool(forKey: Keys.isCollapsed) }
        set { defaults.set(newValue, forKey: Keys.isCollapsed) }
    }

    func expandedFrame(default defaultFrame: NSRect) -> NSRect {
        rect(forKey: Keys.expandedFrame) ?? defaultFrame
    }

    func collapsedFrame(default defaultFrame: NSRect) -> NSRect {
        rect(forKey: Keys.collapsedFrame) ?? defaultFrame
    }

    func saveExpandedFrame(_ frame: NSRect) {
        save(frame, forKey: Keys.expandedFrame)
    }

    func saveCollapsedFrame(_ frame: NSRect) {
        save(frame, forKey: Keys.collapsedFrame)
    }

    var refreshIntervalMinutes: Int {
        get {
            let value = defaults.integer(forKey: Keys.refreshIntervalMinutes)
            if value == 0 { return 5 }
            return min(max(value, 1), 120)
        }
        set {
            defaults.set(min(max(newValue, 1), 120), forKey: Keys.refreshIntervalMinutes)
        }
    }

    private func rect(forKey key: String) -> NSRect? {
        guard let string = defaults.string(forKey: key) else { return nil }
        let rect = NSRectFromString(string)
        if rect.isEmpty || rect.width < 1 || rect.height < 1 { return nil }
        return rect
    }

    private func save(_ rect: NSRect, forKey key: String) {
        defaults.set(NSStringFromRect(rect), forKey: key)
    }
}

enum KeychainStore {
    private static let service = "sub2api-usage-widget"

    static func read(account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let value, !value.isEmpty, value != "missing value", value != "null", value != "undefined" else { return nil }
            return value
        } catch {
            return nil
        }
    }

    static func write(account: String, value: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-generic-password", "-U", "-s", service, "-a", account, "-w", value]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "Sub2APIUsageWidget", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Keychain 保存失败"])
        }
    }

    static func delete(account: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", service, "-a", account]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

final class Sub2APIUsageClient {
    func fetchTodayUsage() async throws -> UsagePayload {
        let day = Self.shanghaiDay()
        let fetchedAt = Self.isoNow()
        let baseUrl = try resolveBaseUrl()
        let stats = try await fetchStatsWithAuth(day: day, baseUrl: baseUrl)
        return UsagePayload(
            ok: true,
            day: day,
            fetchedAt: fetchedAt,
            totalRequests: stats.totalRequests,
            totalTokens: stats.totalTokens,
            totalCacheTokens: stats.totalCacheTokens,
            totalActualCost: stats.totalActualCost,
            needsCredentials: false,
            error: nil
        )
    }

    private func fetchStatsWithAuth(day: String, baseUrl: String) async throws -> UsageStats {
        if let accessToken = KeychainStore.read(account: "access_token") {
            do {
                return try await fetchStats(token: accessToken, day: day, baseUrl: baseUrl)
            } catch {
                if !Self.isAuthorizationError(error) { throw error }
            }
        }

        if let refreshToken = KeychainStore.read(account: "refresh_token") {
            do {
                let refreshed = try await refreshAccessToken(baseUrl: baseUrl, refreshToken: refreshToken)
                try saveTokens(refreshed)
                if let accessToken = refreshed.accessToken {
                    return try await fetchStats(token: accessToken, day: day, baseUrl: baseUrl)
                }
            } catch {
                if !Self.isAuthorizationError(error) { throw error }
            }
        }

        guard let email = KeychainStore.read(account: "email"), let password = KeychainStore.read(account: "password"), !email.isEmpty, !password.isEmpty else {
            throw UsageClientError.needsCredentials("缺少 Sub2API 登录凭据。请输入服务地址、邮箱和密码。")
        }

        let loginResult: AuthResult
        do {
            loginResult = try await login(baseUrl: baseUrl, email: email, password: password)
        } catch {
            throw UsageClientError.needsCredentials("登录失败，请重新输入 Sub2API 邮箱和密码。(\(error.localizedDescription))")
        }
        if loginResult.requires2FA {
            throw UsageClientError.needsCredentials("当前账号开启了 2FA，小组件暂不支持独立完成二次验证。建议为挂件准备一个只读管理员账号。")
        }
        guard let accessToken = loginResult.accessToken else {
            throw UsageClientError.needsCredentials("登录成功但没有返回 access_token，请重新确认账号权限。")
        }
        try saveTokens(loginResult)
        return try await fetchStats(token: accessToken, day: day, baseUrl: baseUrl)
    }

    private func resolveBaseUrl() throws -> String {
        guard let saved = KeychainStore.read(account: "base_url") else {
            throw UsageClientError.needsCredentials("缺少 Sub2API 服务地址。请输入服务地址、邮箱和密码。")
        }
        let normalized = Self.normalizeBaseUrl(saved)
        guard !normalized.isEmpty, URL(string: normalized) != nil else {
            throw UsageClientError.needsCredentials("服务地址格式不正确，请重新输入。")
        }
        return normalized
    }

    private func saveTokens(_ auth: AuthResult) throws {
        if let accessToken = auth.accessToken, !accessToken.isEmpty {
            try KeychainStore.write(account: "access_token", value: accessToken)
        }
        if let refreshToken = auth.refreshToken, !refreshToken.isEmpty {
            try KeychainStore.write(account: "refresh_token", value: refreshToken)
        }
    }

    private func fetchStats(token: String, day: String, baseUrl: String) async throws -> UsageStats {
        do {
            return try Self.extractStats(from: await requestJSON(url: statsUrl(day: day, baseUrl: baseUrl, mode: "range"), token: token))
        } catch {
            if Self.isAuthorizationError(error) { throw error }
            return try Self.extractStats(from: await requestJSON(url: statsUrl(day: day, baseUrl: baseUrl, mode: "period"), token: token))
        }
    }

    private func statsUrl(day: String, baseUrl: String, mode: String) throws -> URL {
        guard var components = URLComponents(string: "\(Self.normalizeBaseUrl(baseUrl))/api/v1/usage/stats") else {
            throw UsageClientError.invalidBaseUrl
        }
        if mode == "period" {
            components.queryItems = [URLQueryItem(name: "period", value: "today")]
        } else {
            components.queryItems = [
                URLQueryItem(name: "start_date", value: day),
                URLQueryItem(name: "end_date", value: day),
            ]
        }
        guard let url = components.url else { throw UsageClientError.invalidBaseUrl }
        return url
    }

    private func requestJSON(url: URL, token: String) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        return try await sendJSON(request)
    }

    private func login(baseUrl: String, email: String, password: String) async throws -> AuthResult {
        try await requestAuth(baseUrl: baseUrl, path: "/auth/login", body: ["email": email, "password": password])
    }

    private func refreshAccessToken(baseUrl: String, refreshToken: String) async throws -> AuthResult {
        try await requestAuth(baseUrl: baseUrl, path: "/auth/refresh", body: ["refresh_token": refreshToken])
    }

    private func requestAuth(baseUrl: String, path: String, body: [String: String]) async throws -> AuthResult {
        guard let url = URL(string: "\(Self.normalizeBaseUrl(baseUrl))/api/v1\(path)") else {
            throw UsageClientError.invalidBaseUrl
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try Self.extractAuth(from: await sendJSON(request))
    }

    private func sendJSON(_ request: URLRequest) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageClientError.invalidResponse("接口没有返回有效 HTTP 响应。")
        }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageClientError.requestFailed(httpResponse.statusCode, body)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func extractAuth(from payload: Any) throws -> AuthResult {
        let object = unwrapDataEnvelope(payload)
        let accessToken = stringValue(object["access_token"])
        let refreshToken = stringValue(object["refresh_token"])
        let requires2FA = boolValue(object["requires_2fa"])
        return AuthResult(accessToken: accessToken, refreshToken: refreshToken, requires2FA: requires2FA)
    }

    private static func extractStats(from payload: Any) throws -> UsageStats {
        let object = unwrapDataEnvelope(payload)
        return UsageStats(
            totalRequests: doubleValue(object["total_requests"]),
            totalTokens: doubleValue(object["total_tokens"]),
            totalCacheTokens: doubleValue(object["total_cache_tokens"]),
            totalActualCost: doubleValue(object["total_actual_cost"])
        )
    }

    private static func unwrapDataEnvelope(_ payload: Any) -> [String: Any] {
        guard let object = payload as? [String: Any] else { return [:] }
        if let code = object["code"], let intCode = code as? Int, intCode != 0 {
            return object
        }
        if let data = object["data"] as? [String: Any] {
            return data
        }
        return object
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func isAuthorizationError(_ error: Error) -> Bool {
        if case UsageClientError.requestFailed(let status, _) = error {
            return status == 401 || status == 403
        }
        return false
    }

    static func normalizeBaseUrl(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    static func shanghaiDay(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func isoNow(date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

final class WidgetContentView: NSView {
    weak var controller: WidgetWindowController?
    private let usageClient = Sub2APIUsageClient()
    private let stateStore = WidgetStateStore.shared
    private var timer: Timer?
    private var payload = UsagePayload(ok: false, day: "今日", fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: nil, error: "正在刷新...")
    private var usageStatus = ("正在刷新今日用量", NSColor.systemGreen)
    private var isCredentialPromptVisible = false
    private var displayMode: WidgetDisplayMode
    private var isDragging = false
    private var isCollapseButtonPressed = false
    private var collapsedDragStartMouse: NSPoint?
    private var collapsedDragStartOrigin: NSPoint?
    private var collapsedInteractionEnabledAt = Date.distantPast
    private let collapseButtonSize: CGFloat = 32

    init(frame: NSRect, displayMode: WidgetDisplayMode) {
        self.displayMode = displayMode
        super.init(frame: frame)
        wantsLayer = true
        startTimer()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "配置...", action: #selector(openConfiguration(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func openConfiguration(_ sender: Any?) {
        promptForCredentials()
    }

    @objc private func refreshFromMenu(_ sender: Any?) {
        payload = UsagePayload(ok: false, day: "今日", fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: nil, error: "正在刷新...")
        needsDisplay = true
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        if displayMode == .collapsed {
            guard Date() >= collapsedInteractionEnabledAt else { return }
            isDragging = false
            collapsedDragStartMouse = NSEvent.mouseLocation
            collapsedDragStartOrigin = window?.frame.origin
            return
        }

        if collapseButtonHitRect.contains(convert(event.locationInWindow, from: nil)) {
            isCollapseButtonPressed = true
            needsDisplay = true
            return
        }

        if event.clickCount >= 2 {
            payload = UsagePayload(ok: false, day: "今日", fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: nil, error: "正在刷新...")
            needsDisplay = true
            refresh()
            return
        }

        window?.performDrag(with: event)
        controller?.windowDidFinishDragging()
    }

    override func mouseDragged(with event: NSEvent) {
        if displayMode == .collapsed {
            guard Date() >= collapsedInteractionEnabledAt else { return }
            isDragging = true
            guard let startMouse = collapsedDragStartMouse, let startOrigin = collapsedDragStartOrigin else { return }
            let current = NSEvent.mouseLocation
            window?.setFrameOrigin(NSPoint(x: startOrigin.x + current.x - startMouse.x, y: startOrigin.y + current.y - startMouse.y))
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isCollapseButtonPressed {
            let shouldCollapse = displayMode == .expanded && collapseButtonHitRect.contains(convert(event.locationInWindow, from: nil))
            isCollapseButtonPressed = false
            needsDisplay = true
            if shouldCollapse {
                controller?.collapse()
            }
            return
        }

        if displayMode == .collapsed {
            guard Date() >= collapsedInteractionEnabledAt, collapsedDragStartMouse != nil else {
                isDragging = false
                collapsedDragStartMouse = nil
                collapsedDragStartOrigin = nil
                return
            }
            if isDragging {
                controller?.snapCollapsedWindowToNearestSide()
            } else {
                controller?.expand()
            }
            isDragging = false
            collapsedDragStartMouse = nil
            collapsedDragStartOrigin = nil
        }
        super.mouseUp(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if displayMode == .collapsed {
            drawCollapsed()
            return
        }

        let bounds = self.bounds
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.08, alpha: 0.78).setFill()
        background.fill()
        NSColor(calibratedWhite: 0.82, alpha: 0.42).setStroke()
        background.lineWidth = 1.4
        background.stroke()

        drawText("今日Token用量", x: 20, y: 20, width: 230, height: 28, size: 25, weight: .bold, color: .white)
        drawCircle(x: bounds.width - 43, y: 26, radius: 8, color: payload.ok ? .systemGreen : .systemPink)
        drawCollapseButton()
        drawText("\(payload.day ?? "今日") · \(formatTime(payload.fetchedAt)) 更新", x: 21, y: 55, width: bounds.width - 42, height: 18, size: 12, weight: .regular, color: NSColor(calibratedWhite: 0.82, alpha: 0.82))

        if payload.ok {
            drawSeparator(y: 80)
            drawMetric(label: "总请求数", value: integer(payload.totalRequests), y: 90)
            drawSeparator(y: 124)
            drawTokenMetric(y: 134)
            drawSeparator(y: 200)
            drawMetric(label: "总消费", value: money(payload.totalActualCost), y: 210, valueColor: NSColor(calibratedRed: 0.53, green: 0.94, blue: 0.67, alpha: 1))
            drawUsageStatus(y: 252)
        } else {
            drawSeparator(y: 82, color: NSColor.systemPink.withAlphaComponent(0.35))
            drawText(payload.error ?? "读取失败", x: 20, y: 98, width: bounds.width - 40, height: bounds.height - 112, size: 13, weight: .regular, color: NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.86, alpha: 1), wraps: true)
        }
    }

    func setDisplayMode(_ mode: WidgetDisplayMode) {
        displayMode = mode
        if mode == .collapsed {
            collapsedInteractionEnabledAt = Date().addingTimeInterval(0.45)
            isDragging = false
            collapsedDragStartMouse = nil
            collapsedDragStartOrigin = nil
        }
        needsDisplay = true
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(stateStore.refreshIntervalMinutes * 60), repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        Task.detached(priority: .utility) { [usageClient] in
            do {
                let nextPayload = try await usageClient.fetchTodayUsage()
                await MainActor.run {
                    self.applyPayload(nextPayload)
                }
            } catch {
                let usageError = error as? UsageClientError
                let nextPayload = UsagePayload(ok: false, day: Sub2APIUsageClient.shanghaiDay(), fetchedAt: Sub2APIUsageClient.isoNow(), totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: usageError?.needsCredentials == true, error: error.localizedDescription)
                await MainActor.run {
                    self.applyPayload(nextPayload)
                }
            }
        }
    }

    private func applyPayload(_ nextPayload: UsagePayload) {
        payload = nextPayload
        if nextPayload.ok {
            usageStatus = Self.randomUsageStatus(for: nextPayload.totalTokens ?? 0)
        }
        needsDisplay = true
        if nextPayload.ok != true && nextPayload.needsCredentials == true {
            promptForCredentials()
        }
    }

    private func promptForCredentials() {
        guard !isCredentialPromptVisible else { return }
        isCredentialPromptVisible = true

        let baseUrlField = NSTextField(frame: NSRect(x: 0, y: 102, width: 300, height: 24))
        baseUrlField.placeholderString = "服务地址，例如 https://sub2api.example.com"
        baseUrlField.stringValue = readCredential(account: "base_url") ?? ""
        let emailField = NSTextField(frame: NSRect(x: 0, y: 68, width: 300, height: 24))
        emailField.placeholderString = "邮箱"
        emailField.stringValue = readCredential(account: "email") ?? ""
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        passwordField.placeholderString = "密码"
        passwordField.stringValue = readCredential(account: "password") ?? ""
        let intervalField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        intervalField.placeholderString = "刷新间隔（分钟，1-120）"
        intervalField.stringValue = String(stateStore.refreshIntervalMinutes)
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 126))
        stack.addSubview(baseUrlField)
        stack.addSubview(emailField)
        stack.addSubview(passwordField)
        stack.addSubview(intervalField)

        let alert = NSAlert()
        alert.messageText = "配置 Sub2API"
        alert.informativeText = "服务地址和登录凭据会保存到 macOS Keychain。刷新间隔会保存在本机配置中。"
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存并刷新")
        alert.addButton(withTitle: "取消")

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        isCredentialPromptVisible = false

        guard response == .alertFirstButtonReturn else { return }
        let baseUrl = normalizedBaseUrl(baseUrlField.stringValue)
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        let refreshInterval = min(max(Int(intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? stateStore.refreshIntervalMinutes, 1), 120)
        guard !baseUrl.isEmpty, !email.isEmpty, !password.isEmpty else {
            payload = UsagePayload(ok: false, day: nil, fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: true, error: "服务地址、邮箱和密码不能为空。双击卡片可重新输入。")
            needsDisplay = true
            return
        }

        do {
            try saveCredential(account: "base_url", value: baseUrl)
            try saveCredential(account: "email", value: email)
            try saveCredential(account: "password", value: password)
            stateStore.refreshIntervalMinutes = refreshInterval
            deleteCredential(account: "access_token")
            deleteCredential(account: "refresh_token")
            startTimer()
            payload = UsagePayload(ok: false, day: "今日", fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: nil, error: "正在刷新...")
            needsDisplay = true
            refresh()
        } catch {
            payload = UsagePayload(ok: false, day: nil, fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: true, error: "保存凭据失败：\(error.localizedDescription)")
            needsDisplay = true
        }
    }

    private func normalizedBaseUrl(_ value: String) -> String {
        Sub2APIUsageClient.normalizeBaseUrl(value)
    }

    private func saveCredential(account: String, value: String) throws {
        try KeychainStore.write(account: account, value: value)
    }

    private func readCredential(account: String) -> String? {
        KeychainStore.read(account: account)
    }

    private func deleteCredential(account: String) {
        KeychainStore.delete(account: account)
    }

    private func drawMetric(label: String, value: String, y: CGFloat, valueColor: NSColor = .white) {
        drawText(label, x: 20, y: y + 6, width: 95, height: 22, size: 12, weight: .medium, color: NSColor(calibratedWhite: 0.82, alpha: 0.82))
        drawText(value, x: 120, y: y, width: bounds.width - 140, height: 34, size: 25, weight: .bold, color: valueColor, alignment: .right)
    }

    private func drawTokenMetric(y: CGFloat) {
        drawText("总 Token", x: 20, y: y + 4, width: 95, height: 22, size: 12, weight: .medium, color: NSColor(calibratedWhite: 0.82, alpha: 0.82))
        drawText(compact(payload.totalTokens), x: 106, y: y - 2, width: bounds.width - 126, height: 30, size: 22, weight: .bold, color: .white, alignment: .right)
        drawText("缓存命中", x: 20, y: y + 35, width: 95, height: 18, size: 11, weight: .regular, color: NSColor(calibratedWhite: 0.82, alpha: 0.68))
        drawText(compact(payload.totalCacheTokens), x: 106, y: y + 31, width: bounds.width - 126, height: 24, size: 16, weight: .semibold, color: NSColor(calibratedRed: 0.62, green: 0.82, blue: 1.0, alpha: 1), alignment: .right)
    }

    private func drawUsageStatus(y: CGFloat) {
        drawText(usageStatus.0, x: 20, y: y, width: bounds.width - 40, height: 18, size: 12, weight: .semibold, color: usageStatus.1)
    }

    private var collapseButtonRect: NSRect {
        NSRect(x: bounds.width - 78, y: 18, width: collapseButtonSize, height: collapseButtonSize)
    }

    private var collapseButtonHitRect: NSRect {
        collapseButtonRect.insetBy(dx: -10, dy: -10)
    }

    private func drawCollapseButton() {
        let rect = collapseButtonRect
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 1, alpha: 0.11).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.28).setStroke()
        path.lineWidth = 1
        path.stroke()
        drawText("‹", x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, size: 23, weight: .semibold, color: NSColor(calibratedWhite: 1, alpha: 0.82), alignment: .center)
    }

    private func drawCollapsed() {
        let bounds = self.bounds
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.08, alpha: 0.84).setFill()
        background.fill()
        NSColor(calibratedWhite: 0.82, alpha: 0.36).setStroke()
        background.lineWidth = 1.2
        background.stroke()

        let statusColor = payload.ok ? usageStatus.1 : NSColor.systemPink
        drawCircle(x: 22, y: bounds.midY - 5, radius: 5, color: statusColor)
        drawText(compact(payload.totalTokens), x: 44, y: 13, width: bounds.width - 62, height: 25, size: 20, weight: .bold, color: .white, alignment: .left)
    }

    private static func randomUsageStatus(for tokenCount: Double) -> (String, NSColor) {
        if tokenCount < 20_000_000 {
            return ([
                "今天用量很轻，节奏不错",
                "今天挺克制，保持这个节奏",
                "用量很健康，安心继续",
                "今天负载不高，状态不错",
            ].randomElement()!, NSColor.systemGreen)
        }

        if tokenCount <= 50_000_000 {
            return ([
                "今天用得有点多了，注意休息",
                "用量上来了，记得歇一会儿",
                "今天调用不少，稍微收着点",
                "已经进入高频使用，留意成本",
            ].randomElement()!, NSColor.systemOrange)
        }

        return ([
            "今天用得太多了，建议停一停",
            "用量偏高，先缓一缓吧",
            "今天消耗很猛，注意预算",
            "已经重度使用，建议复盘一下",
        ].randomElement()!, NSColor.systemRed)
    }

    private func drawSeparator(y: CGFloat, color: NSColor = NSColor(calibratedWhite: 0.82, alpha: 0.18)) {
        color.setFill()
        NSRect(x: 20, y: y, width: bounds.width - 40, height: 1).fill()
    }

    private func drawCircle(x: CGFloat, y: CGFloat, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: radius * 2, height: radius * 2)).fill()
    }

    private func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, alignment: NSTextAlignment = .left, wraps: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        NSString(string: text).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes: attributes)
    }

    private func formatTime(_ value: String?) -> String {
        guard let value else { return "--:--" }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        guard let date = fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value) else { return "--:--" }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func integer(_ value: Double?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value ?? 0)) ?? "0"
    }

    private func compact(_ value: Double?) -> String {
        let number = value ?? 0
        if number >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.2fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return integer(number)
    }

    private func money(_ value: Double?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value ?? 0)) ?? "$0.0000"
    }
}

final class DraggableWidgetWindow: NSWindow {
    weak var widgetController: WidgetWindowController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private var initialMouseLocation: NSPoint?
    private var initialFrameOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialFrameOrigin = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = initialMouseLocation, let startOrigin = initialFrameOrigin else { return }
        let current = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: startOrigin.x + current.x - startMouse.x, y: startOrigin.y + current.y - startMouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        widgetController?.windowDidFinishDragging()
        initialMouseLocation = nil
        initialFrameOrigin = nil
    }
}

final class WidgetWindowController {
    private let expandedSize = NSSize(width: 320, height: 300)
    private let collapsedSize = NSSize(width: 148, height: 52)
    private let edgeInset: CGFloat = 8
    private let stateStore = WidgetStateStore.shared
    private let window: DraggableWidgetWindow
    private let contentView: WidgetContentView

    private var displayMode: WidgetDisplayMode

    init() {
        let defaultExpandedFrame = NSRect(x: 28, y: 500, width: expandedSize.width, height: expandedSize.height)
        displayMode = stateStore.isCollapsed ? .collapsed : .expanded
        let defaultCollapsedFrame = Self.collapsedFrame(from: defaultExpandedFrame, size: collapsedSize, edgeInset: edgeInset)
        let initialFrame = displayMode == .collapsed
            ? stateStore.collapsedFrame(default: defaultCollapsedFrame)
            : stateStore.expandedFrame(default: defaultExpandedFrame)

        window = DraggableWidgetWindow(contentRect: initialFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = WidgetContentView(frame: NSRect(x: 0, y: 0, width: initialFrame.width, height: initialFrame.height), displayMode: displayMode)
        contentView.controller = self
        window.widgetController = self
        window.contentView = contentView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.setFrame(initialFrame, display: true)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func collapse() {
        guard displayMode == .expanded else { return }
        stateStore.saveExpandedFrame(window.frame)
        displayMode = .collapsed
        stateStore.isCollapsed = true

        let nextFrame = Self.collapsedFrame(from: window.frame, size: collapsedSize, edgeInset: edgeInset)
        apply(mode: .collapsed, frame: nextFrame, animate: true)
        stateStore.saveCollapsedFrame(window.frame)
    }

    func expand() {
        guard displayMode == .collapsed else { return }
        stateStore.saveCollapsedFrame(window.frame)
        displayMode = .expanded
        stateStore.isCollapsed = false

        let defaultFrame = NSRect(x: 28, y: 500, width: expandedSize.width, height: expandedSize.height)
        var nextFrame = stateStore.expandedFrame(default: defaultFrame)
        nextFrame.size = expandedSize
        apply(mode: .expanded, frame: constrain(frame: nextFrame), animate: true)
        stateStore.saveExpandedFrame(window.frame)
    }

    func snapCollapsedWindowToNearestSide() {
        guard displayMode == .collapsed else { return }
        let nextFrame = Self.collapsedFrame(from: window.frame, size: collapsedSize, edgeInset: edgeInset)
        apply(mode: .collapsed, frame: nextFrame, animate: true)
        stateStore.saveCollapsedFrame(window.frame)
    }

    func windowDidFinishDragging() {
        if displayMode == .expanded {
            stateStore.saveExpandedFrame(window.frame)
        } else {
            stateStore.saveCollapsedFrame(window.frame)
        }
    }

    private func apply(mode: WidgetDisplayMode, frame: NSRect, animate: Bool) {
        contentView.setDisplayMode(mode)
        contentView.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        window.setFrame(frame, display: true, animate: animate)
    }

    private func constrain(frame: NSRect) -> NSRect {
        guard let screenFrame = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return frame
        }

        var next = frame
        if next.maxX > screenFrame.maxX - edgeInset {
            next.origin.x = screenFrame.maxX - edgeInset - next.width
        }
        if next.minX < screenFrame.minX + edgeInset {
            next.origin.x = screenFrame.minX + edgeInset
        }
        if next.maxY > screenFrame.maxY - edgeInset {
            next.origin.y = screenFrame.maxY - edgeInset - next.height
        }
        if next.minY < screenFrame.minY + edgeInset {
            next.origin.y = screenFrame.minY + edgeInset
        }
        return next
    }

    private static func collapsedFrame(from frame: NSRect, size: NSSize, edgeInset: CGFloat) -> NSRect {
        guard let screenFrame = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return NSRect(x: frame.minX, y: frame.minY, width: size.width, height: size.height)
        }

        let centerY = frame.midY
        let minY = screenFrame.minY + edgeInset
        let maxY = screenFrame.maxY - edgeInset - size.height
        let y = min(max(centerY - size.height / 2, minY), maxY)
        let distanceToLeft = abs(frame.midX - screenFrame.minX)
        let distanceToRight = abs(screenFrame.maxX - frame.midX)
        let x = distanceToLeft <= distanceToRight ? screenFrame.minX + edgeInset : screenFrame.maxX - edgeInset - size.width
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var widgetController: WidgetWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let controller = WidgetWindowController()
        controller.show()
        widgetController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installEditMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Sub2APIUsageWidget",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }
}

func acquireSingleInstanceLock() -> Int32? {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("com.abnerchen.sub2api-usage-widget.lock")
    let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    if fd < 0 {
        return nil
    }

    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return nil
    }

    return fd
}

let singleInstanceLock = acquireSingleInstanceLock()
if singleInstanceLock == nil {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
