"""装好后的账号引导（Kavita 健康后运行）。

Kavita 的第一个注册用户自动是管理员，而 OIDC 登录按邮箱关联已有账号，预置账号不会拿到管理员角色。
所以这里用官方接口注册管理员（用户名、邮箱、密码都来自核心注入），再打开自动登录，让用户经核心
单点登录进来时不再看到 Kavita 自己的登录页。每次创建容器重跑，都已存在时幂等跳过。
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://kavita:5000"


def request(method, path, payload=None, token=None):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=body, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def json_body(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return raw


# 第一个管理员。已有管理员时接口返回 400（本地化的拒绝文案），此时靠登录验证是否已是我们建过的账号。
status, raw = request("POST", "/api/account/register", {
    "username": os.environ["WONTON_OWNER_NAME"],
    "email": os.environ["WONTON_OWNER_EMAIL"],
    "password": os.environ["WONTON_SECRET_OWNER_PASSWORD"],
})
if status == 200:
    print("已注册管理员", os.environ["WONTON_OWNER_NAME"])
else:
    print("注册未新建账号（HTTP %d），用登录验证" % status)

status, raw = request("POST", "/api/account/login", {
    "username": os.environ["WONTON_OWNER_NAME"],
    "password": os.environ["WONTON_SECRET_OWNER_PASSWORD"],
})
if status != 200:
    sys.exit(f"注册和登录都失败（HTTP {status}）：{raw[:200]}")
print("管理员账号可用")
token = json_body(raw)["token"]

# GET /api/settings 返回的 OIDC Secret 是打码的，Kavita 在写入时按长度还原。
status, raw = request("GET", "/api/settings", token=token)
if status != 200:
    sys.exit(f"读取服务器设置失败（HTTP {status}）：{raw[:200]}")
settings = json_body(raw)

if settings["oidcConfig"]["autoLogin"]:
    print("AutoLogin 已开启")
else:
    settings["oidcConfig"]["autoLogin"] = True
    status, raw = request("POST", "/api/settings", settings, token=token)
    if status != 200:
        sys.exit(f"写入服务器设置失败（HTTP {status}）：{raw[:200]}")
    print("AutoLogin 已开启")
