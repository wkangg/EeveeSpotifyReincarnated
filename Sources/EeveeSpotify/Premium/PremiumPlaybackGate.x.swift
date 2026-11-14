import Foundation

// MARK: - 9.2 playback gate (queue / on-demand / seek)
//
// Forcing the ObjC product state to Premium (EeveePremiumForce) is enough for
// "Your plan" and ad blocking, but 9.2 gates queue, on-demand track selection
// and seeking behind two further layers that never read those hooks.
//
// Why the product-state hooks cannot reach them, from the 9.2.0 binary:
//
//   * `-[SPTCoreProductState setOverrides:]` is a no-op - its implementation is
//     a bare `ret`. Seeding overrides writes to nothing.
//   * `values` and `overrides` are not ObjC storage either; both read a
//     `std::map` back out of the C++ core via `valuesDictFromMap:`. The only
//     ObjC-side writer is `writeStringToBackend:forKey:`, which pushes the
//     value to Spotify's servers, so it is not usable for a local-only tweak.
//
// What actually gates playback:
//
//   1. `SPTPlayerRestrictions`, the per-player-state restriction object. It has
//      no BOOL ivars at all - only `_disallow*Reasons` sets - so every
//      `disallow*` BOOL is derived from its reason set. Replacing the getters
//      class-wide covers every instance, including the ones the player rebuilds
//      on each state update.
//   2. NowPlaying's player-state restrictions handling, which on 9.2 defaults to
//      an "updated" path that does not read the ObjC bridge at all.

private let queueRemoteFlags: [String: Any] = [
    // Measured on 9.2.0: Spotify computes this as true, which puts NowPlaying on
    // the "updated" player-state restrictions path. The queue button lives in
    // NowPlaying, and clearing the ObjC SPTPlayerRestrictions bridge below only
    // ever reached the legacy path - which is why seeking (legacy) started
    // working while the queue entry point (updated) stayed hidden. Force the
    // legacy handling so both read the bridge we control.
    "ios-feature-nowplayingplatform.updated_player_state_restrictions_handling_enabled": false,
]

// Measured defaults on 9.2.0, kept here so they are not guessed at again:
//   ios-feature-queue.is_new_player_restriction_enabled        = false
//   ios-feature-queue.is_queue_entry_point_enabled_for_mft_plus = false
//   ios-feature-queue.is_play_next_context_menu_enabled        = false
//   ios-feature-queue.is_swipe_to_play_next_enabled            = false
//   ios-feature-nowplaying.bottom_sheet_queue_enabled          = true
//   ios-feature-nowplaying.jam_queue_button_enabled            = true
//   ios-feature-nowplayingbar.queue_badge                      = true
// Forcing the first four to true changed nothing: the queue *feature* flags are
// already on, so the entry point is withheld by a permission, not a flag.

// The two reason properties that are dictionaries rather than sets.
private let dictionaryReasonSelectors: Set<String> = [
    "disallowSettingSignalsReasons",
    "disallowSettingModesReasons",
]

private func methodReturnType(_ method: Method) -> Character? {
    guard let types = method_getTypeEncoding(method) else { return nil }
    return String(cString: types).first
}

/// Clears every playback restriction `SPTPlayerRestrictions` can report.
///
/// Both the BOOL getters and the reason collections are replaced: a consumer may
/// read either, and a Swift consumer that builds its own permission value from
/// the reasons would otherwise still see the Free reasons behind a cleared BOOL.
@discardableResult
private func neutralizePlayerRestrictions() -> Int {
    guard let cls: AnyClass = NSClassFromString("SPTPlayerRestrictions") else {
        eeveeLog("[EeveeSpotify][Gate] Skipped: SPTPlayerRestrictions not found")
        return 0
    }
    var count: UInt32 = 0
    guard let list = class_copyMethodList(cls, &count) else { return 0 }
    defer { free(list) }

    let emptySet = NSSet()
    let emptyDictionary = NSDictionary()
    var flags = 0
    var reasons = 0

    for index in 0..<Int(count) {
        let method = list[index]
        let selector = method_getName(method)
        let name = String(cString: sel_getName(selector))
        // Getters only - the `setDisallow*Reasons:` setters end in a colon.
        guard name.hasPrefix("disallow"), !name.hasSuffix(":") else { continue }
        guard let returnType = methodReturnType(method) else { continue }

        if returnType == "B" || returnType == "c" {
            let block: @convention(block) (AnyObject) -> ObjCBool = { _ in ObjCBool(false) }
            class_replaceMethod(cls, selector, imp_implementationWithBlock(block), "B@:")
            flags += 1
        } else if returnType == "@", name.hasSuffix("Reasons") {
            let empty: AnyObject = dictionaryReasonSelectors.contains(name) ? emptyDictionary : emptySet
            let block: @convention(block) (AnyObject) -> AnyObject = { _ in empty }
            class_replaceMethod(cls, selector, imp_implementationWithBlock(block), "@@:")
            reasons += 1
        }
    }

    eeveeLog("[EeveeSpotify][Gate] SPTPlayerRestrictions cleared: %d flag(s), %d reason set(s)", flags, reasons)
    return flags + reasons
}

// Off by default. Clearing the restrictions bridge made seeking work, but none
// of the three levers tried (the bridge, the ios-feature-queue flags, and
// NowPlaying's restrictions handling) produced a queue entry point, and tracks
// are being cut short. Until we know what actually ends playback, this stays
// off so the tweak is not changing player behaviour while we measure it.
private let enablePlaybackGate = false

/// Must run before `activateRemoteFlags()`, which snapshots the forced flags.
func activatePremiumPlaybackGate() {
    guard enablePlaybackGate else {
        writeDebugLog("[Gate] off (enablePlaybackGate=false)")
        return
    }
    RemoteFlags.shared.force(queueRemoteFlags, by: "PlaybackGate")
    neutralizePlayerRestrictions()
}
