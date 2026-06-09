#!/usr/bin/env bash
# Smoke test for class-eu009 LiteLLM stack.
# Usage:
#   ./test.sh                 # tests http://localhost:4000
#   ./test.sh http://1.2.3.4  # tests against a remote LiteLLM

set -u

BASE="${1:-http://localhost:4000}"
KEY="${LITELLM_KEY:-sk-class-eu009-demo}"

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
  echo "$out" | grep -q '"qwen3.6"' && echo "$out" | grep -q '"qwen3-embedding"' && echo "$out" | grep -q '"whisper"'
}

chat_qwen() {
  local out
  out=$(curl -s -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -X POST "$BASE/v1/chat/completions" \
    -d '{"model":"qwen3.6","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":10,"temperature":0}')
  echo "  $out" | head -c 600; echo
  echo "$out" | grep -qi 'pong'
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
  local tmp=/tmp/class-eu009-test.wav
  # 1s of 440Hz tone via ffmpeg (skip if absent)
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "  (ffmpeg not available — skipping audio gen, using existing $tmp if present)"
  else
    ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ac 1 -ar 16000 "$tmp" >/dev/null 2>&1
  fi
  if [ ! -f "$tmp" ]; then
    echo "  no test audio file at $tmp"
    return 1
  fi
  local out
  out=$(curl -s -H "Authorization: Bearer $KEY" \
    -X POST "$BASE/v1/audio/transcriptions" \
    -F "model=whisper" -F "file=@$tmp")
  echo "  $out" | head -c 400; echo
  echo "$out" | grep -q '"text"'
}

echo "Target: $BASE"
echo "Key:    ${KEY:0:16}…"

run "list /v1/models"               list_models
run "chat /v1/chat/completions (qwen3.6)" chat_qwen
run "embeddings /v1/embeddings (qwen3-embedding)" embed
run "transcription /v1/audio/transcriptions (whisper)" transcribe

echo ""
echo "================="
echo " pass=$pass  fail=$fail"
echo "================="
exit "$fail"
