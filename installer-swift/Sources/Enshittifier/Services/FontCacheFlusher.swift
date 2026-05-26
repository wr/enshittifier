import Foundation

enum FontCacheFlusher {
    /// Best-effort flush of the user-level macOS font cache, then bounce
    /// fontd so the daemon picks up the new bytes.
    ///
    /// Why both: `atsutil databases -removeUser` clears the on-disk cache,
    /// but the running fontd keeps its in-memory registration. Empirically
    /// (macOS 26.5), an in-place patched font silently disappears from
    /// `atsutil fonts -list` after install — apps see no descriptor for
    /// the family until fontd respawns. `killall fontd` triggers launchd
    /// to restart it cleanly, no sudo required. We never touch
    /// /System/Library/Fonts/ (system fonts get a shadow into
    /// ~/Library/Fonts/), so the system-scope flush — which would prompt
    /// for admin — is unnecessary.
    @discardableResult
    static func flush() -> Bool {
        let flushed = runSilently(launchPath: "/usr/bin/atsutil",
                                  arguments: ["databases", "-removeUser"])
        let oldPid = fontdPid()
        // `killall` exits non-zero if no matching process; fontd should
        // always be running but treat absence as fine.
        _ = runSilently(launchPath: "/usr/bin/killall", arguments: ["fontd"])
        waitForFontdRestart(oldPid: oldPid)
        return flushed
    }

    /// Block until launchd has respawned fontd with a new PID and given it
    /// a beat to rebuild its registration. Without this, `CTFontCollection
    /// CreateFromAvailableFonts(nil)` and `CTFontManagerRegisterFontURLs`
    /// run against a half-up daemon: the calls block for tens of seconds,
    /// and when they return, the active set is incomplete (so every
    /// untouched family looks inactive in the UI, and the just-patched
    /// font still renders with stale bytes).
    private static func waitForFontdRestart(oldPid: Int32?) {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let pid = fontdPid(), pid != oldPid {
                // New fontd is alive. Pause for it to scan ~/Library/Fonts
                // before any caller queries CoreText.
                Thread.sleep(forTimeInterval: 1.5)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func fontdPid() -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "fontd"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let first = raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        return Int32(first.trimmingCharacters(in: .whitespaces))
    }

    @discardableResult
    private static func runSilently(launchPath: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
