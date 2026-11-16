# Erebine.ai Container Images

<div style="text-align: center;">
<img src="https://erebine.ai/erebine-ogimage.png" alt="Project Logo" width="50%">
</div>

A high-performance, accelerated intelligence platform.

Running standalone agents for inference and artificial intelligence workloads, is simple and
efficient. https://Erebine.ai is designed to be a powerful and flexible platform for running
AI workloads, with a focus on performance and ease of use.

Using the provided compose files, you can quickly set up and run your AI workloads with minimal
configuration. The compose files are designed to be easy to use and customizable, allowing you
to tailor the environment to your specific needs.

## Vendor terms

The GPU EIM images contain vendor software under vendor terms. The CUDA images
(`eim-vllm-cuda`, `eim-vllm-omni-cuda`) carry NVIDIA software, the ROCm image
(`eim-vllm-rocm`) AMD's, and the Intel GPU images (`eim-vllm-omix`,
`eim-vllm-omni-omix`) Intel's. Pulling or running those images is subject to
the vendor's terms, and some of them restrict use, not only redistribution --
the NVIDIA components, for one, are licensed only for use in systems with
NVIDIA GPUs. The CPU images (`eim-vllm-cpu`, `eim-vllm-zendnn`) contain no
software under Intel's developer-tools license agreement; the OpenMP runtime
they preload is LLVM's. The EEM image carries no NVIDIA, AMD or Intel software.

[VENDOR_NOTICES](VENDOR_NOTICES) names the terms, links them, lists the
restrictions you are least likely to expect, and says where each license text
sits inside the image.

## Getting Started

To get started with Erebine.ai, simply clone the repository and follow the instructions in the
README file. The compose files are located in the `compose` directory, and you can choose
the one that best suits your needs.

This repository carries the compose files and the license notices, not the images' Dockerfiles.
Erebine builds the images and publishes them to `ghcr.io/erebine/container-agents`; each image
carries its license texts under `/usr/share/licenses/erebine/`, and the EIM documentation at
https://erebine.ai/docs/eim lists every image and, for each image a file here runs, that compose
file.

Before running the compose files, make sure to set the `EREBINE_EIM_JOIN_KEY` environment
variable with your join key. This key is required for the agent to connect to the Erebine
network. You can obtain a join key from the Erebine dashboard.

Documentation for running private agents can be found in the
[docs](https://erebine.ai/docs/private-agents), which provides detailed information on how to use
and customize the compose files for your specific use case.

> **NVIDIA GPUs:** to run with Docker or Podman, install the
> [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
> first so the container runtime can access the GPU. Without it, the agent
> cannot reach CUDA inside the container.

Basic execution is as simple as running the following commands in your terminal:

``` shell
export EREBINE_EIM_JOIN_KEY=xxxxxxxx
export RENDER_GID="$(getent group render | cut -d: -f3)"
export VIDEO_GID="$(getent group video | cut -d: -f3)"
sudo mkdir -p /data/erebine/models /data/erebine/config /data/erebine/vllm-cache
sudo chown -R 5152:5152 /data/erebine
sudo podman compose -f compose/compose.agent-amd-rocm.yaml down
sudo -E podman compose -f compose/compose.agent-amd-rocm.yaml up -d
sudo podman logs eim-vllm-rocm -f
```

* The first three commands set the join key and the host's render and video group ids, which
  the ROCm and Intel files pass to the container by number.
* The `mkdir` and `chown` commands create the host directories the compose file mounts, owned
  by the user the EIM runs as (uid 5152). Each compose file's header lists the directories it
  mounts.
* The `down` command ensures that any existing containers are stopped and removed.
* The `up -d` command starts the new containers in detached mode.
* The last command allows you to view the logs of the running container in real-time.

### AMD GPU on Windows (WSL2)

WSL2 has no amdgpu driver: the GPU is WSL's `/dev/dxg`. Inside a WSL2
distribution, run the AMD stack from `compose/compose.agent-amd-rocm-wsl.yaml`
instead of `compose/compose.agent-amd-rocm.yaml`: it gives the container
`/dev/dxg` and `/usr/lib/wsl/lib/libdxcore.so`, runs unprivileged and turns
PyTorch's expandable segments off. An NVIDIA GPU uses
`compose/compose.agent-nvidia.yaml` unchanged. See
https://erebine.ai/docs/eim/windows.

```bash
sudo -E podman compose -f compose/compose.agent-amd-rocm-wsl.yaml up -d
```

### Optional system configuration

While optional, these settings can help improve performance when running AI workloads in containers.
They adjust the maximum buffer sizes for network communication, which can be beneficial for
certain workloads that require high throughput.

``` shell
sudo sysctl -w net.core.wmem_max=4194304 | tee -a /etc/sysctl.conf
sudo sysctl -w net.core.rmem_max=4194304 | tee -a /etc/sysctl.conf
```
