# Jarvis Phase 1 Testing Guide

**Quick reference for testing the P0 fixes**

---

## Pre-Test Setup

### Mac App
```bash
cd /home/ubuntu/AIS-OS/mac-app
# Build and run in Xcode on your Mac
```

### iOS App
```bash
cd /home/ubuntu/AIS-OS/mac-app/JarvisiOS
# Build and run in Xcode on your iPhone
```

### iOS Settings
Set auto-lock to 30 seconds for easier testing:
**Settings → Display & Brightness → Auto-Lock → 30 Seconds**

---

## Test 1: No More Lock Storms (Mac) ⏱️ 5 minutes

**What we're testing**: WakeWordManager reentrancy guard

**Steps**:
1. Open Activity Monitor (Spotlight → "Activity Monitor")
2. Find "jarvis-project" process
3. Launch Jarvis Mac app
4. Say "Hey Jarvis" every 5-10 seconds for 2 minutes
5. Watch CPU % in Activity Monitor

**✅ Pass criteria**:
- CPU stays under 30%
- App remains responsive
- No audio glitches or hangs

**❌ Fail indicators**:
- CPU spikes to 90%+
- App freezes
- Console shows rapid "audio engine failed" errors

**Console logs to watch for** (⌘+Space → "Console.app" → search "jarvis"):
```
✅ Good:
"👋 Wake phrase detected"
"😴 Sleep phrase detected"

⚠️ Quota hit (expected after many rapid restarts):
"⏳ WakeWordManager: backing off 1s before retry (failure #1)"
"⏳ WakeWordManager: backing off 2s before retry (failure #2)"

❌ Bad (shouldn't see these):
Multiple "audio engine failed" with no backoff delays
```

---

## Test 2: Screen Stays Awake (iOS) ⏱️ 2 minutes

**What we're testing**: AudioSessionManager prevents screen lock

**Steps**:
1. Set iPhone auto-lock to 30 seconds
2. Launch Jarvis iOS app
3. Say "Hey Jarvis"
4. Ask a question that takes >30 seconds: "What were my achievements at Central Retail?"
5. **Don't touch the screen** during processing and playback
6. Wait 45 seconds total

**✅ Pass criteria**:
- Screen stays bright during entire conversation
- Audio plays clearly
- Screen lock restored after conversation ends

**❌ Fail indicators**:
- Screen goes dark during conversation
- Audio cuts off when screen would normally lock
- Screen stays awake forever (no restore after conversation)

**Console logs** (Xcode → Debug Area → Console):
```
✅ Expected flow:
"✅ AudioSessionManager: voice conversation mode enabled (screen lock disabled)"
[... conversation happens ...]
"✅ AudioSessionManager: voice conversation mode disabled (screen lock restored)"

❌ Should NOT see:
"❌ AudioSessionManager: failed to configure audio session"
```

---

## Test 3: Error Path Cleanup (iOS) ⏱️ 1 minute

**What we're testing**: Audio session restored on errors

**Steps**:
1. Launch Jarvis iOS app
2. Say "Hey Jarvis"
3. Start speaking, then **stop mid-sentence** (don't finish query)
4. Wait for timeout
5. Check screen lock is restored

**✅ Pass criteria**:
- Screen lock restored even on error/timeout
- Console shows "voice conversation mode disabled"

---

## Test 4: Background Cleanup (iOS) ⏱️ 30 seconds

**What we're testing**: Force-disable on app background

**Steps**:
1. Launch Jarvis iOS app
2. Say "Hey Jarvis" → start a query
3. **Swipe up to home screen** mid-processing
4. Check console logs

**✅ Pass criteria**:
- Console shows "⚠️ AudioSessionManager: force-disabling voice conversation mode"
- No audio session errors

---

## Test 5: Bluetooth Headset (iOS, optional) ⏱️ 2 minutes

**What we're testing**: Audio routing to Bluetooth

**Requires**: Bluetooth headphones/headset

**Steps**:
1. Connect Bluetooth headphones
2. Launch Jarvis iOS app
3. Say "Hey Jarvis" → ask a question
4. Verify audio plays through headphones

**✅ Pass criteria**:
- Audio plays through Bluetooth device
- No fallback to phone speaker

---

## Test 6: Background Music Duck (iOS, optional) ⏱️ 1 minute

**What we're testing**: `.duckOthers` option

**Steps**:
1. Start playing music (Apple Music, Spotify, etc.)
2. Launch Jarvis iOS app
3. Say "Hey Jarvis" → ask a question
4. Notice music volume during Jarvis speech

**✅ Pass criteria**:
- Music volume lowers automatically during Jarvis speech
- Music volume restores after Jarvis finishes

---

## Quick Validation Commands

### Check if Mac app is running
```bash
ps aux | grep jarvis-project
```

### Monitor Mac app logs
```bash
log stream --predicate 'subsystem CONTAINS "jarvis"' --level debug
```

### Check iOS device logs (from Mac)
```bash
# Connect iPhone via USB, then:
xcrun devicectl device monitor logs --style compact
```

---

## Profiler Validation (Advanced)

### Mac: Instruments Time Profiler
1. Open Xcode → Product → Profile (⌘+I)
2. Select "Time Profiler"
3. Run test scenario
4. Look for `HALB_Mutex::Lock()` samples - should be minimal

### Expected profile (good):
```
main thread: 95% idle
- 3% SFSpeechRecognizer callbacks
- 2% UI updates
```

### Bad profile (bug present):
```
main thread: 85% blocked
- 60% HALB_Mutex::Lock
- 20% _pthread_mutex_firstfit_lock_wait
```

---

## Troubleshooting

### "Audio engine failed to start"
- **Cause**: Likely another app using mic
- **Fix**: Close other apps, restart Jarvis

### "Quota limit reached"
- **Cause**: Hit Apple's 1,000/hour limit
- **Expected**: Should see backoff (1s, 2s, 4s, 8s)
- **If no backoff**: Bug - report

### Screen lock not preventing
- **Check**: Console logs show "voice conversation mode enabled"
- **If not**: AudioSessionManager not initializing
- **Check**: iOS settings → Privacy → Microphone → Jarvis (enabled)

### Bluetooth audio not working
- **Check**: Headset connected in iOS Settings → Bluetooth
- **Check**: Console shows "allowBluetooth" in audio session config

---

## Quick Pass/Fail Summary

Run all 4 core tests (Tests 1-4), takes ~10 minutes total:

| Test | Mac | iOS | Duration | Status |
|------|-----|-----|----------|--------|
| 1. No lock storms | ✓ | | 5 min | ☐ |
| 2. Screen stays awake | | ✓ | 2 min | ☐ |
| 3. Error path cleanup | | ✓ | 1 min | ☐ |
| 4. Background cleanup | | ✓ | 30 sec | ☐ |

**All pass? → Phase 1 validated ✅**

**Any fail? → Check troubleshooting section, file bug report**

---

## Reporting Issues

If any test fails, capture:
1. **Console logs** (copy relevant section)
2. **Steps to reproduce**
3. **Expected vs actual behavior**
4. **Device info** (Mac/iOS version, device model)

Post in project tracking or share with team.

---

**Last Updated**: 2026-08-28
**Version**: Phase 1 (P0 fixes)
