# V2 Classifier Testing Guide

## Pre-Deployment Testing

### 1. Backend Verification

First, verify the V2 endpoint is working on the backend:

```bash
# Test V2 classifier directly
curl -X POST https://18.142.241.151:8443/api/v1/orchestrate/classify-v2 \
  -H "Content-Type: application/json" \
  -d '{"query": "Hello how are you?", "enable_llm": false}' \
  --insecure

# Expected response:
{
  "query": "Hello how are you?",
  "tier": "conversational",
  "confidence": 0.95,
  "method": "fast_path",
  "latency_ms": 0.11,
  "reasoning": "Matched conversational greeting pattern",
  "alternative_tier": null,
  "similarity_scores": {...}
}
```

### 2. Build Mac App

```bash
cd /home/ubuntu/AIS-OS/mac-app/jarvis-project

# Option 1: Build in Xcode
open jarvis-project.xcodeproj

# Option 2: Build from command line (if xcrun available)
xcodebuild -scheme Jarvis -configuration Debug build
```

### 3. Run Mac App

1. Launch the app
2. Wait for wake word detection to initialize
3. Check console for startup logs

## Test Cases

### Test Case 1: Conversational Query (Fast Path)

**Query**: "Hello Jarvis"

**Expected Behavior**:
1. V2 Classification log: `tier=conversational, method=fast_path, latency<1ms`
2. Acknowledgment: "Sure" / "Okay" / "Yes"
3. Response time: <1 second
4. Returns to idle state

**Console Output**:
```
📊 V2 Classification: tier=conversational, confidence=0.95, method=fast_path, latency=0.11ms
```

### Test Case 2: Knowledge Query (RAG)

**Query**: "What were my achievements at Central Retail?"

**Expected Behavior**:
1. V2 Classification log: `tier=knowledge, method=semantic, latency<100ms`
2. Acknowledgment: "Let me check that" / "Looking that up" / "One moment"
3. RAG search executes
4. Response with achievements from second brain
5. Response time: 1-3 seconds

**Console Output**:
```
📊 V2 Classification: tier=knowledge, confidence=0.92, method=semantic, latency=75ms
```

### Test Case 3: Research Query (Background)

**Query**: "Research the latest AI developments in retail"

**Expected Behavior**:
1. V2 Classification log: `tier=research, method=semantic, latency<100ms`
2. Acknowledgment: "I'll research that for you" / "Let me look into that"
3. Background task initiated
4. Currently routes to task handler (uses executeCodeStream)
5. Response time: Variable (5-30 seconds)

**Console Output**:
```
📊 V2 Classification: tier=research, confidence=0.88, method=semantic, latency=85ms
```

### Test Case 4: Task Query (Agent)

**Query**: "Create a summary of my top 5 achievements"

**Expected Behavior**:
1. V2 Classification log: `tier=task, method=semantic, latency<100ms`
2. Acknowledgment: "Running that now" / "On it" / "Starting that task"
3. Agent executes with tool use
4. Streaming response (text deltas appear)
5. Response time: 3-15 seconds

**Console Output**:
```
📊 V2 Classification: tier=task, confidence=0.90, method=semantic, latency=92ms
```

### Test Case 5: V1 Fallback

**Simulate**: Backend V2 endpoint down or returning error

**Query**: "What time is it?"

**Expected Behavior**:
1. V2 Classification fails
2. Console log: `⚠️ V2 classification failed: <error>, falling back to V1`
3. Falls back to `processWithSSE()` (existing tiered orchestration)
4. Query completes successfully using V1

**Console Output**:
```
⚠️ V2 classification failed: URLError(.cannotConnectToHost), falling back to V1
```

### Test Case 6: Ambiguous Query

**Query**: "Tell me about optimization"

**Expected Behavior**:
1. V2 Classification may use semantic or adaptive method
2. Confidence might be lower (0.65-0.80)
3. Tier chosen based on similarity scores
4. Default to knowledge tier if uncertain

**Console Output**:
```
📊 V2 Classification: tier=knowledge, confidence=0.72, method=adaptive, latency=125ms
```

## Performance Benchmarks

### Expected Latencies

| Tier | Classification | Execution | Total |
|------|---------------|-----------|-------|
| Conversational | <1ms | 500-1000ms | <1.5s |
| Knowledge | 50-100ms | 1-3s | 1.5-3s |
| Research | 50-100ms | 5-30s (bg) | Variable |
| Task | 50-100ms | 3-15s | 3-15s |

### Classification Method Distribution (Expected)

- **fast_path**: 60-70% (conversational queries)
- **semantic**: 25-35% (knowledge/task queries)
- **adaptive**: 5-10% (ambiguous queries)
- **llm**: <1% (currently disabled, would be fallback)

## Error Handling Tests

### Test 1: Network Timeout

**Simulate**: Disconnect from network during V2 classification

**Expected**: Falls back to V1, or reports network error gracefully

### Test 2: Malformed Response

**Simulate**: Backend returns invalid JSON

**Expected**: Catches decode error, falls back to V1

### Test 3: Missing Fields

**Simulate**: Backend returns response missing required fields

**Expected**: Decode fails, falls back to V1

### Test 4: Unknown Tier

**Simulate**: Backend returns tier="unknown"

**Expected**: Default case handles, routes to knowledge handler

## Integration Tests

### Test 1: Wake Word → V2 → Response

1. Say wake word "Jarvis"
2. Wait for listening indicator
3. Say query "What are my skills?"
4. Verify V2 classification log
5. Verify appropriate tier routing
6. Verify response received
7. Verify returns to idle (wake word re-armed)

### Test 2: Barge-In During Response

1. Ask long query requiring agent
2. Wait for response to start playing
3. Interrupt with "Jarvis" wake word
4. Verify TTS stops
5. Verify can ask new query
6. Verify V2 classification still works

### Test 3: Sequential Queries

1. Ask conversational query → Wait for completion
2. Ask knowledge query → Wait for completion
3. Ask task query → Wait for completion
4. Verify state transitions correct
5. Verify no memory leaks
6. Verify wake word re-arms between queries

### Test 4: Rapid Fire Queries

1. Ask query
2. Before completion, trigger new query
3. Verify previous query cancelled gracefully
4. Verify new query processes correctly
5. Verify no state corruption

## Monitoring

### Console Logs to Watch

```swift
// V2 Classification Success
📊 V2 Classification: tier=<tier>, confidence=<0-1>, method=<method>, latency=<ms>ms

// V2 Classification Failure
⚠️ V2 classification failed: <error>, falling back to V1

// Unknown Tier
⚠️ Unknown tier: <tier>, using default handler

// Query Cancelled
⚠️ ConversationOrchestrator: query cancelled

// Error
❌ ConversationOrchestrator: error - <error>
```

### Metrics to Track

1. **V2 Success Rate**: Should be >99%
2. **Classification Latency**: Should be <100ms average
3. **Tier Distribution**: Should match expected patterns
4. **Fallback Rate**: Should be <1%
5. **User Satisfaction**: Queries complete successfully

## Regression Tests

Ensure existing functionality still works:

- [ ] Wake word detection (Porcupine)
- [ ] Speech recognition (Whisper)
- [ ] TTS playback (native synthesis)
- [ ] Barge-in detection
- [ ] Audio session management
- [ ] State machine transitions
- [ ] Error recovery
- [ ] Background task polling
- [ ] Device pairing
- [ ] Token refresh

## Production Readiness Checklist

- [ ] All test cases pass
- [ ] Performance benchmarks met
- [ ] Error handling verified
- [ ] Integration tests pass
- [ ] Regression tests pass
- [ ] Console logs clean (no unexpected errors)
- [ ] Memory usage stable (no leaks)
- [ ] CPU usage reasonable (<20% idle)
- [ ] Battery impact minimal
- [ ] Wake word false positive rate low (<1/hour)
- [ ] User experience smooth (no stuttering)

## Known Issues

1. **Research tier**: Currently routes to task handler, not dedicated research endpoint
2. **Background progress**: No visual indicator for background tasks
3. **LLM fallback**: Disabled in V2 (enableLlm: false)

## Troubleshooting

### Issue: V2 always falls back to V1

**Possible Causes**:
- Backend V2 endpoint not deployed
- Network connectivity issues
- Self-signed cert validation failing
- Endpoint URL incorrect

**Fix**:
```bash
# Check backend status
curl -X GET https://18.142.241.151:8443/api/v1/system/health --insecure

# Verify V2 endpoint exists
curl -X POST https://18.142.241.151:8443/api/v1/orchestrate/classify-v2 \
  -H "Content-Type: application/json" \
  -d '{"query": "test"}' \
  --insecure
```

### Issue: Classification latency >1 second

**Possible Causes**:
- Backend overloaded
- Network latency high
- Using LLM method (should be disabled)

**Fix**:
- Check backend CPU/memory
- Check network latency
- Verify enableLlm: false

### Issue: Wrong tier assigned

**Possible Causes**:
- Query pattern not recognized
- Similarity scores close
- Need to retrain embeddings

**Fix**:
- Check console for similarity scores
- Verify tier makes sense for query
- Report to backend team if consistently wrong

### Issue: App crashes on query

**Possible Causes**:
- Malformed response from backend
- Decode error
- Memory issue

**Fix**:
- Check console for crash log
- Verify response JSON structure
- Check for nil unwrapping issues

## Support

For issues or questions:
1. Check console logs for errors
2. Verify backend endpoint status
3. Review V2-CLASSIFIER-INTEGRATION.md
4. Contact backend team if API issue
5. File bug report with logs if app issue
