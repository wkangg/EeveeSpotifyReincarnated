import Foundation

// MARK: - Diagnostic: get the product-state attributes body to arrive at all
//
// The 189 Free product-state keys do not come from login5. The launch order is:
//
//   login5/v4/login -> login5/v3/login -> dealer websocket
//   -> nebula/v1/configuration/attributes  (status=304, every launch)
//   -> [AUTH] productStateUpdated  (73ms later, Free)
//
// Because the attributes request is conditional and the server answers 304, the
// response has no body: the core reloads the Free attributes from its own cache.
// That is why SpotifyResponsePatcher has never had a product-state body to
// rewrite, and why seeding the ObjC objects cannot win - the cached values are
// re-pushed a second after launch.
//
// So: drop the conditional headers on that one request, which forces a 200 with
// a real body, and tap the body read-only to learn its format. The tap does not
// suppress or buffer anything, so an empty or unexpected response cannot break
// the attributes load.

enum DiagNebulaAttributes {
    private static var strippedCount = 0
    private static var loggedBodies = 0

    // MARK: Request side - force a body to exist

    private static var originalDataTask: IMP?
    private static var originalDataTaskWithCompletion: IMP?

    /// Returns a copy of `request` with the cache validators removed, so the
    /// server cannot answer 304.
    private static func unconditional(_ request: URLRequest) -> URLRequest {
        var copy = request
        copy.setValue(nil, forHTTPHeaderField: "If-None-Match")
        copy.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        copy.cachePolicy = .reloadIgnoringLocalCacheData
        if strippedCount < 5 {
            strippedCount += 1
            writeDebugLog("[DIAG][NEBULA] stripped cache validators from \(request.url?.path ?? "?")")
        }
        return copy
    }

    private static func rewriteIfNebula(_ request: AnyObject?) -> AnyObject? {
        guard let urlRequest = request as? URLRequest,
              let url = urlRequest.url,
              url.isNebulaAttributes else { return request }
        return unconditional(urlRequest) as NSURLRequest
    }

    static func installRequestHook() {
        guard let cls: AnyClass = NSClassFromString("NSURLSession") else { return }

        let selector = NSSelectorFromString("dataTaskWithRequest:")
        if let method = class_getInstanceMethod(cls, selector) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
            let original = method_getImplementation(method)
            originalDataTask = original
            let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { this, request in
                unsafeBitCast(original, to: Fn.self)(this, selector, rewriteIfNebula(request))
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        let completionSelector = NSSelectorFromString("dataTaskWithRequest:completionHandler:")
        if let method = class_getInstanceMethod(cls, completionSelector) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?
            let original = method_getImplementation(method)
            originalDataTaskWithCompletion = original
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { this, request, handler in
                unsafeBitCast(original, to: Fn.self)(this, completionSelector, rewriteIfNebula(request), handler)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        writeDebugLog("[DIAG][NEBULA] request hook installed")
    }

    // MARK: Response side - read-only tap

    /// Printable runs of 4+ characters, which is enough to recognise
    /// product-state keys such as "on-demand" or "catalogue" in a protobuf body.
    private static func printableRuns(_ data: Data, limit: Int) -> [String] {
        var runs: [String] = []
        var current = [UInt8]()
        for byte in data {
            if byte >= 0x20 && byte < 0x7F {
                current.append(byte)
            } else {
                if current.count >= 4, let s = String(bytes: current, encoding: .utf8) {
                    runs.append(s)
                    if runs.count >= limit { break }
                }
                current.removeAll(keepingCapacity: true)
            }
        }
        if runs.count < limit, current.count >= 4, let s = String(bytes: current, encoding: .utf8) {
            runs.append(s)
        }
        return runs
    }

    static func logBody(_ data: Data, url: URL) {
        guard loggedBodies < 1 else { return }
        loggedBodies += 1
        writeDebugLog("[DIAG][NEBULA] body \(data.count) bytes")
        let runs = printableRuns(data, limit: 60)
        writeDebugLog("[DIAG][NEBULA] strings(\(runs.count)): \(runs.joined(separator: " | "))")

        // Dump the whole body so its protobuf layout can be parsed exactly
        // rather than guessed from printable fragments. Chunked because the
        // log writer is line oriented.
        let encoded = data.base64EncodedString()
        let chunk = 400
        let total = (encoded.count + chunk - 1) / chunk
        writeDebugLog("[DIAG][NEBULA] b64 begin \(encoded.count) chars in \(total) parts")
        var index = encoded.startIndex
        var part = 0
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: chunk, limitedBy: encoded.endIndex) ?? encoded.endIndex
            writeDebugLog("[DIAG][NEBULA] b64 \(part)/\(total) \(encoded[index..<end])")
            index = end
            part += 1
        }
        writeDebugLog("[DIAG][NEBULA] b64 end")
    }
}

func activateDiagNebulaAttributes() {
    DiagNebulaAttributes.installRequestHook()
}
