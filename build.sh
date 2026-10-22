#!/bin/zsh
# Compila o CellStudio sem Xcode/SwiftPM (só Command Line Tools).
set -e
cd "${0:A:h}"
B=build
mkdir -p $B
FLAGS=(-O -target arm64-apple-macosx14.0 -swift-version 5)

swiftc $FLAGS -parse-as-library -module-name CellCore -emit-library -static \
  -emit-module -emit-module-path $B/CellCore.swiftmodule -o $B/libCellCore.a Sources/CellCore/*.swift

if [[ "$1" == "test" ]]; then
  swiftc $FLAGS -I $B -L $B -lCellCore Tests/CellCoreChecks/main.swift -o $B/CellCoreChecks
  exec $B/CellCoreChecks
fi

if [[ "$1" == "test-parts" ]]; then
  SOURCES=(Sources/CellStudio/*.swift)
  SOURCES=(${SOURCES:#Sources/CellStudio/App.swift})
  swiftc $FLAGS -parse-as-library -I $B -L $B -lCellCore $SOURCES Tests/PartImportChecks.swift -o $B/PartImportChecks
  exec $B/PartImportChecks
fi

swiftc $FLAGS -parse-as-library -I $B -L $B -lCellCore -module-name CellStudio Sources/CellStudio/*.swift -o $B/CellStudio

APP="$B/CellStudio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp $B/CellStudio "$APP/Contents/MacOS/"
cp -R Sources/CellStudio/Resources/* "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
tools/build-info.sh > "$APP/Contents/Resources/build-info.json"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "OK -> $APP"
