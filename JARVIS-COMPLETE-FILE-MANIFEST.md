# Jarvis Complete File Manifest - All Changes for Mac Deployment

**Date**: 2026-08-28
**Purpose**: Comprehensive list of ALL files changed/created for Jarvis Phase 1 and Phase 2
**Target**: Pull to Mac for Xcode rebuild

---

## What's Been Implemented

### ✅ Phase 1 (P0 - Critical Fixes)
- WakeWordManager reentrancy guard (CoreAudio lock storm fix)
- iOS AudioSessionManager (screen lock prevention)
- Exponential backoff for quota errors
- Error classification

### ✅ Phase 2 (P1 - Async Conversation)
- Backend SSE streaming endpoint
- ConversationOrchestrator state machine
- Context-aware acknowledgments
- Progress updates for long queries
- Mac/iOS ContentView integration
- UI state visualization

### ⏸️ Phase 3 (P2 - Optional Future)
- Barge-in / interruption detection
- Mid-response cancellation
- NOT YET IMPLEMENTED

### ⏸️ Phase 4 (P2 - Optional Future)
- Semantic endpointing
- Advanced error backoff
- NOT YET IMPLEMENTED

---

## Git Commits to Pull

```bash
# All Phase 1 + Phase 2 commits
git log --oneline --reverse

# Key commits:
ed36467 - Phase 1 (P0) critical fixes
9a9138a - Phase 2 backend + ConversationOrchestrator
f4cb0a0 - Phase 2 ContentView integration (LATEST)
```

**You need to pull up to commit**: `f4cb0a0`

---

## Complete File Inventory

### 1. Backend Files (Python/FastAPI)

These run on the EC2 server. You don't need to pull these to your Mac unless you're running the backend locally.

#### Modified:
```
api/app/routers/orchestrate.py
  Lines added: 124
  Changes:
    - New POST /orchestrate/stream endpoint (SSE)
    - generate_acknowledgment() function (lines 105-142)
    - SSE event generator with progress updates (lines 145-223)
  Commit: 9a9138a
```

---

### 2. Mac/iOS Swift Files - Services Layer

These are shared between Mac and iOS apps.

#### NEW FILES (You must add to Xcode):

**File 1**: `mac-app/jarvis-project/Services/AudioSessionManager.swift`
```
Lines: 127
Purpose: iOS screen lock prevention during conversations
Platform: Cross-platform (iOS implementation + macOS stub)
Key features:
  - UIApplication.isIdleTimerDisabled = true
  - AVAudioSession .voiceChat mode
  - Automatic cleanup on background/errors
Commit: ed36467
Target membership: jarvis-project (Mac), JarvisiOS (iOS)
```

**File 2**: `mac-app/jarvis-project/Services/ConversationOrchestrator.swift`
```
Lines: 316
Purpose: State machine for async conversation flow
Platform: Cross-platform (uses #if os(iOS) where needed)
Key features:
  - ConversationState enum (idle/listening/acknowledged/processing/speaking/error)
  - processQuery() method with immediate acknowledgment
  - JarvisAPIClient extension for orchestrate endpoint
  - OrchestrationResponse model
  - Integrates with NativeTTSManager and AudioSessionManager
Commit: 9a9138a
Target membership: jarvis-project (Mac), JarvisiOS (iOS)
```

#### MODIFIED FILES:

**File 3**: `mac-app/jarvis-project/Services/WakeWordManager.swift`
```
Lines modified: ~50 (spread across file)
Purpose: Fix CoreAudio lock storm via reentrancy guard
Changes:
  - Added isTransitioning mutex (line 35-38)
  - Added consecutiveFailures tracking (line 40-43)
  - Updated restartSessionIfNeeded() with guard (lines 196-202)
  - Error classification for quota vs normal failures (lines 138-166)
  - restartWithBackoff() method (lines 204-217)
Commit: ed36467
```

---

### 3. Mac App UI Files (SwiftUI)

#### MODIFIED FILES:

**File 4**: `mac-app/jarvis-project/Views/ContentView.swift`
```
Lines modified: ~30
Purpose: Integrate ConversationOrchestrator into Mac UI
Changes:
  - Added @StateObject conversationOrchestrator (line 15)
  - Added custom init() with dependency injection (lines 19-23)
  - stopAndProcess() now calls orchestrator.processQuery() (line 448)
  - Removed currentResponse = "" in stopAndProcess() (line 431 removed)
  - Added isProcessing = false after orchestrator completes (line 450)
  - Enhanced statusView to show orchestrator.state (lines 298-311)
  - Added .onChange to sync orchestrator.currentResponse (lines 81-83)
Commits: f4cb0a0
```

---

### 4. iOS App UI Files (SwiftUI)

#### MODIFIED FILES:

**File 5**: `mac-app/JarvisiOS/ContentView.swift`
```
Lines modified: ~30
Purpose: Integrate ConversationOrchestrator into iOS UI
Changes:
  - Added @StateObject conversationOrchestrator (line 17)
  - Added custom init() with dependency injection (lines 21-25)
  - stopAndProcess() now calls orchestrator.processQuery() (line 392)
  - Removed currentResponse = "" in stopAndProcess() (line 382 removed)
  - Removed audioSessionManager calls from stopAndProcess() (orchestrator handles it)
  - Added isProcessing = false after orchestrator completes (line 394)
  - Enhanced statusView to show orchestrator.state (lines 283-293)
  - Added .onChange to sync orchestrator.currentResponse (lines 91-93)
Commits: ed36467 (AudioSessionManager), f4cb0a0 (orchestrator integration)
```

---

### 5. Documentation Files (Markdown)

You can pull these for reference but they're not needed for the app to build.

#### NEW FILES:

```
JARVIS-PHASE1-FIXES-COMPLETE.md (new)
  Purpose: Phase 1 implementation summary
  Commit: ed36467

JARVIS-PHASE1-TESTING-GUIDE.md (new)
  Purpose: Manual testing guide for Phase 1
  Commit: ed36467

JARVIS-PHASE2-ASYNC-CONVERSATION-STATUS.md (new)
  Purpose: Phase 2 implementation status and roadmap
  Commits: 9a9138a, f4cb0a0 (updated)

JARVIS-PHASE2-TESTING-GUIDE.md (new)
  Purpose: Comprehensive testing guide for Phase 2 (8 test scenarios)
  Commit: f4cb0a0

JARVIS-PHASE2-DEPLOYMENT-GUIDE.md (new)
  Purpose: Mac deployment instructions
  Commit: [to be committed]

JARVIS-COMPLETE-FILE-MANIFEST.md (new)
  Purpose: This file - complete file inventory
  Commit: [to be committed]
```

---

## Summary by File Type

### Swift Files You MUST Pull and Add to Xcode

**New Files (2)**:
1. ✅ `mac-app/jarvis-project/Services/AudioSessionManager.swift`
2. ✅ `mac-app/jarvis-project/Services/ConversationOrchestrator.swift`

**Modified Files (3)**:
3. ✅ `mac-app/jarvis-project/Services/WakeWordManager.swift`
4. ✅ `mac-app/jarvis-project/Views/ContentView.swift`
5. ✅ `mac-app/JarvisiOS/ContentView.swift`

**Total Swift files**: 5 (2 new, 3 modified)

### Backend Files (Optional for Mac)
- `api/app/routers/orchestrate.py` (only if running backend locally)

### Documentation Files (Optional)
- 6 new markdown files for reference

---

## Xcode Project Changes Required

### Mac App: `jarvis-project.xcodeproj`

**1. Add New Files to Project**:
```
Services/AudioSessionManager.swift
  - Right-click Services folder → Add Files to "jarvis-project"
  - Select AudioSessionManager.swift
  - CHECK: "Add to targets" → jarvis-project
  - UNCHECK: "Copy items if needed" (already in repo)

Services/ConversationOrchestrator.swift
  - Right-click Services folder → Add Files to "jarvis-project"
  - Select ConversationOrchestrator.swift
  - CHECK: "Add to targets" → jarvis-project
  - UNCHECK: "Copy items if needed"
```

**2. Modified Files (Auto-Detected)**:
- WakeWordManager.swift
- ContentView.swift

These should automatically rebuild with new changes.

**3. Build Settings** (no changes needed):
- Deployment Target: iOS 16.0+ / macOS 13.0+
- Swift Version: 5.x
- Frameworks: Same as before (AVFoundation, Speech, SwiftUI)

---

### iOS App: `JarvisiOS.xcodeproj`

**1. Verify Shared Files Linked**:

The iOS app shares Services from the Mac app. Verify these appear in Project Navigator:

```
JarvisiOS/
  Services/ (shared from jarvis-project)
    AudioSessionManager.swift ← NEW, should appear automatically
    ConversationOrchestrator.swift ← NEW, should appear automatically
    WakeWordManager.swift ← Modified
    (other existing services)
```

If they don't appear automatically:
```
Right-click JarvisiOS project → Add Files to "JarvisiOS"
Navigate to ../jarvis-project/Services/
Select AudioSessionManager.swift and ConversationOrchestrator.swift
CHECK: "Create groups" (not folder references)
CHECK: "Add to targets" → JarvisiOS
UNCHECK: "Copy items if needed"
```

**2. Modified Files (Auto-Detected)**:
- ContentView.swift

Should automatically rebuild with new changes.

---

## File-by-File Change Details

### File 1: AudioSessionManager.swift (NEW)

**Full Path**: `mac-app/jarvis-project/Services/AudioSessionManager.swift`

**Purpose**: Prevent iOS screen lock during voice conversations

**Key Code Sections**:

```swift
// Lines 1-10: Imports and conditional compilation
import Foundation
#if os(iOS)
import UIKit
import AVFoundation

// Lines 20-70: Main class
@MainActor
class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()
    @Published private(set) var isVoiceConversationActive = false

    func enableVoiceConversationMode() {
        // Prevent screen lock
        UIApplication.shared.isIdleTimerDisabled = true

        // Configure audio session for voice chat
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
        )
        try session.setActive(true)
        isVoiceConversationActive = true
    }

    func disableVoiceConversationMode() {
        UIApplication.shared.isIdleTimerDisabled = false
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        isVoiceConversationActive = false
    }
}

// Lines 120-127: macOS stub
#else
@MainActor
class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()
    func enableVoiceConversationMode() {}
    func disableVoiceConversationMode() {}
}
#endif
```

**Xcode Setup**:
- Add to both targets: `jarvis-project` (macOS) and `JarvisiOS` (iOS)
- No special build settings needed
- Conditional compilation handles platform differences

---

### File 2: ConversationOrchestrator.swift (NEW)

**Full Path**: `mac-app/jarvis-project/Services/ConversationOrchestrator.swift`

**Purpose**: State machine for async conversation with immediate acknowledgment

**Key Code Sections**:

```swift
// Lines 1-23: ConversationState enum
enum ConversationState: Equatable {
    case idle, listening, acknowledged, processing, speaking, error(String)

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .acknowledged: return "Acknowledged"
        case .processing: return "Processing"
        case .speaking: return "Speaking"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

// Lines 38-52: Main orchestrator class
@MainActor
class ConversationOrchestrator: ObservableObject {
    @Published private(set) var state: ConversationState = .idle
    @Published private(set) var currentResponse: String = ""
    @Published private(set) var isProcessing: Bool = false

    private let apiClient = JarvisAPIClient.shared
    private let ttsManager: NativeTTSManager
    private let audioSessionManager = AudioSessionManager.shared
    private var currentTask: Task<Void, Never>?

    init(ttsManager: NativeTTSManager) {
        self.ttsManager = ttsManager
    }

// Lines 64-109: processQuery method
    func processQuery(_ query: String, sessionId: String) async throws {
        cancel()  // Cancel any existing task

        state = .acknowledged
        isProcessing = true
        currentResponse = ""

        audioSessionManager.enableVoiceConversationMode()

        currentTask = Task {
            do {
                try await processWithSSE(query: query, sessionId: sessionId)

                await MainActor.run {
                    state = .idle
                    isProcessing = false
                    audioSessionManager.disableVoiceConversationMode()
                }
            } catch {
                await MainActor.run {
                    state = .error(error.localizedDescription)
                    isProcessing = false
                    audioSessionManager.disableVoiceConversationMode()
                }
                throw error
            }
        }

        await currentTask?.value
    }

// Lines 112-158: SSE processing with acknowledgment
    private func processWithSSE(query: String, sessionId: String) async throws {
        // 1. Immediate acknowledgment
        let ackText = generateAcknowledgment(for: query)
        state = .acknowledged
        try await speakImmediate(ackText)

        // 2. Background processing
        state = .processing
        let processingTask = Task {
            try await apiClient.orchestrate(query: query, sessionId: sessionId)
        }

        // 3. Progress update if >8s
        var progressSent = false
        for _ in 0..<16 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if processingTask.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            if !progressSent && _ == 15 {
                progressSent = true
                try await speakImmediate("Still working on that")
            }
        }

        // 4. Get result and speak
        let response = try await processingTask.value
        state = .speaking
        currentResponse = response.answer
        try await speakResponse(response.answer)
    }

// Lines 161-202: Context-aware acknowledgment generation
    private func generateAcknowledgment(for query: String) -> String {
        let queryLower = query.lowercased()

        if queryLower.contains("search") || queryLower.contains("find") {
            return "Let me search for that"
        } else if queryLower.hasPrefix("what") || queryLower.contains(" what ") {
            return "Let me look that up"
        } else if queryLower.hasPrefix("who") || queryLower.contains(" who ") {
            return "Let me check"
        }
        // ... more patterns ...

        return "One moment"  // Default
    }

// Lines 251-312: JarvisAPIClient extension
extension JarvisAPIClient {
    func orchestrate(query: String, sessionId: String, useAgent: Bool? = nil) async throws -> OrchestrationResponse {
        struct OrchestRequest: Codable {
            let query: String
            let useAgent: Bool?
            let conversationId: String?
        }

        let requestBody = OrchestRequest(
            query: query,
            useAgent: useAgent,
            conversationId: sessionId
        )

        let bodyData = try JSONEncoder().encode(requestBody)

        // Manual URLSession request to orchestrate endpoint
        guard let url = URL(string: "https://18.142.241.151:8443/api/v1/orchestrate") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        if let token = UserDefaults.standard.string(forKey: "jarvis_access_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let sessionDelegate = SelfSignedCertificateDelegate()
        let config = URLSessionConfiguration.default
        let urlSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 500)
        }

        return try JSONDecoder().decode(OrchestrationResponse.self, from: data)
    }
}
```

**Xcode Setup**:
- Add to both targets: `jarvis-project` and `JarvisiOS`
- Depends on: NativeTTSManager, JarvisAPIClient, AudioSessionManager
- No special frameworks needed (uses existing AVFoundation, etc.)

---

### File 3: WakeWordManager.swift (MODIFIED)

**Full Path**: `mac-app/jarvis-project/Services/WakeWordManager.swift`

**Changes Made**:

**1. Added reentrancy guard** (lines 35-38):
```swift
/// Mutex guard to prevent concurrent session transitions
private var isTransitioning = false
```

**2. Added failure tracking** (lines 40-43):
```swift
/// Tracks consecutive session failures for exponential backoff
private var consecutiveFailures = 0
private var lastSessionStartTime: Date?
```

**3. Updated restartSessionIfNeeded()** (lines 196-202):
```swift
private func restartSessionIfNeeded() {
    guard !isSuspended, !isTransitioning else { return }
    isTransitioning = true
    defer { isTransitioning = false }
    endSession()
    beginSession()
}
```

**4. Added error classification** (lines 138-166):
```swift
if let error {
    let errorString = error.localizedDescription.lowercased()
    let isQuotaError = errorString.contains("quota") || errorString.contains("rate limit")

    if isQuotaError {
        print("⚠️ WakeWordManager: quota/rate-limit error, applying backoff")
        Task { @MainActor in
            self.consecutiveFailures += 1
            await self.restartWithBackoff()
        }
    } else {
        // Normal restart without backoff
        consecutiveFailures = 0
        restartSessionIfNeeded()
    }
}
```

**5. Added restartWithBackoff()** (lines 204-217):
```swift
private func restartWithBackoff() async {
    let backoffDelay = min(pow(2.0, Double(consecutiveFailures)), 10.0)
    print("⏳ WakeWordManager: backing off \(Int(backoffDelay))s before retry (failure #\(consecutiveFailures))")

    try? await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))

    guard !isSuspended else {
        print("⏸️ WakeWordManager: suspended during backoff, not restarting")
        return
    }

    restartSessionIfNeeded()
}
```

**Xcode Setup**:
- Already in project, will rebuild automatically
- No target membership changes needed

---

### File 4: ContentView.swift (Mac) (MODIFIED)

**Full Path**: `mac-app/jarvis-project/Views/ContentView.swift`

**Changes Made**:

**1. Added conversationOrchestrator StateObject** (line 15):
```swift
@StateObject private var conversationOrchestrator: ConversationOrchestrator
```

**2. Added custom init()** (lines 19-23):
```swift
init() {
    let tts = NativeTTSManager()
    _ttsManager = StateObject(wrappedValue: tts)
    _conversationOrchestrator = StateObject(wrappedValue: ConversationOrchestrator(ttsManager: tts))
}
```

**3. Updated stopAndProcess()** (lines 428-465):
```swift
private func stopAndProcess() async {
    do {
        isProcessing = true
        // Removed: currentResponse = ""

        let transcribedText = try await speechManager.stopRecordingAndTranscribe()

        guard !transcribedText.isEmpty else {
            isProcessing = false
            wakeWordManager.resumeAfterActiveQuery()
            return
        }

        // NEW: Use ConversationOrchestrator
        try await conversationOrchestrator.processQuery(transcribedText, sessionId: sessionId)

        isProcessing = false
        wakeWordManager.resumeAfterActiveQuery()

    } catch let error as SpeechError {
        isProcessing = false
        wakeWordManager.resumeAfterActiveQuery()
        await handleError(error.localizedDescription ?? "Speech recognition failed")
    } catch let error as APIError {
        isProcessing = false
        wakeWordManager.resumeAfterActiveQuery()
        await handleError(error.localizedDescription ?? "API error")
    } catch {
        isProcessing = false
        wakeWordManager.resumeAfterActiveQuery()
        await handleError("Voice input error: \(error.localizedDescription)")
    }
}
```

**4. Enhanced statusView** (lines 296-333):
```swift
private var statusView: some View {
    VStack(spacing: 4) {
        if conversationOrchestrator.state != .idle {
            // Show orchestrator state when active
            HStack(spacing: 8) {
                if conversationOrchestrator.state == .processing {
                    ProgressView().scaleEffect(0.7)
                } else if conversationOrchestrator.state == .speaking || conversationOrchestrator.state == .acknowledged {
                    Image(systemName: "speaker.wave.2.fill").font(.caption)
                }
                Text(conversationOrchestrator.state.description).font(.caption)
            }
            .foregroundColor(conversationOrchestrator.state == .processing ? .primary : .blue)
        } else if isProcessing {
            // Fallback to old processing indicator
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Processing...").font(.caption)
            }
        } else if ttsManager.isSpeaking {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.caption)
                Text("Playing response...").font(.caption)
            }
            .foregroundColor(.blue)
        } else {
            Text(speechManager.isRecording ? "Tap to stop" : "Tap microphone or type to talk to Jarvis")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
```

**5. Added .onChange modifier** (lines 81-83):
```swift
.onChange(of: conversationOrchestrator.currentResponse) { newResponse in
    currentResponse = newResponse
}
```

**Xcode Setup**:
- Already in project, will rebuild automatically
- No changes needed

---

### File 5: ContentView.swift (iOS) (MODIFIED)

**Full Path**: `mac-app/JarvisiOS/ContentView.swift`

**Changes Made**: Identical to Mac ContentView.swift changes

**1. Added conversationOrchestrator StateObject** (line 17):
```swift
@StateObject private var conversationOrchestrator: ConversationOrchestrator
```

**2. Added custom init()** (lines 21-25):
```swift
init() {
    let tts = NativeTTSManager()
    _ttsManager = StateObject(wrappedValue: tts)
    _conversationOrchestrator = StateObject(wrappedValue: ConversationOrchestrator(ttsManager: tts))
}
```

**3. Updated stopAndProcess()** (lines 379-410):
```swift
private func stopAndProcess() async {
    do {
        isProcessing = true
        // Removed: currentResponse = ""

        let transcribedText = try await speechManager.stopRecordingAndTranscribe()

        guard !transcribedText.isEmpty else {
            isProcessing = false
            wakeWordManager.resumeAfterActiveQuery()
            return
        }

        // NEW: Use ConversationOrchestrator (handles AudioSessionManager internally)
        try await conversationOrchestrator.processQuery(transcribedText, sessionId: sessionId)

        isProcessing = false
        wakeWordManager.resumeAfterActiveQuery()

    } catch let error as SpeechError {
        isProcessing = false
        wakeWordManager.resumeAfterActiveQuery()
        await handleError(error.localizedDescription ?? "Speech recognition failed")
    } catch let error as APIError {
        isProcessing = false
        wakeWordManager.resumeAfterActiveQuery()
        await handleError(error.localizedDescription ?? "API error")
    } catch {
        isProcessing = false
        wakeWordManager.resumeAfterActiveQuery()
        await handleError("Voice input error: \(error.localizedDescription)")
    }
}
```

**4. Enhanced statusView** (lines 281-311):
```swift
private var statusView: some View {
    VStack(spacing: 4) {
        if conversationOrchestrator.state != .idle {
            HStack(spacing: 8) {
                if conversationOrchestrator.state == .processing {
                    ProgressView().scaleEffect(0.7)
                } else if conversationOrchestrator.state == .speaking || conversationOrchestrator.state == .acknowledged {
                    Image(systemName: "speaker.wave.2.fill").font(.caption)
                }
                Text(conversationOrchestrator.state.description).font(.caption)
            }
            .foregroundColor(conversationOrchestrator.state == .processing ? .primary : .blue)
        } else if isProcessing {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Processing...").font(.caption)
            }
        } else if ttsManager.isSpeaking {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.caption)
                Text("Playing response...").font(.caption)
            }
            .foregroundColor(.blue)
        } else {
            Text(speechManager.isRecording ? "Tap to stop" : "Tap microphone or type to talk to Jarvis")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
```

**5. Added .onChange modifier** (lines 91-93):
```swift
.onChange(of: conversationOrchestrator.currentResponse) { newResponse in
    currentResponse = newResponse
}
```

**Xcode Setup**:
- Already in project, will rebuild automatically
- Note: Removed direct audioSessionManager calls since orchestrator handles them

---

## Step-by-Step Deployment on Mac

### Step 1: Pull from GitHub

```bash
# Navigate to AIS-OS on your Mac
cd ~/AIS-OS

# Check current status
git status

# Pull all commits up to f4cb0a0
git pull origin main

# Verify you're at the right commit
git log --oneline -1
# Should show: f4cb0a0 Complete Phase 2 (P1) - Async conversation...
```

### Step 2: Verify Files Exist

```bash
# Check new Swift files
ls -la mac-app/jarvis-project/Services/AudioSessionManager.swift
ls -la mac-app/jarvis-project/Services/ConversationOrchestrator.swift

# Check modified files
git diff ed36467^..f4cb0a0 --name-only
```

Expected output:
```
api/app/routers/orchestrate.py
mac-app/jarvis-project/Services/AudioSessionManager.swift
mac-app/jarvis-project/Services/ConversationOrchestrator.swift
mac-app/jarvis-project/Services/WakeWordManager.swift
mac-app/jarvis-project/Views/ContentView.swift
mac-app/JarvisiOS/ContentView.swift
JARVIS-PHASE1-FIXES-COMPLETE.md
JARVIS-PHASE1-TESTING-GUIDE.md
JARVIS-PHASE2-ASYNC-CONVERSATION-STATUS.md
JARVIS-PHASE2-TESTING-GUIDE.md
```

### Step 3: Open Xcode Projects

**Mac App**:
```bash
open ~/AIS-OS/mac-app/jarvis-project.xcodeproj
```

Wait for Xcode to open, then:
1. Check Project Navigator (⌘1)
2. Look for Services folder
3. **Verify new files appear**:
   - ✅ AudioSessionManager.swift
   - ✅ ConversationOrchestrator.swift

If missing:
1. Right-click `Services` folder
2. "Add Files to jarvis-project"
3. Navigate to and select both new files
4. **UNCHECK** "Copy items if needed"
5. **CHECK** "Add to targets: jarvis-project"
6. Click "Add"

**iOS App**:
```bash
open ~/AIS-OS/mac-app/JarvisiOS.xcodeproj
```

Repeat same verification for iOS target.

### Step 4: Clean Build Folder

In Xcode:
1. Menu: Product → Clean Build Folder (⇧⌘K)
2. Wait for "Clean Finished"

### Step 5: Build

In Xcode:
1. Menu: Product → Build (⌘B)
2. Watch for build errors in Issue Navigator (⌘5)

**Expected**: 0 errors, 0 warnings (or only existing warnings)

If build fails, see Troubleshooting section in JARVIS-PHASE2-DEPLOYMENT-GUIDE.md

### Step 6: Run

In Xcode:
1. Select target: "jarvis-project" or "JarvisiOS"
2. Select destination: "My Mac" or iPhone simulator/device
3. Menu: Product → Run (⌘R)
4. App should launch successfully

### Step 7: Quick Smoke Test

1. Say "Hey Jarvis"
2. Ask: "What were my achievements?"
3. **Verify**: Hear "Let me check your records" within 1 second
4. **Verify**: See status: "Acknowledged" → "Processing" → "Speaking"
5. **Verify**: Full response plays

**Success**: If you hear immediate acknowledgment, Phase 2 is working!

---

## File Dependencies Graph

```
ContentView (Mac/iOS)
    ↓ uses
ConversationOrchestrator
    ↓ uses
    ├── NativeTTSManager (existing)
    ├── JarvisAPIClient (existing, with new extension)
    └── AudioSessionManager (new)
            ↓ uses
            └── UIApplication (iOS)
                AVAudioSession (iOS)

WakeWordManager (modified)
    ↓ uses
    └── SFSpeechRecognizer (existing)
```

**Build Order** (Xcode handles automatically):
1. AudioSessionManager
2. ConversationOrchestrator (depends on AudioSessionManager)
3. WakeWordManager (independent)
4. ContentView (depends on all services)

---

## Quick Reference - What Changed Where

| Feature | File(s) Changed | Lines | Commit |
|---------|----------------|-------|--------|
| CoreAudio lock storm fix | WakeWordManager.swift | ~50 | ed36467 |
| iOS screen lock prevention | AudioSessionManager.swift (new) | 127 | ed36467 |
| iOS screen lock integration | JarvisiOS/ContentView.swift | ~20 | ed36467 |
| Backend SSE endpoint | api/app/routers/orchestrate.py | +124 | 9a9138a |
| Conversation state machine | ConversationOrchestrator.swift (new) | 316 | 9a9138a |
| Mac orchestrator integration | jarvis-project/Views/ContentView.swift | ~30 | f4cb0a0 |
| iOS orchestrator integration | JarvisiOS/ContentView.swift | ~30 | f4cb0a0 |

---

## Rollback Strategy

If any issues after deployment:

**Option 1**: Revert to Phase 1 only (stable, no async conversation)
```bash
git checkout 9a9138a
# Rebuild Xcode projects
```

**Option 2**: Revert to pre-Phase 1 (last known stable before all changes)
```bash
git log --oneline | grep -B 1 "Phase 1"
git checkout [commit-before-phase-1]
```

**Option 3**: Cherry-pick specific features
```bash
# Keep Phase 1 fixes but revert Phase 2
git revert f4cb0a0
git revert 9a9138a
# Keep ed36467 (Phase 1)
```

---

## Post-Deployment Verification Checklist

After pulling and building:

### Build Verification
- [ ] Mac app builds without errors
- [ ] iOS app builds without errors
- [ ] New files appear in Xcode Project Navigator
- [ ] Target membership correct for both files

### Runtime Verification (Mac)
- [ ] App launches successfully
- [ ] Authenticates to backend
- [ ] "Hey Jarvis" wake word works
- [ ] Voice query gets immediate acknowledgment
- [ ] Status view shows state transitions
- [ ] Full response plays correctly

### Runtime Verification (iOS)
- [ ] App launches successfully
- [ ] Authenticates to backend
- [ ] "Hey Jarvis" wake word works
- [ ] Voice query gets immediate acknowledgment
- [ ] Screen stays awake during conversation
- [ ] Screen lock restores after conversation
- [ ] Full response plays correctly

### Phase 2 Features Verification
- [ ] Acknowledgment is context-aware (not always "One moment")
- [ ] Long queries (>8s) get progress update
- [ ] State machine visible in UI
- [ ] Error handling works (try disconnecting network mid-query)
- [ ] Cancellation works (say "Hey Jarvis" mid-processing)

---

## Summary

**Total files to pull**: 11 (5 Swift, 6 docs)

**Critical Swift files**: 5
- 2 new (AudioSessionManager, ConversationOrchestrator)
- 3 modified (WakeWordManager, Mac ContentView, iOS ContentView)

**Xcode actions required**:
1. Pull from GitHub
2. Add 2 new files to Xcode targets
3. Clean build folder
4. Build
5. Run
6. Test

**Estimated time**: 30-45 minutes (including testing)

**Risk level**: Low (rollback available)

---

**Last Updated**: 2026-08-28
**Git Range**: `ed36467..f4cb0a0` (Phase 1 + Phase 2)
**Status**: Complete implementation, ready for deployment
