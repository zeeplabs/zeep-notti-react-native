#!/usr/bin/env bash
# Self-test for scripts/check-android-adapter.sh (ANSDK-01, ANSDK-16). The classes cases compile fixtures
# with javac and are skipped when no JDK is found.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../check-android-adapter.sh"

failures=0

# expect <exit-code> <description> <command...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local out got
  set +e
  out="$("$@" 2>&1)"
  got=$?
  set -e
  if [[ "$got" == "$want" ]]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (expected exit $want, got $got)"
    printf '       %s\n' "${out//$'\n'/$'\n'       }"
    failures=$((failures + 1))
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- layout ---------------------------------------------------------------------------------------

# layout_fixture <name> [manifest-content]: a repo root with the adapter files and an empty manifest.
layout_fixture() {
  local dir="$tmp/layout-$1" f
  for f in NottiBridge NottiModule NottiNativeApi NottiPackage; do
    mkdir -p "$dir/android/src/main/java/com/notti"
    echo 'package com.notti' >"$dir/android/src/main/java/com/notti/$f.kt"
  done
  for f in NottiAdapterTest NottiBridgeTest NottiModuleTest NottiTestSupport; do
    mkdir -p "$dir/android/src/test/java/com/notti"
    echo 'package com.notti' >"$dir/android/src/test/java/com/notti/$f.kt"
  done
  printf '%s\n' "${2:-<manifest />}" >"$dir/android/src/main/AndroidManifest.xml"
  echo "$dir"
}

ok="$(layout_fixture ok)"
expect 0 "adapter files and an empty manifest pass" "$script" layout "$ok"

ds="$(layout_fixture ds)"
touch "$ds/android/src/main/java/com/notti/.DS_Store"
expect 0 ".DS_Store is ignored" "$script" layout "$ds"

core="$(layout_fixture core)"
echo 'package com.notti' >"$core/android/src/main/java/com/notti/NottiCore.kt"
expect 1 "a core file in com/notti fails" "$script" layout "$core"

other="$(layout_fixture other)"
mkdir -p "$other/android/src/main/java/com/zeeplabs/notti"
echo 'package com.zeeplabs.notti' >"$other/android/src/main/java/com/zeeplabs/notti/Notti.kt"
expect 1 "a file in another package fails" "$script" layout "$other"

missing="$(layout_fixture missing)"
rm "$missing/android/src/main/java/com/notti/NottiNativeApi.kt"
expect 1 "a missing adapter file fails" "$script" layout "$missing"

extratest="$(layout_fixture extratest)"
echo 'package com.notti' >"$extratest/android/src/test/java/com/notti/NottiCoreTest.kt"
expect 1 "an extra test file fails" "$script" layout "$extratest"

notest="$(layout_fixture notest)"
rm -rf "$notest/android/src/test/java"
expect 1 "a missing test source dir fails" "$script" layout "$notest"

service="$(layout_fixture service '<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application>
    <service android:name="com.notti.NottiFirebaseMessagingService" />
  </application>
</manifest>')"
expect 1 "a manifest component fails" "$script" layout "$service"

perm="$(layout_fixture perm '<manifest><uses-permission android:name="android.permission.POST_NOTIFICATIONS" /></manifest>')"
expect 1 "a manifest permission fails" "$script" layout "$perm"

commented="$(layout_fixture commented '<?xml version="1.0" encoding="utf-8"?>
<!-- was: <provider android:name="com.notti.NottiInitProvider" /> -->
<manifest xmlns:android="http://schemas.android.com/apk/res/android" />')"
expect 0 "XML declaration, comments and namespace attributes pass" "$script" layout "$commented"

nomanifest="$(layout_fixture nomanifest)"
rm "$nomanifest/android/src/main/AndroidManifest.xml"
expect 1 "a missing manifest fails" "$script" layout "$nomanifest"

# --- classpath ------------------------------------------------------------------------------------

# classpath_fixture <name> <pin-line> <report-lines>: a repo root with android/build.gradle and a report.
classpath_fixture() {
  local dir="$tmp/classpath-$1"
  mkdir -p "$dir/android"
  printf 'dependencies {\n  implementation "com.facebook.react:react-android"\n%s\n}\n' "$2" >"$dir/android/build.gradle"
  printf 'releaseRuntimeClasspath - Runtime classpath of '"'"'/release'"'"'.\n%s\n' "$3" >"$dir/report.txt"
  echo "$dir"
}
pin='  api "br.com.zeeplabs:notti-android:0.2.0"'
tree='+--- project :react-native-notti
|    +--- br.com.zeeplabs:notti-android:0.2.0
|    |    \--- com.google.firebase:firebase-messaging:25.1.2
|    |         \--- com.google.firebase:firebase-common:22.0.1
+--- com.example:other:1.0
|    \--- com.google.firebase:firebase-messaging:24.0.0 -> 25.1.2 (*)
\--- com.google.firebase:firebase-messaging-ktx:24.0.0'

c="$(classpath_fixture ok "$pin" "$tree")"
expect 0 "one firebase-messaging and the pinned notti-android pass" "$script" classpath "$c/report.txt" "$c"
expect 0 "the report can come from stdin" bash -c "'$script' classpath - '$c' <'$c/report.txt'"

c="$(classpath_fixture two "$pin" "$tree
\\--- com.google.firebase:firebase-messaging:24.0.0")"
expect 1 "two firebase-messaging versions fail" "$script" classpath "$c/report.txt" "$c"

c="$(classpath_fixture nofcm "$pin" '\--- br.com.zeeplabs:notti-android:0.2.0')"
expect 1 "no firebase-messaging fails" "$script" classpath "$c/report.txt" "$c"

c="$(classpath_fixture nonotti "$pin" '\--- com.google.firebase:firebase-messaging:25.1.2')"
expect 1 "no notti-android fails" "$script" classpath "$c/report.txt" "$c"

c="$(classpath_fixture raised "$pin" "${tree/notti-android:0.2.0/notti-android:0.2.0 -> 0.2.1}")"
expect 1 "notti-android raised past the pin fails" "$script" classpath "$c/report.txt" "$c"

c="$(classpath_fixture strictly "$pin" "${tree/notti-android:0.2.0/notti-android:\{strictly 0.2.0\} -> 0.2.0}")"
expect 0 "rich version notation resolving to the pin passes" "$script" classpath "$c/report.txt" "$c"

c="$(classpath_fixture failed "$pin" "$tree
\\--- com.example:missing:1.0 FAILED")"
expect 1 "an unresolved dependency fails" "$script" classpath "$c/report.txt" "$c"

c="$(classpath_fixture dynamic '  api "br.com.zeeplabs:notti-android:0.2.+"' "$tree")"
expect 1 "a dynamic pin in android/build.gradle fails" "$script" classpath "$c/report.txt" "$c"

c="$(classpath_fixture notreport "$pin" "$tree")"
printf '%s\n' "$tree" >"$c/report.txt"
expect 1 "input that is not a releaseRuntimeClasspath report fails" "$script" classpath "$c/report.txt" "$c"

expect 1 "a missing report fails" "$script" classpath "$tmp/nope.txt" "$c"

# --- classes --------------------------------------------------------------------------------------

jdk_bin=""
if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]]; then
  jdk_bin="$JAVA_HOME/bin/"
elif command -v javac >/dev/null; then
  jdk_bin=""
else
  jdk_bin="none"
fi

if [[ "$jdk_bin" == "none" ]]; then
  echo "skip - classes cases (no javac; set JAVA_HOME)"
else
  # jar_fixture <name> [javac-flags] -- <relative-source>=<content>...: compiles the sources into <name>.jar.
  jar_fixture() {
    local name="$1" flags="$2" dir="$tmp/classes-$1" pair
    shift 3
    mkdir -p "$dir/src" "$dir/out"
    for pair in "$@"; do
      mkdir -p "$(dirname "$dir/src/${pair%%=*}")"
      printf '%s\n' "${pair#*=}" >"$dir/src/${pair%%=*}"
    done
    # shellcheck disable=SC2086
    "${jdk_bin}javac" $flags -d "$dir/out" $(find "$dir/src" -name '*.java')
    "${jdk_bin}jar" cf "$tmp/$name.jar" -C "$dir/out" .
    echo "$tmp/$name.jar"
  }
  adapter=(
    'com/notti/NottiModule.java=package com.notti; public class NottiModule { class Inner {} }'
    'com/notti/NativeNottiSpec.java=package com.notti; public abstract class NativeNottiSpec {}'
    'com/notti/BuildConfig.java=package com.notti; public final class BuildConfig {}'
  )

  j="$(jar_fixture ok "" -- "${adapter[@]}")"
  expect 0 "adapter, NativeNottiSpec and BuildConfig classes pass" "$script" classes "$j"

  j="$(jar_fixture core "" -- "${adapter[@]}" 'com/notti/NottiCore.java=package com.notti; class NottiCore {}')"
  expect 1 "a class compiled from a core source fails" "$script" classes "$j"

  j="$(jar_fixture native "" -- "${adapter[@]}" 'com/zeeplabs/notti/NottiModule.java=package com.zeeplabs.notti; class NottiModule {}')"
  expect 1 "a class outside com.notti fails" "$script" classes "$j"

  j="$(jar_fixture sub "" -- 'com/notti/inapp/NottiModule.java=package com.notti.inapp; class NottiModule {}')"
  expect 1 "a class in a com.notti subpackage fails" "$script" classes "$j"

  j="$(jar_fixture nosource "-g:none" -- "${adapter[@]}")"
  expect 1 "a class without a SourceFile attribute fails" "$script" classes "$j"

  mkdir -p "$tmp/aar-ok"
  cp "$tmp/ok.jar" "$tmp/aar-ok/classes.jar"
  "${jdk_bin}jar" cf "$tmp/ok.aar" -C "$tmp/aar-ok" .
  expect 0 "an AAR with adapter classes passes" "$script" classes "$tmp/ok.aar"

  mkdir -p "$tmp/aar-libs/libs"
  cp "$tmp/ok.jar" "$tmp/aar-libs/classes.jar"
  cp "$tmp/core.jar" "$tmp/aar-libs/libs/extra.jar"
  "${jdk_bin}jar" cf "$tmp/libs.aar" -C "$tmp/aar-libs" .
  expect 1 "an AAR bundling a core class in libs/ fails" "$script" classes "$tmp/libs.aar"

  mkdir -p "$tmp/aar-empty/res"
  touch "$tmp/aar-empty/res/.keep"
  "${jdk_bin}jar" cf "$tmp/empty.aar" -C "$tmp/aar-empty" .
  expect 1 "an AAR without classes.jar fails" "$script" classes "$tmp/empty.aar"

  cp "$tmp/ok.jar" "$tmp/ok.zip"
  expect 1 "a file that is not an .aar or .jar fails" "$script" classes "$tmp/ok.zip"
fi

expect 2 "an unknown mode is a usage error" "$script" nope

if [[ "$failures" -gt 0 ]]; then
  echo "$failures failure(s)"
  exit 1
fi
