# dev-10x-ai-live

Hands-on code for the **dev-10x AI live classes**. Each folder is a
self-contained mini-project you can clone, run, and tear down.

## Modules

- [`multi-model-stack/`](./multi-model-stack) — One GPU server, one
  OpenAI-compatible endpoint, three models behind it: a chat LLM
  (vLLM), an embedding model (vLLM), and Whisper transcription
  (speaches). All wired through LiteLLM.

---

## Requirements (any GPU module)

- **NVIDIA GPU** with recent drivers — **24 GB+ VRAM** is enough for the
  defaults; the full-fat preset wants 80 GB+.
- **Linux** (Ubuntu 22.04 / 24.04 recommended) with **Docker Engine**
  and the **NVIDIA Container Toolkit**.
- Outbound internet (models are pulled from Hugging Face on first run).

### Install Docker + NVIDIA Container Toolkit (Ubuntu)

If you don't have them yet, copy-paste this block on the server:

```bash
# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker

# NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Wire NVIDIA into Docker
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### Sanity check

```bash
sudo docker run --rm --runtime=nvidia --gpus all \
  nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi
```

You should see your GPU. If not, fix the toolkit before continuing.

---

## Quickstart — `multi-model-stack`

### 1. Get the code on the server

```bash
git clone https://github.com/barckcode/dev-10x-ai-live.git
cd dev-10x-ai-live/multi-model-stack
```

### 2. Tune the `.env` to match your GPU

```bash
cp .env.example .env
# edit .env if needed (see comments inside)
```

The defaults run **Qwen3-8B + Qwen3-Embedding-8B + Whisper large-v3**
on a single ~24 GB GPU. Common edits:

| GPU class | What to change in `.env` |
|---|---|
| 24 GB (3090/4090) | Keep defaults. |
| 48–80 GB (A100 40/80, H100) | `LLM_GPU_UTIL=0.65`, `LLM_MAX_LEN=65536`. |
| 80 GB+ (H100, RTX PRO 6000) | `LLM_MODEL=Qwen/Qwen3.6-35B-A3B-FP8`, `TORCH_CUDA_ARCH_LIST=12.0+PTX` if Blackwell. |
| <16 GB | `LLM_MODEL=Qwen/Qwen3-4B-Instruct`, `EMBED_MODEL=Qwen/Qwen3-Embedding-0.6B`, `WHISPER_MODEL=Systran/faster-whisper-small`. |

### 3. Bring the stack up

```bash
sudo docker compose up -d
```

First boot downloads ~30 GB of weights, so it takes **5–10 min**. Watch
progress with:

```bash
sudo docker compose logs -f vllm-llm
```

Wait until you see `Application startup complete` for the LLM and
`docker compose ps` shows all four services as `(healthy)`.

### 4. Smoke-test everything

```bash
./test.sh
```

Expected output:

```
── list /v1/models                                  ✓ PASS
── chat /v1/chat/completions (qwen3.6)              ✓ PASS
── embeddings /v1/embeddings (qwen3-embedding)      ✓ PASS
── transcription /v1/audio/transcriptions (whisper) ✓ PASS

 pass=4  fail=0
```

(The script needs `ffmpeg` for the audio test: `sudo apt-get install -y ffmpeg`.)

### 5. Call the API yourself

The endpoint is `http://<server-ip>:4000/v1` and behaves like the
OpenAI API. The master key is whatever you set in `LITELLM_MASTER_KEY`
(default `sk-class-demo`).

```bash
# chat
curl http://<server-ip>:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-class-demo" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.6","messages":[{"role":"user","content":"hi"}]}'

# embeddings
curl http://<server-ip>:4000/v1/embeddings \
  -H "Authorization: Bearer sk-class-demo" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-embedding","input":"hello"}'

# transcription
curl http://<server-ip>:4000/v1/audio/transcriptions \
  -H "Authorization: Bearer sk-class-demo" \
  -F "model=whisper" -F "file=@your-audio.wav"
```

Python (OpenAI SDK):

```python
from openai import OpenAI
client = OpenAI(base_url="http://<server-ip>:4000/v1", api_key="sk-class-demo")
print(client.chat.completions.create(
    model="qwen3.6",
    messages=[{"role": "user", "content": "Hello"}],
).choices[0].message.content)
```

### 6. Tear it all down

```bash
sudo docker compose down -v       # stops containers, deletes volumes (cached weights!)
```

To keep the cache for a faster next boot, drop the `-v`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `vllm-llm` stays `(unhealthy)` but `/v1/models` works | The `python` binary is missing in the image. Make sure the healthcheck uses `python3` (it does on `main`). |
| `vllm-llm` OOM at startup | Lower `LLM_GPU_UTIL` (e.g. `0.45`) or `LLM_MAX_LEN`. |
| `vllm-embedding` OOM after LLM started | Lower `EMBED_GPU_UTIL`. The LLM grabs memory first; the embedding service sees the remainder. |
| Whisper request returns `Model not installed locally` | The first request triggers a download. Re-run `./test.sh` or `POST /v1/models/Systran/faster-whisper-large-v3` directly to `:8090`. |
| `No connected db` from LiteLLM | The key you sent doesn't match `LITELLM_MASTER_KEY`. Check your `.env`. |

---

Open an issue if anything breaks on your hardware.
