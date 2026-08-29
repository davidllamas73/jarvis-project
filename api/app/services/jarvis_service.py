"""
Jarvis Backend Service
Interfaces with the existing Jarvis ChromaDB and automation scripts
"""
import sys
import os
from typing import List, Dict, Any, Optional
from datetime import datetime
import json

from app.config import settings
from app.models.responses import SearchResult, InterviewBrief, EmailDraft

# Add Jarvis backend to Python path
sys.path.insert(0, settings.jarvis_path)

try:
    import chromadb
    from chromadb.config import Settings as ChromaSettings
except ImportError:
    raise ImportError(f"Cannot import chromadb. Check JARVIS_PATH: {settings.jarvis_path}")


class JarvisService:
    """Service to interact with Jarvis backend"""

    def __init__(self):
        self.jarvis_path = settings.jarvis_path
        self.chroma_path = os.path.join(self.jarvis_path, "chroma_db")
        self._client = None
        self._brain_collection = None

        # Conversation memory: {conversation_id: [(query, answer), ...]}
        self.conversations: Dict[str, List[tuple]] = {}
        self.max_history_turns = 5  # Keep last 5 turns

    @property
    def client(self):
        """Lazy load ChromaDB client"""
        if self._client is None:
            self._client = chromadb.PersistentClient(
                path=self.chroma_path,
                settings=ChromaSettings(anonymized_telemetry=False)
            )
        return self._client

    @property
    def collection(self):
        """
        Get the wiki_sources collection.

        Not cached - re-fetched on every access. ChromaDB stores each
        collection under an on-disk UUID directory that changes when the
        collection is recreated (e.g. a re-embed/reindex run while this
        server is already running). A cached handle keeps pointing at the
        old, now-deleted UUID after that happens, so collection.count()
        starts throwing and get_stats()'s broad except silently reports 0
        chunks - reproduced live: startup logged 840 chunks correctly, but
        /system/health returned 0 after chroma.sqlite3 and a new collection
        UUID directory were rewritten mid-session, with no server restart
        to pick up a fresh handle. get_collection() is a cheap metadata
        lookup, not a data read, so refetching here isn't a real cost.
        """
        return self.client.get_collection(name="wiki_sources")

    @property
    def brain_collection(self):
        """Get the brain_priority collection (optional)"""
        if self._brain_collection is None:
            try:
                self._brain_collection = self.client.get_collection(name="brain_priority")
            except:
                # Brain collection not available yet
                self._brain_collection = None
        return self._brain_collection

    def _expand_query(self, query: str) -> str:
        """
        Expand query to resolve personal pronouns and add semantic context

        Improvements:
        - Semantic enrichment for common query patterns
        - Better matching for achievement/experience queries
        - Company name extraction and context expansion

        Maps for conversational understanding:
        - "I", "me", "my" -> David Llamas Varona (the owner/speaker)
        - "you", "your" (in Jarvis context) -> Jarvis AI assistant
        """
        import re
        query_lower = query.lower()

        # Extract company names for context (common companies in David's history)
        companies = {
            'central retail': 'Central Retail Corporation CRC Thailand',
            'crc': 'Central Retail Corporation Thailand',
            'thai union': 'Thai Union Group TUG Thailand seafood',
            'alshaya': 'Alshaya Group Kuwait Middle East retail',
            'harrods': 'Harrods luxury retail London UK',
            'cocosa': 'COCOSA.com marketplace CEO founder',
            'gloria': 'Gloria Jeans coffee retail',
            'map': 'MAP Indonesia Mitra Adiperkasa retail',
        }

        mentioned_company = None
        for company_key, company_expansion in companies.items():
            if company_key in query_lower:
                mentioned_company = company_expansion
                break

        # Semantic patterns for achievement queries (most common in voice)
        # These expand to include related terms that boost semantic similarity
        achievement_patterns = [
            (r'\b(what|tell me about|describe) (were |are )?my achievements?\b',
             'David Llamas achievements accomplishments impact results growth transformation'),
            (r'\bmy (achievements?|accomplishments?) (at|with|in)\b',
             'achievements accomplishments impact results transformation revenue growth digital'),
            (r'\b(what|how) did I (do|accomplish|achieve)\b',
             'David Llamas accomplishments achievements impact results'),
            (r'\bmy (experience|background|career|work)\b',
             'David Llamas experience career background achievements companies roles'),
            (r'\bmy (role|position|title) (at|with|in)\b',
             'role position responsibilities leadership achievements'),
            (r'\b(what|how) was my (impact|contribution)\b',
             'impact transformation results achievements growth revenue'),
        ]

        # Check for achievement patterns with company context
        for pattern, semantic_expansion in achievement_patterns:
            if re.search(pattern, query_lower):
                # If company mentioned, combine expansion with company context
                if mentioned_company:
                    return f"{mentioned_company} {semantic_expansion}"
                return semantic_expansion

        # Patterns for David (owner) identity queries
        david_identity_patterns = [
            ("who am i", "David Llamas Varona identity background experience career"),
            ("what is my", "David Llamas"),
            ("what are my", "David Llamas"),
            ("tell me about me", "David Llamas Varona background career achievements experience"),
            ("my background", "David Llamas Varona background experience career education companies"),
            ("my experience", "David Llamas Varona experience career achievements roles companies"),
            ("my achievements", "David Llamas Varona achievements accomplishments impact transformation"),
            ("my career", "David Llamas Varona career history companies roles achievements"),
        ]

        # Patterns for Jarvis (assistant) identity queries
        jarvis_identity_patterns = [
            ("who are you", "Jarvis AI assistant capabilities knowledge base"),
            ("what are you", "Jarvis AI assistant second brain RAG"),
            ("what can you do", "Jarvis capabilities functions features"),
            ("tell me about yourself", "Jarvis AI assistant architecture"),
            ("what is jarvis", "Jarvis AI assistant David Llamas second brain"),
            ("who is jarvis", "Jarvis AI assistant AIOS"),
        ]

        # Check for David identity patterns
        for pattern, expansion in david_identity_patterns:
            if pattern in query_lower:
                return expansion

        # Check for Jarvis identity patterns
        for pattern, expansion in jarvis_identity_patterns:
            if pattern in query_lower:
                return expansion

        # Replace standalone first-person pronouns with "David Llamas"
        expanded = query
        expanded = re.sub(r'\bI\b', 'David Llamas', expanded, flags=re.IGNORECASE)
        expanded = re.sub(r'\bme\b', 'David Llamas', expanded, flags=re.IGNORECASE)
        expanded = re.sub(r'\bmy\b', 'David Llamas', expanded, flags=re.IGNORECASE)

        # If company mentioned, append company context for better matching
        if mentioned_company and mentioned_company not in expanded:
            expanded = f"{expanded} {mentioned_company}"

        # Handle standalone "you" - need to determine context
        # This is tricky because Whisper might transcribe:
        # "Who am I?" as "you" OR "Who are you?" as "you"
        # Default to asking about Jarvis (more common in voice interface)
        if query.strip().lower() == 'you':
            return "Jarvis AI assistant capabilities identity"

        return expanded

    def search(
        self,
        query: str,
        n_results: int = 5,
        filter_type: Optional[str] = None,
        use_hybrid: bool = True,
        confidence_threshold: float = 0.7
    ) -> List[SearchResult]:
        """
        Hybrid semantic search across wiki (Tier 1) and brain (Tier 2)

        Args:
            query: Search query
            n_results: Number of results to return
            filter_type: Filter by document type (e.g., 'entity_people', 'concept')
            use_hybrid: If True, use two-tier hybrid search with brain fallback
            confidence_threshold: Min confidence for wiki-only results (0.7 = 0.3 distance)

        Returns:
            List of SearchResult objects
        """
        # Expand query to include owner identity context
        expanded_query = self._expand_query(query)

        # Debug logging
        if expanded_query != query:
            print(f"🔍 Query expansion: '{query}' → '{expanded_query}'")
        else:
            print(f"🔍 Query unchanged: '{query}'")

        where_filter = None
        if filter_type:
            where_filter = {"doc_type": filter_type}

        # Step 1: Search wiki collection (Tier 1 - high quality, curated)
        wiki_results = self.collection.query(
            query_texts=[expanded_query],
            n_results=n_results,
            where=where_filter
        )

        search_results = []
        wiki_confidence = 0.0

        if wiki_results['ids'] and len(wiki_results['ids'][0]) > 0:
            for i in range(len(wiki_results['ids'][0])):
                distance = wiki_results['distances'][0][i] if wiki_results['distances'] else 0.0
                confidence = 1.0 - distance

                if i == 0:
                    wiki_confidence = confidence

                search_results.append(SearchResult(
                    id=wiki_results['ids'][0][i],
                    content=wiki_results['documents'][0][i],
                    metadata=wiki_results['metadatas'][0][i] if wiki_results['metadatas'] else {},
                    score=confidence
                ))

                # Debug: Show top results
                if i < 3:
                    doc_type = wiki_results['metadatas'][0][i].get('doc_type', 'unknown') if wiki_results['metadatas'] else 'unknown'
                    print(f"  Wiki #{i+1}: {doc_type} | confidence={confidence:.3f} | {wiki_results['ids'][0][i][:50]}")

        # Step 2: If wiki confidence is low and brain collection available, search brain (Tier 2)
        if use_hybrid and self.brain_collection and wiki_confidence < confidence_threshold:
            print(f"⚠️  Wiki confidence {wiki_confidence:.3f} < {confidence_threshold}, searching brain archive...")

            brain_results = self.brain_collection.query(
                query_texts=[expanded_query],
                n_results=n_results
            )

            if brain_results['ids'] and len(brain_results['ids'][0]) > 0:
                for i in range(len(brain_results['ids'][0])):
                    distance = brain_results['distances'][0][i] if brain_results['distances'] else 0.0
                    confidence = 1.0 - distance

                    search_results.append(SearchResult(
                        id=brain_results['ids'][0][i],
                        content=brain_results['documents'][0][i],
                        metadata=brain_results['metadatas'][0][i] if brain_results['metadatas'] else {},
                        score=confidence * 0.9  # Slightly lower weight for brain
                    ))

                    # Debug: Show top brain results
                    if i < 3:
                        company = brain_results['metadatas'][0][i].get('company', 'unknown') if brain_results['metadatas'] else 'unknown'
                        print(f"  Brain #{i+1}: {company} | confidence={confidence:.3f} | {brain_results['ids'][0][i][:50]}")

            # Sort combined results by score
            search_results.sort(key=lambda x: x.score, reverse=True)
            search_results = search_results[:n_results]
            print(f"✓ Hybrid search returned {len(search_results)} results")
        else:
            print(f"✓ Wiki-only search returned {len(search_results)} results (confidence={wiki_confidence:.3f})")

        return search_results

    def rag_query(self, query: str, context_size: int = 5) -> tuple[str, List[SearchResult]]:
        """
        RAG-based question answering

        Args:
            query: User question
            context_size: Number of context chunks

        Returns:
            Tuple of (answer, sources)
        """
        # Get relevant context
        sources = self.search(query, n_results=context_size)

        if not sources:
            return "I don't have enough information to answer that question.", []

        # Build context from sources
        context = "\n\n".join([
            f"[Source {i+1}] {src.content}"
            for i, src in enumerate(sources)
        ])

        # Simple answer generation (you can enhance this with Claude API later)
        answer = self._generate_answer(query, context)

        return answer, sources

    def _generate_answer(self, query: str, context: str) -> str:
        """
        Generate answer from context
        For now, returns a simple response. Can integrate Claude API later.
        """
        # Simple heuristic answer for now
        # TODO: Integrate with Claude API for better answers
        return f"Based on the knowledge base, here's what I found:\n\n{context[:500]}..."

    async def rag_query_with_claude(self, query: str, context_size: int = 5, conversation_id: Optional[str] = None) -> tuple[str, float]:
        """
        RAG query with Claude post-processing for natural conversational responses

        Flow:
        1. Retrieve relevant context from RAG (wiki + brain)
        2. Process through Claude to generate natural, human-like response
        3. Return conversational answer (not raw markdown)

        Args:
            query: User question
            context_size: Number of context chunks to retrieve
            conversation_id: Optional conversation ID for history tracking

        Returns:
            Tuple of (answer, confidence_score)
            - answer: Natural conversational response from Claude
            - confidence_score: Top match confidence (0.0-1.0), based on vector similarity
        """
        from anthropic import AsyncAnthropic
        import os

        # Step 1: Retrieve context from RAG
        sources = self.search(query, n_results=context_size, use_hybrid=True)

        if not sources:
            return "I don't have information about that in my knowledge base yet. Would you like me to search for documents that might contain this information?", 0.0

        # Extract top match confidence (this is what triggers background mode)
        top_confidence = sources[0].score if sources else 0.0
        print(f"🎯 Top match confidence: {top_confidence:.3f}")

        # Step 1.5: Get conversation history if conversation_id provided
        conversation_history = []
        if conversation_id:
            conversation_history = self.conversations.get(conversation_id, [])[-self.max_history_turns:]
            print(f"💬 Conversation ID: {conversation_id}, history: {len(conversation_history)} turns")
            if conversation_history:
                print(f"   Last turn: Q='{conversation_history[-1][0][:50]}...' A='{conversation_history[-1][1][:50]}...'")

        # Step 2: Build context for Claude
        context_parts = []
        for i, src in enumerate(sources[:context_size]):
            context_parts.append(f"[Source {i+1}]\n{src.content}\n")

        context = "\n".join(context_parts)

        # Step 3: Process through Claude for natural response
        client = AsyncAnthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))

        system_prompt = """You're Jarvis - David's friendly AI assistant. This is SPOKEN, so keep it SHORT and natural.

YOUR STYLE:
- Talk like a friend, not a manual
- 1 sentence for simple stuff, 2-3 max for complex
- Use contractions (I'm, you're, that's)
- Be warm and helpful, not robotic

VOICE EXAMPLES:
❌ "I am Jarvis, your personal AI assistant and comprehensive second brain system..."
✅ "I'm Jarvis, your assistant."

❌ "Based on the information available in my knowledge base, I can provide..."
✅ "Let me tell you what I found."

❌ "I would be delighted to assist you with that inquiry..."
✅ "Sure!"

CONVERSATION:
- Use history - don't repeat what David already knows
- If he asks "what about that?" - you should know what "that" means from context
- Keep answers direct and friendly

NO TECHNICAL JARGON:
- Never say "knowledge base", "RAG", "sources", "chunks", "context"
- Just answer naturally

Remember: You're talking to a friend. Be brief, warm, and helpful."""

        # Build conversation history context
        history_text = ""
        if conversation_history:
            history_lines = []
            for q, a in conversation_history:
                history_lines.append(f"David: {q}")
                history_lines.append(f"Jarvis: {a}")
            history_text = "Previous conversation:\n" + "\n".join(history_lines) + "\n\n"

        user_message = f"""{history_text}Question: {query}

Context:
{context}

Answer naturally and briefly (1-2 sentences). Sound like a helpful friend."""

        response = await client.messages.create(
            model="claude-sonnet-4-5-20250929",
            max_tokens=1024,
            system=system_prompt,
            messages=[{
                "role": "user",
                "content": user_message
            }],
            temperature=0.7
        )

        # Extract text response
        answer = response.content[0].text

        # Store in conversation history
        if conversation_id:
            if conversation_id not in self.conversations:
                self.conversations[conversation_id] = []
                print(f"💬 Created new conversation: {conversation_id}")
            self.conversations[conversation_id].append((query, answer))
            # Keep only last N turns
            self.conversations[conversation_id] = self.conversations[conversation_id][-self.max_history_turns:]
            print(f"💾 Stored turn in conversation {conversation_id}: now {len(self.conversations[conversation_id])} turns")

        return answer, top_confidence

    def get_interview_brief(
        self,
        company: str,
        person: Optional[str],
        role: str
    ) -> InterviewBrief:
        """
        Generate interview prep brief

        Args:
            company: Company name
            person: Person name (optional)
            role: Role/position

        Returns:
            InterviewBrief object
        """
        # Search for company information
        company_results = self.search(f"{company} company overview", n_results=3)
        company_overview = "\n".join([r.content[:200] for r in company_results[:2]])

        # Search for person if provided
        person_background = None
        if person:
            person_results = self.search(f"{person} {company}", n_results=2)
            if person_results:
                person_background = person_results[0].content[:300]

        # Search for your achievements relevant to the role
        achievement_results = self.search(
            f"achievements {role} relevant experience",
            n_results=5,
            filter_type="achievement"
        )
        achievements = [r.content[:150] for r in achievement_results[:3]]

        # Generate talking points
        talking_points = [
            f"Digital transformation experience relevant to {role}",
            f"Experience scaling teams and technology at {company} scale",
            "Track record of business impact and ROI",
        ]

        # Questions to ask
        questions = [
            f"What are the biggest challenges for {role} in the next 12 months?",
            f"How does {company} approach digital transformation?",
            "What does success look like in the first 90 days?",
        ]

        return InterviewBrief(
            company_overview=company_overview or f"No specific information found for {company}",
            person_background=person_background,
            role_context=f"Role: {role} at {company}",
            your_achievements=achievements if achievements else ["No specific achievements found"],
            talking_points=talking_points,
            questions_to_ask=questions,
            generated_at=datetime.utcnow()
        )

    def draft_email(
        self,
        recipient: str,
        purpose: str,
        context: Optional[str]
    ) -> EmailDraft:
        """
        Draft email using network context

        Args:
            recipient: Recipient name
            purpose: Email purpose
            context: Additional context

        Returns:
            EmailDraft object
        """
        # Search for recipient information
        recipient_results = self.search(f"{recipient} person contact", n_results=2)
        recipient_info = recipient_results[0].content[:200] if recipient_results else ""

        # Simple email generation (enhance with Claude API later)
        subject = f"Re: {purpose}"

        body = f"""Hi {recipient},

I hope this message finds you well.

{context or purpose}

Looking forward to connecting.

Best regards,
David
"""

        return EmailDraft(
            subject=subject,
            body=body,
            recipient=recipient,
            purpose=purpose
        )

    def get_stats(self) -> Dict[str, Any]:
        """Get Jarvis statistics"""
        try:
            collection = self.collection
            count = collection.count()

            # Read embedding summary if available
            summary_path = os.path.join(self.chroma_path, "embedding_summary.json")
            if os.path.exists(summary_path):
                with open(summary_path, 'r') as f:
                    summary = json.load(f)
                    return {
                        "total_documents": summary.get("total_documents", 0),
                        "total_chunks": summary.get("total_chunks", count),
                        "document_types": summary.get("document_types", {}),
                    }

            return {
                "total_documents": 0,
                "total_chunks": count,
                "document_types": {},
            }
        except Exception as e:
            # Logged, not just returned in a field the client never reads -
            # this silent-zero fallback previously hid a real bug (stale
            # cached collection handle) until it was noticed live in the UI.
            print(f"⚠️ get_stats failed: {e}")
            return {
                "total_documents": 0,
                "total_chunks": 0,
                "document_types": {},
                "error": str(e)
            }


# Global instance
jarvis_service = JarvisService()
