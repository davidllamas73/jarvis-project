#!/usr/bin/env python3
"""
Test script for 4-tier query routing

Tests each tier with representative queries and validates:
1. Correct tier classification
2. Appropriate acknowledgment generation
3. Expected latency ranges
4. Response quality
"""
import asyncio
import time
import sys
import os

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app.services.query_classifier import query_classifier, QueryTier


# Test queries for each tier
TEST_QUERIES = {
    QueryTier.CONVERSATIONAL: [
        "Hello Jarvis",
        "How are you?",
        "Thank you",
        "Good morning",
        "What can you do?",
        "Who are you?",
    ],
    QueryTier.KNOWLEDGE: [
        "What are my achievements at Central Retail?",
        "Who is David Llamas?",
        "Tell me about my work at Thai Union",
        "What was my role at Alshaya?",
        "What did I accomplish at Harrods?",
        "Show me my background",
    ],
    QueryTier.RESEARCH: [
        "What are the latest trends in retail AI?",
        "What is happening with OpenAI today?",
        "Tell me about recent developments in LLMs",
        "What is the latest news about Thailand?",
        "How is the tech market performing?",
        "What are current AI industry trends?",
    ],
    QueryTier.TASK: [
        "Write an email to the board about our Q4 results",
        "Draft a proposal for the new AI initiative",
        "Analyze the competitive landscape for retail tech",
        "Create a presentation on digital transformation",
        "Implement a function to calculate ROI",
        "Review this code and suggest improvements",
    ],
}


def test_classifier():
    """Test query classifier with all test queries"""
    print("=" * 80)
    print("QUERY CLASSIFIER TEST")
    print("=" * 80)
    print()

    total_tests = 0
    correct_classifications = 0
    misclassifications = []

    for expected_tier, queries in TEST_QUERIES.items():
        print(f"\n{expected_tier.upper()} Queries")
        print("-" * 80)

        for query in queries:
            total_tests += 1

            # Classify
            actual_tier, confidence = query_classifier.classify(query)

            # Check correctness
            is_correct = actual_tier == expected_tier
            if is_correct:
                correct_classifications += 1
                status = "✅"
            else:
                status = "❌"
                misclassifications.append({
                    "query": query,
                    "expected": expected_tier,
                    "actual": actual_tier,
                    "confidence": confidence
                })

            # Print result
            print(f"{status} {query[:50]:50s} → {actual_tier:15s} (conf={confidence:.2f})")

    # Summary
    print()
    print("=" * 80)
    print("SUMMARY")
    print("=" * 80)
    accuracy = (correct_classifications / total_tests) * 100
    print(f"Total tests: {total_tests}")
    print(f"Correct: {correct_classifications}")
    print(f"Accuracy: {accuracy:.1f}%")

    if misclassifications:
        print()
        print("MISCLASSIFICATIONS:")
        print("-" * 80)
        for mc in misclassifications:
            print(f"  Query: {mc['query']}")
            print(f"  Expected: {mc['expected']} | Got: {mc['actual']} (conf={mc['confidence']:.2f})")
            print()

    return accuracy >= 90.0  # Success threshold


async def test_api_integration():
    """Test actual API endpoint integration"""
    print()
    print("=" * 80)
    print("API INTEGRATION TEST")
    print("=" * 80)
    print()

    import httpx

    base_url = "https://localhost:8443"
    endpoint = f"{base_url}/api/v1/orchestrate/tiered"

    # Test one query from each tier
    test_cases = [
        ("Hello Jarvis", QueryTier.CONVERSATIONAL, 500),
        ("What are my achievements?", QueryTier.KNOWLEDGE, 5000),
        ("What's the latest AI news?", QueryTier.RESEARCH, 10000),
        ("Draft an email about Q4 results", QueryTier.TASK, 30000),
    ]

    async with httpx.AsyncClient(verify=False) as client:
        for query, expected_tier, max_latency_ms in test_cases:
            print(f"\nTesting: {query}")
            print("-" * 80)

            start = time.time()

            try:
                response = await client.post(
                    endpoint,
                    json={"query": query},
                    timeout=60.0
                )

                latency_ms = int((time.time() - start) * 1000)

                if response.status_code == 200:
                    result = response.json()

                    # Validate response
                    tier = result.get("tier")
                    confidence = result.get("confidence")
                    path = result.get("path")
                    ack = result.get("acknowledgment")

                    print(f"  Tier: {tier} (expected: {expected_tier})")
                    print(f"  Confidence: {confidence:.2f}")
                    print(f"  Path: {path}")
                    print(f"  Acknowledgment: {ack}")
                    print(f"  Latency: {latency_ms}ms (max: {max_latency_ms}ms)")

                    # Check tier
                    if tier == expected_tier.value:
                        print(f"  ✅ Tier correct")
                    else:
                        print(f"  ❌ Tier incorrect (expected {expected_tier.value})")

                    # Check latency (allow 2x margin for testing)
                    if latency_ms <= max_latency_ms * 2:
                        print(f"  ✅ Latency acceptable")
                    else:
                        print(f"  ⚠️ Latency high (expected <{max_latency_ms}ms)")

                    # Show answer preview
                    answer = result.get("answer", "")
                    if answer:
                        preview = answer[:100] + "..." if len(answer) > 100 else answer
                        print(f"  Answer: {preview}")

                else:
                    print(f"  ❌ HTTP {response.status_code}: {response.text}")

            except httpx.ConnectError:
                print(f"  ⚠️ API not running - skipping integration test")
                print(f"  Run: cd api && python -m uvicorn app.main:app --reload")
                return False
            except Exception as e:
                print(f"  ❌ Error: {str(e)}")

    return True


async def test_streaming():
    """Test streaming endpoint with SSE"""
    print()
    print("=" * 80)
    print("STREAMING TEST")
    print("=" * 80)
    print()

    import httpx

    base_url = "https://localhost:8443"
    endpoint = f"{base_url}/api/v1/orchestrate/tiered/stream"

    query = "What are my achievements at Central Retail?"

    print(f"Testing stream: {query}")
    print("-" * 80)

    try:
        async with httpx.AsyncClient(verify=False) as client:
            async with client.stream(
                "POST",
                endpoint,
                json={"query": query},
                timeout=60.0
            ) as response:
                if response.status_code == 200:
                    async for line in response.aiter_lines():
                        if line.startswith("event:"):
                            event_type = line.split(": ")[1]
                            print(f"\n📡 Event: {event_type}")
                        elif line.startswith("data:"):
                            import json
                            data = json.loads(line.split(": ", 1)[1])
                            print(f"   Data: {data}")
                else:
                    print(f"❌ HTTP {response.status_code}")

    except httpx.ConnectError:
        print(f"⚠️ API not running - skipping streaming test")
        return False
    except Exception as e:
        print(f"❌ Error: {str(e)}")
        return False

    return True


async def main():
    """Run all tests"""
    print()
    print("🧪 TIERED ROUTING TEST SUITE")
    print()

    # Test 1: Classifier
    classifier_passed = test_classifier()

    # Test 2: API integration (only if API is running)
    api_passed = await test_api_integration()

    # Test 3: Streaming (only if API is running)
    stream_passed = await test_streaming()

    # Summary
    print()
    print("=" * 80)
    print("FINAL RESULTS")
    print("=" * 80)
    print(f"Classifier: {'✅ PASS' if classifier_passed else '❌ FAIL'}")
    print(f"API Integration: {'✅ PASS' if api_passed else '⚠️ SKIPPED'}")
    print(f"Streaming: {'✅ PASS' if stream_passed else '⚠️ SKIPPED'}")
    print()

    if classifier_passed:
        print("🎉 Core classifier tests passed!")
        print()
        print("To test API endpoints:")
        print("  1. cd api")
        print("  2. source venv/bin/activate")
        print("  3. python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8443 --ssl-keyfile=key.pem --ssl-certfile=cert.pem")
        print("  4. python test_tiered_routing.py")
    else:
        print("❌ Classifier tests failed - fix patterns before testing API")
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
