#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# check-license.sh -- fail when this repository tells people to run an image
# whose terms it does not state.
#
# Why this exists
# ---------------
# No image is built here. The Dockerfiles, the OCI license labels and the
# license files inside the images all live in Erebine/platform. What this
# repository ships is the instruction to pull and run those images, and three
# documents that say what running them means:
#
#   LICENSE       the MIT text covering the Erebine layer, a copy of the
#                 platform's Resources/licensing/erebine-binaries-MIT.txt.
#   VENDOR_NOTICES the NVIDIA and AMD terms that bind anyone who runs the GPU
#                 images. These restrict use and not only redistribution --
#                 emotion recognition is prohibited outright on the NVIDIA
#                 images -- so a reader who follows a compose file without
#                 seeing this document can breach terms by running it.
#   THIRD_PARTY_NOTICES, PATCHES.md
#                 where the component notices are, and what Erebine changes.
#
# The failure this guards against is specific and quiet: a compose file gains
# an image, or an image is renamed, and VENDOR_NOTICES is not updated. The
# repository then instructs people to run something whose terms it has never
# stated, and every other check in the world still passes. Everything here is
# repository-local for that reason -- it is the agreement between the compose
# files and the notices that can drift, not the images.
#
# Nothing in this check resolves a registry, a release or a tag.
#
# Usage
# -----
#   scripts/check-license.sh              # check the repository
#   scripts/check-license.sh --self-test  # run against fixtures
#
# Exit status: 0 pass, 1 check failed, 2 usage error.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The only registry path the compose files may name. An image published
# anywhere else is not one whose terms these notices describe.
REGISTRY="ghcr.io/erebine/container-agents"

# Erebine/platform Resources/licensing/erebine-binaries-MIT.txt, byte for
# byte. LICENSE is a copy of that file, so the comparison is exact.
read -r -d '' CANONICAL_LICENSE <<'TXT' || true
MIT License

Copyright (c) 2026 Kevin Carter

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Trademarks are not licensed under this license. See https://erebine.ai/trademark.
Third-party components: see THIRD_PARTY_NOTICES.

Erebine is MIT-licensed agents, an open API, a proprietary control plane.
The erectl client and the EIM and EEM agents are distributed as MIT-licensed
binaries. The Erebine platform (router, control plane, frontend) is proprietary.
Documentation and design papers are published under CC BY 4.0.
TXT

# The documents that govern the vendor software in the GPU images. This
# notice summarizes them and is only safe as a summary while it links them.
REQUIRED_TERMS_LINKS=(
  "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-software-license-agreement/"
  "https://www.nvidia.com/en-us/agreements/enterprise-software/product-specific-terms-for-ai-products/"
  "https://rocm.docs.amd.com/en/latest/about/license.html"
)

# Files the licensing documents refer to by name. A dangling reference sends
# a reader looking for terms that are not there.
REQUIRED_FILES=(LICENSE VENDOR_NOTICES THIRD_PARTY_NOTICES PATCHES.md README.md)

# Prints one "<file>\t<image-ref>" line per image reference in the compose
# files under ROOT, with ${VAR:-default} expanded to its default.
compose_images() {
  python3 - "$1" <<'PY'
import os
import re
import sys

root = sys.argv[1]
compose = os.path.join(root, "compose")
if not os.path.isdir(compose):
    sys.exit(0)


def expand(text):
    """Returns the text with ${VAR:-default} reduced to default."""
    text = re.sub(r"\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}", r"\1", text)
    text = re.sub(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", "", text)
    return text


for name in sorted(os.listdir(compose)):
    if not name.endswith((".yaml", ".yml")):
        continue
    path = os.path.join(compose, name)
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = re.match(r"\s*image:\s*(\S+)\s*$", line)
            if match:
                print(f"compose/{name}\t{expand(match.group(1))}")
PY
}

# Runs every check under ROOT. Prints one line per check and returns 0 when
# all of them pass.
check_tree() {
  local root="$1" failed=0 name

  for name in "${REQUIRED_FILES[@]}"; do
    if [ -s "$root/$name" ]; then
      echo "ok   $name: present and non-empty"
    else
      echo "FAIL $name: missing or empty"
      failed=1
    fi
  done

  if [ -s "$root/LICENSE" ]; then
    if printf '%s\n' "$CANONICAL_LICENSE" | diff -u - "$root/LICENSE" >/dev/null; then
      echo "ok   LICENSE: matches the canonical Erebine license text"
    else
      echo "FAIL LICENSE: differs from the canonical Erebine license text"
      printf '%s\n' "$CANONICAL_LICENSE" | diff -u --label canonical - \
        --label LICENSE "$root/LICENSE" | sed 's/^/     /' || true
      failed=1
    fi
  fi

  if [ -s "$root/VENDOR_NOTICES" ]; then
    local link
    for link in "${REQUIRED_TERMS_LINKS[@]}"; do
      if grep -qF -- "$link" "$root/VENDOR_NOTICES"; then
        echo "ok   VENDOR_NOTICES: links ${link##*/agreements/}"
      else
        echo "FAIL VENDOR_NOTICES: no longer links $link"
        failed=1
      fi
    done
  fi

  # The README is where a reader starts, and the GPU restrictions are the
  # part they are least likely to expect. It must send them to the notice.
  if [ -s "$root/README.md" ] && grep -qF 'VENDOR_NOTICES' "$root/README.md"; then
    echo "ok   README.md: points at VENDOR_NOTICES"
  else
    echo "FAIL README.md: does not point at VENDOR_NOTICES"
    failed=1
  fi

  # Every image these compose files tell people to run must be published
  # where the notices say, and must be named in VENDOR_NOTICES -- whether it
  # carries vendor terms or is recorded as carrying none.
  local images seen=0 line file ref image
  images="$(compose_images "$root")"
  while IFS=$'\t' read -r file ref; do
    [ -n "${ref:-}" ] || continue
    seen=$((seen + 1))
    case "$ref" in
      "$REGISTRY"/*) ;;
      *)
        echo "FAIL $file: image is not published under $REGISTRY"
        echo "     $ref"
        failed=1
        continue ;;
    esac
    image="${ref#"$REGISTRY"/}"
    image="${image%%:*}"
    if grep -qE "(^|[^A-Za-z0-9_-])${image}([^A-Za-z0-9_-]|$)" "$root/VENDOR_NOTICES"; then
      echo "ok   $file: $image is covered by VENDOR_NOTICES"
    else
      echo "FAIL $file: $image is not named in VENDOR_NOTICES"
      echo "     Every image a compose file runs must be recorded there, as"
      echo "     carrying vendor terms or as carrying none."
      failed=1
    fi
  done <<<"$images"

  if [ "$seen" -eq 0 ]; then
    echo "FAIL compose/: no image references found"
    failed=1
  fi

  for name in LICENSE VENDOR_NOTICES THIRD_PARTY_NOTICES PATCHES.md README.md; do
    [ -f "$root/$name" ] || continue
    if LC_ALL=C grep -q '[^[:print:][:space:]]' "$root/$name"; then
      echo "FAIL $name: non-ASCII bytes"
      LC_ALL=C grep -n '[^[:print:][:space:]]' "$root/$name" | head -5 | sed 's/^/     /'
      failed=1
    else
      echo "ok   $name: ASCII only"
    fi
  done

  return "$failed"
}

# Builds fixture trees and proves the check fails on an image no notice
# covers, an image from the wrong registry, an edited license text, a lost
# vendor terms link, a README that stops pointing at the notice, a missing
# document and a non-ASCII byte.
self_test() {
  local tmp status=0 case_name
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local good="$tmp/good"
  mkdir -p "$good/compose"
  printf '%s\n' "$CANONICAL_LICENSE" >"$good/LICENSE"
  printf 'See VENDOR_NOTICES for the vendor terms.\n' >"$good/README.md"
  printf 'Notices. See PATCHES.md.\n' >"$good/THIRD_PARTY_NOTICES"
  printf 'Changes to upstream components.\n' >"$good/PATCHES.md"
  {
    printf 'VENDOR NOTICES\n\n'
    printf '  eim-vllm-cuda        NVIDIA.\n'
    printf '  eem                  No vendor terms.\n\n'
    local link
    for link in "${REQUIRED_TERMS_LINKS[@]}"; do printf '  %s\n' "$link"; done
  } >"$good/VENDOR_NOTICES"
  cat >"$good/compose/compose.agent-nvidia.yaml" <<'YML'
services:
  agent:
    image: ${DOCKER_REGISTRY:-ghcr.io/erebine/container-agents}/eim-vllm-cuda:${VERSION:-latest}
YML
  cat >"$good/compose/compose.agent-eem.yaml" <<'YML'
services:
  eem:
    image: ${EEM_IMAGE:-ghcr.io/erebine/container-agents/eem:latest}
YML

  if check_tree "$good" >/dev/null; then
    echo "self-test ok   both compose reference shapes pass"
  else
    echo "self-test FAIL both compose reference shapes should pass"
    check_tree "$good" || true
    status=1
  fi

  for case_name in uncovered-image wrong-registry edited-license lost-terms-link \
                   readme-drops-notice missing-vendor-notices non-ascii; do
    local bad="$tmp/$case_name"
    cp -r "$good" "$bad"
    case "$case_name" in
      uncovered-image)
        cat >"$bad/compose/compose.agent-new.yaml" <<'YML'
services:
  agent:
    image: ${DOCKER_REGISTRY:-ghcr.io/erebine/container-agents}/eim-vllm-gaudi:${VERSION:-latest}
YML
        ;;
      wrong-registry)
        sed -i 's|ghcr.io/erebine/container-agents|ghcr.io/xerotier/container-agents|' \
          "$bad/compose/compose.agent-nvidia.yaml" ;;
      edited-license)
        sed -i 's/without restriction, including/for evaluation only, including/' \
          "$bad/LICENSE" ;;
      lost-terms-link)
        sed -i '\|rocm.docs.amd.com|d' "$bad/VENDOR_NOTICES" ;;
      readme-drops-notice)
        printf 'Getting started.\n' >"$bad/README.md" ;;
      missing-vendor-notices)
        rm -f "$bad/VENDOR_NOTICES" ;;
      non-ascii)
        printf 'NVIDIA\302\256\n' >>"$bad/VENDOR_NOTICES" ;;
    esac
    if check_tree "$bad" >/dev/null 2>&1; then
      echo "self-test FAIL $case_name should fail"
      status=1
    else
      echo "self-test ok   $case_name fails"
    fi
  done
  return "$status"
}

case "${1:-}" in
  "") check_tree "$REPO_ROOT" ;;
  --self-test) self_test ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
