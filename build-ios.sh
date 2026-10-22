#!/bin/zsh
# CellStudio para iPhone, sem projeto Xcode (mesmo estilo do build.sh).
#
#   ./build-ios.sh check     compila o app iOS como Mac Catalyst (só Command Line Tools) para achar erros
#   ./build-ios.sh catalyst  gera build/ios/CellStudio-Catalyst.app (a versão iPhone rodando no Mac, para testar)
#   ./build-ios.sh sim       gera build/ios/CellStudio.app para o Simulador do iOS (precisa do Xcode)
#   ./build-ios.sh device    gera build/ios/device/CellStudio.app para iPhone (precisa do Xcode; assinar e instalar
#                            pelo projeto do Xcode – ver ios/README.md)
set -e
cd "${0:A:h}"
B=build/ios
MODE=${1:-check}

case $MODE in
  check|catalyst)
    SDK=$(xcrun --show-sdk-path)
    TARGET=arm64-apple-ios17.0-macabi
    EXTRA=(-Fsystem $SDK/System/iOSSupport/System/Library/Frameworks -I $SDK/System/iOSSupport/usr/lib/swift -L $SDK/System/iOSSupport/usr/lib/swift)
    OUT=$B/catalyst ;;
  sim)
    SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
    TARGET=arm64-apple-ios17.0-simulator
    EXTRA=()
    OUT=$B ;;
  device)
    SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    TARGET=arm64-apple-ios17.0
    EXTRA=()
    OUT=$B/device ;;
  *) echo "uso: $0 check|catalyst|sim|device"; exit 1 ;;
esac

mkdir -p $OUT
FLAGS=(-O -target $TARGET -sdk $SDK -swift-version 5 $EXTRA)

swiftc $FLAGS -parse-as-library -module-name CellCore -emit-library -static \
  -emit-module -emit-module-path $OUT/CellCore.swiftmodule -o $OUT/libCellCore.a Sources/CellCore/*.swift

if [[ $MODE == check ]]; then
  swiftc $FLAGS -parse-as-library -I $OUT -typecheck Sources/CellStudio/*.swift
  echo "OK – app iOS compila"
  exit 0
fi

swiftc $FLAGS -parse-as-library -I $OUT -L $OUT -lCellCore -module-name CellStudio Sources/CellStudio/*.swift -o $OUT/CellStudio

if [[ $MODE == catalyst ]]; then
  APP=$OUT/CellStudio-Catalyst.app
  rm -rf $APP
  mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
  cp $OUT/CellStudio $APP/Contents/MacOS/
  cp -R Sources/CellStudio/Resources/* $APP/Contents/Resources/
  sed -e 's/<key>LSRequiresIPhoneOS<\/key><true\/>//' ios/Info.plist > $APP/Contents/Info.plist
  tools/build-info.sh > $APP/Contents/Resources/build-info.json
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" $APP/Contents/Info.plist 2>/dev/null || true
  codesign --force --sign - $APP >/dev/null 2>&1 || true
  echo "OK -> $APP"
  exit 0
fi

# iOS: pacote plano (executável, Info.plist e recursos na raiz do .app)
APP=$OUT/CellStudio.app
rm -rf $APP
mkdir -p $APP
cp $OUT/CellStudio $APP/
cp -R Sources/CellStudio/Resources/* $APP/
cp ios/Info.plist $APP/
tools/build-info.sh > $APP/build-info.json
echo "OK -> $APP"
if [[ $MODE == sim ]]; then
  codesign --force --sign - $APP >/dev/null 2>&1 || true
  # instala e abre no simulador já ligado (abra um em Xcode ▸ Open Developer Tool ▸ Simulator)
  if xcrun simctl list devices booted | grep -q Booted; then
    xcrun simctl install booted $APP && xcrun simctl launch booted local.diogoramos.cellstudio
  else
    echo "Nenhum simulador ligado: abra o Simulator e rode de novo para instalar."
  fi
fi
