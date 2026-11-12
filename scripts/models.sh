#!/usr/bin/env bash
# models.sh NAME [DIR] - download the model models.lock names, check it, and
# print the path of the file.
#
# The file comes from the publisher's URL at the pinned revision and only
# from there. It is refused when NAME has no line in models.lock, when its
# licence is not one of the permissive OSI licences below, and when its sha256
# is not the one the line pins. A file already in DIR is hashed again before
# it is used. DIR defaults to .cache/models; on a workstation it is the
# directory the runs keep their models in, and nothing else is read from it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="${MODELS_LOCK:-$ROOT/models.lock}"
name="${1:?usage: models.sh NAME [DIR]}"
dir="${2:-$ROOT/.cache/models}"
# Permissive OSI licences only. A model under any other licence, or under
# none the lock can name, is not served here.
ALLOWED=" Apache-2.0 MIT BSD-2-Clause BSD-3-Clause "
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

read -r url sum license < <(awk -v n="$name" '$1 == n && $0 !~ /^[[:space:]]*#/ {print $2, $3, $4}' "$LOCK" | head -n 1) || true
[ -n "${url:-}" ] && [ -n "${sum:-}" ] || { echo "models.lock has no line for '$name': not downloading it" >&2; exit 1; }
case "$ALLOWED" in
  *" $license "*) ;;
  *) echo "$name is licensed '$license', which is not a permissive OSI licence this repository serves" >&2; exit 1 ;;
esac
case "$url" in
  https://huggingface.co/*/resolve/[0-9a-f]*/*) ;;
  *) echo "$name: $url is not a file at a pinned revision of a Hugging Face repository" >&2; exit 1 ;;
esac

mkdir -p "$dir"
file="$dir/$name.gguf"
if [ ! -s "$file" ] || [ "$(sha256 "$file")" != "$sum" ]; then
  rm -f "$file.part"
  curl -fsSL --retry 3 -o "$file.part" "$url"
  got="$(sha256 "$file.part")"
  if [ "$got" != "$sum" ]; then
    rm -f "$file.part"
    echo "$name: the file is $got, models.lock pins $sum. Not keeping it." >&2
    exit 1
  fi
  mv -f "$file.part" "$file"
fi
printf '%s\n' "$file"
