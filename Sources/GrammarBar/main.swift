import AppKit

setvbuf(stdout, nil, _IONBF, 0) // unbuffered stdout so print() shows up immediately when piped

// AppDelegate.init() is nonisolated; AppKit guarantees delegate methods
// run on the main thread, which is where @MainActor methods execute.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
