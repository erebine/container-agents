# Changes to upstream components in the Erebine agent images

## Rule

Apache-2.0 section 4(b) requires modified files to carry prominent notices
stating that they were changed. Every change these images make to an
upstream component is listed here: what changes, the files touched, the
images affected, and the pinned upstream version it applies to.

- A source patch to an upstream component marks every line it changes with
  a "Modified by Erebine" comment, and the image ships the patch and a
  notice that the component was modified beside the component's other
  notices. `THIRD_PARTY_NOTICES` names the component as modified and points
  here. An edit to an installed file is listed here with the file it edits.
- Update an entry when its change, or the pinned version it applies to,
  changes; remove it when the change is retired.
- Re-check this file against the images whenever a pinned version changes
  (see "Verifying" below).

## Findings

Checked 2026-11-15 against the v3.4.0 images: the Dockerfiles and launch
scripts that build them, and the license files in the published images.
This file covers the images the notices in this repository describe:
eim-vllm-cuda, eim-vllm-omni-cuda, eim-vllm-rocm, eim-vllm-omix,
eim-vllm-omni-omix, eim-vllm-cpu, eim-vllm-zendnn and eem. It does not cover
the speech and Laya images.

- Two upstream sources are patched, both in the Intel GPU images and both so
  that they build with the open-source DPC++ compiler: oneCCL, and the build
  files of vllm-xpu-kernels.
- One installed upstream file is edited: Triton's `entry_points.txt`, in the
  images that remove Triton's NVIDIA backend.
- No image patches vLLM, vllm-omni or LMCache source, and no file of theirs
  is edited. The images change how they run through Erebine launchers that
  replace functions in memory, add files inside installed packages, and
  drop or replace dependencies the components declare.
- The images remove files they must not ship: NVIDIA developer tools, AMD
  binary-only, debugger and profiler tools, and PyTorch's CMake files. Each
  removal is listed.
- The eem image changes no upstream component. libzmq and libsodium, in
  every image, are built from unmodified upstream source; UMF and PTI, in
  the Intel GPU images, are built from unmodified source with their own
  build options (UMF without its CUDA memory provider).

### vLLM

Pinned: 0.33.0 (eim-vllm-cuda, eim-vllm-omni-cuda, eim-vllm-cpu,
eim-vllm-zendnn), 0.33.0+xpu from the v0.33.0rc3 release assets
(eim-vllm-omix, eim-vllm-omni-omix), 0.29.1.dev0+rocm10.1.0, AMD's build
(eim-vllm-rocm).

| Change | Images | Files touched | How |
|---|---|---|---|
| Fused-MoE tuning configs for the H100 NVL, aliased to the H100 80GB HBM3 configs | eim-vllm-cuda, eim-vllm-omni-cuda | Adds symlinks `vllm/model_executor/layers/fused_moe/configs/*device_name=NVIDIA_H100_NVL*.json`, each pointing at the matching existing `*device_name=NVIDIA_H100_80GB_HBM3*.json`, where no NVL file exists. No existing file changes. | Build step |
| Launch wrapper `erebine-vllm` | every image above except eem | None in vLLM. Before importing vLLM it sets defaults for `HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE`, `HF_HUB_DISABLE_TELEMETRY`, `VLLM_NO_USAGE_STATS`, `DO_NOT_TRACK`, filters `SyntaxWarning`/`DeprecationWarning` for invalid escape sequences, replaces `huggingface_hub.get_safetensors_metadata` in memory (returns `None` for local directories), applies the three changes below, then calls `vllm.entrypoints.cli.main.main`. | Erebine script `/usr/local/bin/erebine-vllm`; the EIM runs it in place of `vllm` |
| Cached prompt tokens on every continuous-usage chunk | same | None on disk. Replaces `OpenAIServingChat.chat_completion_stream_generator` (`vllm.entrypoints.openai.chat_completion.serving`) in memory. On a stream that asks for `continuous_usage_stats`, from a server started with `--enable-prompt-tokens-details`, each usage chunk gains `prompt_tokens_details.cached_tokens`, the count vLLM reports for the request. | `erebine-vllm` |
| Reasoning tokens in usage, for a vLLM that does not report them | same | None on disk. Replaces `OpenAIServingChat.chat_completion_stream_generator` and `chat_completion_full_generator` in memory to add `usage.completion_tokens_details.reasoning_tokens`, only when the serving module lacks vLLM's own support (`_make_completion_tokens_details`, vLLM 0.29.0 and later). The vLLM in these images has it, so here the change does nothing. | `erebine-vllm` |
| The torchcodec fallback warning once per process | same | None in vLLM. Adds a logging filter to the logger of `vllm.multimodal.media.audio` that passes the first "torchcodec unavailable" warning in each process and drops the repeats. | `erebine-vllm` |
| huggingface_hub version shim | same | None in vLLM or huggingface_hub. Adds `erebine_hf_compat.py` and `erebine_hf_compat.pth` to site-packages; at interpreter start it replaces `importlib.metadata.version` in memory so an installed huggingface_hub 2.x reports `1.99.0`. | `.pth` start-up hook installed by each image |
| Intel OpenMP requirement dropped | eim-vllm-cpu, eim-vllm-zendnn | None in vLLM. The CPU wheel requires `intel-openmp==2024.2.1` on x86_64; that requirement, and the `intel-cmplr-lib-ur` it pulls in, are overridden out of the install. The images preload LLVM's OpenMP runtime through `/usr/local/lib64/libiomp5.so` instead (see `VENDOR_NOTICES`). | Install override at build time |
| tensorizer requirement overridden | eim-vllm-rocm | None in vLLM. The wheel requires `tensorizer==2.10.1`; the image installs 2.12.1, as AMD's ROCm 10.1.0 vLLM installation guide directs. | Install step |

### vllm-omni

Pinned: 0.33.0rc1 (eim-vllm-omni-cuda, eim-vllm-omni-omix).

| Change | Images | Files touched | How |
|---|---|---|---|
| OpenCV GUI build left out | eim-vllm-omni-cuda, eim-vllm-omni-omix | None in vllm-omni. Its dependencies cosmos-guardrail and retinaface-py require `opencv-python`, OpenCV's GUI build, whose `cv2` needs X11, GL and Qt libraries the images do not carry. `opencv-python` is not installed; `cv2` is vLLM's `opencv-python-headless`, the same OpenCV release without highgui. | Install step |
| Python version marker set aside | eim-vllm-omni-omix | None in vllm-omni. Every vllm-omni release declares `Requires-Python <3.14`, and the Intel GPU image runs CPython 3.14, so the install ignores that marker. Every other installed distribution is held at its version, and the build checks that vllm-omni imports. | Install step |
| Dependencies left out | eim-vllm-omni-omix | None in vllm-omni. The thirteen distributions the Intel GPU image leaves out (see PyTorch below) and `fa3-fwd`, a CUDA kernel, are dropped from what the vllm-omni install adds. | Install step |

### LMCache

Pinned: 0.5.6 (eim-vllm-cuda, eim-vllm-omni-cuda), 0.5.5 (eim-vllm-rocm). Both
images build it from the release's unmodified source, against their own
torch, with its Rust `raw_block` extension from the same tag.

| Change | Images | Files touched | How |
|---|---|---|---|
| fs L2 adapter capacity (`max_capacity_gb`) | eim-vllm-cuda, eim-vllm-omni-cuda, eim-vllm-rocm | None in LMCache. Replaces, in memory, `fs_l2_adapter.FSL2AdapterConfig.from_dict`, `FSL2Adapter.__init__` and `FSL2Adapter.get_usage`. | Erebine launcher `/usr/local/bin/erebine-lmcache` |
| s3 L2 adapter path-style addressing (`s3_bucket`) | same | None in LMCache. Replaces, in memory, `s3_l2_adapter.S3L2AdapterConfig.from_dict` and the module's `HttpRequest`. | same |

The eim-vllm-cpu and eim-vllm-zendnn images carry the launcher but do not
install LMCache. The Intel GPU images carry neither.

### Triton

Pinned: as each image's torch and vLLM resolve it; the CPU images pin
triton 3.8.0+cpu.

| Change | Images | Files touched | How |
|---|---|---|---|
| NVIDIA backend removed | eim-vllm-cpu, eim-vllm-zendnn, eim-vllm-rocm; eim-vllm-omix (and so eim-vllm-omni-omix) only if a dependency brings the backend in | Removes `triton/backends/nvidia/` (in eim-vllm-rocm also `*_triton/backends/nvidia/`) and **modifies** `*triton*.dist-info/entry_points.txt`: the `nvidia =` line is deleted, so `import triton` does not look for the removed backend. | Build step (`sed -i`) |
| NVIDIA developer tools removed | eim-vllm-cuda, eim-vllm-omni-cuda | Removes `ptxas`, `ptxas-blackwell`, `nvdisasm` and `cuobjdump` from `triton` and `tokenspeed_triton`; `libdevice.10.bc` stays. | Build step |

### NVIDIA CUDA wheels

Pinned: as the torch cu130 build and vLLM 0.33.0 resolve them;
`nvidia-nvvm` and `nvidia-cuda-crt` at 13.4.92 (eim-vllm-cuda,
eim-vllm-omni-cuda).

| Change | Images | Files touched | How |
|---|---|---|---|
| CUDA compiler removed | eim-vllm-cuda, eim-vllm-omni-cuda | Uninstalls `nvidia-cuda-nvcc`, which vLLM's tilelang, humming-kernels and cuda-toolkit dependencies require, and `nvidia-cuda-nvdisasm`, and removes `cicc` from `nvidia/cu13/nvvm/bin/` (the `nvidia-nvvm` wheel). `libnvvm` and `libdevice.10.bc` stay. At run time the operator can supply a CUDA toolkit. | Build step |
| Unversioned CUDA runtime link | eim-vllm-cuda, eim-vllm-omni-cuda | Adds `nvidia/cu13/lib/libcudart.so`, a symbolic link to `libcudart.so.13`. No file changes. | Build step |

### AMD ROCm SDK

Pinned: the ROCm 10.1.0 wheels (eim-vllm-rocm).

| Change | Images | Files touched | How |
|---|---|---|---|
| Binary-only, debugger and profiler tools removed | eim-vllm-rocm | Removes from `_rocm_sdk_core`: `lib/librocprof-trace-decoder.so*`, which is binary-only under AMD's own terms; the `rocgdb*`, `rocgcore*`, `roccoremerge*`, `rocprofv3` and `rocprofv3-avail` programs; `lib/rocprofiler-sdk/`, `lib/roctracer/`, `share/roctracer/`, `share/rocgdb/` and `lib/python3/site-packages/rocprofv3/`. Removes the matching console scripts from the venv's `bin/`. | Build step |
| Development links and headers added | eim-vllm-rocm | Adds an unversioned `<name>.so` symbolic link beside each versioned library in `_rocm_sdk_core/lib/`, and copies the rocPRIM and hipCUB headers from `rocm-sdk-devel` of the same release into `_rocm_sdk_core/include/`. No file changes. | Build step |

### AMD Quark

Pinned: amd-quark 0.12.post1 (eim-vllm-rocm).

| Change | Images | Files touched | How |
|---|---|---|---|
| Prebuilt hw_emulation kernels | eim-vllm-rocm | Adds `quark/torch/kernel/hw_emulation/lib/libhw_emulation_gpu.so`, compiled from Quark's own sources with the flags its run-time compile uses, and the hipified copies of those sources that the build writes beside the originals. No existing file changes. | Build step |
| Python version marker set aside | eim-vllm-rocm | None in Quark. amd-quark 0.12.post1 declares `Requires-Python <3.14`; vLLM requires that release, AMD builds its vLLM wheel for CPython 3.14 only, and amd-quark is a pure-Python wheel, so it is installed on 3.14. | Install step |

### PyTorch

Pinned: as each image's vLLM names it.

| Change | Images | Files touched | How |
|---|---|---|---|
| CMake package files removed | every image above except eem | Removes `torch/share/cmake/`. | Build step |
| oneAPI runtime requirements replaced | eim-vllm-omix, eim-vllm-omni-omix | None in torch. The requirements that torch's XPU wheel, the oneMKL wheels and vLLM declare on seven oneAPI runtime wheels under Intel's developer-tools license agreement (`intel-sycl-rt`, `intel-cmplr-lib-rt`, `intel-cmplr-lib-ur`, `intel-cmplr-lic-rt`, `dpcpp-cpp-rt`, `intel-opencl-rt`, `intel-openmp`), and on `oneccl`, `oneccl-devel`, `impi-rt`, `intel-pti`, `umf` and `auto-round-lib`, are overridden out of the install. The open-source SYCL runtime and the oneCCL, PTI and vllm-xpu-kernels builds stand in for them; without `auto-round-lib`, vLLM's INC int2 path is unavailable. | Install override at build time |

### oneCCL

Pinned: 2022.1.1, uxlfoundation/oneCCL at e7c674e0 (eim-vllm-omix,
eim-vllm-omni-omix).

| Change | Images | Files touched | How |
|---|---|---|---|
| Builds with the open-source DPC++ compiler | eim-vllm-omix, eim-vllm-omni-omix | **Modifies** `CMakeLists.txt` (the Release flags of `libccl.so.2` and its plugins drop `-march=native` and `-flto`) and `deps/libccl/CMakeLists.txt` (`CMAKE_CXX_STANDARD` 11 to 17, which SYCL requires). Each changed line carries a "Modified by Erebine" comment. The image ships the patch and `oneccl.MODIFIED` in `/opt/oneccl/share/licenses/`, beside oneCCL's `LICENSE`. | `oneccl-2022.1.1-open-source-dpcpp.patch`, applied with `git apply` before the build |

### vllm-xpu-kernels

Pinned: 0.1.15.4, vllm-project/vllm-xpu-kernels release/v0.1.15 at 1c7cbeee
(eim-vllm-omix, eim-vllm-omni-omix).

| Change | Images | Files touched | How |
|---|---|---|---|
| Builds with the open-source DPC++ compiler | eim-vllm-omix, eim-vllm-omni-omix | **Modifies** `setup.py` (the `icpx -v` version probe is removed) and `cmake/toolchain.cmake` (`clang` and `clang++` in place of `icx` and `icpx`). Each changed line carries a "Modified by Erebine" comment. The image ships the patch and a `MODIFIED` notice in `/usr/share/licenses/erebine/intel/oss/vllm-xpu-kernels/`. | `vllm-xpu-kernels-0.1.15.4-open-source-dpcpp.patch`, applied with `git apply` before the build |
| Build options | eim-vllm-omix, eim-vllm-omni-omix | None in the source. Built for Xe2 GPUs only, with the Xe3P attention kernels off and upstream's "default" attention kernel set rather than the "full" set the published wheel carries. An attention combination outside that set falls back to a slower reference path, or stops the engine with an error naming it. | Build step |

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
for LMCache; expected output is empty. Repeat with `triton` for Triton: in
the images that remove its NVIDIA backend, the expected output is its
`entry_points.txt` as `MODIFIED`. Removed files are not reported.
