// SPDX-License-Identifier: MIT
import Foundation

/// Rendered artifacts the installer writes to disk: the launchd entrypoint, the
/// vLLM wrapper, and the HuggingFace compat shim. The app embeds them so it is
/// self-contained and is the source of truth for these files.
enum Templates {
    /// launchd entrypoint: enroll-once, then run. Installed to ~/.local/bin.
    static let entrypoint = #"""
    #!/bin/bash
    # SPDX-License-Identifier: MIT
    # Xerotier Backend Agent Entrypoint (macOS / Apple Silicon)
    # Handles one-time enrollment and subsequent runs under launchd.

    set -e

    ENROLLMENT_STATE_FILE="${HOME}/.config/xerotier/enrollment.json"
    AGENT_BIN="${XEROTIER_AGENT_BIN:-${HOME}/.local/bin/xerotier-xim-agent}"

    export XEROTIER_AGENT_VLLM_PATH="${XEROTIER_AGENT_VLLM_PATH:-${HOME}/.local/bin/xerotier-vllm}"

    build_enroll_args() {
        local args=("enroll")
        [[ -n "${XEROTIER_AGENT_JOIN_KEY}" ]] && args+=("--join-key" "${XEROTIER_AGENT_JOIN_KEY}")
        [[ -n "${XEROTIER_AGENT_MAX_CONCURRENT}" ]] && args+=("--max-concurrent" "${XEROTIER_AGENT_MAX_CONCURRENT}")
        [[ -n "${XEROTIER_AGENT_LOG_LEVEL}" ]] && args+=("--log-level" "${XEROTIER_AGENT_LOG_LEVEL}")
        if [[ "${XEROTIER_AGENT_ALLOW_INSECURE}" == "1" ]] || [[ "${XEROTIER_AGENT_ALLOW_INSECURE}" == "true" ]]; then
            args+=("--insecure")
        fi
        echo "${args[@]}"
    }

    build_run_args() {
        local args=("run")
        [[ -n "${XEROTIER_AGENT_LOG_LEVEL}" ]] && args+=("--log-level" "${XEROTIER_AGENT_LOG_LEVEL}")
        [[ -n "${XEROTIER_AGENT_MAX_CONCURRENT}" ]] && args+=("--max-concurrent" "${XEROTIER_AGENT_MAX_CONCURRENT}")
        [[ -n "${XEROTIER_AGENT_VLLM_PATH}" ]] && args+=("--vllm-path" "${XEROTIER_AGENT_VLLM_PATH}")
        [[ -n "${XEROTIER_AGENT_METRICS_PORT}" ]] && args+=("--metrics-port" "${XEROTIER_AGENT_METRICS_PORT}")
        # Forward the agent's native tuning flags from env so they reliably reach
        # vLLM (the agent also reads these env vars, but passing the flags removes
        # any doubt about precedence).
        [[ -n "${XEROTIER_AGENT_GPU_MEMORY_UTILIZATION}" ]] && args+=("--gpu-memory-utilization" "${XEROTIER_AGENT_GPU_MEMORY_UTILIZATION}")
        [[ -n "${XEROTIER_AGENT_MAX_NUM_SEQS}" ]] && args+=("--max-num-seqs" "${XEROTIER_AGENT_MAX_NUM_SEQS}")
        [[ -n "${XEROTIER_AGENT_MAX_MODEL_LEN}" ]] && args+=("--max-model-len" "${XEROTIER_AGENT_MAX_MODEL_LEN}")
        [[ -n "${XEROTIER_AGENT_VLLM_QUANTIZATION}" ]] && args+=("--quantization" "${XEROTIER_AGENT_VLLM_QUANTIZATION}")
        [[ -n "${XEROTIER_AGENT_KV_CACHE_BACKEND}" ]] && args+=("--kv-cache-backend" "${XEROTIER_AGENT_KV_CACHE_BACKEND}")
        [[ -n "${XEROTIER_AGENT_MODEL_CACHE_MAX_SIZE_GB}" ]] && args+=("--model-cache-max-size-gb" "${XEROTIER_AGENT_MODEL_CACHE_MAX_SIZE_GB}")
        if [[ "${XEROTIER_AGENT_DISABLE_METRICS_SERVER}" == "1" ]] || [[ "${XEROTIER_AGENT_DISABLE_METRICS_SERVER}" == "true" ]]; then
            args+=("--disable-metrics-server")
        fi
        if [[ -n "${XEROTIER_AGENT_VLLM_ARGS}" ]]; then
            for arg in ${XEROTIER_AGENT_VLLM_ARGS}; do args+=("--vllm-arg=${arg}"); done
        fi
        if [[ -n "${XEROTIER_AGENT_VLLM_ENV}" ]]; then
            for env in ${XEROTIER_AGENT_VLLM_ENV}; do
                local val="${env#*=}"
                [[ -n "${val}" ]] && args+=("--vllm-env=${env}")
            done
        fi
        echo "${args[@]}"
    }

    main() {
        mkdir -p "$(dirname "${ENROLLMENT_STATE_FILE}")"
        if [[ $# -gt 0 ]]; then exec "${AGENT_BIN}" "$@"; fi

        if [[ -f "${ENROLLMENT_STATE_FILE}" ]]; then
            echo "[entrypoint] Enrollment state found; starting agent..."
            run_args=$(build_run_args)
            # shellcheck disable=SC2086
            exec "${AGENT_BIN}" ${run_args}
        fi

        if [[ -z "${XEROTIER_AGENT_JOIN_KEY}" ]]; then
            echo "[entrypoint] ERROR: No enrollment state and XEROTIER_AGENT_JOIN_KEY not set." >&2
            exit 1
        fi

        echo "[entrypoint] Enrolling with join key..."
        enroll_args=$(build_enroll_args)
        # shellcheck disable=SC2086
        if ! "${AGENT_BIN}" ${enroll_args}; then
            echo "[entrypoint] ERROR: Enrollment failed." >&2
            exit 1
        fi
        echo "[entrypoint] Enrollment successful; starting agent..."
        run_args=$(build_run_args)
        # shellcheck disable=SC2086
        exec "${AGENT_BIN}" ${run_args}
    }

    main "$@"
    """#

    /// vLLM wrapper (HF offline + local-safetensors). `@VENV_PYTHON@` is the
    /// absolute venv interpreter; substituted by `vllmWrapper(venvPython:)`.
    private static let vllmWrapperTemplate = #"""
    #!@VENV_PYTHON@
    # SPDX-License-Identifier: MIT
    # Xerotier vLLM Wrapper (macOS / Apple Silicon)

    import os
    import sys
    import warnings

    warnings.filterwarnings("ignore", message=r"invalid escape sequence", category=SyntaxWarning)
    warnings.filterwarnings("ignore", message=r"invalid escape sequence", category=DeprecationWarning)

    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

    try:
        import huggingface_hub
        _original = huggingface_hub.get_safetensors_metadata

        def _local_aware(repo_id, *args, **kwargs):
            if isinstance(repo_id, str) and os.path.isdir(repo_id):
                return None
            return _original(repo_id, *args, **kwargs)

        huggingface_hub.get_safetensors_metadata = _local_aware
    except (ImportError, AttributeError):
        pass

    from vllm.entrypoints.cli.main import main

    if __name__ == "__main__":
        sys.exit(main())
    """#

    /// huggingface_hub version-compat shim, installed into the venv via a .pth.
    static let hfCompat = #"""
    # SPDX-License-Identifier: MIT
    # Xerotier - HuggingFace Hub Compatibility Shim
    import importlib.metadata as _ilm

    _real_version = _ilm.version

    def _patched_version(name):
        if name.replace("-", "_").lower() == "huggingface_hub":
            try:
                real = _real_version(name)
                parts = real.split(".")
                major = int(parts[0]) if parts else 0
                if major >= 2:
                    return "1.99.0"
            except Exception:
                pass
        return _real_version(name)

    _ilm.version = _patched_version
    """#

    static func vllmWrapper(venvPython: String) -> String {
        vllmWrapperTemplate.replacingOccurrences(of: "@VENV_PYTHON@", with: venvPython)
    }
}
