"""
Orchestration Router
Smart routing between fast path (RAG) and agent path (reasoning)
with async background task support for long-running queries
"""
from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import Optional, AsyncGenerator
import json
import asyncio

from app.services.orchestration_agent import jarvis_agent
from app.services.jarvis_service import jarvis_service
from app.services.task_store import task_store, TaskStatus
from app.services.query_classifier import query_classifier, QueryTier

router = APIRouter(prefix="/orchestrate", tags=["orchestration"])


class OrchestQuery(BaseModel):
    query: str
    use_agent: Optional[bool] = None  # None = auto-detect, True = force agent, False = force RAG
    conversation_id: Optional[str] = None


class OrchestResponse(BaseModel):
    answer: str
    path: str  # "fast", "agent", or "background"
    confidence: float
    conversation_id: Optional[str] = None
    needs_background: bool = False  # NEW: signals client to poll for result
    task_id: Optional[str] = None   # NEW: task ID for polling


class TaskStatusResponse(BaseModel):
    """Response for task status polling"""
    task_id: str
    status: str  # pending | running | done | failed
    result: Optional[str] = None
    error: Optional[str] = None


def should_use_agent(query: str) -> bool:
    """
    Decide whether to use agent path or fast path

    Agent path is Claude with tool use (search_knowledge_base, find_documents,
    extract_from_pdf, update_wiki_entity) in a loop - two-plus full Claude API
    round trips per query, ~15-20s typical. Reserved for requests that actually
    need to hunt for or write information, not plain questions.

    Fast path is a single Claude-post-processed RAG call (~4-5s typical) - it
    already handles ordinary "what/who/how/can you tell me" questions well,
    since it's Claude reasoning over retrieved context, not raw retrieval.

    Previously almost every question word ("what", "how", "can you", ...)
    routed to the agent path, since ordinary spoken queries are overwhelmingly
    phrased as questions - this made the slow path the default for most real
    voice traffic instead of the exception.
    """
    query_lower = query.lower()

    # Explicit multi-step / gap-filling requests still need the agent's tools
    agent_keywords = [
        "search for", "look for", "find and update",
        "missing", "don't know", "update my wiki", "update the wiki",
        "extract from", "update wiki"
    ]
    if any(k in query_lower for k in agent_keywords):
        return True

    # Everything else - including plain factual questions - defaults to the
    # fast path.
    return False


def generate_interim_response(query: str) -> str:
    """
    Generate friendly interim response when falling back to background agent mode.

    Returns short, natural phrase for immediate TTS while background task runs.
    """
    query_lower = query.lower()

    # Search/find queries
    if any(word in query_lower for word in ["search", "find", "look for"]):
        return "I'm not fully sure, let me search through everything and get back to you"

    # Complex analysis
    if any(word in query_lower for word in ["analyze", "compare", "how does"]):
        return "That's a good question. Let me look into that further and I'll let you know"

    # Default
    return "I'm not fully sure about that. Let me research it and get back to you"


async def _run_agent_task(task_id: str, query: str):
    """
    Background task runner - executes agent query asynchronously

    Runs in fire-and-forget mode (not awaited by request handler).
    Updates task_store with result or error when done.
    """
    try:
        print(f"🔥 Background task {task_id} starting...")
        task_store.mark_running(task_id)

        # Run the full agent path (multi-step tool use, can take 15-30s+)
        result = await jarvis_agent.process_query(query)

        task_store.mark_done(task_id, result)
        print(f"✅ Background task {task_id} completed successfully")

    except Exception as e:
        error_msg = f"Agent task failed: {str(e)}"
        task_store.mark_failed(task_id, error_msg)
        print(f"❌ Background task {task_id} failed: {error_msg}")


@router.post("", response_model=OrchestResponse)
async def orchestrate_query(request: OrchestQuery):
    """
    Smart routing endpoint with async background task support

    Flow:
    1. If explicit agent keywords OR user forces agent: background mode
    2. Otherwise: try fast path
    3. If fast path confidence < 0.7: fall back to background mode
    4. Background mode: return immediately with task_id, kick off agent in background

    Routes to either fast path (RAG) or background agent path (tool use)
    """
    try:
        # Check for explicit agent keywords (always goes to background)
        if request.use_agent is None:
            force_agent = should_use_agent(request.query)
        else:
            force_agent = request.use_agent

        if force_agent:
            # Explicit agent keywords - skip fast path, go straight to background
            print(f"🎯 Agent keywords detected, going to background mode")
            task = task_store.create(request.query)
            asyncio.create_task(_run_agent_task(task.task_id, request.query))

            return OrchestResponse(
                answer=generate_interim_response(request.query),
                path="background",
                confidence=0.0,  # Not based on RAG match
                conversation_id=request.conversation_id,
                needs_background=True,
                task_id=task.task_id
            )

        # Try fast path first
        print(f"🏃 Trying fast path for: '{request.query[:50]}...'")
        answer, confidence = await jarvis_service.rag_query_with_claude(
            request.query,
            context_size=5,
            conversation_id=request.conversation_id
        )

        print(f"📊 Fast path result: confidence={confidence:.3f}")

        # Adaptive threshold accounts for embedding quality reality
        # Before async implementation: fake confidence scores (0.80/0.85) hid this issue
        # After: real ChromaDB scores exposed that wiki embeddings return 0.15-0.40 for valid matches
        # Agent's internal search achieves 0.35-0.42 for same queries (better query formulation)
        # Setting to 0.15 allows most valid matches through fast path
        # Lower matches go to background agent which finds better results
        CONFIDENCE_THRESHOLD = 0.15

        # If confidence is good, return immediately
        if confidence >= CONFIDENCE_THRESHOLD:
            print(f"✅ Fast path succeeded (confidence {confidence:.3f} >= {CONFIDENCE_THRESHOLD})")
            return OrchestResponse(
                answer=answer,
                path="fast",
                confidence=confidence,
                conversation_id=request.conversation_id,
                needs_background=False
            )

        # Low confidence - fall back to background agent mode
        print(f"⚠️ Fast path low confidence ({confidence:.3f} < {CONFIDENCE_THRESHOLD}), falling back to background agent")
        task = task_store.create(request.query)
        asyncio.create_task(_run_agent_task(task.task_id, request.query))

        return OrchestResponse(
            answer=generate_interim_response(request.query),
            path="background",
            confidence=confidence,
            conversation_id=request.conversation_id,
            needs_background=True,
            task_id=task.task_id
        )

    except Exception as e:
        print(f"❌ Orchestration error: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Orchestration failed: {str(e)}")


@router.get("/tasks/{task_id}", response_model=TaskStatusResponse)
async def get_task_status(task_id: str):
    """
    Poll endpoint for background task status

    Client polls this every ~3s while waiting for background result.
    Returns task status and result/error when complete.
    """
    task = task_store.get(task_id)

    if not task:
        raise HTTPException(status_code=404, detail=f"Task {task_id} not found")

    return TaskStatusResponse(
        task_id=task.task_id,
        status=task.status.value,
        result=task.result,
        error=task.error
    )


@router.post("/reset")
async def reset_conversation():
    """Reset agent conversation history"""
    jarvis_agent.reset_conversation()
    return {"status": "conversation reset"}


def generate_acknowledgment(query: str) -> str:
    """
    Generate context-aware acknowledgment for immediate TTS feedback.

    Returns short, natural acknowledgment (<500ms to speak) based on query content.
    """
    query_lower = query.lower()

    # Search/find queries
    if any(word in query_lower for word in ["search", "find", "look for"]):
        return "Let me search for that"

    # Information queries (what, who, how)
    if query_lower.startswith("what") or "what " in query_lower:
        return "Let me look that up"
    elif query_lower.startswith("who") or "who " in query_lower:
        return "Let me check"
    elif query_lower.startswith("how") or "how " in query_lower:
        return "Let me see"
    elif query_lower.startswith("where") or "where " in query_lower:
        return "Let me find that"
    elif query_lower.startswith("when") or "when " in query_lower:
        return "Let me check the timeline"

    # Achievements, career, records
    if any(word in query_lower for word in ["achievement", "career", "experience", "work"]):
        return "Let me check your records"

    # Email, message, draft
    if any(word in query_lower for word in ["email", "message", "draft", "write"]):
        return "I'll draft that for you"

    # Analysis, comparison
    if any(word in query_lower for word in ["analyze", "compare", "difference", "versus"]):
        return "Let me analyze that"

    # Default generic acknowledgment
    return "One moment"


@router.post("/stream")
async def orchestrate_stream(request: OrchestQuery):
    """
    Streaming orchestration with immediate acknowledgment and progressive updates.

    Server-Sent Events (SSE) flow:
    1. event: ack → Immediate acknowledgment text for TTS (<500ms)
    2. event: status → Optional progress update (if processing >8s)
    3. event: chunk → Response text chunks as they arrive
    4. event: done → Final completion with full answer and metadata

    This eliminates awkward silence during long queries (10-15s agent path).
    Client speaks acknowledgment immediately while processing in background.
    """
    async def event_generator() -> AsyncGenerator[str, None]:
        try:
            # 1. IMMEDIATE ACKNOWLEDGMENT (<500ms)
            ack_text = generate_acknowledgment(request.query)
            yield f"event: ack\n"
            yield f"data: {json.dumps({'text': ack_text})}\n\n"

            # 2. DETERMINE PROCESSING PATH
            if request.use_agent is None:
                use_agent = should_use_agent(request.query)
            else:
                use_agent = request.use_agent

            path = "agent" if use_agent else "fast"

            # 3. START PROCESSING (potentially long-running)
            if use_agent:
                processing_task = asyncio.create_task(
                    jarvis_agent.process_query(request.query)
                )
            else:
                processing_task = asyncio.create_task(
                    jarvis_service.rag_query_with_claude(request.query, context_size=5)
                )

            # 4. OPTIONAL PROGRESS UPDATE (if >8s)
            progress_sent = False
            for _ in range(16):  # Check every 0.5s for 8s total
                await asyncio.sleep(0.5)
                if processing_task.done():
                    break
                if not progress_sent and _ == 15:  # 8 seconds elapsed
                    progress_sent = True
                    yield f"event: status\n"
                    yield f"data: {json.dumps({'text': 'Still working on that'})}\n\n"

            # 5. GET RESULT
            result = await processing_task

            # Handle tuple return from fast path (answer, confidence)
            if isinstance(result, tuple):
                answer, confidence = result
            else:
                answer = result
                confidence = 0.85

            # 6. STREAM RESPONSE IN CHUNKS
            # For now, send full response as single chunk
            # Future: implement true streaming from Claude SDK
            yield f"event: chunk\n"
            yield f"data: {json.dumps({'text': answer})}\n\n"

            # 7. FINAL COMPLETION
            yield f"event: done\n"
            yield f"data: {json.dumps({
                'answer': answer,
                'path': path,
                'confidence': confidence,
                'conversation_id': request.conversation_id
            })}\n\n"

        except Exception as e:
            # Error event
            yield f"event: error\n"
            yield f"data: {json.dumps({'message': str(e)})}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"  # Disable nginx buffering
        }
    )


# ============================================================================
# TIERED ROUTING (4-Tier Architecture)
# ============================================================================

class TieredOrchestQuery(BaseModel):
    query: str
    conversation_id: Optional[str] = None
    force_tier: Optional[str] = None  # Optional override: "conversational", "knowledge", "research", "task"


class TieredOrchestResponse(BaseModel):
    answer: str
    tier: str  # "conversational", "knowledge", "research", or "task"
    confidence: float
    path: str  # "direct", "rag", "web", "agent"
    latency_ms: int
    conversation_id: Optional[str] = None
    acknowledgment: Optional[str] = None  # Immediate response for TTS
    needs_background: bool = False
    task_id: Optional[str] = None


def generate_tier_acknowledgment(tier: QueryTier, query: str) -> str:
    """
    Generate tier-specific acknowledgment for immediate TTS feedback.

    Meets 200-300ms human baseline for natural conversation flow.
    """
    if tier == QueryTier.CONVERSATIONAL:
        # No acknowledgment - respond immediately
        return None

    elif tier == QueryTier.KNOWLEDGE:
        # "Let me look that up..." (personal knowledge)
        query_lower = query.lower()
        if any(word in query_lower for word in ["achievement", "accomplishment", "work", "role"]):
            return "Let me check your records"
        elif any(word in query_lower for word in ["who is", "tell me about"]):
            return "Let me look that up"
        else:
            return "Let me check that for you"

    elif tier == QueryTier.RESEARCH:
        # "Let me search for that..." (external knowledge)
        query_lower = query.lower()
        if any(word in query_lower for word in ["latest", "recent", "news"]):
            return "Let me find the latest information"
        elif any(word in query_lower for word in ["what is", "who is"]):
            return "Let me search for that"
        else:
            return "Let me look that up online"

    elif tier == QueryTier.TASK:
        # "Let me complete that for you now..." (complex task)
        query_lower = query.lower()
        if any(word in query_lower for word in ["write", "draft", "compose"]):
            return "I'll draft that for you"
        elif any(word in query_lower for word in ["analyze", "review", "assess"]):
            return "Let me analyze that for you"
        elif any(word in query_lower for word in ["code", "implement", "build"]):
            return "I'll work on that now"
        else:
            return "Let me complete that for you"

    return None


async def handle_conversational_query(query: str, conversation_id: Optional[str]) -> tuple[str, float]:
    """
    T1: Conversational handler - Direct Claude response (no tools)

    Uses Claude Haiku for fast, natural conversation.
    Target latency: <500ms TTFT
    Cost: ~$0.0001/query
    """
    from anthropic import AsyncAnthropic
    import os

    client = AsyncAnthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))

    # Simple system prompt for conversational queries
    system_prompt = """You are Jarvis, David Llamas' personal AI assistant.

You are helpful, friendly, and conversational. Keep responses natural and concise.
For simple greetings and pleasantries, respond warmly and briefly."""

    try:
        response = await client.messages.create(
            model="claude-haiku-4-20250514",  # Fast, cheap model for T1
            max_tokens=150,  # Short responses for conversational queries
            system=system_prompt,
            messages=[{
                "role": "user",
                "content": query
            }]
        )

        answer = response.content[0].text
        confidence = 0.95  # High confidence for conversational matches

        return answer, confidence

    except Exception as e:
        print(f"❌ Conversational handler error: {str(e)}")
        return "I'm having trouble right now. Could you try again?", 0.5


async def handle_knowledge_query(query: str, conversation_id: Optional[str]) -> tuple[str, float]:
    """
    T2: Knowledge handler - Haiku + RAG (wiki/brain)

    Uses existing jarvis_service RAG pipeline with Haiku for faster response.
    Target latency: 2-5s
    Cost: ~$0.002/query
    """
    # Use existing RAG service (already optimized for personal knowledge)
    answer, confidence = await jarvis_service.rag_query_with_claude(
        query,
        context_size=5,
        conversation_id=conversation_id
    )

    return answer, confidence


async def handle_research_query(query: str, conversation_id: Optional[str]) -> tuple[str, float]:
    """
    T3: Research handler - Sonnet + Web search

    Performs web search and uses Claude Sonnet for synthesis.
    Target latency: 5-10s
    Cost: ~$0.03/query

    TODO: Integrate actual web search capability (Perplexity API, Tavily, or similar)
    For now, falls back to agent path which can use web search tools.
    """
    # Placeholder - fall back to agent path for now
    # In production, would integrate web search API here
    print(f"⚠️ Research tier not fully implemented - falling back to agent path")
    result = await jarvis_agent.process_query(query)
    return result, 0.75


async def handle_task_query(query: str, conversation_id: Optional[str]) -> tuple[str, float]:
    """
    T4: Task handler - Full agent with tools

    Uses existing orchestration_agent with full tool access.
    Target latency: 10-90s
    Cost: ~$0.10/query
    """
    # Use existing agent path (already has all the tools)
    result = await jarvis_agent.process_query(query)
    return result, 0.85


@router.post("/tiered", response_model=TieredOrchestResponse)
async def orchestrate_tiered_query(request: TieredOrchestQuery):
    """
    4-Tier routing endpoint with query classification

    Flow:
    1. Classify query into tier (T1-T4) using rule-based classifier
    2. Generate tier-appropriate acknowledgment
    3. Route to appropriate handler:
       - T1 (Conversational): Direct Claude Haiku, no tools
       - T2 (Knowledge): Haiku + RAG (wiki/brain)
       - T3 (Research): Sonnet + Web search
       - T4 (Task): Full agent with tools
    4. Return response with tier metadata

    Latency targets:
    - T1: <500ms (immediate)
    - T2: 2-5s (quick lookup)
    - T3: 5-10s (web search)
    - T4: 10-90s (complex task)
    """
    import time
    start_time = time.time()

    try:
        # 1. CLASSIFY QUERY
        if request.force_tier:
            # Manual override for testing
            tier = QueryTier(request.force_tier)
            confidence = 1.0
            print(f"🎯 Forced tier: {tier}")
        else:
            # Automatic classification
            tier, confidence = query_classifier.classify(request.query)
            print(f"🎯 Classified as {tier} (confidence={confidence:.2f})")

        # 2. GENERATE ACKNOWLEDGMENT
        acknowledgment = generate_tier_acknowledgment(tier, request.query)

        # 3. ROUTE TO HANDLER
        if tier == QueryTier.CONVERSATIONAL:
            answer, handler_confidence = await handle_conversational_query(
                request.query,
                request.conversation_id
            )
            path = "direct"

        elif tier == QueryTier.KNOWLEDGE:
            answer, handler_confidence = await handle_knowledge_query(
                request.query,
                request.conversation_id
            )
            path = "rag"

        elif tier == QueryTier.RESEARCH:
            answer, handler_confidence = await handle_research_query(
                request.query,
                request.conversation_id
            )
            path = "web"

        elif tier == QueryTier.TASK:
            # For complex tasks, consider background mode
            query_lower = request.query.lower()
            is_very_complex = any(word in query_lower for word in [
                "analyze all", "write a detailed", "create a comprehensive",
                "research and", "build a", "implement"
            ])

            if is_very_complex:
                # Background mode for very long tasks
                task = task_store.create(request.query)
                asyncio.create_task(_run_agent_task(task.task_id, request.query))

                latency_ms = int((time.time() - start_time) * 1000)

                return TieredOrchestResponse(
                    answer=acknowledgment or "I'll work on that now and get back to you",
                    tier=tier.value,
                    confidence=confidence,
                    path="agent_background",
                    latency_ms=latency_ms,
                    conversation_id=request.conversation_id,
                    acknowledgment=acknowledgment,
                    needs_background=True,
                    task_id=task.task_id
                )
            else:
                # Synchronous agent for reasonable tasks
                answer, handler_confidence = await handle_task_query(
                    request.query,
                    request.conversation_id
                )
                path = "agent"

        else:
            raise ValueError(f"Unknown tier: {tier}")

        # 4. RETURN RESPONSE
        latency_ms = int((time.time() - start_time) * 1000)

        print(f"✅ Tier {tier} completed in {latency_ms}ms (path={path})")

        return TieredOrchestResponse(
            answer=answer,
            tier=tier.value,
            confidence=confidence,
            path=path,
            latency_ms=latency_ms,
            conversation_id=request.conversation_id,
            acknowledgment=acknowledgment,
            needs_background=False
        )

    except Exception as e:
        latency_ms = int((time.time() - start_time) * 1000)
        print(f"❌ Tiered orchestration error: {str(e)}")
        raise HTTPException(
            status_code=500,
            detail=f"Tiered orchestration failed: {str(e)}"
        )


@router.post("/tiered/stream")
async def orchestrate_tiered_stream(request: TieredOrchestQuery):
    """
    Streaming 4-Tier routing endpoint with immediate acknowledgment

    Server-Sent Events (SSE) flow:
    1. event: tier → Classification result (tier, confidence)
    2. event: ack → Immediate acknowledgment for TTS (if tier > T1)
    3. event: chunk → Response text as it arrives
    4. event: done → Final completion with metadata

    This enables natural conversation flow:
    - T1: Immediate response (no ack needed)
    - T2: "Let me look that up..." → result
    - T3: "Let me search for that..." → result
    - T4: "I'll complete that for you..." → result
    """
    async def event_generator() -> AsyncGenerator[str, None]:
        import time
        start_time = time.time()

        try:
            # 1. CLASSIFY QUERY
            if request.force_tier:
                tier = QueryTier(request.force_tier)
                confidence = 1.0
            else:
                tier, confidence = query_classifier.classify(request.query)

            print(f"🎯 Stream classified as {tier} (confidence={confidence:.2f})")

            # Send tier classification
            yield f"event: tier\n"
            yield f"data: {json.dumps({'tier': tier.value, 'confidence': confidence})}\n\n"

            # 2. GENERATE AND SEND ACKNOWLEDGMENT (if needed)
            acknowledgment = generate_tier_acknowledgment(tier, request.query)
            if acknowledgment:
                yield f"event: ack\n"
                yield f"data: {json.dumps({'text': acknowledgment})}\n\n"

            # 3. PROCESS QUERY
            if tier == QueryTier.CONVERSATIONAL:
                answer, handler_confidence = await handle_conversational_query(
                    request.query,
                    request.conversation_id
                )
                path = "direct"

            elif tier == QueryTier.KNOWLEDGE:
                answer, handler_confidence = await handle_knowledge_query(
                    request.query,
                    request.conversation_id
                )
                path = "rag"

            elif tier == QueryTier.RESEARCH:
                answer, handler_confidence = await handle_research_query(
                    request.query,
                    request.conversation_id
                )
                path = "web"

            elif tier == QueryTier.TASK:
                # Check if very complex (needs background)
                query_lower = request.query.lower()
                is_very_complex = any(word in query_lower for word in [
                    "analyze all", "write a detailed", "create a comprehensive",
                    "research and", "build a", "implement"
                ])

                if is_very_complex:
                    # Background mode
                    task = task_store.create(request.query)
                    asyncio.create_task(_run_agent_task(task.task_id, request.query))

                    # Send background notification
                    yield f"event: background\n"
                    yield f"data: {json.dumps({'task_id': task.task_id, 'message': 'Working on this in the background'})}\n\n"

                    latency_ms = int((time.time() - start_time) * 1000)

                    # Send done event
                    yield f"event: done\n"
                    yield f"data: {json.dumps({
                        'tier': tier.value,
                        'path': 'agent_background',
                        'latency_ms': latency_ms,
                        'needs_background': True,
                        'task_id': task.task_id
                    })}\n\n"

                    return

                else:
                    # Synchronous task
                    answer, handler_confidence = await handle_task_query(
                        request.query,
                        request.conversation_id
                    )
                    path = "agent"

            else:
                raise ValueError(f"Unknown tier: {tier}")

            # 4. STREAM RESPONSE
            # For now, send full response (future: implement true streaming)
            yield f"event: chunk\n"
            yield f"data: {json.dumps({'text': answer})}\n\n"

            # 5. FINAL COMPLETION
            latency_ms = int((time.time() - start_time) * 1000)

            yield f"event: done\n"
            yield f"data: {json.dumps({
                'answer': answer,
                'tier': tier.value,
                'confidence': confidence,
                'path': path,
                'latency_ms': latency_ms,
                'conversation_id': request.conversation_id
            })}\n\n"

            print(f"✅ Tier {tier} stream completed in {latency_ms}ms (path={path})")

        except Exception as e:
            # Error event
            yield f"event: error\n"
            yield f"data: {json.dumps({'message': str(e)})}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"
        }
    )
