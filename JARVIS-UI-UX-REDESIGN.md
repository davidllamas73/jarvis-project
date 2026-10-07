# Jarvis UI/UX Redesign

Date: 2026-10-07
Scope: iOS app (`JarvisiOS/`) and macOS app (`jarvis-project/`)
Status: P0-P3 implemented 2026-10-07 in `JarvisShared/` + platform shells, pending first Xcode build. Decisions taken: iOS drawer, auto-speak voice only, local JSON storage. Old UI in `archives/ui-v1/`.

---

## 1. Why it feels broken (root causes)

The current UI is a single fixed screen: header, big mic button, text field, one response box. It is a voice demo, not a chat tool. The three reported bugs come straight from that layout.

| Symptom | Root cause | Where |
|---|---|---|
| Can't scroll the answer | Response box is `.frame(maxHeight: 200).clipped()` with no `ScrollView`. Anything past ~8 lines is cut off. Only one `currentResponse` string exists, so there is no history to scroll anyway. | `JarvisiOS/ContentView.swift` `responseView`; same in `jarvis-project/Views/ContentView.swift` |
| Can't send a new prompt after an answer | `canSubmitPrompt` and the mic button both require `!isProcessing`. `isProcessing` is only cleared after `ttsManager.speakStream()` returns, i.e. after Jarvis finishes *speaking* the whole answer. Long answer = locked for minutes. If the TTS continuation never resumes (audio interruption, route change), it is locked forever. No stop button exists. | `sendQuery()`, `stopAndProcess()` |
| iOS keyboard traps you | `TextField(axis: .vertical)` turns Return into a newline, so there is no submit or dismiss key. No `@FocusState`, no `.scrollDismissesKeyboard`, no tap-outside, no keyboard toolbar. The screen also has no navigation at all, so there is no "main menu" to get back to. | `promptInputView` |

Secondary issues:
- Errors are modal `.alert`s with raw exception text. No retry.
- Status is a single word ("Processing", "Acknowledged"). No sense of what Jarvis is doing (searching brain, running Python, web search).
- No conversations, no persistence. Closing the app loses everything. `sessionId` is per-launch.
- iOS and macOS are two near-identical 600-line `ContentView`s. Every fix has to be done twice.
- `ChatView.swift` (macOS) already has a proper scrolling transcript but is not wired into the app.
- Risk to check in Xcode: the iOS target's `membershipExceptions` only include 5 shared files, but iOS `ContentView` uses `ConversationOrchestrator` and `AudioSessionManager`. Confirm the local project matches the repo.

---

## 2. Best practices for AI assistant apps

Distilled from ChatGPT, Claude, Gemini and Perplexity apps plus Apple HIG. These are the bar.

### Layout
1. **Transcript is the screen.** Scrolling list of turns, newest at bottom. Everything else is chrome around it.
2. **Composer pinned to the bottom** (`safeAreaInset(edge: .bottom)`), rides above the keyboard, grows 1 to 6 lines then scrolls internally.
3. **Auto-follow while streaming, unless the user scrolled up.** Then show a "Jump to latest" pill.
4. **Empty state with suggested prompts** instead of a blank screen. Pull from current priorities (job search, longevity clinic, TU/GJ advisory).

### Input never blocks
5. **Send button morphs to Stop** while a response is generating. Stop cancels the network stream and speech.
6. **Speaking never blocks typing.** Generation state and speech state are separate. Sending a new message while Jarvis is talking stops the speech and starts the new turn.
7. **Voice is a mode, not the default control.** Mic button in the composer starts dictation or full voice mode. Typing users never see a 96pt mic.

### Keyboard
8. iOS: `.scrollDismissesKeyboard(.interactively)`, tap transcript to dismiss, send via button. Return inserts newline (multi-line is right on phone).
9. macOS: Return sends, Shift+Return newline, Esc stops, Cmd+N new chat, Cmd+K search chats, Cmd+, settings.

### Navigation
10. **Conversation list** that persists. macOS: `NavigationSplitView` sidebar. iOS: chats list as root, or a leading drawer; tapping a chat pushes the transcript. Always-visible "New chat" (top right).
11. **Settings** reachable from one tap: server URL, pairing, auto-speak on/off, voice, wake word on/off.

### Message affordances
12. Markdown rendering (headings, lists, tables, code blocks with copy).
13. Per-message actions on long-press / hover: Copy, Read aloud, Retry, Share.
14. **Show agent work** as a collapsible step row above the answer: "Searching brain archive", "Running Python in NetworkOptimizer", "Searching web". Map from the V2 tier + tool events. Collapsed by default when done.
15. Sources as a compact chip row ("4 sources") that expands. Not inline walls of text.
16. **Errors inline** in the transcript as a failed bubble with "Retry". No modal alerts.

### Voice mode (ChatGPT Advanced Voice pattern)
17. Full-screen sheet: animated orb/waveform tied to audio level, live caption of what you said and what Jarvis is saying, big "End" button, mute button.
18. Every voice turn is written into the same conversation transcript, so you can scroll it later.
19. Barge-in: speaking over Jarvis interrupts it (already built in `BargeInDetector`, needs a UI state).

### Quality bar
20. Dynamic Type, VoiceOver labels on every icon button, Reduce Motion respected, 44pt touch targets, haptic on send/stop (iOS).
21. Background tasks (research tier) show as a pending card in the transcript that fills in when done, plus a local notification.

---

## 3. Target design

### iOS

```
┌─────────────────────────────┐
│ ☰  Jarvis ● Connected    ✎  │  nav bar: chats drawer, status, new chat
├─────────────────────────────┤
│                             │
│              ┌───────────┐  │
│              │ You: ...  │  │  user bubble (right, tinted)
│              └───────────┘  │
│  ▸ Searched brain · 3 src   │  agent step row (collapsible)
│  Jarvis answer in plain     │  assistant text, full width,
│  markdown, full width,      │  no bubble, scrolls freely
│  scrolls...                 │
│  ⧉  🔊  ↻                    │  copy / read aloud / retry
│                             │
│        [ ↓ Jump to latest ] │
├─────────────────────────────┤
│ ＋ │ Ask Jarvis…      │🎙│ ⬆ │  composer; ⬆ becomes ■ while running
└─────────────────────────────┘
```

### macOS

```
┌──────────────┬──────────────────────────────────────┐
│ ⌕ Search     │  Jarvis · Connected       🔊 auto  ⚙ │
│ ＋ New chat  ├──────────────────────────────────────┤
│              │                                      │
│ Today        │        transcript (max 760pt wide,   │
│  MAP prep    │        centered, same components)    │
│  GJ Q3 rev   │                                      │
│ Yesterday    │                                      │
│  TU network  │                                      │
│              ├──────────────────────────────────────┤
│              │  ＋  Ask Jarvis…            🎙  ⬆     │
└──────────────┴──────────────────────────────────────┘
```

Menu bar extra stays as a quick-ask popover that opens the main window on the active chat.

---

## 4. Architecture change

Move from "two fat ContentViews" to one shared chat core.

```
jarvis-project/
  Shared/                      ← compiled into BOTH targets
    Chat/
      ChatStore.swift          @Observable, owns conversations, send(), stop(), retry()
      Conversation.swift       SwiftData models: Conversation, Message, AgentStep
      ChatTranscriptView.swift ScrollViewReader + LazyVStack + jump-to-latest
      MessageView.swift        user/assistant rendering, markdown, actions
      ComposerView.swift       text, attachments, mic, send/stop morph
      AgentStepsView.swift
    Voice/
      VoiceModeView.swift      full-screen voice sheet
      VoiceController.swift    wraps speech + wake word + TTS + barge-in
    Settings/SettingsView.swift
  Views/ (macOS shell)  RootSplitView, MenuBarView
JarvisiOS/ (iOS shell)  RootView (chats list + transcript)
```

Key state rule: `ChatStore.generationState` (`idle | streaming | failed`) and `VoiceController.speechState` (`silent | speaking`) are independent. The composer only cares about `generationState`.

Existing services (`JarvisAPIClient`, `ConversationOrchestrator`, `NativeTTSManager`, `WakeWordManager`, `BargeInDetector`) are kept. The UI calls them through `ChatStore` / `VoiceController` instead of directly.

---

## 5. Phased plan

| Phase | What ships | Effort |
|---|---|---|
| **P0 Unblock** | Fix the 3 bugs in place: scrollable response, input not gated on speech + Stop button, keyboard dismiss on iOS, Return-to-send on Mac. No new architecture. | 0.5 day |
| **P1 Chat core** | `Shared/Chat/*`: transcript with history, composer, inline errors with retry, markdown, per-message actions. Same code on both platforms. | 2 days |
| **P2 Navigation and persistence** | SwiftData conversations, chats list / sidebar, new chat, search, settings screen. | 1.5 days |
| **P3 Voice mode and agent steps** | Full-screen voice sheet with live captions, barge-in state, agent step rows from tier/tool events, background task cards. | 2 days |
| **P4 Polish** | Accessibility pass, haptics, Mac shortcuts, menu bar quick ask, empty-state prompts from `context/priorities.md`. | 1 day |

Backend nice-to-haves (Jarvis API, not blocking): emit `tool_start` / `tool_end` SSE events so agent steps are real, not inferred; `GET /conversations` for cross-device sync later.

---

## 6. Open decisions for David

1. iOS navigation: chats list as root (Messages-style) or drawer (ChatGPT-style)? Recommendation: drawer, so you land straight in a chat.
2. Auto-speak answers by default when you typed the question? Recommendation: off for typed, on for voice.
3. Conversation storage: local only (SwiftData) for now, server sync later? Recommendation: local only.
