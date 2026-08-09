#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AOSP_DIR=${AOSP_DIR:-/home/rinnrei/Project/uwuAOSP}
ANDROID_JAR=${ANDROID_JAR:-$AOSP_DIR/prebuilts/sdk/36/public/android.jar}
JAVAC=${JAVAC:-$AOSP_DIR/prebuilts/jdk/jdk21/linux-x86/bin/javac}
JAR=${JAR:-$AOSP_DIR/prebuilts/jdk/jdk21/linux-x86/bin/jar}
AAPT2=${AAPT2:-$AOSP_DIR/out/host/linux-x86/bin/aapt2}
D8=${D8:-$AOSP_DIR/out/host/linux-x86/bin/d8}
APKSIGNER=${APKSIGNER:-$AOSP_DIR/out/host/linux-x86/bin/apksigner}
KEY=${KEY:-$AOSP_DIR/build/make/target/product/security/testkey.pk8}
CERT=${CERT:-$AOSP_DIR/build/make/target/product/security/testkey.x509.pem}
OUT=$SCRIPT_DIR/out
APK=$SCRIPT_DIR/../modules/bk-control/bin/bkk-log-exporter.apk

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex" "$(dirname "$APK")"
"$JAVAC" -source 8 -target 8 -Xlint:-options -cp "$ANDROID_JAR" \
	-d "$OUT/classes" "$SCRIPT_DIR/src/org/bkkernel/logexport/ExportActivity.java"
"$JAR" cf "$OUT/classes.jar" -C "$OUT/classes" .
"$D8" --lib "$ANDROID_JAR" --min-api 26 --output "$OUT/dex" "$OUT/classes.jar"
"$AAPT2" link -o "$OUT/unsigned.apk" -I "$ANDROID_JAR" \
	--manifest "$SCRIPT_DIR/AndroidManifest.xml" \
	--version-code 1 --version-name 1 \
	--min-sdk-version 26 --target-sdk-version 36
zip -q -j "$OUT/unsigned.apk" "$OUT/dex/classes.dex"
"$APKSIGNER" sign --key "$KEY" --cert "$CERT" --out "$APK" "$OUT/unsigned.apk"
"$APKSIGNER" verify --verbose "$APK"
