import Foundation

// MARK: - Diagnostic: who is cutting tracks short?
//
// Tracks stop a few seconds in and playback advances. Nothing in the log says
// why: the per-track [Lyrics] lines are prefetches for a track list, not track
// changes, so they cannot be used to time it.
//
// SPTEsperantoPlayer is the real player object (reached from
// Player_CommonImpl.SPTPlayerServiceImplementation via provideStateObservable).
// It owns the commands that would end a track early, so log each one with a
// backtrace: the caller's frames name the component responsible, which tells us
// whether this is the tweak, Spotify's free-tier enforcement, or the core
// refusing on-demand playback.
//
// Read-only: every hook calls straight through. All hooked selectors take object
// arguments only, so the ABI is unambiguous.

private let esperantoPlayerClassName = "SPTEsperantoPlayer"
private var skipProbeLogCount = 0
private var skipProbeOriginals: [String: IMP] = [:]

private func logPlayerCommand(_ label: String) {
    guard skipProbeLogCount < 12 else { return }
    skipProbeLogCount += 1
    // Drop our own frames; keep enough of the caller to name the component.
    let frames = Thread.callStackSymbols.dropFirst(2).prefix(14)
    writeDebugLog("[DIAG][SKIP] \(label)")
    for frame in frames {
        writeDebugLog("[DIAG][SKIP]     \(frame)")
    }
}

private func probePlayerSelector(_ cls: AnyClass, _ name: String, argCount: Int) -> Bool {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(cls, selector) else { return false }
    guard let encodingPtr = method_getTypeEncoding(method) else { return false }
    let encoding = String(cString: encodingPtr)
    let returnType = encoding.first

    // These player commands return a handle, not void, so the block has to
    // return it too - casting them to a void signature would leave the caller
    // reading a return register nothing set.
    let original = method_getImplementation(method)
    skipProbeOriginals[name] = original

    switch (returnType, argCount) {
    case ("v", 0):
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let block: @convention(block) (AnyObject) -> Void = { this in
            logPlayerCommand(name)
            unsafeBitCast(original, to: Fn.self)(this, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    case ("v", 1):
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { this, a in
            logPlayerCommand(name)
            unsafeBitCast(original, to: Fn.self)(this, selector, a)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    case ("@", 0):
        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        let block: @convention(block) (AnyObject) -> AnyObject? = { this in
            logPlayerCommand(name)
            return unsafeBitCast(original, to: Fn.self)(this, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    case ("@", 1):
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { this, a in
            logPlayerCommand(name)
            return unsafeBitCast(original, to: Fn.self)(this, selector, a)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    case ("@", 2):
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { this, a, b in
            logPlayerCommand(name)
            return unsafeBitCast(original, to: Fn.self)(this, selector, a, b)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    case ("@", 3):
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> AnyObject? = { this, a, b, c in
            logPlayerCommand(name)
            return unsafeBitCast(original, to: Fn.self)(this, selector, a, b, c)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    case ("@", 4):
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject? = { this, a, b, c, d in
            logPlayerCommand(name)
            return unsafeBitCast(original, to: Fn.self)(this, selector, a, b, c, d)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    default:
        writeDebugLog("[DIAG][SKIP] not hooking \(name): encoding \(encoding)")
        skipProbeOriginals[name] = nil
        return false
    }
    return true
}

private var skipProbeAttempts = 0

func activateDiagPlayerSkip() {
    guard let cls: AnyClass = NSClassFromString(esperantoPlayerClassName) else {
        skipProbeAttempts += 1
        guard skipProbeAttempts <= 24 else {
            writeDebugLog("[DIAG][SKIP] gave up: \(esperantoPlayerClassName) never registered")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { activateDiagPlayerSkip() }
        return
    }

    var installed: [String] = []
    let targets: [(String, Int)] = [
        ("stop", 0),
        ("skipToNextTrackWithOptions:", 1),
        ("skipToNextTrackWithOptions:track:", 2),
        ("skipToNextTrackWithOptions:track:loggingParams:", 3),
        ("skipToPreviousTrackWithOptions:", 1),
        ("addToQueue:", 1),
        ("addToQueue:options:", 2),
        ("addToQueue:options:loggingParams:", 3),
        ("playAsNextInQueue:options:loggingParams:", 3),
        // Generic command paths, in case the track is not ended by an explicit
        // skip but by a command funnelled through one of these.
        ("pause:", 1),
        ("performPlayerCommandWithOptions:command:", 2),
        ("executePlayCommand:options:loggingParams:origin:", 4),
    ]
    for (name, argCount) in targets {
        if probePlayerSelector(cls, name, argCount: argCount) {
            installed.append(name)
        }
    }
    writeDebugLog("[DIAG][SKIP] probe installed on \(esperantoPlayerClassName) after \(skipProbeAttempts) retry(ies): \(installed)")
}
