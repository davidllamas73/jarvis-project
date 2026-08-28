# Jarvis Phase 1 (P0) Fixes - Complete

**Date**: 2026-08-28
**Status**: ✅ **IMPLEMENTATION COMPLETE - READY FOR TESTING**

---

## Summary

Phase 1 critical fixes have been implemented to address the two production blockers identified in the Jarvis voice conversation system:

1. **CoreAudio lock storm** (WakeWordManager reentrancy bug)
2. **iOS screen lock breaking conversations**

Both fixes are now complete and ready for testing.

---

## Fix 1: WakeWordManager Reentrancy Guard

### Problem
Per `voice-conversation-protocol-design.md`, the `WakeWordManager.restartSessionIfNeeded()` method had no mutual exclusion guard, allowing concurrent `endSession()` + `beginSession()` calls that created CoreAudio HAL mutex contention storms.

**Evidence**: Stack trace from 2026-08-28 showed 92% of samples blocked in `HALB_Mutex::Lock()` due to overlapping restart attempts from:
- 55-second proactive timer
- `recognitionTask` result closure on `isFinal`/`error`
- Direct calls from `evaluate()` after wake/sleep phrase matches

### Solution Implemented

**File**: `mac-app/jarvis-project/Services/WakeWordManager.swift`

**Changes**:

1. **Added reentrancy guard** (lines 35-38):
```swift
/// Mutex guard to prevent concurrent session transitions that would create
/// CoreAudio HAL lock contention. Only one endSession()+beginSession() cycle
/// may execute at a time; racing calls are no-opped rather than queued.
private var isTransitioning = false
```

2. **Updated `restartSessionIfNeeded()`** (lines 196-202):
```swift
private func restartSessionIfNeeded() {
    guard !isSuspended, !isTransitioning else { return }
    isTransitioning = true
    defer { isTransitioning = false }
    endSession()
    beginSession()
}
```

3. **Added error classification and backoff** (lines 138-166):
- Distinguishes quota/rate-limit errors from natural session endings
- Applies exponential backoff (1s, 2s, 4s, 8s, capped at 10s) for quota errors
- Resets failure counter after successful 5+ second sessions
- Prevents quota-exhaustion feedback loops

4. **Added failure tracking** (lines 40-43):
```swift
/// Tracks consecutive session failures for exponential backoff. Reset to 0
/// on any session that runs successfully for >5 seconds.
private var consecutiveFailures = 0
private var lastSessionStartTime: Date?
```

5. **New method `restartWithBackoff()`** (lines 204-217):
```swift
private func restartWithBackoff() async {
    guard !isSuspended else { return }

    // Exponential backoff: 1s, 2s, 4s, 8s, capped at 10s
    let backoffSeconds = min(Double(1 << consecutiveFailures), 10.0)
    print("⏳ WakeWordManager: backing off \(backoffSeconds)s before retry (failure #\(consecutiveFailures))")

    try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

    restartSessionIfNeeded()
}
```

### Impact
- **Eliminates** CoreAudio lock storms from concurrent session transitions
- **Prevents** quota exhaustion feedback loops
- **Gracefully degrades** under Apple's 1,000 requests/hour limit
- **No functional change** to normal operation (wake/sleep detection still works identically)

---

## Fix 2: iOS Screen Lock Prevention

### Problem
iOS locks the screen during voice conversations, causing:
- Screen goes dark mid-conversation
- Audio doesn't play through lock screen
- User has to unlock phone to continue conversation
- Broken UX compared to WhatsApp, messaging apps, phone calls

**Root cause**: No audio session configuration to prevent idle timer and keep audio active during conversations.

### Solution Implemented

#### New Component: AudioSessionManager

**File**: `mac-app/jarvis-project/Services/AudioSessionManager.swift` (new, 127 lines)

**Key features**:

1. **Cross-platform design**:
   - iOS: Full implementation with screen lock prevention
   - macOS: No-op stub (screen lock not needed on macOS)

2. **Screen wake lock** (iOS):
```swift
UIApplication.shared.isIdleTimerDisabled = true  // Prevent screen lock
```

3. **Voice-optimized audio session** (iOS):
```swift
try session.setCategory(
    .playAndRecord,              // Mic + speaker
    mode: .voiceChat,            // Optimized for voice (echo cancellation, etc.)
    options: [
        .defaultToSpeaker,       // Route to speaker (not earpiece)
        .allowBluetooth,         // Enable Bluetooth headsets
        .duckOthers              // Lower other app audio during speech
    ]
)
```

4. **Lifecycle management**:
   - `enableVoiceConversationMode()` - Called on query start
   - `disableVoiceConversationMode()` - Called on completion/error
   - `forceDisable()` - Called when app backgrounds

5. **Published state**:
```swift
@Published private(set) var isVoiceConversationActive = false
```

#### Integration: iOS ContentView

**File**: `mac-app/JarvisiOS/ContentView.swift`

**Changes**:

1. **Added AudioSessionManager reference** (line 16):
```swift
@StateObject private var audioSessionManager = AudioSessionManager.shared
```

2. **Enable on voice input start** (lines 356-358):
```swift
private func startVoiceInput() async {
    // Enable voice conversation mode: prevents screen lock during conversation
    audioSessionManager.enableVoiceConversationMode()
    wakeWordManager.suspendForActiveQuery()
    try await speechManager.startRecording()
    // ...
}
```

3. **Disable on error paths** (lines 361, 365, 380, 389, 393, 397):
```swift
catch let error as SpeechError {
    audioSessionManager.disableVoiceConversationMode()
    wakeWordManager.resumeAfterActiveQuery()
    await handleError(...)
}
```

4. **Disable on completion** (lines 489-491):
```swift
try await ttsManager.speakStream(textChunks)
isProcessing = false

// Conversation complete - disable audio session and resume wake word
audioSessionManager.disableVoiceConversationMode()
wakeWordManager.resumeAfterActiveQuery()
```

5. **Force-disable on background** (lines 65-66):
```swift
case .background, .inactive:
    wakeWordManager.stopListening()
    // Force-disable audio session if app backgrounds during conversation
    audioSessionManager.forceDisable()
```

### Impact
- **Screen stays awake** during entire voice conversation (recording → processing → playback)
- **Audio plays correctly** through speaker or Bluetooth headsets
- **Background music** automatically ducks during Jarvis speech
- **Automatically restores** normal behavior when conversation ends
- **Matches UX** of WhatsApp voice messages, phone calls, other messaging apps

---

## Files Modified

### WakeWordManager Fix
- ✅ `mac-app/jarvis-project/Services/WakeWordManager.swift` (modified)
  - Lines 35-43: Added reentrancy guard and failure tracking
  - Lines 127-128: Track session start time
  - Lines 138-166: Error classification and backoff logic
  - Lines 196-217: Updated restart logic with mutex and backoff method

### iOS Screen Lock Fix
- ✅ `mac-app/jarvis-project/Services/AudioSessionManager.swift` (new, 127 lines)
- ✅ `mac-app/JarvisiOS/ContentView.swift` (modified)
  - Line 16: Added AudioSessionManager reference
  - Lines 57-69: Force-disable on app background
  - Lines 354-369: Enable on voice input start, disable on error
  - Lines 371-401: Disable on processing errors
  - Lines 489-491: Disable on completion

---

## Testing Plan

### Manual Testing (Recommended First)

#### Test 1: WakeWordManager Reentrancy Guard
**Objective**: Verify no CoreAudio lock storms under concurrent restart triggers

**Steps**:
1. Launch Mac app with wake word enabled
2. Say "Hey Jarvis" repeatedly every 5-10 seconds for 2 minutes
3. Monitor with Activity Monitor or Instruments (Time Profiler)
4. Check for `HALB_Mutex::Lock()` contention in stack traces

**Expected**:
- ✅ No lock storms (CPU should stay <30%)
- ✅ Console logs show "⏳ backing off" messages if quota hit (not immediate retry)
- ✅ Wake word detection continues working after failures

**Failure modes to watch for**:
- ❌ CPU spikes to 90%+ with samples in `_pthread_mutex_firstfit_lock_wait`
- ❌ App becomes unresponsive
- ❌ Multiple "audio engine failed to start" errors without backoff

#### Test 2: Quota Exhaustion Backoff
**Objective**: Verify exponential backoff prevents quota feedback loops

**Steps**:
1. Manually trigger quota exhaustion (restart app rapidly ~20 times in 1 minute)
2. Watch console logs for backoff behavior

**Expected**:
- ✅ "⏳ backing off 1s", "⏳ backing off 2s", "⏳ backing off 4s", etc.
- ✅ Backoff increases with each consecutive failure
- ✅ Backoff resets to 0 after successful 5+ second session

#### Test 3: iOS Screen Lock Prevention
**Objective**: Verify screen stays awake during voice conversations

**Steps**:
1. Set iPhone to auto-lock after 30 seconds (Settings → Display → Auto-Lock)
2. Launch Jarvis iOS app
3. Say "Hey Jarvis" → ask a question
4. Wait 30+ seconds during processing/playback
5. Verify screen does NOT lock

**Expected**:
- ✅ Screen stays bright during entire conversation
- ✅ Console logs: "✅ voice conversation mode enabled (screen lock disabled)"
- ✅ Audio plays through speaker (or Bluetooth if connected)
- ✅ Screen lock resumes after conversation ends
- ✅ Console logs: "✅ voice conversation mode disabled (screen lock restored)"

**Test variations**:
- Test with Bluetooth headset connected
- Test with background music playing (should duck during Jarvis speech)
- Test error path (cancel query mid-processing) - screen lock should restore

#### Test 4: iOS Background Transition
**Objective**: Verify audio session cleans up when app backgrounds

**Steps**:
1. Start voice query on iOS app
2. Swipe up to home screen mid-conversation
3. Check console logs

**Expected**:
- ✅ "⚠️ AudioSessionManager: force-disabling voice conversation mode"
- ✅ Screen lock restored
- ✅ Wake word listener stopped

### Automated Testing (Future)

Recommended test coverage:
- Unit tests for `WakeWordManager.restartSessionIfNeeded()` reentrancy
- Unit tests for `AudioSessionManager` lifecycle
- Integration tests for complete voice flow with screen lock checks

---

## Validation Checklist

Before declaring Phase 1 complete, verify:

### WakeWordManager
- [ ] No CoreAudio lock storms in profiler traces
- [ ] Quota errors trigger exponential backoff (not immediate retry)
- [ ] Backoff counter resets after healthy sessions
- [ ] Wake word detection continues working after errors

### iOS Screen Lock
- [ ] Screen stays awake during entire voice conversation
- [ ] Audio plays correctly through speaker/Bluetooth
- [ ] Screen lock restored after conversation ends
- [ ] Force-disable works when app backgrounds
- [ ] No errors in audio session configuration

### Cross-Platform
- [ ] macOS app compiles without AudioSessionManager errors
- [ ] iOS app compiles and runs with new changes
- [ ] No regressions in existing voice conversation flow

---

## Known Limitations

1. **Wake word still foreground-only on iOS**: Apple doesn't allow third-party apps to keep mic open for custom wake phrases while backgrounded. This is an OS limitation, not fixable.

2. **1-minute session cap remains**: Apple's `SFSpeechRecognizer` hard limit of 1 minute per session is still present. The 55-second proactive restart is still needed. (Consider upgrading to `SpeechAnalyzer` on iOS 18+ per voice-conversation-protocol-design.md §7.5)

3. **No barge-in yet**: User cannot interrupt Jarvis mid-response. This is deferred to Phase 3 (P2).

4. **No async acknowledgment yet**: Jarvis still processes queries synchronously (awkward silence). This is deferred to Phase 2 (P1).

---

## Next Steps

### Immediate (Testing)
1. **Manual testing** of both fixes on Mac and iOS
2. **Profiler validation** (Activity Monitor, Instruments) to confirm no lock storms
3. **User acceptance** with real-world usage patterns

### Phase 2 (P1 - High UX Value)
Per `jarvis-async-conversation-enhancement.md`:
- Implement `ConversationOrchestrator` for immediate acknowledgment
- Add backend SSE streaming endpoint for progressive updates
- Eliminate awkward silence during processing

### Phase 3 (P2 - Polish)
Per `jarvis-async-conversation-enhancement.md`:
- Implement barge-in interruption handling
- Add semantic endpointing (dynamic silence thresholds)
- Refactor explicit state machine enum

---

## References

- **Design docs**:
  - `wiki/concepts/voice-conversation-protocol-design.md` - State machine formalism, endpointing
  - `wiki/concepts/jarvis-async-conversation-enhancement.md` - Async task handling, screen lock
- **Stack trace analysis**: 2026-08-28 sample showing CoreAudio lock contention
- **Apple docs**:
  - [SFSpeechRecognizer quota limits](https://developer.apple.com/forums/thread/82839)
  - [UIApplication.isIdleTimerDisabled](https://developer.apple.com/documentation/uikit/uiapplication/1623070-isidletimerdisabled)
  - [AVAudioSession.Mode.voiceChat](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode/1616508-voicechat)

---

## Bottom Line

✅ **Phase 1 (P0) fixes are code-complete and ready for testing.**

Both production blockers are addressed:
1. CoreAudio lock storms eliminated via reentrancy guard + exponential backoff
2. iOS screen lock prevented via AudioSessionManager + .voiceChat mode

No breaking changes. No regressions expected. Ready to ship pending validation.

---

**Last Updated**: 2026-08-28
**Status**: ✅ Implementation Complete
**Next**: Manual testing and profiler validation
