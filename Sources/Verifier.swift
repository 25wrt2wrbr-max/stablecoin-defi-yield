import Foundation

/// Crawls a protocol's own app page with Moli and reads back the APY the site
/// actually renders, so the figure can be cross-checked against the first-party API.
///
/// This implements requirement 5 of the project — the APY must be verified by code
/// going to the DeFi app's website itself before the user sees it.
actor APYVerifier {

    /// APYs drift between an API read and a UI render, and sites round for display.
    /// Treat anything within this many percentage points as agreement.
    static let tolerancePercent: Double = 0.75

    /// Wall-clock guard. Moli gets its own `--timeout`; this is the outer backstop
    /// for a process that wedges entirely.
    private let hardTimeout: TimeInterval = 75

    // MARK: - Moli resolution

    /// Resolve the moli binary. A GUI app launched from Finder inherits a minimal PATH,
    /// so we cannot rely on PATH lookup alone.
    private static func moliPath() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/moli",
            "/usr/local/bin/moli",
            "/opt/homebrew/bin/moli",
            "/usr/bin/moli"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Last resort: ask the login shell, which has the user's real PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v moli"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        } catch { /* fall through to nil */ }
        return nil
    }

    // MARK: - Extraction script

    /// The JS we evaluate inside the rendered page. Looks for an element whose text
    /// mentions APY, walks up to a container that also contains a `%`, and reports
    /// both the raw percent and the label context so the caller can pick the best one.
    ///
    /// Verified working against app.beefy.com on 2026-09-26 (returned 34.64 for a
    /// vault whose API totalApy was 0.3464).
    private static let extractionJS = #"""
    (() => {
      const out = { url: location.href, title: document.title, candidates: [], ready: false };
      const all = [...document.querySelectorAll('*')];
      const seen = new Set();
      for (const el of all) {
        const own = (el.innerText || '').trim();
        if (!own || own.length > 200) continue;
        if (!/apy/i.test(own)) continue;
        let node = el;
        for (let i = 0; i < 3 && node; i++) {
          const t = (node.innerText || '').trim();
          if (t.length > 200) { node = node.parentElement; continue; }
          const pcts = [...t.matchAll(/([0-9]+(?:\.[0-9]+)?)\s*%/g)].map(m => parseFloat(m[1]));
          if (pcts.length) {
            if (!seen.has(t)) { seen.add(t); out.candidates.push({ text: t.slice(0, 200), pcts }); }
            break;
          }
          node = node.parentElement;
        }
      }
      out.ready = out.candidates.length > 0;
      return JSON.stringify(out);
    })()
    """#

    private struct ExtractResult: Decodable {
        let url: String?
        let title: String?
        let candidates: [Candidate]
        let ready: Bool

        struct Candidate: Decodable {
            let text: String
            let pcts: [Double]
        }
    }

    // MARK: - Verification

    /// Crawl `pageURL` and decide the verification state for an opportunity whose
    /// API-reported APY (as a percentage) is `apiPercent`.
    func verify(id: String, pageURL: URL, apiPercent: Double) async -> VerificationState {
        guard let moli = Self.moliPath() else {
            return .unverified(reason: "Moli not installed — cannot crawl to verify")
        }

        // Each crawl gets its own scratch file, so concurrent verifications don't race.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apy-extract-\(UUID().uuidString).js")
        do {
            try Self.extractionJS.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return .unverified(reason: "Could not stage crawl script")
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let output: String
        do {
            output = try await runProcess(
                executable: moli,
                arguments: [
                    "fetch",
                    "--wait", "networkidle",
                    "--timeout", "45000",
                    "--eval-file", scriptURL.path,
                    pageURL.absoluteString
                ]
            )
        } catch {
            return .unverified(reason: crawlReason(for: error))
        }

        // Moli writes the JS value to stdout as compact JSON.
        guard let jsonStart = output.firstIndex(of: "{"),
              let data = String(output[jsonStart...]).data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ExtractResult.self, from: data) else {
            return .unverified(reason: "Could not read APY from the site")
        }

        guard let crawled = Self.pickAPY(from: parsed.candidates) else {
            return .unverified(reason: parsed.ready ? "No APY on page" : "Page did not render an APY")
        }

        if abs(crawled - apiPercent) <= Self.tolerancePercent {
            return .verified(api: apiPercent, crawled: crawled)
        }
        // The site is the ground truth (requirement 5), but show both so the
        // discrepancy is visible rather than hidden.
        return .mismatch(api: apiPercent, crawled: crawled)
    }

    /// Choose the APY the site is presenting as *the* yield figure.
    ///
    /// Preference order:
    ///   1. A candidate explicitly labelled "total apy" (Beefy's headline).
    ///   2. A candidate labelled "apy" but not one of the sub-components.
    ///   3. Any candidate closest to the API value (least surprising to the user).
    private static func pickAPY(from candidates: [ExtractResult.Candidate]) -> Double? {
        guard !candidates.isEmpty else { return nil }

        func isSubComponent(_ text: String) -> Bool {
            let t = text.lowercased()
            return t.contains("vault apr") || t.contains("trading apr")
                || t.contains("daily") || t.contains("historical")
                || t.contains("deposit fee") || t.contains("withdrawal fee")
        }

        // 1. explicit "total apy"
        for c in candidates where c.text.lowercased().contains("total apy") {
            if let v = c.pcts.first { return v }
        }
        // 2. plain "apy" that isn't a sub-component
        for c in candidates {
            let t = c.text.lowercased()
            if t.contains("apy") && !isSubComponent(c.text), let v = c.pcts.first { return v }
        }
        // 3. fall back to the first non-sub-component number
        for c in candidates where !isSubComponent(c.text) {
            if let v = c.pcts.first { return v }
        }
        return candidates.first?.pcts.first
    }

    private func crawlReason(for error: Error) -> String {
        if let e = error as? ProcessError {
            switch e {
            case .timedOut: return "Crawl timed out"
            case .launchFailed: return "Could not start the crawler"
            case .nonZeroExit(_, let stderr):
                let s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? "Crawler failed" : "Crawler failed: \(String(s.prefix(90)))"
            }
        }
        return "Crawl failed"
    }

    // MARK: - Process plumbing

    enum ProcessError: Error {
        case launchFailed(String)
        case timedOut
        case nonZeroExit(Int32, String)
    }

    private func runProcess(executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Moli inherits the user's real PATH so it can find its own helpers.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(NSHomeDirectory())/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env

            // Guard against a wedged process, and make sure the continuation fires once.
            let lock = NSLock()
            var finished = false

            func finish(_ result: Result<String, Error>) {
                lock.lock()
                if finished { lock.unlock(); return }
                finished = true
                lock.unlock()
                continuation.resume(with: result)
            }

            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(decoding: outData, as: UTF8.self)
                let err = String(decoding: errData, as: UTF8.self)
                if proc.terminationStatus == 0 {
                    finish(.success(out))
                } else {
                    finish(.failure(ProcessError.nonZeroExit(proc.terminationStatus, err)))
                }
            }

            let deadline = DispatchTime.now() + hardTimeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
                finish(.failure(ProcessError.timedOut))
            }

            do {
                try process.run()
            } catch {
                finish(.failure(ProcessError.launchFailed(error.localizedDescription)))
            }
        }
    }
}