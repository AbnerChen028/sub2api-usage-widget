import Cocoa

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

enum WidgetRefreshError: LocalizedError {
    case emptyOutput
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .emptyOutput:
            return "刷新没有返回数据。请双击卡片重新刷新。"
        case .invalidJSON(let output):
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                return "刷新没有返回数据。请双击卡片重新刷新。"
            }
            return "刷新返回格式异常：\(String(text.prefix(180)))"
        }
    }
}

final class WidgetContentView: NSView {
    private let scriptPath: String
    private var timer: Timer?
    private var payload = UsagePayload(ok: false, day: "今日", fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: nil, error: "正在刷新...")
    private var usageStatus = ("正在刷新今日用量", NSColor.systemGreen)
    private var isCredentialPromptVisible = false

    init(frame: NSRect, scriptPath: String) {
        self.scriptPath = scriptPath
        super.init(frame: frame)
        wantsLayer = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            payload = UsagePayload(ok: false, day: "今日", fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: nil, error: "正在刷新...")
            needsDisplay = true
            refresh()
            return
        }
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.08, alpha: 0.78).setFill()
        background.fill()
        NSColor(calibratedWhite: 0.82, alpha: 0.42).setStroke()
        background.lineWidth = 1.4
        background.stroke()

        drawText("今日Token用量", x: 20, y: 18, width: 230, height: 28, size: 25, weight: .bold, color: .white)
        drawCircle(x: bounds.width - 42, y: 29, radius: 8, color: payload.ok ? .systemGreen : .systemPink)
        drawText("\(payload.day ?? "今日") · \(formatTime(payload.fetchedAt)) 更新", x: 21, y: 52, width: bounds.width - 42, height: 18, size: 12, weight: .regular, color: NSColor(calibratedWhite: 0.82, alpha: 0.82))

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

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [scriptPath] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin node \(shellQuote(scriptPath))"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WidgetRefreshError.emptyOutput
                }
                let nextPayload: UsagePayload
                do {
                    nextPayload = try JSONDecoder().decode(UsagePayload.self, from: data)
                } catch {
                    throw WidgetRefreshError.invalidJSON(output)
                }
                DispatchQueue.main.async {
                    self.payload = nextPayload
                    if nextPayload.ok {
                        self.usageStatus = Self.randomUsageStatus(for: nextPayload.totalTokens ?? 0)
                    }
                    self.needsDisplay = true
                    if nextPayload.ok != true && nextPayload.needsCredentials == true {
                        self.promptForCredentials()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.payload = UsagePayload(ok: false, day: nil, fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: nil, error: error.localizedDescription)
                    self.needsDisplay = true
                }
            }
        }
    }

    private func promptForCredentials() {
        guard !isCredentialPromptVisible else { return }
        isCredentialPromptVisible = true

        let baseUrlField = NSTextField(frame: NSRect(x: 0, y: 68, width: 300, height: 24))
        baseUrlField.placeholderString = "服务地址，例如 https://sub2api.example.com"
        let emailField = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        emailField.placeholderString = "邮箱"
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        passwordField.placeholderString = "密码"
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 92))
        stack.addSubview(baseUrlField)
        stack.addSubview(emailField)
        stack.addSubview(passwordField)

        let alert = NSAlert()
        alert.messageText = "配置 Sub2API"
        alert.informativeText = "服务地址和登录凭据会保存到 macOS Keychain。地址或密码修改、登录失效时，会再次提示你更新。"
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
        guard !baseUrl.isEmpty, !email.isEmpty, !password.isEmpty else {
            payload = UsagePayload(ok: false, day: nil, fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: true, error: "服务地址、邮箱和密码不能为空。双击卡片可重新输入。")
            needsDisplay = true
            return
        }

        do {
            try saveCredential(account: "base_url", value: baseUrl)
            try saveCredential(account: "email", value: email)
            try saveCredential(account: "password", value: password)
            deleteCredential(account: "access_token")
            deleteCredential(account: "refresh_token")
            payload = UsagePayload(ok: false, day: "今日", fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: nil, error: "正在刷新...")
            needsDisplay = true
            refresh()
        } catch {
            payload = UsagePayload(ok: false, day: nil, fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, needsCredentials: true, error: "保存凭据失败：\(error.localizedDescription)")
            needsDisplay = true
        }
    }

    private func normalizedBaseUrl(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    private func saveCredential(account: String, value: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-generic-password", "-U", "-s", "sub2api-usage-widget", "-a", account, "-w", value]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "Sub2APIUsageWidget", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "security add-generic-password 失败"])
        }
    }

    private func deleteCredential(account: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", "sub2api-usage-widget", "-a", account]
        try? process.run()
        process.waitUntilExit()
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
        initialMouseLocation = nil
        initialFrameOrigin = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let scriptPath = CommandLine.arguments.dropFirst().first ?? ""
        let frame = NSRect(x: 28, y: 500, width: 320, height: 300)
        let window = DraggableWidgetWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = WidgetContentView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height), scriptPath: scriptPath)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
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

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
