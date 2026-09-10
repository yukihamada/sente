#!/bin/sh
# Sente.app をビルドする(Xcodeプロジェクト不要・swiftc 1発 + バンドル手組み)
#   ./build.sh            → ./build/Sente.app
#   ./build.sh --install  → さらに /Applications へ配置
set -eu

cd "$(dirname "$0")"
VERSION="${SENTE_APP_VERSION:-1.0.0}"
BUILD="${SENTE_APP_BUILD:-1}"
OUT="build"
APP="$OUT/Sente.app"

command -v swiftc >/dev/null 2>&1 || { echo "swiftc が必要です(Xcode か Command Line Tools を入れてください)"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ compiling (arm64 + x86_64)"
# 両アーキ入りにしておくと Intel Mac でもそのまま動く。片方しか SDK が無い環境では素直に諦める。
if swiftc -O -target arm64-apple-macos13.0 -o "$OUT/Sente-arm64" Sente.swift 2>/dev/null \
   && swiftc -O -target x86_64-apple-macos13.0 -o "$OUT/Sente-x86_64" Sente.swift 2>/dev/null; then
  lipo -create -output "$APP/Contents/MacOS/Sente" "$OUT/Sente-arm64" "$OUT/Sente-x86_64"
  rm -f "$OUT/Sente-arm64" "$OUT/Sente-x86_64"
else
  swiftc -O -o "$APP/Contents/MacOS/Sente" Sente.swift
fi
chmod +x "$APP/Contents/MacOS/Sente"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sente</string>
  <key>CFBundleDisplayName</key><string>Sente — 声で使うコーディングエージェント</string>
  <key>CFBundleIdentifier</key><string>io.teai.sente</string>
  <key>CFBundleExecutable</key><string>Sente</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>あなたの声を聞き取って指示に変えるために使います。録音は koe.live に送られ、文字起こし後すぐ破棄されます。</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 署名: Developer ID があればそれで、無ければ ad-hoc。
# ad-hoc だと初回だけ右クリック→開く が要る(Gatekeeper)。
if [ -n "${SENTE_SIGN_ID:-}" ]; then
  codesign --force --deep --options runtime --sign "$SENTE_SIGN_ID" "$APP"
  echo "→ signed with $SENTE_SIGN_ID"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "→ ad-hoc signed (配布時は初回のみ右クリック→開く)"
fi

echo "✅ $APP ($VERSION build $BUILD)"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Sente.app
  cp -R "$APP" /Applications/Sente.app
  echo "✅ /Applications/Sente.app に配置しました"
fi
