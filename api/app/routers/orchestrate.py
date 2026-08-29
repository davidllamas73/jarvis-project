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
