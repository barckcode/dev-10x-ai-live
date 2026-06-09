#!/usr/bin/env bash
# Live-demo smoke test for the multi-model-stack.
# Each test shows: endpoint, model, request, response, token usage.
# All four calls go through LiteLLM (the single entry point on :4000).
#
# Usage:
#   ./test.sh                        # against http://localhost:4000
#   ./test.sh http://1.2.3.4:4000    # against a remote stack
#
# Requires: curl, jq (sudo apt-get install jq).

set -u

BASE="${1:-http://localhost:4000}"
KEY="${LITELLM_KEY:-sk-class-demo}"

B='\033[1m'; D='\033[2m'; G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'

pass=0; fail=0
header() {
  echo ""
  printf "${C}═══════════════════════════════════════════════════════════════════${N}\n"
  printf "${C}  %s${N}\n" "$1"
  printf "${C}═══════════════════════════════════════════════════════════════════${N}\n"
}
ok()   { printf "${G}✓ PASS${N}\n"; pass=$((pass+1)); }
ko()   { printf "${R}✗ FAIL${N}\n"; fail=$((fail+1)); }
kv()   { printf "  ${B}%-10s${N} %s\n" "$1" "$2"; }
note() { printf "  ${D}%s${N}\n" "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "Missing jq. Install with: sudo apt-get install -y jq"; exit 2
fi

echo ""
printf "${B}Multi-Model-Stack Smoke Test${N}\n"
kv "Target:"   "$BASE  (all 4 calls go through LiteLLM)"
kv "Auth key:" "${KEY:0:14}…"

# ─────────────────────────────────────────────────────────────────────
header "TEST 1/4 — List available models"
kv "Endpoint:" "GET $BASE/v1/models"
echo ""
out=$(curl -s -H "Authorization: Bearer $KEY" "$BASE/v1/models")
echo "  Models exposed by LiteLLM:"
echo "$out" | jq -r '.data[] | "    • " + .id' 2>/dev/null
echo ""
if echo "$out" | jq -e '.data | map(.id) | (contains(["qwen3.6"]) and contains(["qwen3-embedding"]) and contains(["whisper"]))' >/dev/null 2>&1; then
  ok
else
  ko; echo "  raw: $out" | head -c 400
fi

# ─────────────────────────────────────────────────────────────────────
header "TEST 2/4 — Chat completion (LLM)"
PROMPT="What is the capital of Japan? Answer in one short sentence."
kv "Endpoint:" "POST $BASE/v1/chat/completions"
kv "Model:"    "qwen3.6  (vLLM serving Qwen/Qwen3-8B)"
kv "Prompt:"   "\"$PROMPT\""
echo ""
note "Calling..."
out=$(curl -s -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -X POST "$BASE/v1/chat/completions" \
  -d "{\"model\":\"qwen3.6\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}],\"max_tokens\":256,\"temperature\":0}")
echo ""
content=$(echo "$out" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
if [ -n "$content" ]; then
  echo "  Response:"
  echo "$content" | sed 's/^/    /'
  echo ""
  echo "$out" | jq -r '"  Tokens: prompt=" + (.usage.prompt_tokens|tostring) + "  completion=" + (.usage.completion_tokens|tostring) + "  total=" + (.usage.total_tokens|tostring)'
  echo "$out" | jq -r '"  Backend model: " + .model + "   (" + (.system_fingerprint // "?") + ")"'
  ok
else
  ko; echo "  raw: $out" | head -c 400
fi

# ─────────────────────────────────────────────────────────────────────
header "TEST 3/4 — Embeddings"
TEXT="LiteLLM exposes an OpenAI-compatible API in front of any backend."
kv "Endpoint:" "POST $BASE/v1/embeddings"
kv "Model:"    "qwen3-embedding  (vLLM serving Qwen/Qwen3-Embedding-8B)"
kv "Input:"    "\"$TEXT\""
echo ""
note "Calling..."
out=$(curl -s -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -X POST "$BASE/v1/embeddings" \
  -d "{\"model\":\"qwen3-embedding\",\"input\":\"$TEXT\"}")
echo ""
dim=$(echo "$out" | jq -r '.data[0].embedding | length' 2>/dev/null)
if [ -n "$dim" ] && [ "$dim" -gt 0 ]; then
  preview=$(echo "$out" | jq -r '.data[0].embedding[0:6] | map(. * 10000 | round / 10000) | tostring')
  norm=$(echo "$out" | jq -r '[.data[0].embedding[] | . * .] | add | sqrt')
  tokens=$(echo "$out" | jq -r '.usage.prompt_tokens // "n/a"')
  echo "  Vector dimensions: $dim"
  echo "  First 6 values:    $preview"
  printf "  L2 norm:           %.4f\n" "$norm"
  echo ""
  echo "  Tokens used: $tokens"
  ok
else
  ko; echo "  raw: $out" | head -c 400
fi

# ─────────────────────────────────────────────────────────────────────
header "TEST 4/4 — Audio transcription (Whisper)"
WAV=/tmp/multi-model-stack-jfk.wav
if [ ! -f "$WAV" ]; then
  note "Downloading sample audio (JFK speech, 11s)..."
  curl -fsSL -o "$WAV" \
    https://github.com/ggerganov/whisper.cpp/raw/master/samples/jfk.wav 2>/dev/null \
    || {
      note "Network unavailable, falling back to ffmpeg sine tone..."
      command -v ffmpeg >/dev/null && \
        ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ac 1 -ar 16000 "$WAV" >/dev/null 2>&1
    }
fi
SIZE=$(stat -c%s "$WAV" 2>/dev/null || stat -f%z "$WAV")
kv "Endpoint:" "POST $BASE/v1/audio/transcriptions"
kv "Model:"    "whisper  (speaches serving Systran/faster-whisper-large-v3)"
kv "Audio:"    "$WAV  ($SIZE bytes)"
echo ""
note "Transcribing (first run downloads model on the speaches side, up to ~1 min)..."
out=$(curl -s --max-time 300 -H "Authorization: Bearer $KEY" \
  -X POST "$BASE/v1/audio/transcriptions" \
  -F "model=whisper" -F "file=@$WAV")
echo ""
text=$(echo "$out" | jq -r '.text // empty' 2>/dev/null)
if [ -n "$text" ]; then
  lang=$(echo "$out" | jq -r '.language // "?"')
  dur=$(echo "$out" | jq -r '.duration // "?"')
  echo "  Detected language: $lang"
  echo "  Audio duration:    $dur s"
  echo "  Transcript:"
  echo "$text" | sed 's/^[[:space:]]*/    /'
  ok
else
  ko; echo "  raw: $out" | head -c 400
fi

# ─────────────────────────────────────────────────────────────────────
echo ""
printf "${C}═══════════════════════════════════════════════════════════════════${N}\n"
if [ "$fail" -eq 0 ]; then
  printf "${G}  ALL GREEN — pass=%d fail=%d${N}\n" "$pass" "$fail"
else
  printf "${Y}  pass=%d  ${R}fail=%d${N}\n" "$pass" "$fail"
fi
printf "${C}═══════════════════════════════════════════════════════════════════${N}\n"
exit "$fail"
