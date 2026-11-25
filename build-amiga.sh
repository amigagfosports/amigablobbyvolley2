#!/bin/sh
# Blobby Volley 2 for AmigaOS 3.x / AmiCradle (68040 + FPU, SDL 2 through
# GFOpenGPU), built with the os32-gcc16 stove: OpenAmigaGCC 16.2.0-open3 or
# open4, known by their archives' SHA-256, or GFOpenAmigaGCC 16.2.0-open5
# (Cradle's os32-gcc16 stove), which has no published archive: its receipt
# records the SHA-256 of the compiler's own programs instead. The receipt
# says which. This is the build Cradle's stove_build runs (STOVE= and OUT=
# set, target .).
#   STOVE   the stove (default ~/AmiCradle/stoves/os32-gcc16, then
#           ~/AmigaChrome/stoves/os32-gcc16)
#   OUT     the output directory (default build-amiga)
#   JOBS    parallel compiles (default 2)
# The engine source and the game data are the upstream tree imported into this
# repository (gameports/catalog.json holds the upstream commit); patches/ is
# applied to a copy, never to the tree itself, and nothing is fetched.
# Outputs: BlobbyVolley2/blobby (the program), BlobbyVolley2/COPYING,
# receipt.json, build.log. The game data is not built here:
# runtime-data/build-amiga.sh packs it (target runtime-data).
# MIT, Copyright (c) 2026 AmiCradle Team.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${STOVE:-}" ]; then
    STOVE="$HOME/AmiCradle/stoves/os32-gcc16"
    [ -d "$STOVE" ] || STOVE="$HOME/AmigaChrome/stoves/os32-gcc16"
fi
OUT=${OUT:-"$HERE/build-amiga"}
JOBS=${JOBS:-2}
P="$STOVE/prefix"
SDK="$P/m68k-amigaos"
CC="$P/bin/m68k-amigaos-gcc"
CXX="$P/bin/m68k-amigaos-g++"

# the compiler is recorded, not checked (BL-144): scripts/record_stove.py
# prints "RELEASE ARCHIVE-SHA256" (the release the compiler's --version names;
# "unpublished" when the stove names no archive) and the compiler's own
# --version line on stderr; it fails only when the stove has no compiler
COMPILER=$(python3 "$HERE/scripts/record_stove.py" --stove "$STOVE")
RELEASE=${COMPILER% *}
ARCHIVE=${COMPILER#* }
"$CC" --version | head -n 1

# SDL 2 and SDL2_mixer from the stove's SDK (GFOpenGPU's link stubs: the
# program opens LIBS:GFOpenGPU/SDL2.module and SDL2_mixer.module when it runs)
for f in include/SDL2/SDL.h lib/libSDL2.a include/SDL2/SDL_mixer.h lib/libSDL2_mixer.a; do
    [ -f "$SDK/$f" ] || { echo "the stove has no $f"; exit 2; }
done

PIN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ports"]["blobbyvolley2"]["source"]["commit"])' "$HERE/gameports/catalog.json")
REPO_REV=$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)
EPOCH=$(git -C "$HERE" show -s --format=%ct HEAD 2>/dev/null || date +%s)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/blobby-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/include" "$OUT"
cp -R "$HERE/src" "$HERE/data" "$WORK/"
for patch in "$HERE"/patches/*.patch; do
    [ -f "$patch" ] || continue
    echo "patch: $(basename "$patch")"
    patch --batch --forward --fuzz=0 -p1 -d "$WORK" < "$patch"
done

# config.h: what upstream's CMake writes from config.h.in (an install prefix
# the AmigaOS paths in main.cpp do not use)
cat > "$WORK/include/config.h" <<'EOF'
/* build-amiga.sh: upstream's config.h.in for AmigaOS 3.x */
#pragma once
#define BLOBBY_INSTALL_PREFIX "PROGDIR:"
EOF

# upstream's source lists (src/CMakeLists.txt, src/lua, src/tinyxml), as they
# are, without what is not built:
# - the OpenGL and GP2X renderers (SDL 1.2 and OpenGL 1.x code; the SDL
#   renderer is the game's own software one),
# - online and network play (NetworkGame, NetworkMessage, NetworkState and
#   RakNet, the dedicated server): BLOBBY_NO_NETWORK; of RakNet only
#   BitStream.cpp, which the physics' state calls name;
# - lua.c and luac.c are not in upstream's list either.
# and with the port's own two files (patches 0001 and 0004).
cmake_list() {  # file set-name
    sed -n "/^set *($2/,/)/p" "$1" | sed -e '1d' -e '$d' | tr ' \t' '\n\n' | grep -E '\.(c|cpp)$' || true
}
SOURCES=$( {
    cmake_list "$HERE/src/CMakeLists.txt" common_SRC
    cmake_list "$HERE/src/CMakeLists.txt" blobby_SRC
    cmake_list "$HERE/src/lua/CMakeLists.txt" lua_SRC | sed 's|^|lua/|'
    cmake_list "$HERE/src/tinyxml/CMakeLists.txt" tinyxml_SRC | sed 's|^|tinyxml/|'
    echo raknet/BitStream.cpp
    echo blobby_sdl2.cpp
    echo dirfs/physfs_dirs.cpp
} | grep -v -x -E 'NetworkGame\.cpp|NetworkMessage\.cpp|RenderManagerGL2D\.cpp|RenderManagerGP2X\.cpp|state/NetworkState\.cpp' | LC_ALL=C sort -u )
[ "$(printf '%s\n' $SOURCES | wc -l)" -gt 50 ] || { echo "could not read the source lists"; exit 2; }

# -fno-delete-null-pointer-checks: address 0 is memory on an Amiga
FLAGS="-noixemul -m68040 -m68881 -pthread -fno-delete-null-pointer-checks -O2 -Wall
 -Wno-unused -Wno-sign-compare -Wno-deprecated-declarations
 -Wno-cpp -Wno-misleading-indentation -Wno-unknown-pragmas -Wno-parentheses
 -ffile-prefix-map=$WORK=. -I$WORK/include -I$WORK/src -I$WORK/src/dirfs
 -I$SDK/include/SDL2 -DTIXML_USE_STL -DBLOBBY_NO_NETWORK"
LIBS="-lSDL2_mixer -lSDL2 -lm -pthread"

(
    cd "$WORK/src"
    export SOURCE_DATE_EPOCH="$EPOCH"
    printf '%s\n' $SOURCES | xargs -P "$JOBS" -I{} sh -c '
        o=$(echo "{}" | tr / _).o
        case "{}" in *.cpp) c="$1"; std="-std=gnu++14 -Wno-reorder";; *) c="$0"; std=-std=gnu99;; esac
        echo "cc {}"
        "$c" $2 $std -c "{}" -o "$o"' "$CC" "$CXX" "$FLAGS"
    OBJS=$(for s in $SOURCES; do printf '%s ' "$(echo "$s" | tr / _).o"; done)
    echo "link blobby"
    # shellcheck disable=SC2086
    "$CXX" -noixemul -m68040 -m68881 -pthread -o blobby $OBJS -L"$SDK/lib" $LIBS
) 2>&1 | tee "$OUT/build.log"

EXE="$WORK/src/blobby"
[ -f "$EXE" ] || { echo "no executable: see build.log"; exit 2; }
[ "$(od -An -tx1 -N4 "$EXE" | tr -d ' \n')" = "000003f3" ] || { echo "not an Amiga HUNK executable"; exit 2; }

# the drawer: the program and the licence (runtime-data/build-amiga.sh packs
# the game data that goes beside it as PROGDIR:data; the game makes
# PROGDIR:User itself)
D="$OUT/BlobbyVolley2"
mkdir -p "$D"
cp "$EXE" "$D/blobby"
cp "$HERE/COPYING" "$D/COPYING"

python3 - "$HERE" "$OUT" "$PIN" "$REPO_REV" "$EPOCH" "$STOVE" "$RELEASE" "$ARCHIVE" <<'EOF'
import hashlib, json, sys
from pathlib import Path
here, out, pin, rev, epoch, stove, release, archive = Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:]
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
sdk = Path(stove) / "prefix/m68k-amigaos"
inputs = ["lib/libSDL2.a", "include/SDL2/SDL.h", "lib/libSDL2_mixer.a", "include/SDL2/SDL_mixer.h"]
drawer = out / "BlobbyVolley2"
receipt = {
    "upstream_commit": pin, "repository_commit": rev, "source_date_epoch": epoch,
    "recipe": {"build-amiga.sh": sha(here / "build-amiga.sh")},
    "patches": {p.name: sha(p) for p in sorted((here / "patches").glob("*.patch"))},
    "compiler_release": release, "compiler_archive_sha256": archive,
    "sdk_inputs": {n: sha(sdk / n) for n in inputs if (sdk / n).is_file()},
    "network": False,
    "executable_sha256": sha(drawer / "blobby"),
    "executable_bytes": (drawer / "blobby").stat().st_size,
    "scope": "Source build only; built without network play (BLOBBY_NO_NETWORK); no runtime or release pass implied",
}
if archive == "unpublished":
    # no archive to name: the compiler's own programs, by SHA-256
    prefix = Path(stove) / "prefix"
    files = ["bin/m68k-amigaos-gcc", "bin/m68k-amigaos-g++", "bin/m68k-amigaos-as", "bin/m68k-amigaos-ld"]
    files += sorted(str(p.relative_to(prefix)) for p in prefix.glob("libexec/gcc/m68k-amigaos/*/cc1*"))
    receipt["compiler_files_sha256"] = {f: sha(prefix / f) for f in files if (prefix / f).is_file()}
(out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
EOF
