#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:-"$repository/dist"}
scratch=${2:-"$repository/.build"}
app="$output/AIListener.app"
runtime="$repository/evidence/AI-4/runtime/sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts/lib"
model="$repository/evidence/AI-4/models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23"

swift build --disable-sandbox --scratch-path "$scratch" -c release --product AIListenerApp
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" \
  "$app/Contents/Resources/Model" "$app/Contents/Resources/Licenses"
cp "$scratch/release/AIListenerApp" "$app/Contents/MacOS/AIListenerApp"
cp "$repository/Config/Info.plist" "$app/Contents/Info.plist"
cp "$runtime/libsherpa-onnx-c-api.dylib" "$app/Contents/Frameworks/"
cp "$runtime/libonnxruntime.1.24.4.dylib" "$app/Contents/Frameworks/"
cp "$model/encoder-epoch-99-avg-1.int8.onnx" "$app/Contents/Resources/Model/"
cp "$model/decoder-epoch-99-avg-1.onnx" "$app/Contents/Resources/Model/"
cp "$model/joiner-epoch-99-avg-1.int8.onnx" "$app/Contents/Resources/Model/"
cp "$model/tokens.txt" "$app/Contents/Resources/Model/"
cp "$repository/evidence/AI-4/runtime/sherpa-onnx/LICENSE" \
  "$app/Contents/Resources/Licenses/sherpa-onnx-LICENSE"
cp "$model/README.md" "$app/Contents/Resources/Licenses/model-README.md"

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"
find "$app" -type f -print0 | sort -z | xargs -0 shasum -a 256 > "$output/AIListener.app.sha256"
