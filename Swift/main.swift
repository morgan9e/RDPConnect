import SwiftUI
import AppKit
import Security
import CoreGraphics
import ApplicationServices

extension String: @retroactive Error {}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case fixed
    case dynamic
    case scale

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fixed:   return "Fixed size"
        case .dynamic: return "Dynamic resolution"
        case .scale:   return "Scale to fit"
        }
    }
}

private struct RawCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct Connection: Codable, Equatable {
    var host = ""
    var username = ""
    var password = ""
    var domain = ""

    var resolution = "Fullscreen"
    var customResolution = "1920x1200"
    var displayMode = DisplayMode.dynamic
    var clientScale = "100"
    var customScale = "150"
    var serverScale = "100"
    var customServerScale = "150"
    var multiMonitor = false

    var ignoreCert = true
    var clipboard = true
    var audio = true
    var microphone = false
    var driveRedirect = false

    var captureCmdKeys = true

    var reverseScroll = false

    /// Swap ⌘ and ⌥ by position, PC-style: ⌘ → Alt (right ⌘ → AltGr),
    /// ⌥ → Win/Super. Done via FreeRDP's RDP-scancode remap.
    var swapCmdOpt = false

    /// Send right Ctrl as left Ctrl; Korean server layouts turn right Ctrl into Hanja.
    var rightCtrlAsLeft = false

    var extraArgs = ""

    static let customResolution = "Custom"

    static let resolutionPresets = [
        "2560x1600", "2560x1440", "1920x1200", "1920x1080",
        "1600x900", "1440x900", "1366x768", "1280x800", "1024x768",
    ]

    static let customScale = "Custom"

    static let scalePresets: [String] = ["100", "125", "150", "175", "200", customScale]
    static let serverScalePresets: [String] = ["100", "125", "150", "175", "200", "225", "250", customScale]

    static func percent(_ value: String, _ custom: String) -> Int {
        let raw = (value == customScale ? custom : value)
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        return min(max(Int(raw) ?? 100, 50), 500)
    }

    var scalePercent: Int { Connection.percent(clientScale, customScale) }
    var scaleFactor: Double { Double(scalePercent) / 100 }

    var serverScalePercent: Int { Connection.percent(serverScale, customServerScale) }

    static func parseSize(_ s: String) -> (w: Int, h: Int)? {
        let parts = s.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .split(whereSeparator: { $0 == "x" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0
        else { return nil }
        return (w, h)
    }

    static func aspectRatio(_ w: Int, _ h: Int) -> String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = max(gcd(w, h), 1)
        let rw = w / g, rh = h / g
        let named: [String: String] = [
            "16:9": "16:9", "8:5": "16:10", "16:10": "16:10",
            "4:3": "4:3", "5:4": "5:4", "3:2": "3:2", "1:1": "1:1",
            "43:18": "21:9", "64:27": "21:9", "12:5": "21:9", "21:9": "21:9",
        ]
        if let name = named["\(rw):\(rh)"] { return name }
        if rw <= 24 && rh <= 24 { return "\(rw):\(rh)" }
        let r = Double(w) / Double(h)
        return r >= 1 ? String(format: "%.2f:1", r) : String(format: "1:%.2f", 1 / r)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys, _ d: String) -> String { (try? c.decode(String.self, forKey: k)) ?? d }
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decode(Bool.self, forKey: k)) ?? d }
        host = s(.host, "")
        if let extra = try? decoder.container(keyedBy: RawCodingKey.self),
           let oldPort = try? extra.decode(String.self, forKey: RawCodingKey("port")),
           !oldPort.isEmpty, oldPort != "3389", !host.contains(":") {
            host = "\(host):\(oldPort)"
        }
        username = s(.username, "")
        password = s(.password, "")
        domain = s(.domain, "")
        let savedRes = s(.resolution, "Fullscreen")
        if savedRes == "Fullscreen" || savedRes == Connection.customResolution
            || Connection.resolutionPresets.contains(savedRes) {
            resolution = savedRes
            customResolution = s(.customResolution, "1920x1200")
        } else {
            resolution = Connection.customResolution
            customResolution = savedRes
        }
        displayMode = (try? c.decode(DisplayMode.self, forKey: .displayMode)) ?? .dynamic
        clientScale = s(.clientScale, "100")
        customScale = s(.customScale, "150")
        serverScale = s(.serverScale, "100")
        customServerScale = s(.customServerScale, "150")
        multiMonitor = b(.multiMonitor, false)
        ignoreCert = b(.ignoreCert, true)
        clipboard = b(.clipboard, true)
        audio = b(.audio, true)
        microphone = b(.microphone, false)
        driveRedirect = b(.driveRedirect, false)
        captureCmdKeys = b(.captureCmdKeys, true)
        reverseScroll = b(.reverseScroll, false)
        swapCmdOpt = b(.swapCmdOpt, false)
        rightCtrlAsLeft = b(.rightCtrlAsLeft, false)
        extraArgs = s(.extraArgs, "")
    }

    func buildArguments(screenSize: (w: Int, h: Int)? = nil) -> Result<[String], String> {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else { return .failure("Server address is required.") }

        var args: [String] = []

        args.append("/v:\(trimmedHost)")

        let user = username.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { args.append("/u:\(user)") }

        let dom = domain.trimmingCharacters(in: .whitespaces)
        if !dom.isEmpty { args.append("/d:\(dom)") }

        if !password.isEmpty { args.append("/p:\(password)") }

        let isFullscreen = (resolution == "Fullscreen")
        let base: (w: Int, h: Int)?
        if isFullscreen {
            base = screenSize
        } else {
            let sizeString = (resolution == Connection.customResolution) ? customResolution : resolution
            guard let size = Connection.parseSize(sizeString) else {
                return .failure("Invalid resolution '\(sizeString)'. Use WIDTHxHEIGHT, e.g. 1920x1200.")
            }
            base = size
        }

        func even(_ n: Int) -> Int { max(n - (n % 2), 2) }

        switch displayMode {
        case .scale:
            if isFullscreen { args.append("/f") }
            else if let b = base { args.append("/w:\(even(b.w))"); args.append("/h:\(even(b.h))") }
            if let b = base {
                let sw = even(max(Int((Double(b.w) / scaleFactor).rounded()), 320))
                let sh = even(max(Int((Double(b.h) / scaleFactor).rounded()), 240))
                args.append("/smart-sizing:\(sw)x\(sh)")
            } else {
                args.append("/smart-sizing")
            }
        case .dynamic:
            if isFullscreen { args.append("/f") }
            else if let b = base { args.append("/w:\(even(b.w))"); args.append("/h:\(even(b.h))") }
            args.append("/dynamic-resolution")
        case .fixed:
            if isFullscreen { args.append("/f") }
            else if let b = base { args.append("/w:\(even(b.w))"); args.append("/h:\(even(b.h))") }
        }

        if serverScalePercent != 100 {
            args.append("/scale-desktop:\(min(max(serverScalePercent, 100), 500))")
        }
        if multiMonitor { args.append("/multimon") }

        if ignoreCert { args.append("/cert:ignore") }
        if clipboard { args.append("+clipboard") }
        if audio { args.append("/sound:sys:mac") }
        if microphone { args.append("/microphone") }
        if driveRedirect { args.append("/drive:home,~") }
        // RDP scancodes: 0x38/0x138 = left/right Alt, 0x15b/0x15c = left/right Win,
        // 0x1d/0x11d = left/right Ctrl.
        var remaps: [String] = []
        if swapCmdOpt { remaps += ["0x38=0x15b", "0x15b=0x38", "0x138=0x15c", "0x15c=0x138"] }
        if rightCtrlAsLeft { remaps.append("0x11d=0x1d") }
        if !remaps.isEmpty {
            args.append("/kbd:" + remaps.map { "remap:\($0)" }.joined(separator: ","))
        }

        let extras = extraArgs.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        args.append(contentsOf: extras)

        return .success(args)
    }
}

struct Favorite: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var conn: Connection
}

enum Keychain {
    static let service = "RDPConnect"

    static func set(_ password: String, for id: UUID) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(for id: UUID) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }

    static func delete(for id: UUID) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ] as CFDictionary)
    }
}

final class KeyGrabber {
    private static let sentinel: Int64 = 0x6B62
    private static let keyG: Int64 = 5

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?

    private var childPID: pid_t = 0
    private var grab = true
    private var childFront = false

    var captureCmd = true
    var reverseScroll = false

    var log: ((String) -> Void)?

    func start(pid: pid_t) -> Bool {
        stop()
        childPID = pid
        grab = true

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            log?("Keyboard grab needs Accessibility access. Enable RDPConnect in System Settings > Privacy & Security > Accessibility, then reconnect.")
            return false
        }

        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << CGEventType.scrollWheel.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: keyGrabberCallback, userInfo: ctx)
        else {
            log?("Keyboard grab failed.")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        childFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.childFront = app?.processIdentifier == pid
        }
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tap = nil; source = nil; observer = nil; childFront = false
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.sentinel { return pass }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let f = event.flags

        if type == .keyDown && keycode == Self.keyG &&
            f.contains(.maskControl) && f.contains(.maskAlternate) && !f.contains(.maskCommand) {
            grab.toggle()
            log?(grab ? "Keyboard grab on." : "Keyboard grab off.")
            return nil
        }

        guard grab, childFront else { return pass }

        if type == .scrollWheel {
            if reverseScroll {
                for f in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                          .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
                    event.setIntegerValueField(f, value: -event.getIntegerValueField(f))
                }
                for f in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
                    event.setDoubleValueField(f, value: -event.getDoubleValueField(f))
                }
            }
            return pass
        }

        guard captureCmd else { return pass }

        func forward() -> Unmanaged<CGEvent>? {
            if let copy = event.copy() {
                copy.setIntegerValueField(.eventSourceUserData, value: Self.sentinel)
                copy.postToPid(childPID)
            }
            return nil
        }

        if type == .flagsChanged && (keycode == 55 || keycode == 54) {
            return forward()
        }
        if (type == .keyDown || type == .keyUp) && f.contains(.maskCommand) {
            return forward()
        }
        return pass
    }
}

private let keyGrabberCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyGrabber>.fromOpaque(refcon).takeUnretainedValue()
        .handle(type: type, event: event)
}

@MainActor
final class AppState: ObservableObject {
    @Published var conn = Connection()
    @Published var favorites: [Favorite] = []
    @Published var selectedID: UUID? = nil

    @Published var status = "Ready."
    @Published var log = ""
    @Published var isRunning = false

    private var process: Process?
    private let binary = AppState.findBinary()
    private let grabber = KeyGrabber()
    private let storeURL = AppState.supportDir().appendingPathComponent("favorites.json")
    private let lastURL  = AppState.supportDir().appendingPathComponent("last.json")

    private static let lastPasswordID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    static func nativeScreenSize() -> (w: Int, h: Int)? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let s = screen.backingScaleFactor
        return (Int((screen.frame.width * s).rounded()), Int((screen.frame.height * s).rounded()))
    }

    private static func supportDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RDPConnect", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        loadFavorites()
        loadLast()
    }

    static func findBinary() -> String? {
        ["/opt/homebrew/bin/sdl-freerdp", "/usr/local/bin/sdl-freerdp",
         "/opt/homebrew/bin/sdl-freerdp3", "/usr/bin/sdl-freerdp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func findMenuZap() -> String? {
        if let u = Bundle.main.url(forResource: "menuzap", withExtension: "dylib"),
           FileManager.default.fileExists(atPath: u.path) { return u.path }
        if let dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            let p = dir.appendingPathComponent("menuzap.dylib").path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    func loadFavorites() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([Favorite].self, from: data) else { return }
        favorites = list
    }

    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            try? data.write(to: storeURL)
        }
    }

    private struct LastSession: Codable {
        var conn: Connection
        var selectedID: UUID?
    }

    private func persistLast() {
        var stored = conn
        let password = stored.password
        stored.password = ""
        Keychain.set(password, for: Self.lastPasswordID)
        if let data = try? JSONEncoder().encode(LastSession(conn: stored, selectedID: selectedID)) {
            try? data.write(to: lastURL)
        }
    }

    private func loadLast() {
        guard let data = try? Data(contentsOf: lastURL),
              let snap = try? JSONDecoder().decode(LastSession.self, from: data) else { return }
        var c = snap.conn
        c.password = Keychain.get(for: Self.lastPasswordID)
        conn = c
        selectedID = (snap.selectedID).flatMap { id in
            favorites.contains { $0.id == id } ? id : nil
        }
        status = selectedName.map { "Restored '\($0)'." } ?? "Restored last connection."
    }

    func apply(_ fav: Favorite) {
        var c = fav.conn
        c.password = Keychain.get(for: fav.id)
        conn = c
        selectedID = fav.id
        status = "Loaded '\(fav.name)'."
    }

    func newConnection() {
        conn = Connection()
        selectedID = nil
        status = "New connection."
    }

    func saveFavorite(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        var stored = conn
        let password = stored.password
        stored.password = ""

        if let idx = favorites.firstIndex(where: { $0.name == trimmed }) {
            favorites[idx].conn = stored
            Keychain.set(password, for: favorites[idx].id)
            selectedID = favorites[idx].id
        } else {
            let fav = Favorite(name: trimmed, conn: stored)
            favorites.append(fav)
            Keychain.set(password, for: fav.id)
            selectedID = fav.id
        }
        favorites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistFavorites()
        status = "Saved '\(trimmed)'."
    }

    func deleteSelected() {
        guard let id = selectedID, let idx = favorites.firstIndex(where: { $0.id == id }) else { return }
        let name = favorites[idx].name
        Keychain.delete(for: favorites[idx].id)
        favorites.remove(at: idx)
        persistFavorites()
        selectedID = nil
        status = "Deleted '\(name)'."
    }

    var selectedName: String? { favorites.first { $0.id == selectedID }?.name }

    private func append(_ line: String) { log += line + "\n" }

    func connect() {
        guard !isRunning else { return }
        guard let binary else {
            status = "sdl-freerdp not found."
            append("sdl-freerdp not found. Install it with: brew install freerdp")
            return
        }
        switch conn.buildArguments(screenSize: AppState.nativeScreenSize()) {
        case .failure(let msg):
            status = msg
        case .success(let args):
            persistLast()
            launch(binary: binary, args: args)
        }
    }

    private func launch(binary: String, args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        if conn.captureCmdKeys, let zap = AppState.findMenuZap() {
            let existing = env["DYLD_INSERT_LIBRARIES"]
            env["DYLD_INSERT_LIBRARIES"] = existing.map { "\(zap):\($0)" } ?? zap
            append("Menu shortcuts routed to the session.")
        }
        // SDL's Spaces-based fullscreen animates in after the first frame, which leaves
        // the window blank until something forces a full redraw. Fill the screen directly.
        if conn.resolution == "Fullscreen" {
            env["SDL_VIDEO_MAC_FULLSCREEN_SPACES"] = "0"
        }
        proc.environment = env

        let shown = args.map { $0.hasPrefix("/p:") ? "/p:******" : $0 }
        append("run: \(binary) \(shown.joined(separator: " "))")

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self.append(text.trimmingCharacters(in: .newlines)) }
        }
        proc.terminationHandler = { p in
            Task { @MainActor in
                self.grabber.stop()
                self.isRunning = false
                self.process = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                self.status = "Session ended (exit \(p.terminationStatus))."
                self.append("Session ended (exit code \(p.terminationStatus))")
            }
        }
        do {
            try proc.run()
            process = proc
            isRunning = true
            status = "Connected to \(conn.host)."

            if conn.captureCmdKeys || conn.reverseScroll {
                grabber.captureCmd = conn.captureCmdKeys
                grabber.reverseScroll = conn.reverseScroll
                grabber.log = { [weak self] msg in Task { @MainActor in self?.append(msg) } }
                if grabber.start(pid: proc.processIdentifier) {
                    if conn.captureCmdKeys {
                        append("Keyboard grab on (toggle: Ctrl+Opt+G).")
                    }
                    if conn.reverseScroll { append("Scroll direction reversed for the session") }
                }
            }
        } catch {
            status = "Failed to launch."
            append("Failed to launch: \(error.localizedDescription)")
        }
    }

    func disconnect() { process?.terminate() }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var showSaveSheet = false
    @State private var saveName = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Favorite", selection: favoriteBinding) {
                        Text("New Connection...").tag(UUID?.none)
                        if !state.favorites.isEmpty { Divider() }
                        ForEach(state.favorites) { fav in
                            Text(fav.name).tag(Optional(fav.id))
                        }
                    }
                    HStack {
                        Button("Save...") { saveName = state.selectedName ?? state.conn.host; showSaveSheet = true }
                        Button("Delete") { state.deleteSelected() }
                            .disabled(state.selectedID == nil)
                        Spacer()
                    }
                }

                Section("Connection") {
                    TextField("Server", text: $state.conn.host, prompt: Text("host or host:port"))
                    TextField("Username", text: $state.conn.username)
                    SecureField("Password", text: $state.conn.password)
                }

                Section("Display") {
                    Picker("Resolution", selection: $state.conn.resolution) {
                        Text("Fullscreen").tag("Fullscreen")
                        ForEach(Connection.resolutionPresets, id: \.self) { Text($0).tag($0) }
                        Text("Custom...").tag(Connection.customResolution)
                    }
                    if state.conn.resolution == Connection.customResolution {
                        TextField("Custom size", text: $state.conn.customResolution,
                                  prompt: Text("e.g. 1920x1200"))
                        if let (w, h) = Connection.parseSize(state.conn.customResolution) {
                            Text("Detected aspect ratio: \(Connection.aspectRatio(w, h))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Enter as WIDTH x HEIGHT.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Mode", selection: $state.conn.displayMode) {
                        ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                    }
                    if state.conn.displayMode == .scale {
                        Picker("Client scale", selection: $state.conn.clientScale) {
                            ForEach(Connection.scalePresets, id: \.self) { p in
                                Text(p == Connection.customScale ? "Custom..." : "\(p)%").tag(p)
                            }
                        }
                        if state.conn.clientScale == Connection.customScale {
                            TextField("Client scale %", text: $state.conn.customScale,
                                      prompt: Text("e.g. 150"))
                        }
                    }
                }

                Section {
                    Picker("Server DPI scale", selection: $state.conn.serverScale) {
                        ForEach(Connection.serverScalePresets, id: \.self) { p in
                            Text(p == Connection.customScale ? "Custom..." : (p == "100" ? "Off (100%)" : "\(p)%")).tag(p)
                        }
                    }
                    if state.conn.serverScale == Connection.customScale {
                        TextField("Server scale %", text: $state.conn.customServerScale,
                                  prompt: Text("e.g. 150"))
                    }
                } header: {
                    Text("Server scaling")
                }

                Section("Options") {
                    TextField("Domain", text: $state.conn.domain)
                    Toggle("Use all monitors", isOn: $state.conn.multiMonitor)
                    Toggle("Send Cmd shortcuts to session", isOn: $state.conn.captureCmdKeys)
                    Toggle("Swap Cmd and Option (PC layout)", isOn: $state.conn.swapCmdOpt)
                    Toggle("Send right Ctrl as left Ctrl", isOn: $state.conn.rightCtrlAsLeft)
                    Toggle("Reverse scroll direction", isOn: $state.conn.reverseScroll)
                    Toggle("Ignore certificate", isOn: $state.conn.ignoreCert)
                    Toggle("Share clipboard", isOn: $state.conn.clipboard)
                    Toggle("Forward audio", isOn: $state.conn.audio)
                    Toggle("Forward microphone", isOn: $state.conn.microphone)
                    Toggle("Share home folder", isOn: $state.conn.driveRedirect)
                    TextField("Extra arguments", text: $state.conn.extraArgs, prompt: Text("e.g. /gfx /rfx"))
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button { openWindow(id: "log") } label: {
                    Image(systemName: "text.alignleft")
                }
                .help("Show log")
                .buttonStyle(.borderless)

                if state.isRunning {
                    Button("Disconnect", role: .destructive) { state.disconnect() }
                } else {
                    Button("Connect") { state.connect() }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .frame(minHeight: 480)
        .sheet(isPresented: $showSaveSheet) { saveSheet }
    }

    private var favoriteBinding: Binding<UUID?> {
        Binding(
            get: { state.selectedID },
            set: { newID in
                if let id = newID, let fav = state.favorites.first(where: { $0.id == id }) {
                    state.apply(fav)
                } else {
                    state.newConnection()
                }
            }
        )
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Favorite").font(.headline)
            TextField("Name", text: $saveName)
                .frame(width: 240)
            HStack {
                Spacer()
                Button("Cancel") { showSaveSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    state.saveFavorite(name: saveName)
                    showSaveSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

struct LogView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.log.isEmpty ? "No output yet." : state.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .id("logEnd")
                }
                .onChange(of: state.log) { proxy.scrollTo("logEnd", anchor: .bottom) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Clear") { state.log = "" }
            }
            .padding(8)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct RDPConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("RDPConnect", id: "main") {
            ContentView().environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("Log", id: "log") {
            LogView().environmentObject(state)
        }
        .defaultSize(width: 560, height: 360)
    }
}
