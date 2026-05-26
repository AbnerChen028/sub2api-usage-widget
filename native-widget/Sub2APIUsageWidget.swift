import Cocoa

struct UsagePayload: Decodable {
    let ok: Bool
    let day: String?
    let fetchedAt: String?
    let totalRequests: Double?
    let totalTokens: Double?
    let totalCacheTokens: Double?
    let totalActualCost: Double?
    let error: String?
}

final class WidgetContentView: NSView {
    private let scriptPath: String
    private var timer: Timer?
    private var payload = UsagePayload(ok: false, day: "今日", fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, error: "正在刷新...")
    private var usageStatus = ("正在刷新今日用量", NSColor.systemGreen)

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

        drawText("Sub2API 今日用量", x: 20, y: 18, width: 230, height: 28, size: 25, weight: .bold, color: .white)
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
                let nextPayload = try JSONDecoder().decode(UsagePayload.self, from: data)
                DispatchQueue.main.async {
                    self.payload = nextPayload
                    if nextPayload.ok {
                        self.usageStatus = Self.randomUsageStatus(for: nextPayload.totalTokens ?? 0)
                    }
                    self.needsDisplay = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.payload = UsagePayload(ok: false, day: nil, fetchedAt: nil, totalRequests: nil, totalTokens: nil, totalCacheTokens: nil, totalActualCost: nil, error: error.localizedDescription)
                    self.needsDisplay = true
                }
            }
        }
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
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
