#!/usr/bin/env bash
# Guards the adapter-only Android layout (ANSDK-01, ANSDK-16): since 0.9.0 the engine lives in
# br.com.zeeplabs:notti-android, and this package keeps only the com.notti adapter. A ported core file
# coming back would run a second engine next to the native one and could clash with its classes.
#
# Usage:
#   scripts/check-android-adapter.sh layout [repo-root]
#       android/src/main/java holds exactly the four adapter files, android/src/test/java exactly the
#       four test files, and android/src/main/AndroidManifest.xml declares no element (components and
#       permissions merge from the native AAR).
#   scripts/check-android-adapter.sh classpath <dependencies-report|-> [repo-root]
#       <dependencies-report> is the output of (from example/android)
#       `./gradlew :app:dependencies --configuration releaseRuntimeClasspath`. Requires one resolved
#       com.google.firebase:firebase-messaging version and br.com.zeeplabs:notti-android at the exact
#       version android/build.gradle pins.
#   scripts/check-android-adapter.sh classes <library.aar|classes.jar>
#       Every class of the built library is under com/notti/ and compiled from an adapter source, the
#       Codegen NativeNottiSpec or the AGP BuildConfig (needs javap: JAVA_HOME or PATH).
set -euo pipefail

default_root="$(cd "$(dirname "$0")/.." && pwd)"

main_files=(
  com/notti/NottiBridge.kt
  com/notti/NottiModule.kt
  com/notti/NottiNativeApi.kt
  com/notti/NottiPackage.kt
)
test_files=(
  com/notti/NottiAdapterTest.kt
  com/notti/NottiBridgeTest.kt
  com/notti/NottiModuleTest.kt
  com/notti/NottiTestSupport.kt
)
# Source file stems a library class may be compiled from: the adapter files, the Codegen spec and the
# BuildConfig AGP generates for the com.notti namespace.
class_sources=(NottiBridge NottiModule NottiNativeApi NottiPackage NativeNottiSpec BuildConfig)

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 layout [repo-root] | classpath <dependencies-report|-> [repo-root] | classes <aar|jar>" >&2
  exit 2
}

# check_tree <dir> <label> <expected relative paths...>
check_tree() {
  local dir="$1" label="$2"
  shift 2
  [[ -d "$dir" ]] || fail "$dir not found"
  local expected actual
  expected="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  actual="$(cd "$dir" && find . -type f ! -name .DS_Store | sed 's#^\./##' | LC_ALL=C sort)"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: $label must hold exactly the adapter files (ANSDK-01); the engine lives in br.com.zeeplabs:notti-android" >&2
    diff <(echo "$expected") <(echo "$actual") | sed -n 's/^< /  missing: /p; s/^> /  unexpected: /p' >&2
    exit 1
  fi
}

check_layout() {
  local root="${1:-$default_root}"
  check_tree "$root/android/src/main/java" "android/src/main/java" "${main_files[@]}"
  check_tree "$root/android/src/test/java" "android/src/test/java" "${test_files[@]}"

  local manifest="$root/android/src/main/AndroidManifest.xml"
  [[ -f "$manifest" ]] || fail "$manifest not found"
  local tags
  tags="$(perl -0777 -ne 's/<!--.*?-->//gs; s/<\?.*?\?>//gs; print "$1\n" while /<([A-Za-z][\w:.-]*)/g' "$manifest")"
  if [[ "$tags" != "manifest" ]]; then
    echo "error: android/src/main/AndroidManifest.xml must be an empty <manifest /> (ANSDK-12); components and permissions merge from the native AAR. Found elements:" >&2
    printf '  <%s>\n' $tags >&2
    exit 1
  fi
  echo "layout ok: adapter files only, empty library manifest"
}

check_classpath() {
  local report="${1:-}" root="${2:-$default_root}"
  [[ -n "$report" ]] || usage
  local text
  if [[ "$report" == "-" ]]; then
    text="$(cat)"
  else
    [[ -f "$report" ]] || fail "$report not found"
    text="$(cat "$report")"
  fi

  local build_file="$root/android/build.gradle" pinned
  [[ -f "$build_file" ]] || fail "$build_file not found"
  pinned="$(sed -nE 's/^[[:space:]]*api[[:space:]]+"br\.com\.zeeplabs:notti-android:([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' "$build_file")"
  [[ -n "$pinned" && "$(wc -l <<<"$pinned")" -eq 1 ]] ||
    fail "$build_file must declare exactly one api \"br.com.zeeplabs:notti-android:X.Y.Z\" (exact pin, OQ-2)"

  grep -qE '^releaseRuntimeClasspath' <<<"$text" ||
    fail "input is not a releaseRuntimeClasspath dependencies report"
  if grep -qE ' FAILED$' <<<"$text"; then
    echo "error: unresolved dependencies in releaseRuntimeClasspath:" >&2
    grep -E ' FAILED$' <<<"$text" >&2
    exit 1
  fi

  # resolved <group:name>: the version each tree line resolves to (after "->" when Gradle replaced it).
  resolved() {
    grep -F -- "--- $1:" <<<"$text" |
      sed -E 's/\{(strictly|require|prefer) ([^}]*)\}/\2/g' |
      sed -E "s/.*--- ${1//./\\.}:([^ ]+)( -> ([^ ]+))?.*/\1 \3/" |
      awk '{ print ($2 != "" ? $2 : $1) }' | LC_ALL=C sort -u || true
  }

  local fcm notti
  fcm="$(resolved com.google.firebase:firebase-messaging)"
  if [[ -z "$fcm" ]]; then
    fail "com.google.firebase:firebase-messaging is not on releaseRuntimeClasspath (ANSDK-16)"
  elif [[ "$(wc -l <<<"$fcm")" -ne 1 ]]; then
    echo "error: more than one com.google.firebase:firebase-messaging version on releaseRuntimeClasspath (ANSDK-16):" >&2
    printf '  %s\n' $fcm >&2
    exit 1
  fi

  notti="$(resolved br.com.zeeplabs:notti-android)"
  if [[ "$notti" != "$pinned" ]]; then
    fail "br.com.zeeplabs:notti-android must resolve to $pinned (android/build.gradle); found: ${notti:-none}"
  fi
  echo "classpath ok: firebase-messaging $fcm, notti-android $notti"
}

check_classes() {
  local artifact="${1:-}"
  [[ -n "$artifact" ]] || usage
  [[ -f "$artifact" ]] || fail "$artifact not found"
  local javap="javap"
  [[ -n "${JAVA_HOME:-}" ]] && javap="$JAVA_HOME/bin/javap"
  command -v "$javap" >/dev/null || fail "javap not found (set JAVA_HOME)"
  command -v unzip >/dev/null || fail "unzip not found"

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  local jars=()
  case "$artifact" in
    *.aar)
      unzip -q "$artifact" 'classes.jar' 'libs/*.jar' -d "$tmp/aar" 2>/dev/null || true
      [[ -f "$tmp/aar/classes.jar" ]] || fail "$artifact has no classes.jar"
      jars+=("$tmp/aar/classes.jar")
      if [[ -d "$tmp/aar/libs" ]]; then
        while IFS= read -r j; do jars+=("$j"); done < <(find "$tmp/aar/libs" -name '*.jar' | LC_ALL=C sort)
      fi
      ;;
    *.jar) jars+=("$artifact") ;;
    *) fail "$artifact is not an .aar or .jar" ;;
  esac

  local jar n=0
  for jar in "${jars[@]}"; do
    n=$((n + 1))
    mkdir -p "$tmp/classes/$n"
    unzip -q "$jar" '*.class' -d "$tmp/classes/$n" 2>/dev/null || true
  done

  local entries=()
  while IFS= read -r entry; do entries+=("$entry"); done < <(cd "$tmp/classes" && find . -name '*.class' | sed 's#^\./##' | LC_ALL=C sort)
  local count="${#entries[@]}"

  # One javap run for every class: "Classfile <path>" opens each block, "SourceFile: "<name>"" closes it.
  local sources=""
  if [[ "$count" -gt 0 ]]; then
    sources="$(cd "$tmp/classes" && "$javap" -v "${entries[@]}" 2>&1 |
      awk '/^Classfile /{ cur = $2; sub(/^.*\/classes\//, "", cur) }
           /^SourceFile: "/{ s = $0; sub(/^SourceFile: "/, "", s); sub(/"$/, "", s); print cur "\t" s }')"
  fi

  local bad=() entry rel src stem allowed s
  for entry in "${entries[@]}"; do
    rel="${entry#*/}"
    if [[ "$rel" != com/notti/* || "${rel#com/notti/}" == */* ]]; then
      bad+=("$rel (outside com.notti)")
      continue
    fi
    src="$(awk -F'\t' -v e="$entry" '$1 == e { print $2; exit }' <<<"$sources")"
    stem="${src%.*}"
    allowed=0
    for s in "${class_sources[@]}"; do
      if [[ "$stem" == "$s" && ("$src" == *.kt || "$src" == *.java) ]]; then allowed=1; fi
    done
    [[ "$allowed" -eq 1 ]] || bad+=("$rel (compiled from ${src:-unknown source})")
  done

  [[ "$count" -gt 0 ]] || fail "$artifact holds no classes"
  if [[ "${#bad[@]}" -gt 0 ]]; then
    echo "error: the library may only ship the com.notti adapter, NativeNottiSpec and BuildConfig (ANSDK-01); the engine lives in br.com.zeeplabs:notti-android. Unexpected classes:" >&2
    printf '  %s\n' "${bad[@]}" >&2
    exit 1
  fi
  echo "classes ok: $count classes, all from the adapter, NativeNottiSpec or BuildConfig"
}

case "${1:-}" in
  layout) check_layout "${2:-}" ;;
  classpath) check_classpath "${2:-}" "${3:-}" ;;
  classes) check_classes "${2:-}" ;;
  *) usage ;;
esac
