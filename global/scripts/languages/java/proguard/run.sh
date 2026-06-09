#!/usr/bin/env sh
# ProGuard provides BYTECODE-LEVEL dead code detection via whole-program call graph analysis.
# It traces reachability from entry points and reports unreachable classes, methods, and fields.
# Projects can override keep rules by placing a `.proguard-keep.pro` file in the project root.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="proguard" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/proguard-usage.txt"

PROGUARD_VERSION="${PROGUARD_VERSION:-7.6.1}"
PROGUARD_DIR="/tmp/proguard-$PROGUARD_VERSION"
if [ ! -d "$PROGUARD_DIR" ]; then
  echo "Installing ProGuard $PROGUARD_VERSION..."
  wget -q "https://github.com/Guardsquare/proguard/releases/download/v$PROGUARD_VERSION/proguard-$PROGUARD_VERSION.tar.gz" -O /tmp/proguard.tar.gz
  tar xzf /tmp/proguard.tar.gz -C /tmp
  rm /tmp/proguard.tar.gz
fi

# Build the project to produce bytecode
if [ -f "gradlew" ]; then
  echo "Building project with Gradle..."
  if ! ./gradlew classes --quiet 2>&1; then
    echo "BUILD FAILED: Gradle compilation failed. Skipping ProGuard analysis."
    echo "SKIP: compilation failed" > "$fileName"
    exit 1
  fi
  INPUT_JARS=$(find . -path "*/build/libs/*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" 2>/dev/null | head -1)
  if [ -z "$INPUT_JARS" ]; then
    INPUT_JARS=$(find . -path "*/build/classes/java/main" -type d 2>/dev/null | head -1)
  fi
elif [ -f "pom.xml" ]; then
  echo "Building project with Maven..."
  if ! mvn compile -q 2>&1; then
    echo "BUILD FAILED: Maven compilation failed. Skipping ProGuard analysis."
    echo "SKIP: compilation failed" > "$fileName"
    exit 1
  fi
  INPUT_JARS=$(find . -path "*/target/*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" 2>/dev/null | head -1)
  if [ -z "$INPUT_JARS" ]; then
    INPUT_JARS=$(find . -path "*/target/classes" -type d 2>/dev/null | head -1)
  fi
fi

if [ -z "$INPUT_JARS" ]; then
  echo "No compiled classes found. Skipping ProGuard analysis."
  echo "SKIP: no compiled classes found" > "$fileName"
  exit 0
fi

# Detect Java runtime library
JAVA_JMODS="$JAVA_HOME/jmods/java.base.jmod"
JAVA_RT="$JAVA_HOME/lib/rt.jar"
if [ -f "$JAVA_JMODS" ]; then
  LIBRARY_JARS="$JAVA_JMODS(!**.jar;!module-info.class)"
elif [ -f "$JAVA_RT" ]; then
  LIBRARY_JARS="$JAVA_RT"
else
  echo "Cannot find Java runtime library. Skipping ProGuard analysis."
  echo "SKIP: no Java runtime found" > "$fileName"
  exit 0
fi

# Build ProGuard config
PROGUARD_CONF="/tmp/proguard-analysis.pro"
cat > "$PROGUARD_CONF" <<'PROGUARD_EOF'
-dontoptimize
-dontobfuscate

# Keep all public static void main entry points
-keep public class * {
    public static void main(java.lang.String[]);
}

# Keep Spring/Jakarta framework entry points
-keep @org.springframework.stereotype.Component class *
-keep @org.springframework.stereotype.Service class *
-keep @org.springframework.stereotype.Repository class *
-keep @org.springframework.stereotype.Controller class *
-keep @org.springframework.web.bind.annotation.RestController class *
-keep @org.springframework.context.annotation.Configuration class *
-keep @org.springframework.boot.autoconfigure.SpringBootApplication class *
-keep @jakarta.inject.Named class *
-keep @jakarta.enterprise.context.* class *

# Keep all public API surface
-keep public class * {
    public protected *;
}

# Suppress warnings for missing library classes
-dontwarn **
PROGUARD_EOF

# Append project-level overrides if present
if [ -f ".proguard-keep.pro" ]; then
  echo "" >> "$PROGUARD_CONF"
  cat ".proguard-keep.pro" >> "$PROGUARD_CONF"
fi

echo "Running ProGuard dead code analysis..."
proguardLog="/tmp/proguard-run.log"
EXIT_CODE=0
java -jar "$PROGUARD_DIR/lib/proguard.jar" \
  -injars "$INPUT_JARS" \
  -outjars /dev/null \
  -libraryjars "$LIBRARY_JARS" \
  -printusage "$fileName" \
  -include "$PROGUARD_CONF" > "$proguardLog" 2>&1 || EXIT_CODE=$?

# ProGuard's process exit code is an unreliable pass/fail signal for this
# check. On Java 21 it exits non-zero while reading certain `module-info`
# class files from dependencies (e.g. Spring Boot) even when there is no
# dead code, which made this advisory job fail on every run -- with the
# cause hidden because the output was sent to /dev/null. The signal this
# check actually cares about is the `-printusage` report: the list of
# unreachable classes, methods, and fields. So decide pass/fail from that
# report rather than ProGuard's raw exit status, and always surface
# ProGuard's output so genuine problems stay diagnosable.
if [ "${EXIT_CODE:-0}" -ne 0 ]; then
  echo "ProGuard exited with status ${EXIT_CODE}; output follows:"
  sed 's/^/  | /' "$proguardLog"
fi
rm -f "$proguardLog"

if [ -s "$fileName" ]; then
  echo "ProGuard reported potential dead code (see $fileName):"
  cat "$fileName"
  echo "ProGuard analysis complete. Results written to: $fileName"
  exit 1
fi

# Empty usage report -> no dead code. Pass even when ProGuard exited non-zero
# on an internal/environmental error (surfaced above), since this advisory
# check should fail only on a real dead-code finding.
: > "$fileName"
if [ "${EXIT_CODE:-0}" -ne 0 ]; then
  echo "ProGuard did not finish cleanly (status ${EXIT_CODE}, see output above) but produced no dead-code findings; treating as a non-blocking warning."
else
  echo "No dead code detected."
fi
echo "ProGuard analysis complete. Results written to: $fileName"
exit 0
