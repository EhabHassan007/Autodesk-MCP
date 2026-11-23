#!/usr/bin/env bash
# Builds the LibreDWG pack (Windows x64) that Smart Connector's dwg_inspect and dwg_convert tools run.
#
#   scripts/build-libredwg-windows.sh [OUTPUT_FOLDER]      (default: ./libredwg-pack)
#
# Runs on Linux, macOS or WSL; nothing is built on the PCs and nothing from here is committed. It cross-compiles
# LibreDWG (GPL-3.0-or-later, https://github.com/libredwg/libredwg) at the pinned commit with Zig's bundled MinGW
# toolchain and writes the programs, libredwg.dll, the licence text, SOURCE.txt and SHA256SUMS to OUTPUT_FOLDER.
# release-preparation/beta17/libredwg-pack.json records the commit and the SHA-256 of every file; build.ps1
# -LibreDwgPack <folder> refuses a pack that does not match it, then adds it to the release ZIP and the setup .exe.
# Needs: git, cmake, ninja, python3 with the ziglang package (pip install ziglang==0.17.1), sha256sum.
set -euo pipefail

LIBREDWG_URL="https://github.com/libredwg/libredwg"
LIBREDWG_COMMIT="a5fdc8ef80c675b3a36dbefd11a902e9e3bfff9f"
JSMN_URL="https://github.com/zserge/jsmn"
JSMN_COMMIT="85695f3d5903b1cd5b4030efe50db3b4f5f3c928"   # LibreDWG's own submodule pin
PROGRAMS=(dwglayers dwggrep dwg2dxf dwgread dwgrewrite dwgbmp)

out="${1:-./libredwg-pack}"
for tool in git cmake ninja python3 sha256sum; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
python3 -m ziglang version >/dev/null 2>&1 || { echo "Missing Zig: pip install ziglang==0.17.1" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fetch() { # url commit folder
    git init -q "$3"
    git -C "$3" fetch -q --depth 1 "$1" "$2"
    git -C "$3" checkout -q FETCH_HEAD
    [ "$(git -C "$3" rev-parse HEAD)" = "$2" ] || { echo "Unexpected commit in $1" >&2; exit 1; }
}
fetch "$LIBREDWG_URL" "$LIBREDWG_COMMIT" "$work/src"
fetch "$JSMN_URL" "$JSMN_COMMIT" "$work/jsmn"
# The JSON reader needs jsmn.h, a git submodule that a plain checkout leaves empty.
cp "$work/jsmn/jsmn.h" "$work/src/jsmn/jsmn.h"

cat > "$work/zigcc.sh" <<'WRAP'
#!/bin/sh
exec python3 -m ziglang cc -target x86_64-windows-gnu "$@"
WRAP
chmod +x "$work/zigcc.sh"

# One shared libredwg.dll (about 17 MB) instead of a full copy in every program (7 to 14 MB each): about 5.8 MB zipped in all.
cmake -S "$work/src" -B "$work/build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_C_COMPILER="$work/zigcc.sh" -DCMAKE_RC_COMPILER=: \
    -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_C_FLAGS="-Os -ffunction-sections -fdata-sections" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--gc-sections -s" -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--gc-sections -s" \
    -DDISABLE_WERROR=On -DENABLE_LTO=Off -DBUILD_SHARED_LIBS=On >"$work/cmake.log" 2>&1 || { tail -30 "$work/cmake.log" >&2; exit 1; }
ninja -C "$work/build" "${PROGRAMS[@]}" >"$work/ninja.log" 2>&1 || { tail -30 "$work/ninja.log" >&2; exit 1; }

rm -rf "$out"; mkdir -p "$out"
for program in "${PROGRAMS[@]}"; do cp "$work/build/$program.exe" "$out/"; done
cp "$work/build/libredwg.dll" "$out/"
cp "$work/src/COPYING" "$out/COPYING"
cat > "$out/SOURCE.txt" <<TXT
LibreDWG (dwglayers, dwggrep, dwg2dxf, dwgread, dwgrewrite, dwgbmp and libredwg.dll)
Copyright (C) Free Software Foundation, Inc. and the LibreDWG contributors.
Licence: GNU General Public License version 3 or later (COPYING in this folder).

These programs are built, unmodified, from this source:
  $LIBREDWG_URL
  commit $LIBREDWG_COMMIT
with the jsmn header from $JSMN_URL commit $JSMN_COMMIT.
Build: scripts/build-libredwg-windows.sh in the Autodesk-MCP repository (Zig $(python3 -m ziglang version), x86_64-windows-gnu, -Os).

Smart Connector starts these programs as separate programs and does not link them. On request the maintainers of
Autodesk-MCP will provide the complete corresponding source, as the licence requires; it is also available at the address above.
TXT
(cd "$out" && sha256sum *.exe *.dll COPYING SOURCE.txt | sort -k2 > SHA256SUMS)
echo "LibreDWG pack written to $out"; cat "$out/SHA256SUMS"
