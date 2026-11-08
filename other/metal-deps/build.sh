#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
MANIFEST="$SCRIPT_DIR/manifest.json"
BREW_LOCK="$SCRIPT_DIR/homebrew.lock"
MPV_PATCH="$SCRIPT_DIR/patches/mpv-metal-macos.patch"
PL_PATCH="$SCRIPT_DIR/patches/libplacebo-metal.patch"
BUILD_ROOT=${IINA_METAL_BUILD_ROOT:-"$ROOT_DIR/build/metal-deps"}
SOURCE_ROOT="$BUILD_ROOT/sources"
OBJECT_ROOT="$BUILD_ROOT/objects"
PREFIX="$BUILD_ROOT/prefix"
CARGO_BUILD_HOME="$BUILD_ROOT/cargo-home"
MODULE_CACHE="$BUILD_ROOT/module-cache"

json_value() {
  /usr/bin/python3 -c 'import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for component in sys.argv[2].split("."):
    value = value[component]
print(value)' "$MANIFEST" "$1"
}

fail() {
  echo "metal-deps: $*" >&2
  exit 1
}

[[ $(uname -m) == arm64 ]] || fail "Apple Silicon is required"
[[ $(json_value target.architecture) == arm64 ]] || fail "manifest architecture is not arm64"

DEPLOYMENT_TARGET=$(json_value target.deploymentTarget)
EXPECTED_SDK=$(json_value target.sdk)
ACTUAL_SDK=$(xcrun --sdk macosx --show-sdk-version)
[[ "$ACTUAL_SDK" == "$EXPECTED_SDK" ]] || fail "Xcode macOS SDK $EXPECTED_SDK is required (found $ACTUAL_SDK)"

for tool in brew git ninja pkgconf cargo-cinstall clang xcrun python3 ffmpeg; do
  command -v "$tool" >/dev/null || fail "missing tool: $tool"
done

while read -r formula expected_version; do
  [[ -n "${formula:-}" && "$formula" != \#* ]] || continue
  installed=$(brew list --versions "$formula" 2>/dev/null | awk '{print $2}')
  [[ "$installed" == "$expected_version" ]] ||
    fail "$formula must be $expected_version (found ${installed:-not installed})"
done < "$BREW_LOCK"

mkdir -p "$SOURCE_ROOT" "$OBJECT_ROOT" "$PREFIX" "$CARGO_BUILD_HOME" "$MODULE_CACHE"

# Avoid rustup shims attempting to update themselves; never install a toolchain.
RUST_VERSION=$(json_value target.rustToolchainVersion)
RUST_BIN="$HOME/.rustup/toolchains/${RUST_VERSION}-aarch64-apple-darwin/bin"
if [[ -x "$RUST_BIN/rustc" && -x "$RUST_BIN/cargo" ]]; then
  export PATH="$RUST_BIN:$PATH"
fi
command -v rustc >/dev/null || fail "missing Rust $RUST_VERSION compiler"
command -v cargo >/dev/null || fail "missing Rust $RUST_VERSION cargo"
RUSTC_PATH=$(command -v rustc)
RUSTC_REAL=$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$RUSTC_PATH")
[[ ${RUSTC_REAL##*/} != rustup ]] || fail "Rust $RUST_VERSION must be installed; rustup shims are not used"
[[ $(rustc --version) == "rustc $RUST_VERSION "* ]] ||
  fail "Rust $RUST_VERSION is required (found $(rustc --version 2>/dev/null || echo unavailable))"
export CARGO_HOME="$CARGO_BUILD_HOME"

# A broken Homebrew Python shim can prevent Meson and Ninja's Meson helpers
# from importing mesonbuild. Make both use the same working Python environment.
if ! command -v meson >/dev/null || ! meson --version >/dev/null 2>&1; then
  MESON_PREFIX=$(brew --prefix meson)
  MESON_SITE=""
  for site in "$MESON_PREFIX"/lib/python*/site-packages; do
    if [[ -d "$site/mesonbuild" ]]; then
      MESON_SITE=$site
      break
    fi
  done
  [[ -n "$MESON_SITE" ]] || fail "cannot find Homebrew Meson Python package"
  export PYTHONPATH="$MESON_SITE${PYTHONPATH:+:$PYTHONPATH}"
  python3 -m mesonbuild.mesonmain --version >/dev/null || fail "Meson Python fallback failed"
  mkdir -p "$BUILD_ROOT/bin"
  cat > "$BUILD_ROOT/bin/meson" <<'EOF'
#!/bin/sh
exec python3 -m mesonbuild.mesonmain "$@"
EOF
  chmod +x "$BUILD_ROOT/bin/meson"
  export PATH="$BUILD_ROOT/bin:$PATH"
fi

# Compare the complete tracked and untracked worktree to the expected patched
# tree using temporary indexes; never rewrite or discard local changes.
check_source_tree() {
  local destination=$1 patch=${2:-} expected_index actual_index expected actual
  git -C "$destination" diff --cached --quiet || fail "$destination has staged changes"
  expected_index=$(mktemp "$BUILD_ROOT/expected-index.XXXXXX")
  actual_index=$(mktemp "$BUILD_ROOT/actual-index.XXXXXX")
  rm -f "$expected_index" "$actual_index"
  GIT_INDEX_FILE="$expected_index" git -C "$destination" read-tree HEAD
  if [[ -n "$patch" ]]; then
    GIT_INDEX_FILE="$expected_index" git -C "$destination" apply --cached --unidiff-zero "$patch" ||
      fail "patch does not apply to $destination"
  fi
  expected=$(GIT_INDEX_FILE="$expected_index" git -C "$destination" write-tree)
  GIT_INDEX_FILE="$actual_index" git -C "$destination" read-tree HEAD
  GIT_INDEX_FILE="$actual_index" git -C "$destination" add -A
  actual=$(GIT_INDEX_FILE="$actual_index" git -C "$destination" write-tree)
  rm -f "$expected_index" "$actual_index"
  [[ "$actual" == "$expected" ]] || fail "$destination has unexpected local changes"
  git -C "$destination" submodule foreach --quiet --recursive \
    'test -z "$(git status --porcelain)"' || fail "$destination has modified submodules"
}

clone_exact() {
  local name=$1 url=$2 commit=$3 patch=${4:-} destination="$SOURCE_ROOT/$1"
  if [[ ! -d "$destination/.git" ]]; then
    git clone --filter=blob:none "$url" "$destination"
  fi
  if [[ $(git -C "$destination" rev-parse HEAD) != "$commit" ]]; then
    check_source_tree "$destination"
    git -C "$destination" fetch "$url" "$commit"
    git -C "$destination" checkout --detach "$commit"
  fi
  [[ $(git -C "$destination" rev-parse HEAD) == "$commit" ]] || fail "$name checkout mismatch"
  if [[ -n "$patch" ]] && git -C "$destination" apply --reverse --check --unidiff-zero "$patch" >/dev/null 2>&1; then
    check_source_tree "$destination" "$patch"
  else
    check_source_tree "$destination"
    if [[ -n "$patch" ]]; then
      git -C "$destination" apply --check --unidiff-zero "$patch" || fail "$name patch does not apply cleanly"
      git -C "$destination" apply --unidiff-zero "$patch"
      check_source_tree "$destination" "$patch"
    fi
  fi
}

MPV_COMMIT=$(json_value sources.mpv.commit)
MPV_URL=$(json_value sources.mpv.url)
PL_COMMIT=$(json_value sources.libplacebo.commit)
PL_URL=$(json_value sources.libplacebo.url)
DOVI_COMMIT=$(json_value sources.libdovi.commit)
DOVI_URL=$(json_value sources.libdovi.url)

clone_exact mpv "$MPV_URL" "$MPV_COMMIT" "$MPV_PATCH"
clone_exact libplacebo "$PL_URL" "$PL_COMMIT" "$PL_PATCH"
clone_exact libdovi "$DOVI_URL" "$DOVI_COMMIT"
git -C "$SOURCE_ROOT/libplacebo" submodule update --init --recursive

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export CFLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -I$(brew --prefix spirv-cross)/include -I$(brew --prefix dav1d)/include"
export CXXFLAGS="$CFLAGS"
export OBJCFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -L$(brew --prefix spirv-cross)/lib -L$PREFIX/lib"
export LIBRARY_PATH="$(brew --prefix spirv-cross)/lib:$PREFIX/lib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$(brew --prefix libarchive)/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig:$(brew --prefix)/share/pkgconfig"

cargo cinstall --release --target aarch64-apple-darwin --prefix "$PREFIX" \
  --manifest-path "$SOURCE_ROOT/libdovi/dolby_vision/Cargo.toml"

# Xcode 27 rejects cargo-c's shared libdovi LINKEDIT. Use the valid arm64 static
# archive and keep the Rust runtime out of the application dylib closure.
/usr/bin/python3 -c 'from pathlib import Path
path = Path("'$PREFIX'/lib/pkgconfig/dovi.pc")
text = path.read_text()
text = text.replace("Libs: -L${libdir} -ldovi", "Libs: ${libdir}/libdovi.a -liconv -lSystem -lc -lm")
text = text.replace("Libs.private: -liconv -lSystem -lc -lm", "Libs.private:")
path.write_text(text)'

PL_BUILD="$OBJECT_ROOT/libplacebo"
PL_SETUP=(
  "$PL_BUILD" "$SOURCE_ROOT/libplacebo"
  "--prefix=$PREFIX" --buildtype=release --default-library=shared
  -Dtests=true -Ddemos=false -Dbench=false -Dfuzz=false
  -Dmetal=enabled -Dvulkan=disabled -Dopengl=disabled -Dd3d11=disabled
  -Dshaderc=enabled -Dglslang=disabled -Ddovi=enabled -Dlibdovi=enabled
  -Dlcms=enabled -Dunwind=disabled -Dxxhash=disabled
)
if [[ -f "$PL_BUILD/build.ninja" ]]; then
  meson setup --reconfigure "${PL_SETUP[@]}"
else
  meson setup "${PL_SETUP[@]}"
fi
meson compile -C "$PL_BUILD"
meson test -C "$PL_BUILD" --print-errorlogs
meson install -C "$PL_BUILD"

MPV_BUILD="$OBJECT_ROOT/mpv"
MPV_SETUP=(
  "$MPV_BUILD" "$SOURCE_ROOT/mpv"
  "--prefix=$PREFIX" --buildtype=release --default-library=shared
  -Dbuild-date=false -Dtests=true -Dfuzzers=false -Dcplayer=false -Dlibmpv=true
  -Djavascript=enabled -Dlua=luajit -Dlibarchive=enabled -Duchardet=enabled
  -Dlibbluray=enabled -Djpeg=enabled -Dlcms2=enabled -Drubberband=enabled -Dzimg=enabled
  -Dgl=enabled -Dplain-gl=enabled -Dgl-cocoa=enabled -Dvulkan=disabled
  -Dvideotoolbox-gl=enabled -Dvideotoolbox-pl=enabled -Dx11=disabled
  -Dmacos-touchbar=disabled -Dmacos-media-player=disabled -Dmacos-cocoa-cb=disabled
  -Dswift-build=enabled -Dhtml-build=disabled -Dmanpage-build=disabled -Dpdf-build=disabled
)
if [[ -f "$MPV_BUILD/build.ninja" ]]; then
  meson setup --reconfigure "${MPV_SETUP[@]}"
else
  meson setup "${MPV_SETUP[@]}"
fi
meson compile -C "$MPV_BUILD"
meson test -C "$MPV_BUILD" --print-errorlogs
meson install -C "$MPV_BUILD"

clang -fobjc-arc -arch arm64 -mmacosx-version-min="$DEPLOYMENT_TARGET" \
  -I"$PREFIX/include" -L"$PREFIX/lib" -Wl,-rpath,"$PREFIX/lib" -lmpv \
  -framework AppKit -framework Metal -framework QuartzCore \
  "$SCRIPT_DIR/metal-smoke.m" -o "$OBJECT_ROOT/metal-smoke"

# Keep a known fixture available through rendering and screenshot validation.
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i 'testsrc2=size=640x360:rate=24:duration=10' -c:v libx264 -pix_fmt yuv420p \
  "$OBJECT_ROOT/metal-smoke.mkv"
DYLD_LIBRARY_PATH="$PREFIX/lib:$(brew --prefix)/lib:$(brew --prefix shaderc)/lib:$(brew --prefix little-cms2)/lib" \
  "$OBJECT_ROOT/metal-smoke" "$OBJECT_ROOT/metal-smoke.mkv"

PACKAGE_LIB="$BUILD_ROOT/package/lib"
ruby "$SCRIPT_DIR/package.rb" "$PACKAGE_LIB" "$PREFIX/lib/libmpv.2.dylib"
"$ROOT_DIR/other/verify_arm64_bundle.sh" "$PACKAGE_LIB"
echo "Verified Metal dependency package: $BUILD_ROOT/package"
