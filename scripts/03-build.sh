#!/usr/bin/env bash
# =============================================================================
#  步骤 3/5 :: 注入版本号 + 编译 Linux/amd64
#
#  解决什么：
#    ① 协议库需要较新 GLIBC → 在 Ubuntu 24.04 容器内运行。
#    ② 微信服务端返回 -106「你的应用版本过低」→ 编译前把客户端版本号改新。
#    ③ Apple Silicon 容器内 Go 编译易受 QEMU 影响 → macOS 本机用 Zig 交叉编译。
#    ④ libv08.so / libz.so 找不到 → 启动容器时设置 LD_LIBRARY_PATH。
#
#  版本号规则（iOS 系）：
#    形如 0x18 00 3E 20
#         │  │  │  └─ build 低 16 位
#         │  │  └──── 次版本
#         │  └─────── 保留（00）
#         └────────── 平台：0x18=iOS/iPad
#    例：0x18003B20≈8.0.59  0x18003E20≈8.0.62  0x18005020≈8.0.80
#    实测 8.0.62 仍被判定过低；8.0.80 可通过。可用 WECHAT_VER 覆盖。
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

SRC_DIR="${SRC_DIR:-$PWD/wechat860-src}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu24:latest}"
BUILDER_IMAGE="${BUILDER_IMAGE:-wechat-ipad-builder:latest}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
# Go 1.24.0 can segfault inside amd64 emulation on Apple Silicon while
# scanning packages. Use a later 1.24 patch release by default.
GO_VERSION="${GO_VERSION:-1.24.6}"
BUILD_MODE="${BUILD_MODE:-auto}"
ZIG_BIN="${ZIG_BIN:-$(command -v zig || true)}"
# 默认 0x18005020（≈8.0.80）；实测 8.0.62 会被微信拒绝
WECHAT_VER="${WECHAT_VER:-0x18005020}"

if [ "$BUILD_MODE" = "auto" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    BUILD_MODE="host-cross"
  else
    BUILD_MODE="docker"
  fi
fi

if [ -z "$ZIG_BIN" ] && [ "$(uname -m)" = "arm64" ] \
  && [ -x "$HOME/.cache/wechat-ipad-kit/zig-aarch64-macos-0.14.1/zig" ]; then
  ZIG_BIN="$HOME/.cache/wechat-ipad-kit/zig-aarch64-macos-0.14.1/zig"
fi
if [ -z "$ZIG_BIN" ] && [ "$(uname -m)" = "x86_64" ] \
  && [ -x "$HOME/.cache/wechat-ipad-kit/zig-x86_64-macos-0.14.1/zig" ]; then
  ZIG_BIN="$HOME/.cache/wechat-ipad-kit/zig-x86_64-macos-0.14.1/zig"
fi

[ -f "$SRC_DIR/go.mod" ] || die "找不到源码（${SRC_DIR}）。请先运行 scripts/02-fetch-source.sh"

title "注入客户端版本号: $WECHAT_VER"

# 计算人类可读版本，仅用于日志
human_ver="$(python3 - "$WECHAT_VER" <<'PY' 2>/dev/null || echo '?'
import sys
v = int(sys.argv[1], 16)
print(f"{(v>>24)&0xFF}.{(v>>16)&0xFF}.{v&0xFFFF}")
PY
)"
info "对应版本约为 $human_ver"

# 备份 + 原地替换（幂等：重复执行也安全）
patch_ver() {
  local file="$1" pattern="$2" desc="$3"
  [ -f "$SRC_DIR/$file" ] || { warn "跳过 ${file}（不存在）"; return 0; }
  [ -f "$SRC_DIR/$file.orig" ] || cp "$SRC_DIR/$file" "$SRC_DIR/$file.orig"
  # 用 .orig 作基准，保证多次执行结果一致
  if sed -E "s|${pattern}|var \3 = ${4:-int32}($WECHAT_VER) // patched|" \
       "$SRC_DIR/$file.orig" > "$SRC_DIR/$file"; then
    ok "$desc  ($file)"
  else
    warn "$desc 替换失败 ($file)"
  fi
}

# IPadVersion / IPadVersionx —— 二维码与登录流程实际使用的版本号
[ -f "$SRC_DIR/Algorithm/Util.go.orig" ] || cp "$SRC_DIR/Algorithm/Util.go" "$SRC_DIR/Algorithm/Util.go.orig"
sed -E \
  -e "s|var IPadVersion = int32\(0x[0-9A-Fa-f]+\).*|var IPadVersion = int32($WECHAT_VER) // patched|" \
  -e "s|var IPadVersionx = int32\(0x[0-9A-Fa-f]+\).*|var IPadVersionx = int32($WECHAT_VER) // patched|" \
  "$SRC_DIR/Algorithm/Util.go.orig" > "$SRC_DIR/Algorithm/Util.go.tmp"
mv "$SRC_DIR/Algorithm/Util.go.tmp" "$SRC_DIR/Algorithm/Util.go"
ok "Algorithm/Util.go"

[ -f "$SRC_DIR/baseinfo/basedefine.go.orig" ] || cp "$SRC_DIR/baseinfo/basedefine.go" "$SRC_DIR/baseinfo/basedefine.go.orig"
sed -E \
  -e "s|var ClientVersion = uint32\(0x[0-9A-Fa-f]+\).*|var ClientVersion = uint32($WECHAT_VER) // patched|" \
  -e "s|var PlistVersion = uint32\(0x[0-9A-Fa-f]+\).*|var PlistVersion = uint32($WECHAT_VER) // patched|" \
  "$SRC_DIR/baseinfo/basedefine.go.orig" > "$SRC_DIR/baseinfo/basedefine.go.tmp"
mv "$SRC_DIR/baseinfo/basedefine.go.tmp" "$SRC_DIR/baseinfo/basedefine.go"
ok "baseinfo/basedefine.go"

# The upstream source currently hard-codes the newsync request as iPhone.
# Keep it aligned with the device type used during login (normally iPad),
# otherwise polling can look like a second client and invalidate the session.
sync_file="$SRC_DIR/models/Msg/sync.go"
if [ -f "$sync_file" ]; then
  if grep -q 'DeviceType:[[:space:]]*proto.String("iPhone")' "$sync_file"; then
    sed_in_place 's|DeviceType:[[:space:]]*proto.String("iPhone"),|DeviceType:    proto.String(D.DeviceType),|' "$sync_file"
    ok "同步请求设备类型已对齐登录设备"
  elif grep -q 'DeviceType:[[:space:]]*proto.String(D.DeviceType)' "$sync_file"; then
    ok "同步请求设备类型已对齐登录设备"
  else
    warn "未识别 models/Msg/sync.go 的设备类型字段，保留上游实现"
  fi
fi

title "当前版本号定义"
grep -nE "IPadVersion = |IPadVersionx = " "$SRC_DIR/Algorithm/Util.go" || true
grep -nE "ClientVersion = uint32" "$SRC_DIR/baseinfo/basedefine.go" || true

# Rancher Desktop may expose an arm64 VM even when Docker is invoked from
# Intel macOS. Running the amd64 Go compiler through that emulation is known
# to crash in the Go runtime; use the already supported host cross build.
if [ "$BUILD_MODE" = "docker" ] && [ "$(uname -s)" = "Darwin" ] \
  && [ "$(docker info --format '{{.Architecture}}' 2>/dev/null || true)" = "aarch64" ] \
  && [ -n "$ZIG_BIN" ]; then
  warn "Docker 虚拟机是 ARM64，跳过会导致 Go SIGSEGV 的 amd64 仿真编译，改用 macOS 本机交叉编译。"
  BUILD_MODE="host-cross"
fi

# --------------------------------------------------------------- 构建器镜像
builder_matches_go() {
  [ "$BUILD_MODE" = "docker" ] || return 1
  docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 || return 1
  docker run --platform "$DOCKER_PLATFORM" --rm "$BUILDER_IMAGE" \
    bash -lc 'export PATH=/usr/local/go/bin:$PATH; go version' 2>/dev/null \
    | grep -q "go${GO_VERSION}"
}

if [ "$BUILD_MODE" = "docker" ] && ! builder_matches_go; then
  title "构建编译环境镜像（首次较慢）"
  docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 \
    || die "基础镜像 $BASE_IMAGE 不存在。请先运行 scripts/01-get-base-image.sh"

  BUILD_CTX="$(mktemp -d)"
  cat > "$BUILD_CTX/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/usr/local/go/bin:\$PATH

RUN apt-get update -qq && \\
    apt-get install -y -qq ca-certificates curl xz-utils git gcc g++ libc6-dev >/dev/null

# 安装 Go（走官方国内镜像）
RUN curl -fsSL -o /tmp/go.tgz https://golang.google.cn/dl/go${GO_VERSION}.linux-amd64.tar.gz \\
 && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \\
 && go version

# Go 模块代理（国内）
RUN go env -w GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct \\
 && go env -w GOSUMDB=off \\
 && go env -w GOTOOLCHAIN=local
EOF
  docker build --platform "$DOCKER_PLATFORM" --no-cache -t "$BUILDER_IMAGE" "$BUILD_CTX" || die "编译环境镜像构建失败。"
  rm -rf "$BUILD_CTX"
  ok "编译环境就绪: $BUILDER_IMAGE"
elif docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
  ok "编译环境已存在: $BUILDER_IMAGE"
fi

# --------------------------------------------------------------- 编译
if [ "$BUILD_MODE" = "host-cross" ]; then
  require_cmd go "macOS 本机编译需要已安装的 Go。"
  [ -x "$ZIG_BIN" ] || die "macOS 本机交叉编译需要 Zig。请安装 Zig（brew install zig），或设置 ZIG_BIN=/path/to/zig。"
  title "在 macOS 本机交叉编译 Linux/amd64（CGO 使用 Zig）"
  if (
    cd "$SRC_DIR"
    env CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
      CC="$ZIG_BIN cc -target x86_64-linux-gnu" \
      GOFLAGS=-mod=mod go build -o main .
  ); then
    file "$SRC_DIR/main" | grep -q 'ELF 64-bit LSB.*x86-64' \
      || die "交叉编译产物不是 Linux/amd64 ELF。"
  else
    die "macOS 本机交叉编译失败。请检查 Go、Zig 与网络依赖。"
  fi
elif [ "$BUILD_MODE" = "docker" ]; then
  title "容器内编译（首次会拉取大量 Go 依赖）"
  docker run --platform "$DOCKER_PLATFORM" --rm \
    -v "$SRC_DIR":/src \
    -w /src \
    -e GOFLAGS=-mod=mod \
    -e GOMAXPROCS="${BUILD_PROCS:-2}" \
    "$BUILDER_IMAGE" \
    bash -lc 'export PATH=/usr/local/go/bin:$PATH && go build -o main . ' \
    || die "编译失败。请检查上面的 Go 报错信息。"
else
  die "未知 BUILD_MODE=$BUILD_MODE（可用 auto、host-cross、docker）。"
fi

if [ "$BUILD_MODE" != "host-cross" ] && [ "$(uname -s)" = "Darwin" ] \
  && [ "$(docker info --format '{{.OSType}}/{{.Architecture}}' 2>/dev/null || true)" = "linux/arm64" ]; then
  file "$SRC_DIR/main" | grep -q 'ELF 64-bit LSB.*x86-64' \
    || die "容器编译产物不是 Linux/amd64 ELF。"
fi

if [ ! -x "$SRC_DIR/main" ]; then
  die "编译结束但未生成可执行文件 $SRC_DIR/main。"
fi

title "验证版本号是否真的写进二进制"
python3 - "$SRC_DIR/main" "$WECHAT_VER" <<'PY' || true
import struct, sys
path, ver = sys.argv[1], int(sys.argv[2], 16)
blob = open(path, 'rb').read()
pat = struct.pack('<i', ver)
n = blob.count(pat)
print(f"  目标版本常量 0x{ver:08X} 在二进制中出现 {n} 次")
if n == 0:
    print("  [WARN] 未找到该常量，版本号替换可能未生效！")
    sys.exit(1)
PY

title "完成"
log "可执行文件: $SRC_DIR/main  ($(du -h "$SRC_DIR/main" | cut -f1))"
log "下一步    : bash scripts/04-login.sh"
