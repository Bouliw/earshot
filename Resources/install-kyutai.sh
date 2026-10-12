#!/bin/zsh
# Installs the "High" live caption engine: Kyutai STT 1B en_fr on MLX, in its own Python environment.
# Usage: install-kyutai.sh <folder>. Everything goes into that folder; deleting it uninstalls the engine.
set -euo pipefail
dir=$1
repo=https://huggingface.co/kyutai/stt-1b-en_fr-mlx/resolve/2b995724eef1e964b7ccb6a762b35a665c4abe0d
mkdir -p "$dir/model"

# moshi_mlx pins sentencepiece 0.2.0, whose wheels stop at Python 3.12.
python=""
for p in {/opt/homebrew,/usr/local}/bin/python3.{12,11,10} /Library/Frameworks/Python.framework/Versions/3.{12,11,10}/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [[ -x $p ]] && $p -c 'import sys; sys.exit(not (3, 10) <= sys.version_info[:2] <= (3, 12))' 2>/dev/null; then python=$p; break; fi
done
[[ -n $python ]] || { echo "Python 3.10, 3.11 or 3.12 is needed (python.org or Homebrew)." >&2; exit 2; }
[[ -x $dir/venv/bin/python ]] || $python -m venv "$dir/venv"
"$dir/venv/bin/pip" install --quiet --disable-pip-version-check moshi_mlx==0.3.0

# Pinned revision, and each file checked against its SHA-256 before it is used.
for name sum in \
  config.json 5e6aee8007000d844152932184fb7c7112d73cb9a4be562a313b6fa2b89a68f9 \
  tokenizer_en_fr_audio_8000.model cd87dd5d17169151782ac700280ec057e5d658a9afbe238a048ea5ff318cce69 \
  mimi-pytorch-e351c8d8@125.safetensors 09b782f0629851a271227fb9d36db65c041790365f11bbe5d3d59369cf863f50 \
  model.safetensors 7c21d5adb06f87aaaff2fa34f16dce91a8fe4f1772820453cf3eb0a5285ed129
do
  out=$dir/model/$name
  [[ -f $out ]] && continue
  curl -fsSL --retry 3 -C - -o "$out.part" "$repo/$name"
  if [[ $(shasum -a 256 "$out.part" | cut -d' ' -f1) != "$sum" ]]; then
    rm -f "$out.part"; echo "Checksum mismatch for $name." >&2; exit 3
  fi
  mv "$out.part" "$out"
done
touch "$dir/.installed"
