# IOPaint (LaMa inpainting) for the panel's «quitar marca de agua» — CPU only, self-hosted, internal network only.
# The LaMa weights are baked in at build time (MD5-checked) because the container has no internet at runtime.
# Used by the Liberu worker (queue «marcas-agua»), one image at a time; only for collaborators that authorized it.
FROM python:3.11.11-slim-bookworm

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    XDG_CACHE_HOME=/models \
    HF_HUB_OFFLINE=1 \
    GRADIO_ANALYTICS_ENABLED=False \
    OMP_NUM_THREADS=2 \
    MKL_NUM_THREADS=2

RUN apt-get update \
 && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# CPU wheels of torch (no CUDA: ~10× smaller image), then IOPaint pinned.
RUN pip install torch==2.5.1+cpu torchvision==0.20.1+cpu --index-url https://download.pytorch.org/whl/cpu \
 && pip install iopaint==1.6.0

RUN mkdir -p /models/torch/hub/checkpoints \
 && curl -fsSL -o /models/torch/hub/checkpoints/big-lama.pt \
      https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt \
 && echo "e3aa4aaa15225a33ec84f9f4bc47e500  /models/torch/hub/checkpoints/big-lama.pt" | md5sum -c -

RUN useradd --system --uid 10001 --home-dir /models iopaint && chown -R iopaint /models
USER iopaint
EXPOSE 8080

CMD ["iopaint", "start", "--model=lama", "--device=cpu", "--host=0.0.0.0", "--port=8080", "--model-dir=/models"]
