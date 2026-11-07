# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完 OIDC 链后用 Kavita 自己的“当前用户”接口断言认出的是主人管理员。
# 工具：Kavita 没有声明 MCP，不写 mcp_check。
# 数据：data_write 用随机标记建一个阅读列表，data_check 升级/重装后读回核对。
#
# 会话 jar 和数据标记都放在本插件 checkout 目录里（由 BASH_SOURCE 推导），不依赖 harness 的
# SMOKE_JAR/SMOKE_STATE：e2e 的 identity_check 不经 run_hook，这些变量未导出（set -u 直接退出）。
# SMOKE_OWNER 有值就断言用户名，没有就退化为断言是管理员。

kavita_dir() { printf '%s' "${BASH_SOURCE[0]%/*}"; }
kavita_jar() { printf '%s/.smoke-cookies' "$(kavita_dir)"; }
kavita_marker() { printf '%s/.smoke-marker' "$(kavita_dir)"; }

kavita_log_dump() { echo "== kavita 容器日志"; docker logs "$(docker ps --format '{{.Names}}' | grep -m1 'kavita')" 2>&1 | grep -iE "error|exception|fail|warn" | tail -12; }

kavita_session() { # 走到 Kavita 的 form_post 自动表单，替浏览器提交，会话落在本地 jar 并验证
  local jar page rc="0" action args=() input n v me
  jar="$(kavita_jar)"
  page="$(dweb --sso /oidc/login -L -b "$jar" -c "$jar")" || rc=$?
  if [[ $rc -ne 0 ]]; then echo "OIDC 链失败 rc=$rc：$(head -c 150 <<<"$page")"; kavita_log_dump; return 1; fi
  action="$(sed -n 's/.*action="\([^"]*\)".*/\1/p' <<<"$page" | head -1)"
  if [[ -n "$action" ]]; then
    # ASP.NET 的 noscript 兜底块会把同名字段重复一遍：按 name 取第一次出现的，跳过没有名字的
    while IFS= read -r input; do
      n="$(sed -E 's/.*name="([^"]*)".*/\1/' <<<"$input")"
      v="$(sed -E 's/.*value="([^"]*)".*/\1/' <<<"$input")"
      [[ -n "$n" && ! -v "seen_$n" ]] || continue
      declare "seen_$n=1"
      args+=(--data-urlencode "$n=$v")
    done < <(grep -oE '<input[^>]*>' <<<"$page")
    page="$(curl -sS --noproxy '*' -L -b "$jar" -c "$jar" -H 'Accept: text/html' "${args[@]}" "$action")" ||
      { echo "signin-oidc 表单提交失败：$(head -c 150 <<<"$page")"; kavita_log_dump; return 1; }
  fi
  # 落点页面含 Kavita 字样不代表会话建好（登录页也有）：用当前用户接口确认真登录了
  me="$(dweb /api/account -b "$jar")" || {
    echo "会话没建好（/api/account 失败）：$(head -c 200 <<<"$me")；表单后落点：$(head -c 150 <<<"$page")"
    kavita_log_dump
    return 1
  }
  grep -q '"username"' <<<"$me" || { echo "/api/account 不是用户信息：$(head -c 150 <<<"$me")"; return 1; }
}

web_assert() { grep -qi 'kavita'; }

identity_check() { # OIDC 链落回插件首页后，用 Kavita 自己的当前用户接口核对（401 时整链重试一次）
  local me owner="${SMOKE_OWNER:-}" attempt
  for attempt in 1 2; do
    kavita_session || return 1
    if me="$(dweb /api/account -b "$(kavita_jar)")"; then
      break
    fi
    echo "GET /api/account 失败（第 $attempt 次）：$(head -c 200 <<<"$me")"
    kavita_log_dump
    [[ $attempt == 2 ]] && { echo "GET /api/account 失败：$me"; return 1; }
  done
  if [[ -n "$owner" ]]; then
    jq -e --arg u "$owner" '.username == $u and (.roles | index("Admin") != null)' <<<"$me" >/dev/null ||
      { echo "当前用户不是主人管理员：$(head -c 200 <<<"$me")"; return 1; }
  else
    jq -e '.username != null and (.roles | index("Admin") != null)' <<<"$me" >/dev/null ||
      { echo "当前用户不是管理员：$(head -c 200 <<<"$me")"; return 1; }
  fi
}

data_write() { # 用随机名字建一个阅读列表
  local marker name out
  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s' "$marker" >"$(kavita_marker)"
  kavita_session || return 1
  name="wonton-smoke-$marker"
  out="$(dweb /api/readinglist/create -b "$(kavita_jar)" -H 'Content-Type: application/json' \
    -d "{\"title\":\"$name\"}")" || { echo "建阅读列表失败：$out"; return 1; }
}

data_check() { # 升级/重装后重新走 OIDC，核对阅读列表还在
  local marker lists
  marker="$(cat "$(kavita_marker)" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "没有 data-write 留下的标记"; return 1; }
  kavita_session || return 1
  lists="$(dweb /api/readinglist/lists -X POST -b "$(kavita_jar)" \
    -H 'Content-Type: application/json' -d '{}')" || { echo "读阅读列表失败：$lists"; return 1; }
  jq -e --arg n "wonton-smoke-$marker" 'any(.[]; .title == $n)' <<<"$lists" >/dev/null ||
    { echo "阅读列表不见了：$(head -c 200 <<<"$lists")"; return 1; }
}
