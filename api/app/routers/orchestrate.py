"""
Orchestration Router
Smart routing between fast path (RAG) and agent path (reasoning)
"""
from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import Optional, AsyncGenerator
import json
import asyncio

from app.services.orchestration_agent import jarvis_agent
from app.services.jarvis_service import jarvis_service

router = APIRouter(prefix="/orchestrate", tags=["orchestration"])


class OrchestQuery(BaseModel):
    query: str
    use_agent: Optional[bool] = None  # None = auto-detect, True = force agent, False = force RAG
    conversation_id: Optional[str] = None


class OrchestResponse(BaseModel):
    answer: str
    path: str  # "fast" or "agent"
    confidence: float
    conversation_id: Optional[str] = None


def should_use_agent(query: str) -> bool:
    """
    Decide whether to use agent path or fast path

    Agent path indicators:
    - Questions (who, what, where, when, why, how)
    - Gap-filling scenarios ("I don't know", "find", "search for")
    - Complex multi-step requests
    - Explicit learning requests

    Fast path:
    - Simple factual lookups
    - Known entities
    - Direct retrieval
    """
    query_lower = query.lower()

    # Question words suggest agent path
    question_words = ["who", "what", "where", "when", "why", "how", "can you", "could you"]
    if any(q in query_lower for q in question_words):
        return True

    # Gap-filling keywords
    gap_keywords = ["find", "search for", "look for", "missing", "don't know"]
    if any(k in query_lower for k in gap_keywords):
        return True

    # Default to fast path for simple queries
    return False


@router.post("", response_model=OrchestResponse)
async def orchestrate_query(request: OrchestQuery):
    """
    Smart routing endpoint
    Routes to either fast path (RAG) or agent path (reasoning)
    Both paths now use Claude to generate natural conversational responses
    """
    try:
        # Determine path
        if request.use_agent is None:
            use_agent = should_use_agent(request.query)
        else:
            use_agent = request.use_agent

        if use_agent:
            # Agent path: Full conversational reasoning with tool use
            answer = await jarvis_agent.process_query(request.query)
            path = "agent"
            confidence = 0.85  # Agent provides high-confidence reasoned answers
        else:
            # Fast path: RAG + Claude post-processing for natural response
            answer = await jarvis_service.rag_query_with_claude(request.query, context_size=5)
            path = "fast"
            confidence = 0.80  # RAG with Claude processing provides good confidence

        return OrchestResponse(
            answer=answer,
            path=path,
            confidence=confidence,
            conversation_id=request.conversation_id
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Orchestration failed: {str(e)}")


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
            processing_task = asyncio.create_task(
                jarvis_agent.process_query(request.query) if use_agent
                else jarvis_service.rag_query_with_claude(request.query, context_size=5)
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
            answer = await processing_task

            # 6. STREAM RESPONSE IN CHUNKS
            # For now, send full response as single chunk
            # Future: implement true streaming from Claude SDK
            yield f"event: chunk\n"
            yield f"data: {json.dumps({'text': answer})}\n\n"

            # 7. FINAL COMPLETION
            confidence = 0.85 if use_agent else 0.80
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
