# Jarvis Async Conversation Enhancement: Natural Flow & Background Task Handling

**Category**: Architecture Pattern | Voice UX
**Maturity**: Design (implementation pending)
**Context**: Enhancement to Jarvis voice conversation flow for natural async interactions and screen-lock prevention

---

## 1. Problem Statement

### 1.1 Synchronous Processing Creates Awkward Silence

**Current behavior**:
```
User: "What were my achievements at Central Retail?"
[15 seconds of silence while orchestration agent searches, reasons, synthesizes]
Jarvis: "You achieved..." [full answer]
```

**Issue**: Natural conversation includes acknowledgments and progress updates, especially for complex queries that take >3 seconds.

**Expected behavior** (like Alexa, Siri, human assistants):
```
User: "What were my achievements at Central Retail?"
Jarvis: "Let me search your records for that" [<500ms acknowledgment]
[Background processing: RAG search, Claude reasoning, synthesis - 10-15s]
Jarvis: "I found several major achievements..." [full answer when ready]
```

### 1.2 iOS Screen Lock Breaks Mid-Conversation

**Current behavior** (JarvisiOS/ContentView.swift:56-67):
- App only prevents screen lock via wake-word foreground requirement
- During query processing, iOS can still lock screen
- User speaks → screen locks → response never plays → broken UX

**Issue**: WhatsApp, voice messaging apps, phone calls all prevent screen lock during active audio sessions. Jarvis should too.

### 1.3 No Barge-In or Interruption Handling

**Current behavior**:
- User cannot interrupt Jarvis mid-response
- `NativeTTSManager` has generation-counter pattern but no interruption trigger
- Speaking over Jarvis has no effect

**Expected**: User should be able to interrupt Jarvis with new query or "stop" command.

---

## 2. Architecture Changes

### 2.1 Conversation State Machine

Building on `voice-conversation-protocol-design.md`, formalize explicit states:

```swift
enum ConversationState {
    case idle                    // Not listening, wake-word may be active
    case listening               // Capturing user query (mic active)
    case acknowledged            // Query received, acknowledged verbally, processing in background
    case thinkingQuietly         // Background processing, no audio activity
    case thinkingWithUpdates     // Background processing, with progress TTS updates
    case speaking                // TTS playing response
    case waitingForMoreInput     // Agent asked clarifying question, listening for answer
    case interrupted             // Barge-in detected, cancelling current response
    case error                   // Recoverable error, cooling down
}
```

**Key transitions**:
- `listening` → `acknowledged` → `thinkingWithUpdates` → `speaking` → `idle`
- `speaking` → `interrupted` (barge-in) → `listening` (new query capture)

### 2.2 Async Task Acknowledgment Layer

**New component**: `ConversationOrchestrator` (wraps existing `VoiceService`)

**Responsibilities**:
1. **Immediate acknowledgment** (<500ms) for all queries via TTS
2. **Background task execution** with progress updates
3. **State machine enforcement** (mutual exclusion on transitions)
4. **Screen wake lock management** during active conversations

**Implementation sketch**:

```swift
@MainActor
class ConversationOrchestrator: ObservableObject {
    @Published var state: ConversationState = .idle

    private let voiceService: VoiceService
    private let ttsManager: NativeTTSManager
    private let apiClient: JarvisAPIClient
    private var currentTask: Task<Void, Never>?

    // Screen wake lock (iOS only)
    private var screenLockDisabled = false

    func processQuery(_ query: String) async {
        guard state == .listening else { return }

        // 1. Immediate acknowledgment
        state = .acknowledged
        await speakAcknowledgment(for: query)

        // 2. Background processing with progress updates
        state = .thinkingWithUpdates
        currentTask = Task {
            do {
                let response = try await executeQueryWithUpdates(query)

                guard !Task.isCancelled else { return }

                // 3. Speak final response
                state = .speaking
                await speakResponse(response)

                state = .idle
            } catch {
                state = .error
                await speakError(error)
            }
        }
    }

    private func speakAcknowledgment(for query: String) async {
        let ack = selectAcknowledgment(query: query)
        try? await ttsManager.speak(ack)
    }

    private func selectAcknowledgment(query: String) -> String {
        // Context-aware acknowledgment selection
        let lower = query.lowercased()

        if lower.contains("search") || lower.contains("find") {
            return "Let me search for that"
        } else if lower.contains("what") || lower.contains("who") || lower.contains("how") {
            return "Let me look that up"
        } else if lower.contains("achievements") || lower.contains("career") {
            return "Let me check your records"
        } else if lower.contains("email") || lower.contains("message") {
            return "I'll draft that for you"
        } else {
            return "One moment"
        }
    }

    private func executeQueryWithUpdates(_ query: String) async throws -> String {
        // Send to orchestration agent
        let response = try await apiClient.orchestrate(query: query)

        // If taking >8 seconds, send progress update
        // (implementation would use Task.sleep + race condition)

        return response.answer
    }
}
```

### 2.3 Screen Wake Lock (iOS)

**Problem**: iOS locks screen during processing, audio doesn't play through lock screen.

**Solution**: Configure `AVAudioSession` to prevent idle timer + enable background audio.

**Implementation** (add to `ContentView.swift` or new `AudioSessionManager`):

```swift
import UIKit

#if os(iOS)
class AudioSessionManager {
    static let shared = AudioSessionManager()

    private var isScreenLockDisabled = false

    func enableVoiceConversationMode() {
        guard !isScreenLockDisabled else { return }

        // Prevent screen from sleeping during conversation
        UIApplication.shared.isIdleTimerDisabled = true

        // Configure audio session for voice conversation
        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord allows both mic input and speaker output
            // .defaultToSpeaker routes audio to speaker, not earpiece
            // .allowBluetooth enables Bluetooth headset use
            // .duckOthers lowers other app audio (music, etc) during Jarvis speech
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,  // Optimized for voice conversation
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
            try session.setActive(true)

            isScreenLockDisabled = true
            print("✅ Voice conversation mode enabled - screen lock disabled")
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }

    func disableVoiceConversationMode() {
        guard isScreenLockDisabled else { return }

        UIApplication.shared.isIdleTimerDisabled = false

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            isScreenLockDisabled = false
            print("✅ Voice conversation mode disabled - screen lock restored")
        } catch {
            print("❌ Failed to deactivate audio session: \(error)")
        }
    }
}
#endif
```

**Integration points**:
- Enable on `startVoiceInput()` (ContentView.swift:351)
- Disable on conversation completion or error
- Auto-disable on app background (scenePhase observer)

### 2.4 Barge-In / Interruption Handling

**Component**: `BargeInDetector` (wired to VAD or wake-word manager)

**Implementation sketch**:

```swift
class BargeInDetector {
    private let vadThreshold: Float = 0.7
    private let minDuration: TimeInterval = 0.25  // 250ms sustained speech
    private var voiceStartTime: Date?

    func detectInterruption(audioLevel: Float, isSpeaking: Bool) -> Bool {
        guard isSpeaking else { return false }

        if audioLevel > vadThreshold {
            if voiceStartTime == nil {
                voiceStartTime = Date()
            } else if Date().timeIntervalSince(voiceStartTime!) > minDuration {
                // Sustained voice for >250ms while Jarvis is speaking = barge-in
                return true
            }
        } else {
            voiceStartTime = nil  // Reset on silence
        }

        return false
    }
}
```

**Integration**:
- Monitor audio input during `NativeTTSManager.isSpeaking`
- On barge-in detected: cancel TTS, transition to `listening`, capture new query

---

## 3. Implementation Plan

### Phase 1: Critical Fixes (P0 - Production blockers)

**1.1 WakeWordManager Reentrancy Guard** (voice-conversation-protocol-design.md §7.1)

File: `mac-app/jarvis-project/Services/WakeWordManager.swift:163`

```swift
private var isTransitioning = false

private func restartSessionIfNeeded() {
    guard !isSuspended, !isTransitioning else { return }
    isTransitioning = true
    defer { isTransitioning = false }
    endSession()
    beginSession()
}
```

**Impact**: Eliminates CoreAudio HAL mutex contention storm.

**1.2 iOS Screen Lock Prevention**

Files:
- New: `mac-app/jarvis-project/Services/AudioSessionManager.swift`
- Modify: `mac-app/JarvisiOS/ContentView.swift:351-362, 364-390`

**Changes**:
- Add `AudioSessionManager.shared.enableVoiceConversationMode()` on `startVoiceInput()`
- Add `.disableVoiceConversationMode()` on conversation end/error
- Configure `.voiceChat` mode for AVAudioSession

**Impact**: Screen stays awake during conversations, audio plays through lock screen if needed.

### Phase 2: Async Acknowledgment (P1 - UX improvement)

**2.1 ConversationOrchestrator**

New file: `mac-app/jarvis-project/Services/ConversationOrchestrator.swift`

**Responsibilities**:
- State machine enforcement
- Immediate acknowledgment TTS
- Background task management
- Progress updates for long tasks

**2.2 Integration with ContentView**

Replace direct `apiClient.orchestrate()` calls with `conversationOrchestrator.processQuery()`.

**Impact**: Natural conversation flow with immediate feedback, no awkward silence.

### Phase 3: Barge-In (P2 - Advanced UX)

**3.1 BargeInDetector**

New file: `mac-app/jarvis-project/Services/BargeInDetector.swift`

**3.2 Wire to Audio Input During TTS**

Modify `NativeTTSManager` to expose barge-in callback.

**Impact**: User can interrupt Jarvis mid-response with new query.

### Phase 4: Endpointing & Backoff (P2 - Production hardening)

**4.1 Semantic Endpointing**

Per voice-conversation-protocol-design.md §3, implement dynamic silence thresholds.

**4.2 Error Backoff**

Per §7.3, track consecutive `beginSession()` failures, apply exponential backoff.

---

## 4. API Backend Changes

### 4.1 Streaming with Early Acknowledgment

**Current**: `/api/v1/orchestrate` returns full response after processing completes.

**Enhancement**: Support SSE (Server-Sent Events) for progressive updates:

```python
@router.post("/orchestrate/stream")
async def orchestrate_stream(request: OrchestQuery):
    """
    Streaming orchestration with immediate acknowledgment

    SSE events:
    - ack: Immediate acknowledgment text
    - progress: Progress update (optional)
    - chunk: Response text chunk
    - done: Final completion
    """
    async def generate():
        # 1. Immediate acknowledgment
        ack = generate_acknowledgment(request.query)
        yield f"event: ack\ndata: {json.dumps({'text': ack})}\n\n"

        # 2. Process query (may take 10-15s for agent path)
        response = await jarvis_agent.process_query(request.query)

        # 3. Stream response chunks
        for chunk in chunk_response(response):
            yield f"event: chunk\ndata: {json.dumps({'text': chunk})}\n\n"

        yield f"event: done\ndata: {json.dumps({'answer': response})}\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")
```

**Client integration**: `JarvisAPIClient.swift` add SSE stream parsing.

---

## 5. Testing Strategy

### 5.1 Unit Tests

- `ConversationOrchestrator` state transitions
- `BargeInDetector` VAD thresholds
- `AudioSessionManager` lifecycle

### 5.2 Integration Tests

- Wake word → query → acknowledgment → response flow
- Screen lock prevention during active conversation
- Barge-in cancellation and new query capture

### 5.3 Production Validation

- Long query processing (>10s) shows progress updates
- iOS screen doesn't lock during voice conversation
- Audio plays correctly through Bluetooth headsets
- No CoreAudio lock contention storms under load

---

## 6. Acceptance Criteria

### Phase 1 (P0)
- ✅ No CoreAudio lock storms in sample/profiler traces
- ✅ iOS screen stays awake during voice conversations
- ✅ Audio plays through lock screen if user locks manually mid-response

### Phase 2 (P1)
- ✅ All queries receive <500ms acknowledgment
- ✅ Long queries (>8s) show progress updates
- ✅ Natural conversation flow (no awkward silence)

### Phase 3 (P2)
- ✅ User can interrupt Jarvis mid-response
- ✅ Barge-in has <150ms latency from voice detection to TTS stop
- ✅ False barge-in rate <3% (coughs, background noise don't trigger)

### Phase 4 (P2)
- ✅ Dynamic endpointing reduces false turn-endings by 85%
- ✅ Quota exhaustion doesn't create restart storms

---

## 7. Implementation Timeline

**Phase 1 (P0 - Critical)**: 1-2 days
- WakeWordManager reentrancy guard
- iOS screen lock prevention

**Phase 2 (P1 - High value)**: 2-3 days
- ConversationOrchestrator implementation
- Backend streaming endpoint
- Client SSE integration

**Phase 3 (P2 - Polish)**: 3-4 days
- BargeInDetector implementation
- NativeTTSManager barge-in wiring
- Testing and tuning

**Phase 4 (P2 - Hardening)**: 2-3 days
- Semantic endpointing
- Error backoff logic

**Total**: ~10-12 development days

---

## 8. Related Documents

- [[voice-conversation-protocol-design]] - State machine formalism, endpointing, session lifecycle
- [[Jarvis TTS Streaming Architecture]] - NativeTTSManager generation-counter pattern
- [[Jarvis Orchestration Agent]] - Claude SDK integration, MCP tools

## Sources

- WhatsApp voice message UX patterns
- Siri/Alexa acknowledgment timing studies
- UIApplication.isIdleTimerDisabled - Apple Developer Docs
- AVAudioSession.Mode.voiceChat - Apple AVFoundation Docs

## Last Updated
2026-08-28
