// PageWatcher.swift — tracks which Resolve page is active by running the tiny
// Python sidecar (fusionscript.so) in --watch mode and parsing its JSON lines.
// Restarts the sidecar if it dies.

import Foundation

public final class PageWatcher {
    public var onPage: ((String?) -> Void)?
    public private(set) var currentPage: String?

    private let scriptPath: String
    private var process: Process?
    private var pending = ""
    private let restartDelay: TimeInterval = 2.0

    public init(scriptPath: String = ResolveAgent.defaultScriptPath) {
        self.scriptPath = scriptPath
    }

    public func start() {
        launch()
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    private func launch() {
        let uv = "/opt/homebrew/bin/uv"
        guard FileManager.default.fileExists(atPath: uv) else {
            print("⚠️  uv not found at \(uv) — page detection disabled (install: brew install uv)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--no-project", "--python", "3.14", scriptPath, "--watch"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pending = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            self?.consume(chunk)
        }
        p.terminationHandler = { [weak self] _ in
            guard self?.process === p else { return }
            self?.process = nil
            let delay = self?.restartDelay ?? 2.0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self?.launch()
            }
        }
        do {
            try p.run()
            process = p
            print("✓ page watcher started (sidecar)")
        } catch {
            print("⚠️  page watcher failed to start: \(error)")
        }
    }

    private func consume(_ chunk: String) {
        pending += chunk
        var lines = pending.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return }
        pending = String(lines.removeLast())
        for line in lines where !line.isEmpty {
            handle(line: String(line))
        }
    }

    private func handle(line: String) {
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let page = obj["page"] as? String
        guard page != currentPage else { return }
        currentPage = page
        print("↻ page → \(page ?? "unknown")")
        onPage?(page)
    }
}
