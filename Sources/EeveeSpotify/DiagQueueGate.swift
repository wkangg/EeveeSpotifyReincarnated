import Foundation

// MARK: - Diagnostic: what QueueAddPermissionsProvider actually decides on
//
// Queue_ViewImpl.QueueAddPermissionsProvider is the class that publishes
// QueueAddPermissions (whether "Add to queue" is offered at all). It AND-combines
// three inputs, and we can only see two of them from outside:
//
//   usePlayerRestrictions : Bool  - set from ios-feature-queue.is_new_player_restriction_enabled.
//                                   If this is false, clearing SPTPlayerRestrictions is irrelevant.
//   mftPlusState          : enum? - the free-tier/MFT+ state; backend driven.
//   isOnDemand            : () -> Bool - a closure; not safely callable from here.
//
// Both visible ones are Swift stored properties, which still get ObjC ivar
// entries on an @objc class, so class_getInstanceVariable can read them. This is
// read-only and capped: it tells us which branch the provider is on before we
// spend another build guessing.

private let queueProviderClassName = "_TtC14Queue_ViewImpl27QueueAddPermissionsProvider"
private var queueProbeLogCount = 0
private var originalPlayerStateDidChange: IMP?

private func ivarOffset(_ cls: AnyClass, _ name: String) -> Int? {
    guard let ivar = class_getInstanceVariable(cls, name) else { return nil }
    return ivar_getOffset(ivar)
}

private func describeQueueProvider(_ object: AnyObject) -> String {
    guard let cls: AnyClass = object_getClass(object) else { return "no class" }
    let base = Unmanaged.passUnretained(object).toOpaque()
    var parts: [String] = []

    if let offset = ivarOffset(cls, "usePlayerRestrictions") {
        let value = base.load(fromByteOffset: offset, as: UInt8.self)
        parts.append("usePlayerRestrictions=\(value != 0)")
    } else {
        parts.append("usePlayerRestrictions=<no ivar>")
    }

    if let offset = ivarOffset(cls, "mftPlusState") {
        let value = base.load(fromByteOffset: offset, as: Int32.self)
        parts.append("mftPlusState=\(value)")
    } else {
        parts.append("mftPlusState=<no ivar>")
    }

    return parts.joined(separator: " ")
}

// Queue_ViewImpl loads lazily, so the class is not registered at tweak init.
// Retry on a timer until it appears or we give up, rather than probing once and
// silently finding nothing.
private var queueProbeAttempts = 0

func activateDiagQueueGate() {
    guard NSClassFromString(queueProviderClassName) != nil else {
        queueProbeAttempts += 1
        guard queueProbeAttempts <= 24 else {
            writeDebugLog("[DIAG][QUEUE_GATE] gave up: \(queueProviderClassName) never registered")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { activateDiagQueueGate() }
        return
    }
    installQueueGateProbe()
}

private func installQueueGateProbe() {
    guard let cls: AnyClass = NSClassFromString(queueProviderClassName) else { return }
    writeDebugLog("[DIAG][QUEUE_GATE] provider registered after \(queueProbeAttempts) retry(ies)")

    var ivarNames: [String] = []
    var count: UInt32 = 0
    if let list = class_copyIvarList(cls, &count) {
        for index in 0..<Int(count) {
            if let name = ivar_getName(list[index]) {
                ivarNames.append(String(cString: name))
            }
        }
        free(list)
    }
    writeDebugLog("[DIAG][QUEUE_GATE] found provider, ivars=\(ivarNames)")

    let selector = NSSelectorFromString("player:stateDidChange:fromState:")
    guard let method = class_getInstanceMethod(cls, selector) else {
        writeDebugLog("[DIAG][QUEUE_GATE] no player:stateDidChange:fromState: on provider")
        return
    }

    typealias Original = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
    originalPlayerStateDidChange = method_getImplementation(method)
    let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { this, player, change, from in
        if queueProbeLogCount < 6 {
            queueProbeLogCount += 1
            writeDebugLog("[DIAG][QUEUE_GATE] player state change -> \(describeQueueProvider(this))")
        }
        if let imp = originalPlayerStateDidChange {
            unsafeBitCast(imp, to: Original.self)(this, selector, player, change, from)
        }
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
    writeDebugLog("[DIAG][QUEUE_GATE] probe installed")
}
