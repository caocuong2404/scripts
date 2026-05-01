#!/bin/bash
# Obfuscate all src/*.sh → root *.sh using base64+eval stub
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$ROOT/src"

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: $SRC_DIR not found" >&2; exit 1
fi

count=0
for src in "$SRC_DIR"/*.sh; do
  [ -f "$src" ] || continue
  name="$(basename "$src")"
  out="$ROOT/$name"
  B64=$(base64 < "$src" | tr -d '\n')
  printf '#!/bin/bash\neval "$(echo '"'"'%s'"'"' | base64 -d)"\n' "$B64" > "$out"
  echo "  built: $name"
  count=$((count + 1))
done

echo "Done — $count file(s) obfuscated."
