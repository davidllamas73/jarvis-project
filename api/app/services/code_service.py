"""
Code Execution Service - Enhanced with Conversational AI & Self-Learning
Full Claude Code capabilities + Memory + Activity Logging
"""
import os
import time
import subprocess
from typing import List, Dict, Any, Optional
from anthropic import AsyncAnthropic
from app.models.responses import CodeExecuteResponse, ToolCall
from app.config import settings


class CodeExecutionService:
    """
    Service for executing code with full Claude Code capabilities

    Enhanced Features:
    - Conversational dialogue (not just Q&A)
    - Self-learning mode (corrections, preferences)
    - Activity logging (comprehensive timeline)
    - Proactive suggestions (next actions)
    - Clarifying questions (ambiguity handling)

    Tools available:
    - read_file: Read any file (brain/, wiki/, codebase)
    - write_file: Create new files
    - run_bash: Execute bash commands
    - list_files: Explore directories
    - analyze_image: OCR/document extraction
    - register_correction: Accept user corrections
    - log_activity_event: Log activities manually
    - query_activity_log: Search activity history
    """

    def __init__(self):
        self.client = AsyncAnthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))
        self.conversations: Dict[str, List[Dict]] = {}
        self.max_history_turns = 5  # Reduced from 10 to prevent context explosion

        # Base paths for knowledge access
        self.brain_path = "/home/ubuntu/AIS-OS/brain"
        self.wiki_path = "/home/ubuntu/AIS-OS/wiki"
        self.workspace_path = "/home/ubuntu/AIS-OS"

    def _get_tools(self) -> List[Dict[str, Any]]:
        """Define available tools for Claude"""
        return [
            {
                "name": "read_file",
                "description": "Read contents of a file. Use for accessing brain knowledge, wiki pages, or any file.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "file_path": {
                            "type": "string",
                            "description": "Absolute path to file (e.g., /home/ubuntu/AIS-OS/brain/file.txt)"
                        }
                    },
                    "required": ["file_path"]
                }
            },
            {
                "name": "write_file",
                "description": "Create a new file with content",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "file_path": {
                            "type": "string",
                            "description": "Absolute path for new file"
                        },
                        "content": {
                            "type": "string",
                            "description": "File content"
                        }
                    },
                    "required": ["file_path", "content"]
                }
            },
            {
                "name": "run_bash",
                "description": "Execute a bash command. Use for running scripts, building code, testing, etc.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "command": {
                            "type": "string",
                            "description": "Bash command to execute"
                        },
                        "cwd": {
                            "type": "string",
                            "description": "Working directory (optional)"
                        }
                    },
                    "required": ["command"]
                }
            },
            {
                "name": "list_files",
                "description": "List files in a directory (useful for exploring brain/ or wiki/)",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "directory": {
                            "type": "string",
                            "description": "Directory path to list"
                        },
                        "pattern": {
                            "type": "string",
                            "description": "Optional glob pattern (e.g., '*.md')"
                        }
                    },
                    "required": ["directory"]
                }
            },
            {
                "name": "analyze_image",
                "description": "Extract text and information from images (passport, ID, document scans, etc.) using Claude Vision. Much faster and more accurate than bash OCR tools.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "image_path": {
                            "type": "string",
                            "description": "Path to image file (JPG, PNG, PDF)"
                        },
                        "question": {
                            "type": "string",
                            "description": "Optional: specific question about the image (default: extract all text)"
                        }
                    },
                    "required": ["image_path"]
                }
            },
            {
                "name": "register_correction",
                "description": "Register a user correction or knowledge update. Use when David corrects information or provides new facts to remember.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "correction_type": {
                            "type": "string",
                            "description": "Type of change: 'correction', 'addition', or 'deletion'",
                            "enum": ["correction", "addition", "deletion"]
                        },
                        "category": {
                            "type": "string",
                            "description": "Category: 'identity', 'entity', 'concept', or 'event'",
                            "enum": ["identity", "entity", "concept", "event"]
                        },
                        "old_value": {
                            "type": "string",
                            "description": "Current/incorrect value (or empty string for additions)"
                        },
                        "new_value": {
                            "type": "string",
                            "description": "Corrected/new value"
                        },
                        "source_file": {
                            "type": "string",
                            "description": "Optional: file path to update (e.g., /home/ubuntu/AIS-OS/brain/identity/david_llamas_identity.md)"
                        }
                    },
                    "required": ["correction_type", "category", "old_value", "new_value"]
                }
            },
            {
                "name": "log_activity_event",
                "description": "Log an activity event manually (meeting, email, appointment, etc.). Use when David mentions an event that should be remembered.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "event_type": {
                            "type": "string",
                            "description": "Type of event: meeting, email, call, appointment, etc."
                        },
                        "participants": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "People involved"
                        },
                        "context": {
                            "type": "object",
                            "description": "Event context (subject, topic, location, etc.)"
                        },
                        "outcome": {
                            "type": "object",
                            "description": "Outcome (decisions, action_items, etc.)"
                        },
                        "tags": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Tags for categorization"
                        }
                    },
                    "required": ["event_type"]
                }
            },
            {
                "name": "query_activity_log",
                "description": "Search activity history. Use to answer questions about past events, meetings, conversations.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Search query"
                        },
                        "event_type": {
                            "type": "string",
                            "description": "Filter by event type (optional)"
                        },
                        "date_from": {
                            "type": "string",
                            "description": "Start date ISO format (optional)"
                        },
                        "date_to": {
                            "type": "string",
                            "description": "End date ISO format (optional)"
                        },
                        "limit": {
                            "type": "integer",
                            "description": "Maximum results (default 20)"
                        }
                    }
                }
            },
            {
                "name": "get_daily_summary",
                "description": "Get a summary of today's activities, conversations, and events. Use when David asks about his day.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "date": {
                            "type": "string",
                            "description": "Date in YYYY-MM-DD format (optional, defaults to today)"
                        }
                    }
                }
            }
        ]

    async def _update_dialogue_state_from_conversation(self, query: str, response: str):
        """Extract entities and topics from conversation and update dialogue state"""
        from app.services.memory_service import memory_service
        import re

        # Simple entity extraction (names, companies mentioned)
        entities = []

        # Look for proper nouns (capitalized words)
        text = query + " " + response
        words = re.findall(r'\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\b', text)

        # Filter common words and keep likely entities
        common_words = {'I', 'You', 'The', 'This', 'That', 'What', 'When', 'Where', 'Why', 'How', 'Can', 'Should', 'Would', 'Could', 'Jarvis', 'David'}
        entities = [w for w in words if w not in common_words and len(w) > 2][:10]  # Max 10

        # Extract topic (simple heuristic: first noun phrase in query)
        topic = None
        if "about" in query.lower():
            topic_match = re.search(r'about\s+([A-Za-z\s]+?)[\?.,]', query, re.IGNORECASE)
            if topic_match:
                topic = topic_match.group(1).strip()

        # Update dialogue state
        if entities or topic:
            await memory_service.update_dialogue_state(
                topic=topic,
                entities=entities if entities else None
            )

    async def _execute_tool(self, tool_name: str, tool_input: Dict[str, Any]) -> str:
        """Execute a tool and return result"""
        try:
            if tool_name == "read_file":
                file_path = tool_input["file_path"]

                # Check file size before reading
                file_size = os.path.getsize(file_path)
                max_size = 2_000_000  # 2MB limit (prevents huge files)

                if file_size > max_size:
                    # For large files, only read first and last portions
                    with open(file_path, 'r', encoding='utf-8') as f:
                        lines = f.readlines()

                    if len(lines) > 1000:
                        # Show first 200 and last 200 lines
                        preview = ''.join(lines[:200])
                        preview += f"\n\n... [FILE TOO LARGE: {len(lines)} lines, {file_size:,} bytes] ...\n"
                        preview += f"... [Showing first 200 and last 200 lines only] ...\n\n"
                        preview += ''.join(lines[-200:])
                        return preview
                    else:
                        # If under 1000 lines, read all
                        return ''.join(lines)
                else:
                    # Small file, read normally
                    with open(file_path, 'r', encoding='utf-8') as f:
                        content = f.read()
                    return content

            elif tool_name == "write_file":
                file_path = tool_input["file_path"]
                content = tool_input["content"]
                os.makedirs(os.path.dirname(file_path), exist_ok=True)
                with open(file_path, 'w', encoding='utf-8') as f:
                    f.write(content)
                return f"File created: {file_path}"

            elif tool_name == "run_bash":
                command = tool_input["command"]
                cwd = tool_input.get("cwd", self.workspace_path)
                result = subprocess.run(
                    command,
                    shell=True,
                    cwd=cwd,
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                output = result.stdout if result.returncode == 0 else result.stderr

                # Truncate very large bash outputs
                MAX_BASH_OUTPUT = 100_000  # 100KB max
                if output and len(output) > MAX_BASH_OUTPUT:
                    lines = output.split('\n')
                    if len(lines) > 500:
                        # Show first 200 and last 100 lines
                        truncated = '\n'.join(lines[:200])
                        truncated += f"\n\n... [OUTPUT TRUNCATED: {len(lines)} lines total, showing first 200 and last 100] ...\n\n"
                        truncated += '\n'.join(lines[-100:])
                        output = truncated
                    else:
                        # Just truncate by chars
                        output = output[:MAX_BASH_OUTPUT] + f"\n\n... [TRUNCATED: {len(output):,} chars total] ..."

                return f"Exit code: {result.returncode}\n{output}"

            elif tool_name == "list_files":
                directory = tool_input["directory"]
                pattern = tool_input.get("pattern", "*")
                result = subprocess.run(
                    f"ls -lah {directory}/{pattern}",
                    shell=True,
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                return result.stdout if result.returncode == 0 else "Directory not found"

            elif tool_name == "analyze_image":
                from app.services.vision_service import vision_service
                image_path = tool_input["image_path"]
                question = tool_input.get("question")
                result = await vision_service.analyze_document(image_path, question)
                return result

            elif tool_name == "register_correction":
                from app.services.memory_service import memory_service
                correction = await memory_service.register_correction(
                    correction_type=tool_input["correction_type"],
                    category=tool_input["category"],
                    old_value=tool_input["old_value"],
                    new_value=tool_input["new_value"],
                    source_file=tool_input.get("source_file"),
                    session_id=tool_input.get("session_id")
                )
                # Auto-approve and apply user-stated corrections
                await memory_service.approve_correction(correction.id)
                result = await memory_service.apply_correction(correction.id)
                return f"Correction registered and applied: {correction.id}\nFiles modified: {result.get('files_modified', [])}"

            elif tool_name == "log_activity_event":
                from app.services.activity_service import activity_service
                event = await activity_service.log_event(
                    event_type=tool_input["event_type"],
                    participants=tool_input.get("participants"),
                    context=tool_input.get("context"),
                    outcome=tool_input.get("outcome"),
                    tags=tool_input.get("tags")
                )
                return f"Activity logged: {event.id}"

            elif tool_name == "query_activity_log":
                from app.services.activity_service import activity_service
                events = await activity_service.query_events(
                    query=tool_input.get("query"),
                    event_type=tool_input.get("event_type"),
                    date_from=tool_input.get("date_from"),
                    date_to=tool_input.get("date_to"),
                    limit=tool_input.get("limit", 20)
                )
                import json
                return json.dumps(events, indent=2)

            elif tool_name == "get_daily_summary":
                from app.services.activity_service import activity_service
                from app.services.memory_service import memory_service
                from datetime import datetime
                import json

                # Get date (default to today)
                date = tool_input.get("date")
                if not date:
                    date = datetime.utcnow().strftime("%Y-%m-%d")

                # Get activity summary
                activity_summary = await activity_service.get_daily_summary(date)

                # Get pending corrections
                pending = await memory_service.get_pending_corrections()

                # Build comprehensive summary
                summary = {
                    "date": date,
                    "total_events": activity_summary.get("total_events", 0),
                    "by_type": activity_summary.get("by_type", {}),
                    "participants": activity_summary.get("participants", []),
                    "key_outcomes": activity_summary.get("key_outcomes", []),
                    "pending_corrections": len(pending),
                    "learning_summary": f"{len(pending)} corrections pending approval" if pending else "All corrections processed"
                }

                return json.dumps(summary, indent=2)

            else:
                return f"Unknown tool: {tool_name}"

        except Exception as e:
            return f"Tool error: {str(e)}"

    async def _build_prompt_context(self, session_id: str, query: str):
        """
        Shared setup for execute() and execute_stream(): system prompt, cached wiki
        index, and message history. Kept in one place so both paths stay in sync.
        """
        # Load dialogue state
        from app.services.memory_service import memory_service
        dialogue_state = await memory_service.get_dialogue_state()

        # Get conversation history
        conversation_history = self.conversations.get(session_id, [])[-self.max_history_turns:]

        # Build enhanced system prompt
        system_prompt = """You are Jarvis - David's friendly, helpful AI assistant.

YOUR PERSONALITY:
- Warm, casual, and conversational - like talking to a smart friend
- Enthusiastic but not over-the-top
- Direct and honest - no corporate speak or fluff
- Use contractions (you're, I'll, that's) - sound natural
- Occasional light humor is good

YOUR VOICE (CRITICAL - THIS IS SPOKEN):
- Keep it SHORT - 1 sentence for simple stuff, 2-3 max for complex
- Talk like a person, not a manual
- Drop the formality - say "Sure!" not "Certainly, I shall proceed"
- Examples:
  ❌ BAD: "Based on my knowledge base, I can confirm that you are David Llamas, a distinguished C-suite executive..."
  ✅ GOOD: "You're David Llamas - you've been a CTO and CDO for 20+ years."

  ❌ BAD: "I would be happy to assist you with that request. Let me search my records."
  ✅ GOOD: "Let me check that for you."

CONVERSATION FLOW:
- If something's unclear, just ask - don't give a dissertation
- Remember what you just talked about - use context
- Offer help, don't wait to be asked for every little thing
- When David corrects you, say "Got it" and move on

TOOLS - USE SPARINGLY:
- Only use tools when you actually need info
- "Who am I?" → Just answer, don't search files
- "What meetings today?" → Use activity log tool
- "Extract this document" → Use vision tool
- Don't over-explain what tools you're using

KNOWLEDGE ACCESS:
- Wiki: /home/ubuntu/AIS-OS/wiki/index.md (your main reference)
- Brain: /home/ubuntu/AIS-OS/brain/ (David's docs)
- Memory: /home/ubuntu/AIS-OS/memory/ (preferences, corrections)
- Activity: /home/ubuntu/AIS-OS/activity/ (events, meetings)

CURRENT CONTEXT:
- Topic: """ + str(dialogue_state.get("current_topic")) + """
- Recent mentions: """ + str(dialogue_state.get("entities_mentioned", [])[:5]) + """

Remember: You're a helpful friend, not a corporate assistant. Be brief, warm, and useful."""

        # Load wiki index for caching
        wiki_index_content = ""
        try:
            with open('/home/ubuntu/AIS-OS/wiki/index.md', 'r', encoding='utf-8') as f:
                wiki_index_content = f.read()
        except Exception as e:
            wiki_index_content = f"Wiki index not available: {e}"

        # Build system blocks with caching
        system_blocks = [
            {
                "type": "text",
                "text": system_prompt
            },
            {
                "type": "text",
                "text": f"""
# WIKI INDEX (CACHED FOR FAST ACCESS)

Below is the complete wiki index catalog. This is cached and available instantly.
For detailed entries, use grep/tail on log.md or read specific entity files.

---

{wiki_index_content}

---

END OF WIKI INDEX. You now have full knowledge of David's wiki structure.""",
                "cache_control": {"type": "ephemeral"}
            }
        ]

        # Build messages with conversation history
        messages = []
        for msg in conversation_history:
            messages.append({"role": msg["role"], "content": msg["content"]})

        messages.append({"role": "user", "content": query})

        return system_blocks, messages

    async def execute(
        self,
        query: str,
        session_id: str,
        max_tokens: int = 2048
    ) -> CodeExecuteResponse:
        """
        Execute query with full Claude Code capabilities

        Enhanced with conversational AI and self-learning
        """
        start_time = time.time()

        system_blocks, messages = await self._build_prompt_context(session_id, query)

        # Execute with tool use
        tool_calls = []
        files_modified = []
        response_text = ""

        response = await self.client.messages.create(
            model="claude-sonnet-4-5-20250929",
            max_tokens=max_tokens,
            system=system_blocks,
            messages=messages,
            tools=self._get_tools(),
            temperature=0.7
        )

        # Process response and tool calls
        while response.stop_reason == "tool_use":
            # Execute tools
            tool_results = []
            for content_block in response.content:
                if content_block.type == "tool_use":
                    tool_name = content_block.name
                    tool_input = content_block.input

                    print(f"🔧 Tool: {tool_name}({tool_input})")

                    # Add session_id to tool input for corrections
                    if tool_name == "register_correction":
                        tool_input["session_id"] = session_id

                    # Execute tool
                    tool_output = await self._execute_tool(tool_name, tool_input)

                    # Track tool call
                    tool_calls.append(ToolCall(
                        tool=tool_name,
                        input=tool_input,
                        output=tool_output[:500]  # Truncate for response
                    ))

                    # Track file modifications
                    if tool_name in ["write_file", "edit_file", "register_correction"]:
                        files_modified.append(tool_input.get("file_path", "knowledge_base"))

                    # Prepare tool result for Claude
                    # Truncate large outputs to prevent context explosion
                    MAX_TOOL_OUTPUT = 50_000  # 50KB max per tool output
                    truncated_output = tool_output
                    if len(tool_output) > MAX_TOOL_OUTPUT:
                        truncated_output = tool_output[:MAX_TOOL_OUTPUT] + f"\n\n... [OUTPUT TRUNCATED: {len(tool_output):,} chars total, showing first {MAX_TOOL_OUTPUT:,}] ..."

                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": content_block.id,
                        "content": truncated_output
                    })

            # Continue conversation with tool results
            messages.append({"role": "assistant", "content": response.content})
            messages.append({"role": "user", "content": tool_results})

            response = await self.client.messages.create(
                model="claude-sonnet-4-5-20250929",
                max_tokens=max_tokens,
                system=system_blocks,
                messages=messages,
                tools=self._get_tools(),
                temperature=0.7
            )

        # Extract final text response
        for content_block in response.content:
            if hasattr(content_block, "text"):
                response_text += content_block.text

        # Store conversation
        if session_id not in self.conversations:
            self.conversations[session_id] = []

        self.conversations[session_id].append({"role": "user", "content": query})
        self.conversations[session_id].append({"role": "assistant", "content": response.content})

        # Keep only last N turns
        self.conversations[session_id] = self.conversations[session_id][-self.max_history_turns * 2:]

        # Auto-log this conversation to activity log
        from app.services.activity_service import activity_service
        execution_time_ms = int((time.time() - start_time) * 1000)

        await activity_service.log_conversation(
            session_id=session_id,
            query=query,
            response=response_text,
            tool_calls=len(tool_calls),
            duration_ms=execution_time_ms
        )

        # Update dialogue state with entities and topics from this conversation
        await self._update_dialogue_state_from_conversation(query, response_text)

        print(f"⚡ Execution: {execution_time_ms}ms, {len(tool_calls)} tools, {len(files_modified)} files")

        return CodeExecuteResponse(
            answer=response_text,
            tool_calls=tool_calls,
            files_modified=files_modified,
            execution_time_ms=execution_time_ms
        )

    async def execute_stream(
        self,
        query: str,
        session_id: str,
        max_tokens: int = 2048
    ):
        """
        Same behavior as execute(), but yields text as Claude generates it instead
        of waiting for the full response. Yields dicts the router turns into SSE events:
          {"type": "text_delta", "text": "..."}  - as text streams in
          {"type": "done", "answer": ..., "tool_calls": [...], "files_modified": [...], "execution_time_ms": ...}
          {"type": "error", "message": "..."}

        Tool-use turns can't stream (a tool call has to fully resolve before Claude
        continues), so only the final text-generating turn actually streams to the
        caller - intermediate tool-use turns behave like execute()'s loop.
        """
        start_time = time.time()

        # Tracked outside the try block so the finally clause can log/save whatever
        # was accumulated even if the client disconnects mid-stream (a disconnect
        # raises at the `yield` inside the streaming loop below - without this,
        # the turn would silently vanish from conversation history and the
        # activity log instead of being recorded as a partial response).
        response_text = ""
        tool_calls: List[ToolCall] = []
        files_modified: List[str] = []
        final_content = None
        stream_completed = False

        try:
            system_blocks, messages = await self._build_prompt_context(session_id, query)

            # Intermediate turns: identical to execute()'s loop, non-streaming,
            # since tool calls must fully resolve before Claude can keep going.
            response = await self.client.messages.create(
                model="claude-sonnet-4-5-20250929",
                max_tokens=max_tokens,
                system=system_blocks,
                messages=messages,
                tools=self._get_tools(),
                temperature=0.7
            )

            while response.stop_reason == "tool_use":
                tool_results = []
                for content_block in response.content:
                    if content_block.type == "tool_use":
                        tool_name = content_block.name
                        tool_input = content_block.input

                        print(f"🔧 Tool: {tool_name}({tool_input})")

                        if tool_name == "register_correction":
                            tool_input["session_id"] = session_id

                        tool_output = await self._execute_tool(tool_name, tool_input)

                        tool_calls.append(ToolCall(
                            tool=tool_name,
                            input=tool_input,
                            output=tool_output[:500]
                        ))

                        if tool_name in ["write_file", "edit_file", "register_correction"]:
                            files_modified.append(tool_input.get("file_path", "knowledge_base"))

                        MAX_TOOL_OUTPUT = 50_000
                        truncated_output = tool_output
                        if len(tool_output) > MAX_TOOL_OUTPUT:
                            truncated_output = tool_output[:MAX_TOOL_OUTPUT] + f"\n\n... [OUTPUT TRUNCATED: {len(tool_output):,} chars total, showing first {MAX_TOOL_OUTPUT:,}] ..."

                        tool_results.append({
                            "type": "tool_result",
                            "tool_use_id": content_block.id,
                            "content": truncated_output
                        })

                messages.append({"role": "assistant", "content": response.content})
                messages.append({"role": "user", "content": tool_results})

                response = await self.client.messages.create(
                    model="claude-sonnet-4-5-20250929",
                    max_tokens=max_tokens,
                    system=system_blocks,
                    messages=messages,
                    tools=self._get_tools(),
                    temperature=0.7
                )

            # Final turn: stream the text as it's generated. If this last turn
            # somehow requests a tool (edge case), fall back to its non-streamed text.
            if response.stop_reason == "tool_use":
                for content_block in response.content:
                    if hasattr(content_block, "text"):
                        response_text += content_block.text
                        yield {"type": "text_delta", "text": content_block.text}
                final_content = response.content
            else:
                async with self.client.messages.stream(
                    model="claude-sonnet-4-5-20250929",
                    max_tokens=max_tokens,
                    system=system_blocks,
                    messages=messages,
                    tools=self._get_tools(),
                    temperature=0.7
                ) as stream:
                    async for text in stream.text_stream:
                        response_text += text
                        yield {"type": "text_delta", "text": text}
                    final_message = await stream.get_final_message()
                    final_content = final_message.content

            stream_completed = True
            execution_time_ms = int((time.time() - start_time) * 1000)

            print(f"⚡ Stream execution: {execution_time_ms}ms, {len(tool_calls)} tools, {len(files_modified)} files")

            yield {
                "type": "done",
                "answer": response_text,
                "tool_calls": [tc.model_dump() for tc in tool_calls],
                "files_modified": files_modified,
                "execution_time_ms": execution_time_ms
            }

        except Exception as e:
            print(f"❌ Stream execution error: {str(e)}")
            try:
                yield {"type": "error", "message": str(e)}
            except Exception:
                # Client is already gone (e.g. disconnected mid-stream) - the error
                # event can't be delivered, but the finally block below still runs
                # and records whatever partial response we'd accumulated.
                pass

        finally:
            # Runs on both clean completion and disconnect/error, so a cut-off
            # answer is still recorded as a partial turn instead of vanishing
            # from conversation history and the activity log.
            if final_content is None:
                final_content = [{"type": "text", "text": response_text}] if response_text else []

            if session_id not in self.conversations:
                self.conversations[session_id] = []

            self.conversations[session_id].append({"role": "user", "content": query})
            self.conversations[session_id].append({"role": "assistant", "content": final_content})
            self.conversations[session_id] = self.conversations[session_id][-self.max_history_turns * 2:]

            if response_text:
                from app.services.activity_service import activity_service
                execution_time_ms = int((time.time() - start_time) * 1000)

                log_note = response_text if stream_completed else f"{response_text} [partial - connection dropped]"

                await activity_service.log_conversation(
                    session_id=session_id,
                    query=query,
                    response=log_note,
                    tool_calls=len(tool_calls),
                    duration_ms=execution_time_ms
                )

                await self._update_dialogue_state_from_conversation(query, response_text)


# Singleton instance
code_service = CodeExecutionService()
