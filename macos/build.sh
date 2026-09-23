#!/usr/bin/env bash
# Compila o TradutorBar e monta "Tradutor de Vídeos.app". Com --install, copia para /Applications.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$(cd "$(dirname "$0")/../engine" && pwd)"
APP_NAME="Tradutor de Vídeos"
# Pasta .noindex: o Spotlight e o Launchpad ignoram, senão a cópia de trabalho aparece como um segundo app.
APP="$HERE/build.noindex/$APP_NAME.app"
PLIST="$APP/Contents/Info.plist"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "uso: $0 [--install]" >&2; exit 2 ;;
    esac
done

swift build -c release --package-path "$HERE"
BIN_DIR="$(swift build -c release --package-path "$HERE" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/TradutorBar" "$APP/Contents/MacOS/TradutorBar"
mkdir -p "$APP/Contents/Resources"
cp "$HERE/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.arnaldo.tradutordevideos</string>
    <key>CFBundleName</key>
    <string>Tradutor de Vídeos</string>
    <key>CFBundleDisplayName</key>
    <string>Tradutor de Vídeos</string>
    <key>CFBundleExecutable</key>
    <string>TradutorBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>pt-BR</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST
# Pelo plutil, e não direto no XML acima, para um caminho com & ou < não corromper o plist.
plutil -insert TDVEngineDir -string "$ENGINE_DIR" "$PLIST"
plutil -lint "$PLIST" >/dev/null

# Assinatura ad-hoc muda a cada build, e com isso o macOS descarta permissões já concedidas ao app
# (como o Acesso Total ao Disco que a leitura de cookies do Chrome precisa). Com uma identidade estável
# elas persistem. A identidade vem de TDV_SIGN_IDENTITY ou do arquivo macos/.sign-identity (não versionado).
IDENTITY="${TDV_SIGN_IDENTITY:-$(cat "$(dirname "$0")/.sign-identity" 2>/dev/null || true)}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Assinado com: ${IDENTITY:-assinatura ad-hoc}"
echo "App montado em: $APP"

if [[ "$INSTALL" == 1 ]]; then
    # /Applications é a pasta Aplicativos do Finder; admins escrevem nela sem sudo.
    DEST="${TDV_INSTALL_DIR:-/Applications}"
    mkdir -p "$DEST"
    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
    echo "Instalado em: $DEST/$APP_NAME.app"
fi
