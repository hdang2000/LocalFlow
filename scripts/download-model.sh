#!/bin/sh
# Downloads the Whisper large-v3-turbo model (~1.6 GB) and verifies its SHA-1.
set -eu
dir="$HOME/Library/Application Support/LocalFlow/models"
file="$dir/ggml-large-v3-turbo.bin"
sha="4af2b29d7ec73d781377bfd1758ca957a807e941"
mkdir -p "$dir"
if [ -f "$file" ] && [ "$(shasum -a 1 "$file" | cut -d' ' -f1)" = "$sha" ]; then
  echo "Model already present and verified."; exit 0
fi
curl -fL --progress-bar -o "$file.part" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
[ "$(shasum -a 1 "$file.part" | cut -d' ' -f1)" = "$sha" ] || { echo "Checksum mismatch"; rm -f "$file.part"; exit 1; }
mv "$file.part" "$file"
echo "Model ready: $file"
