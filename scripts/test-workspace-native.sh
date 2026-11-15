#!/bin/zsh
# 原生窗口接口验收：只操作自建子进程的窗口，不启动Snug、不改变显示拓扑、不请求权限。
set -euo pipefail
cd "${0:A:h}/.."

: "${CODEX_TASK_DATA_DIR:?请设置已挂载外置盘上的 CODEX_TASK_DATA_DIR}"
readonly TASK_ROOT="${CODEX_TASK_DATA_DIR:A}"
[[ -d "$TASK_ROOT" && "$TASK_ROOT" == /Volumes/* ]] || {
  print -u2 -- "任务目录必须是已挂载外置盘上的 /Volumes/... 路径"
  exit 1
}
[[ "$(stat -f %d "$TASK_ROOT")" != "$(stat -f %d /)" ]] || {
  print -u2 -- "任务目录与系统盘同卷，停止写入"
  exit 1
}

# 只查询原生SwiftPM的既有产物，不在这里触发项目构建或下载依赖。
readonly BIN_DIR="$(swift build --build-system native --show-bin-path)"
[[ -e "$BIN_DIR/Modules/SnugCore.swiftmodule" ]] || {
  print -u2 -- "缺少SnugCore产物，请先完成项目原生check"
  exit 1
}
typeset -a CORE_OBJECTS
CORE_OBJECTS=("$BIN_DIR"/SnugCore.build/*.o(N))
(( ${#CORE_OBJECTS} )) || { print -u2 -- "缺少SnugCore对象文件"; exit 1; }

mkdir -p "$TASK_ROOT/snug/validation"
readonly TEST_DIR="$(mktemp -d "$TASK_ROOT/snug/validation/workspace-native.XXXXXX")"
readonly APP="$TEST_DIR/WorkspaceFixture.app"
readonly EXECUTABLE="$APP/Contents/MacOS/workspace-native"

cleanup() {
  # 即使控制进程被中断，也只结束本目录创建、且可执行路径仍匹配的fixture子进程。
  if [[ -f "$TEST_DIR/fixture.pid" ]]; then
    local fixture_pid="$(<"$TEST_DIR/fixture.pid")"
    if [[ "$fixture_pid" == <-> && "$(ps -p "$fixture_pid" -o comm= 2>/dev/null || true)" == "$EXECUTABLE" ]]; then
      kill -TERM "$fixture_pid" 2>/dev/null || true
    fi
  fi
  [[ "$TEST_DIR" == "$TASK_ROOT"/snug/validation/workspace-native.* ]] && rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT INT TERM
export TMPDIR="$TEST_DIR/"
mkdir -p "$APP/Contents/MacOS" "$TEST_DIR/module-cache"

swiftc -swift-version 6 -parse-as-library -module-cache-path "$TEST_DIR/module-cache" \
  -I "$BIN_DIR/Modules" "${CORE_OBJECTS[@]}" \
  Sources/SnugSystem/AX.swift Sources/SnugSystem/WindowIdentity.swift Sources/SnugSystem/WorkspaceWindows.swift \
  Tests/Native/WorkspaceNative.swift -o "$EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.chent1024.snug.workspace-fixture</string>
<key>CFBundleExecutable</key><string>workspace-native</string>
<key>CFBundleName</key><string>Snug Workspace Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

"$EXECUTABLE" "$APP" "$TEST_DIR"
