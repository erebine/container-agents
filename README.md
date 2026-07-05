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

## Getting Started

To get started with Erebine.ai, simply clone the repository and follow the instructions in the
README file. The compose files are located in the `compose` directory, and you can choose
the one that best suits your needs.

Before running the compose files, make sure to set the `EREBINE_AGENT_JOIN_KEY` environment
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
export EREBINE_AGENT_JOIN_KEY=xxxxxxxx
sudo podman compose -f compose/compose.agent-amd-rocm.yaml down
sudo -E podman compose -f compose/compose.agent-amd-rocm.yaml up -d
sudo podman logs eim-vllm-rocm -f
```

* The first command sets the required environment variable for the join key.
* The second command ensures that any existing containers are stopped and removed.
* The third command starts the new containers in detached mode.
* The last command allows you to view the logs of the running container in real-time.

### Optional system configuration

While optional, these settings can help improve performance when running AI workloads in containers.
They adjust the maximum buffer sizes for network communication, which can be beneficial for
certain workloads that require high throughput.

``` shell
sudo sysctl -w net.core.wmem_max=4194304 | tee -a /etc/sysctl.conf
sudo sysctl -w net.core.rmem_max=4194304 | tee -a /etc/sysctl.conf
```
