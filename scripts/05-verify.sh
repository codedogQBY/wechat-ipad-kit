#!/usr/bin/env bash
# =============================================================================
#  步骤 5/5 :: 健康检查 / 能力探测 / 一键排错
#
#  用途：
#    - 确认服务、登录态、Redis 三层都正常
#    - 探测常用接口是否可用（取自己资料、拉好友列表）
#    - 出问题时把关键信息一次性收集出来，便于提 issue
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

SRC_DIR="${SRC_DIR:-$PWD/wechat860-src}"
CONTAINER="${CONTAINER:-wechat-ipad}"
REDIS_CONTAINER="${REDIS_CONTAINER:-wechat-redis}"
HOST_PORT="${HOST_PORT:-8058}"
REDIS_DB="${REDIS_DB:-2}"
STATE_DIR="${STATE_DIR:-$PWD/.state}"
PREFIX="$(cat "$STATE_DIR/prefix.txt" 2>/dev/null || echo '/api')"

fails=0
mark_fail() { fails=$((fails + 1)); }

# ------------------------------------------------------------------ 1. 容器
title "1/5  容器状态"
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  ok "容器 $CONTAINER 运行中"
  docker stats --no-stream --format '     内存 {{.MemUsage}}  CPU {{.CPUPerc}}' "$CONTAINER" 2>/dev/null || true
else
  warn "容器 $CONTAINER 未运行"; mark_fail
  log  "  启动: bash scripts/04-login.sh"
fi

# ------------------------------------------------------------ 2. 协议内核
title "2/5  协议内核（动态库）是否加载"
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  if docker logs "$CONTAINER" 2>&1 | grep -qi "Failed to load library"; then
    warn "有动态库加载失败记录："; mark_fail
    docker logs "$CONTAINER" 2>&1 | grep -i "Failed to load library" | tail -3 | sed 's/^/     /'
    log  "  修复：确认 lib/libv08.so 存在；容器启动时执行 ldconfig 并设置 LD_LIBRARY_PATH=/src/lib"
  else
    ok "未发现动态库加载错误"
  fi
fi

# ------------------------------------------------------------------ 3. 端口
title "3/5  服务端口"
if curl -fsS -o /dev/null -m 5 "http://127.0.0.1:$HOST_PORT/" 2>/dev/null; then
  ok "HTTP $HOST_PORT 可访问"
else
  # 有些构建根路径返回 404，但接口仍可用
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$HOST_PORT/" 2>/dev/null || true)"
  [ -n "$code" ] || code=000
  if [ "$code" != "000" ]; then ok "端口有响应（HTTP ${code}）"; else warn "端口无响应"; mark_fail; fi
fi

# ------------------------------------------------------------------ 4. Redis
title "4/5  Redis 登录缓存"
if redis_cli ping >/dev/null 2>&1; then
  n="$(redis_cli -n "$REDIS_DB" DBSIZE 2>/dev/null || echo '?')"
  ok "Docker Redis 可用，DB$REDIS_DB 有 $n 个键"
else
  warn "Redis 不可用"; mark_fail
fi

# --------------------------------------------------------------- 5. 登录态
title "5/5  Redis 登录缓存字段"
logged_in=0
logged_wxid=""
if redis_cli ping >/dev/null 2>&1; then
  for key in $(redis_cli -n "$REDIS_DB" --scan 2>/dev/null | grep -vE '^(wechat|devId):'); do
    out="$(redis_cli -n "$REDIS_DB" GET "$key" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
uin=d.get("Uin") or 0; wxid=d.get("Wxid") or ""; sk=d.get("Sessionkey")
if uin and wxid and sk is not None:
    nick=d.get("NickName") or ""
    print("{}|{}|{}".format(wxid, uin, nick))
' 2>/dev/null)"
    if [ -n "$out" ]; then
      logged_in=1
      [ -n "$logged_wxid" ] || logged_wxid="$(echo "$out" | cut -d'|' -f1)"
      ok "缓存字段齐全（尚需验证微信侧会话）"
      log "     Wxid     : $(echo "$out" | cut -d'|' -f1)"
      log "     Uin      : $(echo "$out" | cut -d'|' -f2)"
      log "     NickName : $(echo "$out" | cut -d'|' -f3)"
      log "     Redis key: $key"
    fi
  done
fi
if [ "$logged_in" -eq 0 ]; then
  warn "未检测到完整登录态"; mark_fail
  log  "  可能是：未点确认 / 二维码过期 / 未调用 LoginCheckQR / 版本号过低"
fi

# --------------------------------------------------------------- 接口探测
session_verified=0
if [ "$logged_in" -eq 1 ]; then
  title "微信侧会话验证 / 通讯录接口探测"
  for ep in "User/GetContractProfile" "Friend/GetContractList"; do
    if [ "$ep" = "User/GetContractProfile" ]; then
      url="http://127.0.0.1:$HOST_PORT$PREFIX/$ep?wxid=$logged_wxid"
      body='{}'
    else
      url="http://127.0.0.1:$HOST_PORT$PREFIX/$ep"
      body="{\"Wxid\":\"$logged_wxid\",\"CurrentWxcontactSeq\":0,\"CurrentChatRoomContactSeq\":0}"
    fi
    resp="$(curl -sS -m 30 -X POST "$url" \
              -H 'Content-Type: application/json' -d "$body" 2>/dev/null || echo '{}')"
    code="$(printf '%s' "$resp" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); print(d.get("Code"))
except Exception: print("?")
' 2>/dev/null)"
    if [ "$ep" = "User/GetContractProfile" ]; then
      if [ "$code" = "0" ]; then
        session_verified=1
        ok "$ep  → Code 0（微信侧会话有效）"
      elif [ "$code" = "-13" ]; then
        warn "$ep  → Code -13（协议会话已超时，需要重新扫码登录）"
        mark_fail
      else
        warn "$ep  → Code $code（无法确认微信侧会话）"
        mark_fail
      fi
    elif [ "$code" = "0" ]; then
      ok "$ep  → Code 0"
    elif [ "$code" = "-13" ]; then
      warn "$ep  → Code -13（协议会话已超时，需要重新扫码登录）"
      mark_fail
    else
      warn "$ep  → Code $code"
    fi
  done
fi

# ------------------------------------------------------------------ 总结
echo
if [ "$fails" -eq 0 ] && [ "$logged_in" -eq 1 ] && [ "$session_verified" -eq 1 ]; then
  ok "全部检查通过 ✅"
  exit 0
fi
if [ "$logged_in" -eq 0 ]; then
  warn "存在 $fails 项异常（登录态未建立）"
elif [ "$session_verified" -eq 0 ]; then
  warn "Redis 中有登录缓存，但微信侧会话未验证"
else
  warn "存在 $fails 项异常"
fi
echo
log "── 排错资料（提 issue 时可附上）────────────────────────"
log "容器日志末尾："
docker logs --tail 20 "$CONTAINER" 2>&1 | sed 's/^/  /' || true
log "磁盘 / 内存："
df -h . 2>/dev/null | tail -1 | sed 's/^/  /' || true
if has_cmd free; then
  free -m 2>/dev/null | head -2 | sed 's/^/  /' || true
elif has_cmd vm_stat; then
  vm_stat 2>/dev/null | sed -n '1,3p' | sed 's/^/  /' || true
fi
log "详见 docs/TROUBLESHOOTING.md"
exit 1
