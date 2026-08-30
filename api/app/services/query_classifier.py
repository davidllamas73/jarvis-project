"""
Query Classifier for 4-Tier Routing
Classifies queries into: conversational, knowledge, research, or task
"""
import re
from enum import Enum
from typing import Tuple, Optional
import logging

logger = logging.getLogger(__name__)


class QueryTier(str, Enum):
    """Query complexity tiers"""
    CONVERSATIONAL = "conversational"  # T1: Greetings, chitchat
    KNOWLEDGE = "knowledge"           # T2: Personal facts, wiki lookup
    RESEARCH = "research"             # T3: External info, web search
    TASK = "task"                     # T4: Writing, coding, analysis


class QueryClassifier:
    """
    Fast rule-based query classifier with confidence scoring

    Uses pattern matching to classify queries into 4 tiers:
    - T1 (Conversational): Immediate response, no tools
    - T2 (Knowledge): Quick RAG lookup, wiki/brain search
    - T3 (Research): Web search, external information
    - T4 (Task): Complex tasks requiring agent with tools

    Based on 2026 industry patterns (RouteLLM, Patronus AI, Decagon)
    """

    def __init__(self):
        # Tier 1: Conversational patterns (highest priority - most specific)
        self.conversational_patterns = [
            # Greetings
            (r'^(hi|hello|hey|good morning|good afternoon|good evening|greetings)', 0.95),
            (r'^(howdy|what\'s up|sup|yo)', 0.90),

            # Gratitude
            (r'^(thank you|thanks|thank|appreciated|cheers|much appreciated)', 0.95),
            (r'\b(thank you|thanks)\b.*$', 0.85),  # Thanks at end

            # Status queries about Jarvis
            (r'^(how are you|what are you|who are you)\??$', 0.95),
            (r'^what (can|do) you (do|know)\??$', 0.95),
            (r'^(tell me about|describe) (yourself|jarvis)\??$', 0.90),

            # Confirmations
            (r'^(yes|yeah|yep|yup|sure|okay|ok|alright|fine|good)\b', 0.90),
            (r'^(no|nope|nah|not really|i don\'t think so)\b', 0.90),

            # Apologies
            (r'^(sorry|my apologies|excuse me|pardon|oops)', 0.90),

            # Simple pleasantries
            (r'^(nice to meet you|pleasure|lovely|wonderful)', 0.85),

            # Capability queries (no specific task)
            (r'^can you help( me)?\??$', 0.85),
            (r'^are you (able|capable|ready)\??$', 0.85),
        ]

        # Tier 4: Task patterns (check before knowledge - more specific)
        self.task_patterns = [
            # Writing tasks
            (r'\b(write|draft|compose|create|prepare) (a|an|the|my)? (email|letter|proposal|document|report|memo)', 0.95),
            (r'\b(generate|produce) (a|an|the)? (document|report|summary|brief)', 0.90),

            # Code tasks
            (r'\b(write|create|implement|build|code|develop) (a|an|the)? (function|script|program|app|application|tool)', 0.95),
            (r'\b(debug|fix|refactor|optimize|improve) (this|the|my)? code', 0.90),

            # Analysis tasks
            (r'\b(analyze|review|assess|evaluate|examine|critique) (this|the|my)?', 0.90),
            (r'\b(compare|contrast) .* (with|to|against)', 0.85),
            (r'\bperform (a|an)? (analysis|assessment|evaluation)', 0.90),

            # Generation tasks
            (r'\b(generate|produce|make|build|create) (a|an|the)? (presentation|deck|slides|chart|graph|diagram)', 0.95),
            (r'\bcreate (a|an)? (plan|strategy|roadmap|framework)', 0.90),

            # Multi-step tasks
            (r'\b(help me|walk me through|guide me through|show me how to) (prepare|plan|build|create)', 0.90),
            (r'\b(step by step|one by one)', 0.85),

            # Research + synthesis (complex)
            (r'\b(research and|find and analyze|gather and summarize)', 0.90),

            # Transformation tasks
            (r'\b(convert|transform|translate|migrate) .* (to|into)', 0.85),
            (r'\bsummarize (this|the) (document|article|paper|report)', 0.90),
        ]

        # Tier 2: Knowledge patterns (personal knowledge base)
        self.knowledge_patterns = [
            # Identity queries
            (r'\b(who am i|what is my name|my full name)\b', 0.95),
            (r'\b(my background|my experience|my career|my history)\b', 0.95),
            (r'\b(tell me about (me|myself))\b', 0.95),

            # Achievement queries
            (r'\b(my achievements?|my accomplishments?|what did i (do|achieve))\b', 0.95),
            (r'\b(what have i (done|accomplished|achieved))\b', 0.90),
            (r'\bmy (impact|contribution|results?) at\b', 0.90),

            # Company/role queries
            (r'\b(my (role|position|title|job) at)\b', 0.95),
            (r'\b(my (work|time|tenure) at)\b', 0.90),
            (r'\b(when did i (work|join|start|leave))\b', 0.90),

            # Personal facts
            (r'\b(my (age|birthday|birth date|passport|address|phone|email))\b', 0.95),
            (r'\b(how old am i|when was i born)\b', 0.95),
            (r'\b(where do i live|my location|my residence)\b', 0.90),

            # Relationship queries (proper names)
            (r'\b(who is|tell me about) [A-Z][a-z]+ [A-Z][a-z]+', 0.85),

            # Company queries (known entities)
            (r'\b(what is|tell me about|explain) (central retail|crc|thai union|alshaya|harrods|cocosa|gloria jeans|map indonesia)\b', 0.90),

            # Resume/CV queries
            (r'\b(my (resume|cv|curriculum vitae)|show me my)\b', 0.90),

            # Project queries
            (r'\b(my (projects?|work on|experience with))\b', 0.85),
            (r'\b(what did i build|what have i built)\b', 0.85),

            # Simple fact lookups from wiki
            (r'^what (is|was) my\b', 0.80),
            (r'^(show|list|find) my\b', 0.80),
        ]

        # Tier 3: Research patterns (external/recent information)
        self.research_patterns = [
            # Current events / time-sensitive
            (r'\b(latest|recent|current|today|this week|this month|now|nowadays)\b', 0.90),
            (r'\b(what\'s (happening|going on|new)|news about)\b', 0.90),
            (r'\b(update (me )?on|keep me posted)\b', 0.85),

            # External entities (not in personal knowledge)
            (r'\b(what is|tell me about|explain) [A-Z]{2,}\b', 0.85),  # Acronyms
            (r'\b(what (is|are)) (the|a|an) [a-z]+ (company|organization|group)\b', 0.80),

            # Market/trend queries
            (r'\b(trends? in|market for|industry|competitors?)\b', 0.85),
            (r'\b(how is .* (doing|performing))\b', 0.80),

            # Fact-checking / verification
            (r'\b(is it true|verify|confirm|check if|fact check)\b', 0.90),
            (r'\b(according to|based on) (recent|latest)\b', 0.80),

            # Search intent
            (r'\b(search for|find (out|me)|look up|google)\b', 0.85),
            (r'\b(can you find|do you know (about|where))\b', 0.75),

            # Comparative external
            (r'\b(how does .* compare to)\b', 0.80),
            (r'\b(better than|worse than|similar to)\b', 0.70),

            # External people/companies not in personal network
            (r'\b(who is|what is|tell me about) (?!david|jarvis)\b', 0.70),
        ]

    def classify(self, query: str) -> Tuple[QueryTier, float]:
        """
        Classify query into one of 4 tiers with confidence score

        Args:
            query: User query string

        Returns:
            Tuple of (tier, confidence) where confidence is 0.0-1.0

        Priority order:
        1. Conversational (highest priority - most specific)
        2. Task (complex, requires tools)
        3. Research (external information)
        4. Knowledge (personal facts - default fallback)
        """
        if not query or not query.strip():
            return QueryTier.CONVERSATIONAL, 1.0

        query_lower = query.lower().strip()

        # Log query for monitoring
        logger.info(f"Classifying query: '{query[:50]}...'")

        # Check each tier in priority order
        tiers_to_check = [
            (QueryTier.CONVERSATIONAL, self.conversational_patterns),
            (QueryTier.TASK, self.task_patterns),
            (QueryTier.RESEARCH, self.research_patterns),
            (QueryTier.KNOWLEDGE, self.knowledge_patterns),
        ]

        best_match = (QueryTier.KNOWLEDGE, 0.5)  # Default fallback

        for tier, patterns in tiers_to_check:
            for pattern, confidence in patterns:
                if re.search(pattern, query_lower):
                    logger.info(f"Matched {tier} pattern: {pattern[:50]}... (confidence={confidence})")

                    # Return first match (highest priority tier)
                    if confidence > best_match[1]:
                        best_match = (tier, confidence)

                    # If high confidence match in current tier, return immediately
                    if confidence >= 0.90:
                        return tier, confidence

        # Return best match found
        logger.info(f"Classification result: {best_match[0]} (confidence={best_match[1]})")
        return best_match

    def classify_with_explanation(self, query: str) -> dict:
        """
        Classify query and return detailed explanation

        Returns:
            {
                "query": str,
                "tier": QueryTier,
                "confidence": float,
                "reasoning": str,
                "pattern_matched": str
            }
        """
        tier, confidence = self.classify(query)

        # Find which pattern matched
        pattern_matched = "default"
        query_lower = query.lower().strip()

        tier_patterns = {
            QueryTier.CONVERSATIONAL: self.conversational_patterns,
            QueryTier.TASK: self.task_patterns,
            QueryTier.RESEARCH: self.research_patterns,
            QueryTier.KNOWLEDGE: self.knowledge_patterns,
        }

        for pattern, conf in tier_patterns[tier]:
            if re.search(pattern, query_lower):
                pattern_matched = pattern
                break

        # Generate reasoning
        reasoning_map = {
            QueryTier.CONVERSATIONAL: "Simple conversational query requiring immediate response with no tools",
            QueryTier.KNOWLEDGE: "Personal knowledge lookup from wiki/brain archive",
            QueryTier.RESEARCH: "External/recent information requiring web search",
            QueryTier.TASK: "Complex task requiring agent with tools and multi-step reasoning",
        }

        return {
            "query": query,
            "tier": tier,
            "confidence": confidence,
            "reasoning": reasoning_map[tier],
            "pattern_matched": pattern_matched,
        }


# Singleton instance
query_classifier = QueryClassifier()
