#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/LocalMeet.app"
CONTENTS_DIR="$APP_DIR/Contents"

if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/LocalMeet" "$CONTENTS_DIR/MacOS/LocalMeet"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

WHISPER_PREFIX="$(brew --prefix whisper-cpp)"
GGML_PREFIX="$(brew --prefix ggml)"
OMP_PREFIX="$(brew --prefix libomp)"
RUNTIME_DIR="$CONTENTS_DIR/Resources/WhisperRuntime"
mkdir -p "$RUNTIME_DIR/bin" "$RUNTIME_DIR/lib" "$RUNTIME_DIR/libexec"

cp -L "$WHISPER_PREFIX/bin/whisper-cli" "$RUNTIME_DIR/bin/whisper-cli"
cp -L "$WHISPER_PREFIX/lib/libwhisper.1.dylib" "$RUNTIME_DIR/lib/libwhisper.1.dylib"
cp -L "$GGML_PREFIX/lib/libggml.0.dylib" "$RUNTIME_DIR/lib/libggml.0.dylib"
cp -L "$GGML_PREFIX/lib/libggml-base.0.dylib" "$RUNTIME_DIR/lib/libggml-base.0.dylib"
cp -L "$OMP_PREFIX/lib/libomp.dylib" "$RUNTIME_DIR/lib/libomp.dylib"
cp -L "$GGML_PREFIX/libexec/"*.so "$RUNTIME_DIR/libexec/"

install_name_tool \
    -change "$GGML_PREFIX/lib/libggml.0.dylib" @rpath/libggml.0.dylib \
    -change "$GGML_PREFIX/lib/libggml-base.0.dylib" @rpath/libggml-base.0.dylib \
    "$RUNTIME_DIR/bin/whisper-cli"

install_name_tool \
    -id @rpath/libwhisper.1.dylib \
    -change "$GGML_PREFIX/lib/libggml.0.dylib" @rpath/libggml.0.dylib \
    -change "$GGML_PREFIX/lib/libggml-base.0.dylib" @rpath/libggml-base.0.dylib \
    "$RUNTIME_DIR/lib/libwhisper.1.dylib"

install_name_tool -id @rpath/libggml.0.dylib "$RUNTIME_DIR/lib/libggml.0.dylib"
install_name_tool -id @rpath/libggml-base.0.dylib "$RUNTIME_DIR/lib/libggml-base.0.dylib"
install_name_tool -id @rpath/libomp.dylib "$RUNTIME_DIR/lib/libomp.dylib"

for backend in "$RUNTIME_DIR/libexec/"*.so; do
    install_name_tool \
        -change @rpath/libggml-base.0.dylib @loader_path/../lib/libggml-base.0.dylib \
        "$backend"
    if otool -L "$backend" | grep -q "$OMP_PREFIX/lib/libomp.dylib"; then
        install_name_tool \
            -change "$OMP_PREFIX/lib/libomp.dylib" @loader_path/../lib/libomp.dylib \
            "$backend"
    fi
done

for runtime_binary in \
    "$RUNTIME_DIR/lib/"*.dylib \
    "$RUNTIME_DIR/libexec/"*.so \
    "$RUNTIME_DIR/bin/whisper-cli"; do
    codesign --force --sign - "$runtime_binary"
done

codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "app.localmeet.mac"' \
    "$APP_DIR"

echo "$APP_DIR"
