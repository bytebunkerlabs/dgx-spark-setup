#!/usr/bin/env bash
# 06-finetune.sh — set up a LoRA/QLoRA fine-tuning workspace.
# We do NOT pip-install a training stack on the host (fights the DGX OS bundle
# and hits sm_121 wheel pain). Instead we scaffold a workspace and a launcher
# that drops you into the validated NGC PyTorch container with GPUs attached.
#
# Sweet spot on a single Spark: QLoRA up to ~70B, or full-parameter on small
# models. For anything bigger, span both nodes (see 09-cluster.sh).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_dgx

WORK="${DATA_ROOT}/finetune"
step "Fine-tuning workspace"

mkdir -p "${WORK}"/{data,configs,outputs,scripts}
ok "Workspace: ${WORK}"

# --- launcher: enter the NGC PyTorch container with the workspace mounted ----
cat > "${WORK}/enter-container.sh" <<EOF
#!/usr/bin/env bash
# Drops you into the NGC PyTorch container with the GPU + this workspace mounted.
# Inside, install a trainer of choice, e.g.:
#   pip install llamafactory       # LLaMA Factory — easiest path
#   pip install unsloth            # fastest (verify aarch64/sm_121 wheels first)
#   # NeMo AutoModel is NVIDIA's native stack and ships in NGC containers.
#
# flash-attn on Blackwell: aarch64 needs an sm_121-patched wheel. If a trainer
# demands flash-attn and the build fails, grab a prebuilt wheel from the
# community index (github.com/bidual/awesome-dgx-spark -> flash_attn for spark)
# or disable flash-attn / use the sdpa attention backend.
set -euo pipefail
docker run --rm -it \\
  --gpus all --ipc=host \\
  -v "${WORK}:/workspace" \\
  -v "${HF_HOME}:/root/.cache/huggingface" \\
  -e HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}" \\
  -w /workspace \\
  "${NGC_PYTORCH_IMAGE}" bash
EOF
chmod +x "${WORK}/enter-container.sh"
ok "Container launcher: ${WORK}/enter-container.sh"

# --- example LLaMA Factory QLoRA config -------------------------------------
cat > "${WORK}/configs/qlora_example.yaml" <<'EOF'
### Example LLaMA Factory QLoRA config. Run INSIDE the container:
###   llamafactory-cli train configs/qlora_example.yaml
model_name_or_path: Qwen/Qwen2.5-7B-Instruct
quantization_bit: 4                 # QLoRA (nf4)
stage: sft
finetuning_type: lora
lora_target: all
lora_rank: 16
dataset: your_dataset               # register your JSONL in data/dataset_info.json
template: qwen
cutoff_len: 4096
per_device_train_batch_size: 1
gradient_accumulation_steps: 8
learning_rate: 1.0e-4
num_train_epochs: 3.0
bf16: true
output_dir: /workspace/outputs/qlora-run
logging_steps: 10
save_steps: 200
EOF
ok "Example QLoRA config: ${WORK}/configs/qlora_example.yaml"

cat <<EOF

  Workflow:
    1) ${WORK}/enter-container.sh          # enter NGC PyTorch container
    2) pip install llamafactory            # (inside) pick your trainer
    3) put data in /workspace/data, edit configs/qlora_example.yaml
    4) llamafactory-cli train configs/qlora_example.yaml

  UMA discipline: BEFORE a training run, if you were just serving models, flush
  the buffer cache so the 128GB pool isn't held by page cache:
       spark-flush-cache
  If you hit 'Out of Memory' with capacity free, that's almost always the cache.

  Cheap-mistakes note: since it's all local, iterate freely — no per-token cost.
EOF
log "Next: dgxsetup monitoring   (dashboards + GPU telemetry)"
