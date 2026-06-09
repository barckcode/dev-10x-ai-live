# dev-10x-ai-live

Hands-on code for the **dev-10x AI live classes**. Each folder is a
self-contained mini-project you can clone, run, and tear down.

## Modules

| Folder | What you'll run |
|---|---|
| [`multi-model-stack/`](./multi-model-stack) | A single GPU server exposing an OpenAI-compatible API that fronts three models — a chat LLM, an embedding model, and Whisper — behind LiteLLM. Brought up with one `docker compose up`. |

## Requirements (for any module that uses a GPU)

- An NVIDIA GPU with recent drivers (24 GB+ VRAM is enough for the defaults).
- Docker Engine and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).
- Outbound internet (models are pulled from Hugging Face on first boot).

Quick sanity check:

```bash
docker run --rm --runtime=nvidia --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

If that prints your GPU, you're good.

## How to use a module

```bash
cd <module>/
cp .env.example .env    # tweak models / GPU util if needed
docker compose up -d    # first boot downloads weights — be patient
./test.sh               # smoke-test all endpoints
docker compose down -v  # full cleanup (containers + volumes)
```

Open an issue if anything breaks on your hardware.
