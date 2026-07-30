#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:?"usage: verify-release-asr.sh OUTPUT_DIR [AUDIO_SECONDS]"}
audio_seconds=${2:-3600}
scratch=${PAPERCLIP_RUN_SCRATCH_DIR:-"$repository/.build/ai16-verification"}
runtime="$repository/evidence/AI-4/runtime/sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts/lib"
model="$repository/evidence/AI-4/models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23"
wav="$model/test_wavs/0.wav"

mkdir -p "$output"
swift build --disable-sandbox --scratch-path "$scratch/release" \
  -c release --product AIListenerASRStress

binary="$scratch/release/release/AIListenerASRStress"
connections="$output/runtime-connections.txt"
: > "$connections"
"$binary" "$runtime/libsherpa-onnx-c-api.dylib" "$model" "$wav" "$audio_seconds" \
  > "$output/release-stress.json" 2> "$output/release-stress.stderr.txt" &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
  lsof -n -P -a -p "$pid" -i >> "$connections" 2>/dev/null || true
  sleep 0.2
done
wait "$pid"

if test -s "$connections"; then
  echo "unexpected network socket observed" >&2
  exit 1
fi
rtf=$(plutil -extract realTimeFactor raw "$output/release-stress.json")
rss=$(plutil -extract peakRSSBytes raw "$output/release-stress.json")
awk -v value="$rtf" 'BEGIN { exit !(value <= 0.8) }' || {
  echo "RTF exceeds 0.8: $rtf" >&2
  exit 1
}
awk -v value="$rss" 'BEGIN { exit !(value <= 3758096384) }' || {
  echo "peak RSS exceeds 3.5 GiB: $rss" >&2
  exit 1
}
if rg -n 'URLSession|https?://|WebSocket|grpc|api[_-]?key' \
  "$repository/Sources" "$repository/Package.swift"; then
  echo "network-capable product token observed" >&2
  exit 1
fi
shasum -a 256 "$runtime/libsherpa-onnx-c-api.dylib" \
  "$runtime/libonnxruntime.1.24.4.dylib" \
  "$model/encoder-epoch-99-avg-1.int8.onnx" \
  "$model/decoder-epoch-99-avg-1.onnx" \
  "$model/joiner-epoch-99-avg-1.int8.onnx" \
  "$model/tokens.txt" > "$output/runtime-model.sha256"
