// ResolveAgent.swift — talks to the running Resolve instance via a tiny Python
// sidecar (fusionscript.so is a CPython extension and cannot load inside Swift).
// The sidecar uses only the Python stdlib and Resolve's bundled scripting bridge.

import Foundation

public enum ResolveAgentError: Error, CustomStringConvertible {
    case uvNotFound(String)
    case pythonFailed(String)

    public var description: String {
        switch self {
        case .uvNotFound(let path):
            return "uv not found at \(path) — install with: brew install uv"
        case .pythonFailed(let stderr):
            return "Resolve page agent failed: \(stderr)"
        }
    }
}

public struct ResolvePageInfo: CustomStringConvertible {
    public let version: String?
    public let page: String?

    public var description: String {
        "version=\(version ?? "?")  page=\(page ?? "?")"
    }
}

public enum ResolveAgent {
    /// Where the sidecar script lives when running from the repo root.
    public static let defaultScriptPath = "tools/resolve_page_agent.py"

    /// Query the running Resolve once. Returns nil if Resolve isn't running.
    public static func queryPage(script: String = defaultScriptPath) throws -> ResolvePageInfo? {
        let output = try runSidecar(script: script, args: ["--once"])
        guard let line = output.split(separator: "\n").last,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolveAgentError.pythonFailed("unexpected sidecar output: \(output)")
        }
        if let error = obj["error"] as? String {
            if error == "resolve-not-running" { return nil }
            throw ResolveAgentError.pythonFailed(error)
        }
        return ResolvePageInfo(
            version: obj["version"] as? String,
            page: obj["page"] as? String
        )
    }

    private static func uvPath() -> String {
        "/opt/homebrew/bin/uv"
    }

    private static func runSidecar(script: String, args: [String]) throws -> String {
        let uv = uvPath()
        guard FileManager.default.fileExists(atPath: uv) else {
            throw ResolveAgentError.uvNotFound(uv)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--no-project", "--python", "3.14", script] + args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ResolveAgentError.pythonFailed(
                String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
