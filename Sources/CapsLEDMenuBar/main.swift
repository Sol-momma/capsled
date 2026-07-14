import AppKit
import CapsLEDCore
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
if let workerStatus = CapsLEDApplication.executeWorkerIfRequested(arguments: arguments) {
    // Persistent On relaunches the current executable as a hidden worker. Handle
    // that private mode before AppKit is initialized so no second menu-bar icon
    // flashes into view and the CLI and app continue to share one ownership lock.
    exit(workerStatus)
}

let application = NSApplication.shared
let delegate = MenuBarApplicationDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
