# Changes to upstream components in the Erebine agent images

## Rule

Apache-2.0 section 4(b) requires modified files to carry prominent notices
stating that they were changed. Every change these images make to an
upstream component is listed here: what changes, the files touched, the
images affected, and the pinned upstream version it applies to.

- A change that **modifies an upstream file** also puts a notice at the top
  of that file and adds to the component's entry in `THIRD_PARTY_NOTICES`:
  "Contains modifications to <component>; see PATCHES.md."
- Add or update the entry in the same commit as the change. Remove it in the
  commit that retires the change.
- Re-check this file against the images whenever a pinned version changes
  (see "Verifying" below).

## Findings

Checked 2026-09-14 against the Dockerfiles and launch scripts that build
these images.
No image applies a source patch (`patch`, `git apply`, `sed -i`) to vLLM or
LMCache, and no upstream file is edited. The images do change how the
components run, and one adds files inside the installed vLLM package:

### vLLM

Pinned: 0.27.1 (eim-vllm-cuda, eim-vllm-omni-cuda), 0.26.0 (eim-vllm-cpu),
0.25.1 (eim-vllm-zendnn), 0.27.1.dev5+rocm10.0.0 (eim-vllm-rocm).

| Change | Images | Files touched | How |
|---|---|---|---|
| Fused-MoE tuning configs for the H100 NVL, aliased to the H100 80GB HBM3 configs | eim-vllm-cuda, eim-vllm-omni-cuda | Adds symlinks `vllm/model_executor/layers/fused_moe/configs/*device_name=NVIDIA_H100_NVL*.json`, each pointing at the matching existing `*device_name=NVIDIA_H100_80GB_HBM3*.json`. No existing file changes. | `RUN` step in `Dockerfile.eim-vllm-cuda` at build time |
| Launch wrapper `erebine-vllm` | every eim image | None in vLLM. Before importing vLLM it sets defaults for `HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE`, `HF_HUB_DISABLE_TELEMETRY`, `VLLM_NO_USAGE_STATS`, `DO_NOT_TRACK`, filters `SyntaxWarning`/`DeprecationWarning` for invalid escape sequences, replaces `huggingface_hub.get_safetensors_metadata` in memory (returns `None` for local directories), then calls `vllm.entrypoints.cli.main.main`. | Erebine script `/usr/local/bin/erebine-vllm`; the agent runs it in place of `vllm` |
| huggingface_hub version shim | every eim image | None in vLLM or huggingface_hub. Adds `erebine_hf_compat.py` and `erebine_hf_compat.pth` to site-packages; at interpreter start it replaces `importlib.metadata.version` in memory so an installed huggingface_hub 2.x reports `1.99.0`. | `.pth` start-up hook installed by each eim Dockerfile |

### vllm-omni

Pinned: v0.27.0rc1 (eim-vllm-omni-cuda). No changes.

### LMCache

Pinned: 0.5.4 (eim-vllm-cuda, eim-vllm-omni-cuda, eim-vllm-rocm).

| Change | Images | Files touched | How |
|---|---|---|---|
| fs L2 adapter capacity (`max_capacity_gb`) | eim-vllm-cuda, eim-vllm-omni-cuda, eim-vllm-rocm | None in LMCache. Replaces, in memory, `fs_l2_adapter.FSL2AdapterConfig.from_dict`, `FSL2Adapter.__init__` and `FSL2Adapter.get_usage`. | Erebine launcher `/usr/local/bin/erebine-lmcache` |
| s3 L2 adapter path-style addressing (`s3_bucket`) | same | None in LMCache. Replaces, in memory, `s3_l2_adapter.S3L2AdapterConfig.from_dict` and the module's `HttpRequest`. | same |

The eim-vllm-cpu and eim-vllm-zendnn images carry the launcher but do not
install LMCache.

## Template for a new entry

```
### <component>

Pinned: <version or tag> (<images>).

| Change | Images | Files touched | How |
|---|---|---|---|
| <what and why> | <images> | <upstream paths, and whether each is modified, added or removed> | <Dockerfile step, patch file, or launcher> |
```

## Verifying

For each image and pinned version, list installed vLLM files that differ
from the wheel's `RECORD`, and files in the package that `RECORD` does not
list. The only expected output is the `ADDED` symlinks above (CUDA images);
a `MODIFIED` line means an upstream file changed and needs an entry and a
notice.

```sh
docker run --rm --entrypoint /opt/venv/bin/python3 "$IMAGE" - <<'PY'
import base64, hashlib, importlib.metadata as md, pathlib
dist = md.distribution("vllm")
recorded = set()
for f in dist.files or []:
    path = pathlib.Path(dist.locate_file(f))
    recorded.add(str(path))
    if f.hash is None or not path.is_file():
        continue
    digest = hashlib.new(f.hash.mode, path.read_bytes()).digest()
    if base64.urlsafe_b64encode(digest).rstrip(b"=").decode() != f.hash.value:
        print("MODIFIED", f)
for path in pathlib.Path(dist.locate_file("vllm")).rglob("*"):
    if path.suffix != ".pyc" and (path.is_file() or path.is_symlink()) and str(path) not in recorded:
        print("ADDED", path)
PY
```

Repeat with `md.distribution("lmcache")` and `dist.locate_file("lmcache")`
for LMCache; expected output is empty.
