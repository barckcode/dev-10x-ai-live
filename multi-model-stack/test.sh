#!/usr/bin/env bash
# Smoke test for the multi-model-stack.
# Usage:
#   ./test.sh                                 # tests http://localhost:4000
#   ./test.sh http://1.2.3.4:4000             # tests against a remote stack
#
# Env overrides:
#   LITELLM_KEY    — master key (default sk-class-demo, must match .env)
#   WHISPER_BASE   — direct base URL for whisper (default derived from BASE
#                    by swapping port 4000 → 8090). Used only to pre-warm
#                    the model before the LiteLLM-routed test.

set -u

BASE="${1:-http://localhost:4000}"
KEY="${LITELLM_KEY:-sk-class-demo}"
WHISPER_BASE="${WHISPER_BASE:-$(echo "$BASE" | sed 's/:4000/:8090/')}"

pass=0
fail=0

run() {
  local name="$1"; shift
  echo ""
  echo "── $name"
  if "$@"; then
    echo "  ✓ PASS"
    pass=$((pass+1))
  else
    echo "  ✗ FAIL"
    fail=$((fail+1))
  fi
}

list_models() {
  local out
  out=$(curl -s -H "Authorization: Bearer $KEY" "$BASE/v1/models")
  echo "  $out" | head -c 500; echo
  echo "$out" | grep -q '"qwen3.6"' && \
    echo "$out" | grep -q '"qwen3-embedding"' && \
    echo "$out" | grep -q '"whisper"'
}

chat() {
  local out
  out=$(curl -s -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -X POST "$BASE/v1/chat/completions" \
    -d '{"model":"qwen3.6","messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":64,"temperature":0}')
  local content
  content=$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"])' 2>/dev/null)
  echo "  content: ${content:0:200}"
  [ -n "$content" ]
}

embed() {
  local out
  out=$(curl -s -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -X POST "$BASE/v1/embeddings" \
    -d '{"model":"qwen3-embedding","input":"hello world from the live class"}')
  local dim
  dim=$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["data"][0]["embedding"]))' 2>/dev/null || echo 0)
  echo "  vector dim: $dim"
  [ "$dim" -gt 0 ]
}

transcribe() {
  local tmp=/tmp/multi-model-stack-test.wav
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "  ffmpeg not found (apt-get install ffmpeg). Skipping audio gen."
  else
    ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ac 1 -ar 16000 "$tmp" >/dev/null 2>&1
  fi
  if [ ! -f "$tmp" ]; then
    echo "  no test audio at $tmp"
    return 1
  fi
  # Pre-warm: speaches downloads the model on first reference. Idempotent.
  echo "  pre-warming whisper model (first run may take ~1 min)…"
  curl -s -X POST "$WHISPER_BASE/v1/models/Systran/faster-whisper-large-v3" -o /dev/null --max-time 300 || true
  local out
  out=$(curl -s --max-time 120 -H "Authorization: Bearer $KEY" \
    -X POST "$BASE/v1/audio/transcriptions" \
    -F "model=whisper" -F "file=@$tmp")
  echo "  $out" | head -c 400; echo
  echo "$out" | grep -q '"text"'
}

echo "Target:        $BASE"
echo "Whisper (raw): $WHISPER_BASE"
echo "Key:           ${KEY:0:16}…"

run "list /v1/models"                                  list_models
run "chat /v1/chat/completions (qwen3.6)"              chat
run "embeddings /v1/embeddings (qwen3-embedding)"      embed
run "transcription /v1/audio/transcriptions (whisper)" transcribe

echo ""
echo "================="
echo " pass=$pass  fail=$fail"
echo "================="
exit "$fail"
