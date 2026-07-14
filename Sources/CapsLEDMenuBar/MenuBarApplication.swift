import AppKit
import CapsLEDCore

private enum Copy {
    private static let japanese = Locale.preferredLanguages.first?.hasPrefix("ja") == true

    static let accessibilityLabel = japanese ? "Caps Lock LED 制御" : "Caps Lock LED control"
    static let ready = japanese ? "操作を選択してください" : "Choose an LED mode"
    static let working = japanese ? "変更中…" : "Updating…"
    static let returning = japanese ? "macOSへ戻しています…" : "Returning control to macOS…"
    static let keepOn = japanese ? "LEDを点灯し続ける" : "Keep LED On"
    static let turnOff = japanese ? "LEDを消灯する" : "Turn LED Off"
    static let automatic = japanese ? "macOSへ制御を戻す" : "Return Control to macOS"
    static let quit = japanese ? "CapsLEDを終了" : "Quit CapsLED"
    static let on = japanese ? "LEDの点灯維持を開始しました" : "Started keeping the LED on"
    static let alreadyOn = japanese ? "LEDの点灯維持は開始済みでした" : "LED maintenance was already running"
    static let off = japanese ? "LEDの消灯を要求しました" : "Requested LED Off"
    static let automaticStatus = japanese ? "LEDの制御をmacOSへ戻しました" : "Returned LED control to macOS"
    static let errorTitle = japanese ? "CapsLEDで操作できませんでした" : "CapsLED could not update the LED"
    static let dismiss = japanese ? "OK" : "OK"
}

final class MenuBarApplicationDelegate: NSObject, NSApplicationDelegate {
    private let commandRunner: LEDModeCommandRunner

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var modeMenuItems: [LEDMode: NSMenuItem] = [:]
    private var isCommandRunning = false
    private var terminationRequested = false
    private var terminationWasApproved = false

    override convenience init() {
        do {
            try self.init(coordinator: CapsLEDModeCoordinator())
        } catch {
            // Bundle.main.executableURL should exist for an app executable. Keep
            // launch failure visible instead of presenting a menu whose actions
            // can never start the persistent worker.
            fatalError("CapsLED could not initialize: \(error.localizedDescription)")
        }
    }

    private init(coordinator: CapsLEDModeSetting) {
        commandRunner = LEDModeCommandRunner(coordinator: coordinator)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationWasApproved else { return .terminateNow }
        guard !terminationRequested else { return .terminateLater }

        terminationRequested = true
        setCommandItemsEnabled(false)
        updateStatus(Copy.returning)

        // Quitting is an ownership boundary, not just a UI event. Restore Auto
        // only after the persistent worker has drained so it cannot race with a
        // final On repair after this process has disappeared.
        commandRunner.prepareForTermination { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.terminationWasApproved = true
                sender.reply(toApplicationShouldTerminate: true)
            case let .failure(error):
                self.terminationRequested = false
                self.setCommandItemsEnabled(true)
                self.updateStatus(Copy.ready)
                self.present(error)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    @objc private func keepLEDOn() {
        apply(.on)
    }

    @objc private func turnLEDOff() {
        apply(.off)
    }

    @objc private func returnControlToMacOS() {
        apply(.automatic)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = symbol()
        item.button?.toolTip = Copy.accessibilityLabel

        let menu = NSMenu()
        let status = NSMenuItem(title: Copy.ready, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        addModeItem(title: Copy.keepOn, mode: .on, action: #selector(keepLEDOn), to: menu)
        addModeItem(title: Copy.turnOff, mode: .off, action: #selector(turnLEDOff), to: menu)
        addModeItem(
            title: Copy.automatic,
            mode: .automatic,
            action: #selector(returnControlToMacOS),
            to: menu
        )
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: Copy.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        statusMenuItem = status
    }

    private func addModeItem(
        title: String,
        mode: LEDMode,
        action: Selector,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        modeMenuItems[mode] = item
        menu.addItem(item)
    }

    private func apply(_ mode: LEDMode) {
        guard !isCommandRunning, !terminationRequested else { return }
        isCommandRunning = true
        setCommandItemsEnabled(false)
        updateStatus(Copy.working)

        // HID ownership changes may wait for another CLI process to finish its
        // jittered backoff. Running them off the main thread keeps the status
        // menu responsive during that bounded coordination window.
        commandRunner.apply(mode) { [weak self] result in
            guard let self else { return }
            if self.terminationRequested {
                // Auto is already queued behind this operation. Preserve the
                // termination status text and let only that final completion
                // decide whether to quit or present an error.
                self.isCommandRunning = false
                return
            }
            switch result {
            case let .success(operationResult):
                self.finish(mode: mode, result: operationResult)
            case let .failure(error):
                self.isCommandRunning = false
                self.setCommandItemsEnabled(true)
                self.updateStatus(Copy.ready)
                self.present(error)
            }
        }
    }

    private func finish(mode: LEDMode, result: CapsLEDModeOperationResult) {
        isCommandRunning = false
        setCommandItemsEnabled(true)
        // These are completion messages, not a continuously synchronized state
        // display. A later CLI command may change the shared owner while this
        // menu is closed, so persistent checkmarks or a filled icon would make a
        // stale assertion about current ownership.
        switch (mode, result) {
        case (.on, .alreadyOn): updateStatus(Copy.alreadyOn)
        case (.on, _): updateStatus(Copy.on)
        case (.off, _): updateStatus(Copy.off)
        case (.automatic, _): updateStatus(Copy.automaticStatus)
        }
    }

    private func setCommandItemsEnabled(_ isEnabled: Bool) {
        modeMenuItems.values.forEach { $0.isEnabled = isEnabled }
    }

    private func updateStatus(_ text: String) {
        statusMenuItem?.title = text
        statusItem?.button?.toolTip = text
    }

    private func symbol() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "capslock",
            accessibilityDescription: Copy.accessibilityLabel
        )
        image?.isTemplate = true
        return image
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Copy.errorTitle
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: Copy.dismiss)
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
