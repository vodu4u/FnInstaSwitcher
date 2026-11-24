import AppKit

// Single instance: hold an exclusive advisory lock for the process lifetime.
// The kernel releases it automatically if InstantFn quits or crashes.
let lockDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(Bundle.main.bundleIdentifier ?? "InstantFn", isDirectory: true)
try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
let lockFD = open(lockDir.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    if !CommandLine.arguments.contains("--benchmark") {
        FileHandle.standardError.write("InstantFn is already running.\n".data(using: .utf8)!)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon (also LSUIElement in Info.plist)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
