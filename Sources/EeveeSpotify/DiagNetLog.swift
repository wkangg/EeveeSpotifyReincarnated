import Foundation

// Temporary diagnostic: which spclient requests does 9.2.0 make at launch, and
// which delegate (if any) sees them? Logs host + path only, never the query string.
private let diagWindowSeconds: TimeInterval = 60
private let diagLock = NSLock()
private var diagSeen = Set<String>()

func diagNetLog(_ source: String, _ url: URL?, extra: String = "") {
    guard let url = url, let host = url.host?.lowercased() else { return }
    let elapsed = Date().timeIntervalSince(tweakInitTime)
    guard elapsed < diagWindowSeconds else { return }
    guard host.contains("spotify") || host.contains("scdn") else { return }

    let key = "\(source) \(host)\(url.path)"
    diagLock.lock()
    let isNew = diagSeen.insert(key).inserted
    diagLock.unlock()
    guard isNew else { return }

    let suffix = extra.isEmpty ? "" : " \(extra)"
    writeDebugLog("[DIAG][\(source)] t=\(Int(elapsed))s \(host)\(url.path)\(suffix)")
}
