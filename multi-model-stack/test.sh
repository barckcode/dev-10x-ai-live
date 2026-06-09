#!/usr/bin/env bash
# Live-demo smoke test for the multi-model-stack.
# Each test shows: endpoint, model, request, response, token usage.
#
# Usage:
#   ./test.sh                        # against http://localhost:4000
#   ./test.sh http://1.2.3.4:4000    # against a remote stack

set -u

BASE="${1:-http://localhost:4000}"
KEY="${LITELLM_KEY:-sk-class-demo}"

# Colors
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

echo ""
printf "${B}Multi-Model-Stack Smoke Test${N}\n"
kv "Target:"    "$BASE  (all 4 calls go through LiteLLM)"
kv "Auth key:"  "${KEY:0:14}…"

# ─────────────────────────────────────────────────────────────────────
header "TEST 1/4 — List available models"
kv "Endpoint:" "GET $BASE/v1/models"
echo ""
out=$(curl -s -H "Authorization: Bearer $KEY" "$BASE/v1/models")
echo "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("  Models exposed by LiteLLM:")
for m in d.get("data", []):
    print(f"    • {m[\"id\"]}")
' 2>/dev/null
echo ""
if echo "$out" | grep -q '"qwen3.6"' && echo "$out" | grep -q '"qwen3-embedding"' && echo "$out" | grep -q '"whisper"'; then
  ok
else
  ko; echo "  raw: $out"
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
echo "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
content = d["choices"][0]["message"]["content"]
usage = d.get("usage", {})
print("  Response:")
for line in content.splitlines() or [content]:
    print(f"    {line}")
print()
print(f"  Tokens: prompt={usage.get(\"prompt_tokens\")}  "
      f"completion={usage.get(\"completion_tokens\")}  "
      f"total={usage.get(\"total_tokens\")}")
print(f"  Backend: {d.get(\"model\")}  ({d.get(\"system_fingerprint\", \"?\")})")
' 2>/dev/null && ok || { ko; echo "  raw: $out" | head -c 500; }

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
echo "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
vec = d["data"][0]["embedding"]
usage = d.get("usage", {})
print(f"  Vector dimensions: {len(vec)}")
print(f"  First 6 values:    [{\", \".join(f\"{v:+.4f}\" for v in vec[:6])}, …]")
print(f"  L2 norm:           {sum(v*v for v in vec)**0.5:.4f}")
print()
print(f"  Tokens used: {usage.get(\"prompt_tokens\")}")
' 2>/dev/null && ok || { ko; echo "  raw: $out" | head -c 500; }

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
kv "Endpoint:" "POST $BASE/v1/audio/transcriptions"
kv "Model:"    "whisper  (speaches serving Systran/faster-whisper-large-v3)"
kv "Audio:"    "$WAV  ($(stat -c%s "$WAV" 2>/dev/null || stat -f%z "$WAV") bytes)"
echo ""
note "Transcribing (first run downloads model on the speaches side, up to ~1 min)..."
out=$(curl -s --max-time 300 -H "Authorization: Bearer $KEY" \
  -X POST "$BASE/v1/audio/transcriptions" \
  -F "model=whisper" -F "file=@$WAV")
echo ""
echo "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f"  Detected language: {d.get(\"language\")}")
print(f"  Audio duration:    {d.get(\"duration\")} s")
print(f"  Transcript:")
text = d.get("text", "").strip()
for line in (text or "(empty)").splitlines():
    print(f"    {line}")
' 2>/dev/null && ok || { ko; echo "  raw: $out" | head -c 500; }

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
