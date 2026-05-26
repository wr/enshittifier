import Foundation

/// Invokes the bundled enshittifier.py via Process. Locates a working
/// python3 + fontTools across the common installation paths so the app
/// works when launched from Finder (where PATH is minimal).
struct PythonFallbackPatcher {
    func patch(url: URL) throws {
        let python = try Self.locatePython()
        let script = try Self.locateScript()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            script.path,
            "--no-backup-yes-i-am-an-idiot",
            "-q",
            url.path,
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PatcherError.patchFailed(trimmed.isEmpty ? "enshittifier.py exited with status \(process.terminationStatus)" : trimmed)
        }
    }

    // MARK: - Locators

    private static let systemPythonCandidates = [
        "/opt/homebrew/bin/python3",   // Apple Silicon Homebrew
        "/usr/local/bin/python3",      // Intel Homebrew
        "/opt/homebrew/bin/python3.14",
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/usr/bin/python3",            // Apple stub — last resort
    ]

    /// Prefer the venv bundled inside Contents/Resources/venv/ — it has
    /// fontTools pre-installed, so end users don't have to pip-install
    /// anything. Falls back to a system python3 only if the bundled venv
    /// is absent (running via `swift run` from the repo, or a misbuilt .app).
    private static func locatePython() throws -> String {
        let fm = FileManager.default

        if let bundled = bundledVenvPython(), fm.isExecutableFile(atPath: bundled) {
            if hasFontTools(at: bundled) { return bundled }
        }

        for candidate in systemPythonCandidates where fm.isExecutableFile(atPath: candidate) {
            if hasFontTools(at: candidate) { return candidate }
        }
        // Differentiate "no python at all" from "python without fontTools"
        for candidate in systemPythonCandidates where fm.isExecutableFile(atPath: candidate) {
            _ = candidate
            throw PatcherError.fontToolsMissing
        }
        throw PatcherError.pythonNotFound
    }

    private static func bundledVenvPython() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let venvPython = resourceURL.appendingPathComponent("venv/bin/python3")
        return venvPython.path
    }

    private static func hasFontTools(at python: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", "import fontTools"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func locateScript() throws -> URL {
        let fm = FileManager.default

        // 1. Bundled into the .app's Contents/Resources/
        if let bundled = Bundle.main.url(forResource: "enshittifier", withExtension: "py"),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }

        // 2. Next to the executable (dev: .build/debug/EnshittifierInstaller)
        let execDir = (Bundle.main.executableURL ?? Bundle.main.bundleURL).deletingLastPathComponent()
        let beside = execDir.appendingPathComponent("enshittifier.py")
        if fm.fileExists(atPath: beside.path) { return beside }

        // 3. Walk up the directory tree looking for a sibling enshittifier.py
        //    (covers `swift run` from the repo)
        var dir = execDir
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("enshittifier.py")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        throw PatcherError.scriptNotFound
    }
}
