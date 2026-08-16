"""
Code Execution Router
Claude Code capabilities via voice - full tool use (Read, Write, Edit, Bash)
"""
import base64
import json
import os
import re
from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from app.models.requests import CodeExecuteRequest
from app.models.responses import CodeExecuteResponse
from app.services.code_service import code_service

router = APIRouter(prefix="/code", tags=["code"])

UPLOADS_ROOT = "/home/ubuntu/AIS-OS/uploads"
MAX_ATTACHMENT_BYTES = 20_000_000  # 20MB per file


def _safe_filename(filename: str) -> str:
    """Strip path components and unsafe characters so attachments can't escape the uploads dir"""
    name = os.path.basename(filename)
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    return name or "file"


def _save_attachments(session_id: str, attachments) -> list[str]:
    """Decode and save uploaded files to a session-scoped directory. Returns saved paths."""
    session_dir = os.path.join(UPLOADS_ROOT, _safe_filename(session_id))
    os.makedirs(session_dir, exist_ok=True)

    saved_paths = []
    for attachment in attachments:
        try:
            data = base64.b64decode(attachment.content_base64)
        except Exception:
            raise HTTPException(status_code=400, detail=f"Invalid base64 content for {attachment.filename}")

        if len(data) > MAX_ATTACHMENT_BYTES:
            raise HTTPException(status_code=413, detail=f"{attachment.filename} exceeds {MAX_ATTACHMENT_BYTES:,} byte limit")

        safe_name = _safe_filename(attachment.filename)
        file_path = os.path.join(session_dir, safe_name)
        with open(file_path, "wb") as f:
            f.write(data)

        saved_paths.append(file_path)

    return saved_paths


def _build_query_with_attachments(request: CodeExecuteRequest) -> str:
    """Save any attachments and append their paths to the query text."""
    query = request.query
    if request.attachments:
        saved_paths = _save_attachments(request.session_id, request.attachments)
        print(f"📎 Saved {len(saved_paths)} attachment(s) for session {request.session_id}")
        attachment_note = "\n\n[Attached files - use read_file to view them]\n" + "\n".join(saved_paths)
        query = query + attachment_note
    return query


@router.post("/execute", response_model=CodeExecuteResponse)
async def execute_code(request: CodeExecuteRequest):
    """
    Execute code with full Claude Code capabilities

    This endpoint provides full tool use:
    - Read files (brain/, wiki/, any accessible file)
    - Write files (create new files)
    - Edit files (modify existing files)
    - Bash commands (run scripts, build, test)
    - Search (Grep, Glob)

    Maintains conversation memory across sessions.
    Optional file attachments are saved to a session-scoped uploads directory
    and their paths are appended to the query so Claude can read them.
    """
    try:
        print(f"💻 Code execute: query='{request.query[:100]}...', session={request.session_id}")

        query = _build_query_with_attachments(request)

        # Execute with full Claude Code capabilities
        response = await code_service.execute(
            query=query,
            session_id=request.session_id,
            max_tokens=request.max_tokens or 2048
        )

        print(f"✅ Code execution complete: {len(response.answer)} chars, {len(response.tool_calls)} tools used")

        return response

    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Code execution error: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Code execution failed: {str(e)}")


@router.post("/execute/stream")
async def execute_code_stream(request: CodeExecuteRequest):
    """
    Same as /execute, but streams the response as Server-Sent Events so the
    client can start speaking/rendering text before the full answer is ready.

    Event format (each line is `data: <json>\\n\\n`):
      {"type": "text_delta", "text": "..."}   - repeated as text generates
      {"type": "done", "answer": ..., "tool_calls": [...], "files_modified": [...], "execution_time_ms": ...}
      {"type": "error", "message": "..."}
    """
    print(f"💻 Code execute (stream): query='{request.query[:100]}...', session={request.session_id}")

    try:
        query = _build_query_with_attachments(request)
    except HTTPException as e:
        async def error_only():
            yield f"data: {json.dumps({'type': 'error', 'message': e.detail})}\n\n"
        return StreamingResponse(error_only(), media_type="text/event-stream")

    async def event_stream():
        async for event in code_service.execute_stream(
            query=query,
            session_id=request.session_id,
            max_tokens=request.max_tokens or 2048
        ):
            yield f"data: {json.dumps(event)}\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        }
    )
