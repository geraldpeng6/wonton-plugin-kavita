# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完 OIDC 链后用 Kavita 自己的“当前用户”接口断言认出的是主人管理员。
# 工具：Kavita 没有声明 MCP，不写 mcp_check。
# 数据：data_write 用随机标记建一个阅读列表，data_check 升级/重装后读回核对。
#
# 会话 jar 用 harness 的 SMOKE_JAR（probes_env 已导出，dweb 也写它，全链必须同一份）；
# 读不到时（老 harness 直接调 identity_check）退回 checkout 目录里自管的一份。数据标记自管。
# SMOKE_OWNER 有值就断言用户名，没有就退化为断言是管理员。

kavita_dir() { printf '%s' "${BASH_SOURCE[0]%/*}"; }
kavita_jar() { printf '%s' "${SMOKE_JAR:-$(kavita_dir)/.smoke-cookies}"; }
kavita_marker() { printf '%s/.smoke-marker' "$(kavita_dir)"; }
kavita_web_url() { printf '%s' "${SMOKE_WEB_URL:-http://$SMOKE_SLUG.${SMOKE_BASE#http://}}"; }

kavita_log_dump() { echo "== kavita 容器日志"; docker logs "$(docker ps --format '{{.Names}}' | grep -m1 'kavita')" 2>&1 | grep -iE "error|exception|fail|warn" | tail -12; }

kavita_absorb() { # 把响应头里的 Set-Cookie 写进 jar，Secure 一律清成 FALSE：
  # ASP.NET 的关联 Cookie 固定带 Secure，http 响应上 curl 会直接丢弃它，OIDC 回调就报 Correlation failed
  local jar="$1" req="$2" hdrs="$3" host cookie pair name value rest attr path exp httponly
  host="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.urlparse(sys.argv[1]).hostname)' "$req")"
  while IFS= read -r cookie; do
    cookie="${cookie#*:}"
    cookie="${cookie# }"
    pair="${cookie%%;*}"
    name="${pair%%=*}"
    value="${pair#*=}"
    [[ -n "$name" && "$name" != "$pair" ]] || continue
    path="/" exp="0" httponly=""
    rest="${cookie#*;}"
    if [[ "$rest" != "$cookie" ]]; then
      while IFS= read -r attr; do
        attr="${attr# }"
        case "${attr,,}" in
          path=*) path="${attr#*=}" ;;
          max-age=*) exp=$(( $(date +%s) + ${attr#*=} )) ;;
          httponly) httponly="#HttpOnly_" ;;
        esac
      done < <(tr ';' '\n' <<<"$rest")
    fi
    printf '%s%s\tTRUE\t%s\tFALSE\t%s\t%s\t%s\n' "$httponly" "$host" "$path" "$exp" "$name" "$value" >>"$jar"
  done < <(grep -i '^set-cookie:' "$hdrs")
}

kavita_walk() { # 学 scripts/dev.sh 的 sso_form_login：逐段跟链，碰到隐藏字段的 POST 表单就替浏览器提交
  local jar="$1" url="$2" page_file method="GET" data="" form
  page_file="$(mktemp)"
  for _ in 1 2 3 4 5 6 7 8; do
    if [[ "$method" == GET ]]; then
      curl -sS --noproxy '*' -L -b "$jar" -c "$jar" -H 'Accept: text/html' -o "$page_file" "$url" || { rm -f "$page_file"; return 1; }
    else
      curl -sS --noproxy '*' -L -b "$jar" -c "$jar" -H 'Accept: text/html' --data "$data" -o "$page_file" "$url" || { rm -f "$page_file"; return 1; }
    fi
    form="$(KAVITA_FORM_URL="$url" python3 - "$page_file" <<'PY'
from html.parser import HTMLParser
from urllib.parse import urlencode, urljoin
import os, sys

class Forms(HTMLParser):
    def __init__(self):
        super().__init__()
        self.current = None
        self.forms = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form" and self.current is None:
            self.current = {"action": a.get("action", ""),
                            "method": a.get("method", "post").lower(),
                            "fields": []}
        elif tag == "input" and self.current is not None:
            name = a.get("name")
            if name and a.get("type", "text").lower() == "hidden":
                self.current["fields"].append((name, a.get("value", "")))

    def handle_endtag(self, tag):
        if tag == "form" and self.current is not None:
            self.forms.append(self.current)
            self.current = None

parser = Forms()
with open(sys.argv[1], encoding="utf-8", errors="replace") as page:
    parser.feed(page.read())
for form in parser.forms:
    if form["method"] == "post" and form["fields"]:
        # ASP.NET 的 noscript 兜底块会把同名字段重复一遍：按 name 去重，取第一次出现的
        seen = set()
        fields = []
        for name, value in form["fields"]:
            if name not in seen:
                seen.add(name)
                fields.append((name, value))
        print(urljoin(os.environ["KAVITA_FORM_URL"], form["action"]))
        print(urlencode(fields))
        break
PY
)" || { rm -f "$page_file"; return 1; }
    [[ -n "$form" ]] || { rm -f "$page_file"; return 0; }
    url="${form%%$'\n'*}"
    data="${form#*$'\n'}"
    method="POST"
  done
  rm -f "$page_file"
  return 1
}

kavita_session() { # 走 Kavita 的 OIDC 挑战、替浏览器提交沿途自动表单（含 form_post），会话落在本地 jar 并验证
  local jar hdrs loc me
  jar="$(kavita_jar)"
  dweb --sso / >/dev/null || { echo "核心会话建立失败"; kavita_log_dump; return 1; }
  # 挑战这一跳不跟 -L 也不写 jar：先把它的 Set-Cookie 补进 jar（Secure 清成 FALSE），再从重定向继续走链
  hdrs="$(mktemp)"
  loc="$(curl -sS --noproxy '*' -D "$hdrs" -o /dev/null -w '%{redirect_url}' -b "$jar" \
    -H 'Accept: text/html' "$(kavita_web_url)/oidc/login")" ||
    { echo "OIDC 挑战请求失败"; rm -f "$hdrs"; kavita_log_dump; return 1; }
  kavita_absorb "$jar" "$(kavita_web_url)/oidc/login" "$hdrs"
  rm -f "$hdrs"
  [[ -n "$loc" ]] || { echo "OIDC 挑战没有重定向"; kavita_log_dump; return 1; }
  loc="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.urljoin(sys.argv[1],sys.argv[2]))' "$(kavita_web_url)/oidc/login" "$loc")"
  kavita_walk "$jar" "$loc" || { echo "OIDC 链没走完"; kavita_log_dump; return 1; }
  # 落点页面含 Kavita 字样不代表会话建好（登录页也有）：用当前用户接口确认真登录了
  me="$(dweb /api/account -b "$jar")" || {
    echo "会话没建好（/api/account 失败）：$(head -c 200 <<<"$me")"
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
