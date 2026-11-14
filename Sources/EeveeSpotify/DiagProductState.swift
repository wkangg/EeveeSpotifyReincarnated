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

// Experiment: the core is seeded from this cached dict, and the player enforces
// Free restrictions from the core's state, not from the ObjC getters we force.
let diagPremiumSeed: [String: String] = [
    "type": "premium", "catalogue": "premium", "product": "premium",
    "ads": "0", "on-demand": "1", "unrestricted": "1", "shuffle-eligible": "1",
    "player-license": "premium", "player-license-v2": "premium",
]

func diagSeedPremium(_ value: AnyObject?) -> AnyObject? {
    guard let dict = value as? NSDictionary else { return value }
    let m = NSMutableDictionary(dictionary: dict)
    for (k, v) in diagPremiumSeed { m[k] = v }
    return m
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
        let productState = diagSeedPremium(productState)
        writeDebugLog("[DIAG][MINIMAL_SESSION] t=\(elapsed)s seeded: \(diagDescribeProductState(productState))")
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
    dumpProductStateResolvers()
    installInjectorLogger()
    neutralizePlayerRestrictions()
}

// MARK: - SPTPlayerRestrictions — strip Free playback restrictions
// The 9.2 player gates queue / on-demand track selection / seeking through the
// SPTPlayerRestrictions object on each player state. The product-state hooks
// can't reach the native license, so neutralise the license-related disallow
// getters directly: BOOL getters return NO, their *ReasonsArray return empty.
private let restrictionKeywords = [
    "AddToQueue", "InsertingInto", "PlayAsNextInQueue", "Seeking",
    "TapToPlay", "SetQueue", "ReorderingEnqueued", "ViewingQueue",
    "RemovingFrom", "Reordering",
]

private func neutralizePlayerRestrictions() {
    guard let cls: AnyClass = NSClassFromString("SPTPlayerRestrictions") else {
        writeDebugLog("[DIAG][RESTRICT] SPTPlayerRestrictions not found")
        return
    }
    var count: UInt32 = 0
    guard let list = class_copyMethodList(cls, &count) else { return }
    defer { free(list) }

    let emptyArray = NSArray()
    var neutralized: [String] = []
    for i in 0..<Int(count) {
        let m = list[i]
        let sel = method_getName(m)
        let name = String(cString: sel_getName(sel))
        guard name.hasPrefix("disallow"), !name.hasSuffix(":") else { continue }
        guard restrictionKeywords.contains(where: { name.contains($0) }) else { continue }

        let ret = strippedEncoding(m).first
        if ret == "B" || ret == "c" {
            let block: @convention(block) (AnyObject) -> ObjCBool = { _ in ObjCBool(false) }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), "B@:")
            neutralized.append("\(name)=NO")
        } else if ret == "@" && name.hasSuffix("ReasonsArray") {
            let block: @convention(block) (AnyObject) -> AnyObject = { _ in emptyArray }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), "@@:")
            neutralized.append("\(name)=[]")
        }
    }
    writeDebugLog("[DIAG][RESTRICT] neutralized \(neutralized.count): \(neutralized.sorted())")
}

// MARK: - RCCProductStateInjector.injectWithAttributesData:error:
// Rewrites the native product-state injection payload to Premium. This is the
// candidate chokepoint for the Free state that still gates queue/on-demand on 9.2.

private let injectorSelectorName = "injectWithAttributesData:error:"
private var originalInjectorIMP: IMP?

// data (NSData), error (NSError**). Rewrites data, returns Premium bytes to orig.
private func premiumInjectData(_ data: AnyObject?) -> AnyObject? {
    guard let ns = data as? Data else { return data }
    let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
    guard let rewritten = diagRewriteAttributesData(ns) else {
        writeDebugLog("[DIAG][INJECT] t=\(elapsed)s not AccountAttributesResponse (size=\(ns.count)); passthrough")
        return data
    }
    writeDebugLog("[DIAG][INJECT] t=\(elapsed)s rewrote \(ns.count)->\(rewritten.count) bytes")
    return rewritten as NSData
}

private func installInjectorLogger() {
    guard let cls: AnyClass = NSClassFromString("RCCProductStateInjector") else {
        writeDebugLog("[DIAG][INJECT] RCCProductStateInjector not found")
        return
    }
    let sel = Selector((injectorSelectorName))
    guard let method = ownMethod(cls, sel) else {
        writeDebugLog("[DIAG][INJECT] no \(injectorSelectorName) on RCCProductStateInjector")
        return
    }
    let encoding = strippedEncoding(method)
    writeDebugLog("[DIAG][INJECT] found injectWithAttributesData:error: encoding=\(encoding)")
    originalInjectorIMP = method_getImplementation(method)
    let ret = encoding.first

    // Branch on the return type so the @convention(c) cast matches the real ABI.
    if ret == "B" || ret == "c" {
        typealias IMPc = @convention(c) (AnyObject, Selector, AnyObject?, UnsafeMutableRawPointer?) -> ObjCBool
        let block: @convention(block) (AnyObject, AnyObject?, UnsafeMutableRawPointer?) -> ObjCBool = { obj, data, err in
            let orig = unsafeBitCast(originalInjectorIMP!, to: IMPc.self)
            return orig(obj, Selector((injectorSelectorName)), premiumInjectData(data), err)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        writeDebugLog("[DIAG][INJECT] logger installed (BOOL return)")
    } else if ret == "v" {
        typealias IMPc = @convention(c) (AnyObject, Selector, AnyObject?, UnsafeMutableRawPointer?) -> Void
        let block: @convention(block) (AnyObject, AnyObject?, UnsafeMutableRawPointer?) -> Void = { obj, data, err in
            let orig = unsafeBitCast(originalInjectorIMP!, to: IMPc.self)
            orig(obj, Selector((injectorSelectorName)), premiumInjectData(data), err)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        writeDebugLog("[DIAG][INJECT] logger installed (void return)")
    } else if ret == "@" {
        typealias IMPc = @convention(c) (AnyObject, Selector, AnyObject?, UnsafeMutableRawPointer?) -> AnyObject?
        let block: @convention(block) (AnyObject, AnyObject?, UnsafeMutableRawPointer?) -> AnyObject? = { obj, data, err in
            let orig = unsafeBitCast(originalInjectorIMP!, to: IMPc.self)
            return orig(obj, Selector((injectorSelectorName)), premiumInjectData(data), err)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        writeDebugLog("[DIAG][INJECT] logger installed (object return)")
    } else {
        originalInjectorIMP = nil
        writeDebugLog("[DIAG][INJECT] unexpected return '\(ret.map(String.init) ?? "?")'; not hooking")
    }
}

// List every NSObject subclass whose name points at the Swift product-state
// layer the 9.2 player reads, with its instance-method selectors. This finds
// the per-key chokepoint we can force Premium at, the way we already force
// SPTCoreProductState's getters.
private func dumpProductStateResolvers() {
    let interesting = ["ProductStateResolver", "ProductStateStorage", "ProductStateTable",
                       "ProductStateReactiveValue", "PLProductState", "ProductStateImpl",
                       "ProductStateParser", "ProductStateInjector", "ProductStateDataSource"]
    let total = objc_getClassList(nil, 0)
    guard total > 0 else { return }
    let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
    defer { buffer.deallocate() }
    let got = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), total)

    var dumped = 0
    for i in 0..<Int(min(got, total)) {
        let cls: AnyClass = buffer[i]
        guard inheritsFromNSObject(cls) else { continue }
        let name = String(cString: class_getName(cls))
        guard interesting.contains(where: { name.contains($0) }) else { continue }

        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { continue }
        defer { free(list) }
        var sels: [String] = []
        for j in 0..<Int(count) {
            sels.append(String(cString: sel_getName(method_getName(list[j]))))
        }
        dumped += 1
        writeDebugLog("[DIAG][PS_RESOLVER] \(name) methods=\(sels.sorted())")
    }
    writeDebugLog("[DIAG][PS_RESOLVER] dumped \(dumped) product-state class(es)")
}
