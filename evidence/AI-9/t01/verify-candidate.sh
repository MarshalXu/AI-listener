#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cd "$repo_root"

check_hash() {
  expected=$1
  path=$2
  actual=$(shasum -a 256 "$path" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "hash mismatch: $path" >&2
    exit 1
  fi
  printf '%s  %s\n' "$actual" "$path"
}

python3 -m json.tool evidence/AI-9/t01/adapter-candidate.json >/dev/null
python3 -m json.tool evidence/AI-9/t01/sbom.spdx.json >/dev/null

check_hash d880aaa79d36b784168a0398b278813d57ba8e135f468894b8f134b664e2e225 \
  evidence/AI-4/runtime/sherpa-runtime.tar.bz2
check_hash 2cbd71b640d9c37d3784f29367333a4577b0398b62e9deeed418170b081cba8b \
  evidence/AI-4/models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23.tar.bz2
check_hash cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 \
  evidence/AI-4/runtime/sherpa-onnx/LICENSE
check_hash 515751f07faad368f0863ae41773ff09635eba5920122d549abb8e45d5c88282 \
  evidence/AI-4/models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/README.md
check_hash 8b294db9045d6e5f94647f4c1eec1af4da143a75053c399611444b378ff966ac \
  evidence/AI-4/models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/tokens.txt
check_hash 1c556ea57cec304e55ec4b72e52c1cc098bb01476ed7d90f3de939fe126487b1 \
  evidence/AI-4/models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/encoder-epoch-99-avg-1.int8.onnx
check_hash 5ee0f03a2768ff1d5c83ef3a493243c7935d316cd41280037b14783a3467cc78 \
  evidence/AI-4/models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/decoder-epoch-99-avg-1.onnx
check_hash a7cf9d82757bdcf786059454495a9ca95e4bd7347f72473fc08d794475c36169 \
  evidence/AI-4/models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/joiner-epoch-99-avg-1.int8.onnx

echo "candidate manifest and SPDX SBOM verified; adapter remains not locked"
