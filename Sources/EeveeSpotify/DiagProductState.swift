import Foundation
import ObjectiveC.runtime

// Temporary diagnostic: where does Spotify 9.2.0 get its product state from?
// Logs only type/catalogue/ads/on-demand/player-license and the key count.

private let minimalSessionSelectorName =
    "createMinimalSessionWithApplicationScope:login5Setup:credentialsStorage:configuration:productStateDict:credentials:accessToken:login5BackoffConfig:login5ExponentialBackoffEnabled:"
private let expectedMinimalSessionEncoding = "@@:@@@@@@@@B"

func diagDescribeProductState(_ value: Any?) -> String {
    guard let value = value else { return "nil" }
    guard let dict = value as? NSDictionary else { return "non-dict(\(type(of: value)))" }
    let pairs = ["type", "catalogue", "ads", "on-demand", "player-license"].map { key -> String in
        guard let v = dict[key] else { return "\(key)=nil" }
        return "\(key)=\(v)"
    }
    return "keys=\(dict.count) " + pairs.joined(separator: " ")
}

private let diagCountLock = NSLock()
private var diagCounts: [String: Int] = [:]

// True for the first `limit` calls tagged `tag`.
func diagShouldLog(_ tag: String, limit: Int) -> Bool {
    diagCountLock.lock(); defer { diagCountLock.unlock() }
    let n = (diagCounts[tag] ?? 0) + 1
    diagCounts[tag] = n
    return n <= limit
}

private typealias MinimalSessionIMP = @convention(c) (
    AnyObject, Selector,
    AnyObject?, AnyObject?, AnyObject?, AnyObject?,
    AnyObject?, AnyObject?, AnyObject?, AnyObject?,
    Bool
) -> AnyObject?

private var originalMinimalSessionIMP: IMP?

private func strippedEncoding(_ method: Method) -> String {
    guard let raw = method_getTypeEncoding(method) else { return "?" }
    return String(cString: raw).filter { !$0.isNumber }
}

// Bridging a class to Any/AnyObject sends it retain/release. Some root classes
// (e.g. __NSGenericDeallocHandler) trap on that, so only touch NSObject subclasses.
private func inheritsFromNSObject(_ cls: AnyClass) -> Bool {
    var current: AnyClass? = cls
    while let c = current {
        if ObjectIdentifier(c) == ObjectIdentifier(NSObject.self) { return true }
        current = class_getSuperclass(c)
    }
    return false
}

// class_copyMethodList never runs +initialize or +resolveInstanceMethod:.
private func ownMethod(_ cls: AnyClass, _ sel: Selector) -> Method? {
    var count: UInt32 = 0
    guard let list = class_copyMethodList(cls, &count) else { return nil }
    defer { free(list) }
    for i in 0..<Int(count) where method_getName(list[i]) == sel {
        return list[i]
    }
    return nil
}

private func installMinimalSessionLogger(_ method: Method, owner: String) {
    guard originalMinimalSessionIMP == nil else { return }
    originalMinimalSessionIMP = method_getImplementation(method)
    let block: @convention(block) (
        AnyObject,
        AnyObject?, AnyObject?, AnyObject?, AnyObject?,
        AnyObject?, AnyObject?, AnyObject?, AnyObject?,
        Bool
    ) -> AnyObject? = { obj, scope, setup, storage, config, productState, creds, token, backoff, expEnabled in
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[DIAG][MINIMAL_SESSION] t=\(elapsed)s \(owner) productStateDict: \(diagDescribeProductState(productState))")
        let orig = unsafeBitCast(originalMinimalSessionIMP!, to: MinimalSessionIMP.self)
        return orig(obj, Selector((minimalSessionSelectorName)),
                    scope, setup, storage, config, productState, creds, token, backoff, expEnabled)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
    writeDebugLog("[DIAG][MINIMAL_SESSION] logger installed on \(owner)")
}

func activateDiagProductState() {
    let sel = Selector((minimalSessionSelectorName))
    let total = objc_getClassList(nil, 0)
    guard total > 0 else { return }
    let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
    defer { buffer.deallocate() }
    let got = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), total)

    var found = 0
    for i in 0..<Int(min(got, total)) {
        let cls: AnyClass = buffer[i]
        guard inheritsFromNSObject(cls) else { continue }
        let name = String(cString: class_getName(cls))
        var candidates: [(Method, String)] = []
        if let m = ownMethod(cls, sel) { candidates.append((m, "-[\(name)]")) }
        if let meta = object_getClass(cls), let m = ownMethod(meta, sel) { candidates.append((m, "+[\(name)]")) }

        for (method, owner) in candidates {
            found += 1
            let encoding = strippedEncoding(method)
            writeDebugLog("[DIAG][MINIMAL_SESSION] found \(owner) encoding=\(encoding)")
            if encoding == expectedMinimalSessionEncoding {
                installMinimalSessionLogger(method, owner: owner)
            } else {
                writeDebugLog("[DIAG][MINIMAL_SESSION] encoding differs from \(expectedMinimalSessionEncoding); not hooking")
            }
        }
    }
    writeDebugLog("[DIAG][MINIMAL_SESSION] scanned \(got) classes, \(found) implementation(s)")
}
