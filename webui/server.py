# -*- coding: utf-8 -*-
"""
webui/server.py — reg-factory 本地 Web 面板后端(FastAPI)。

只绑 127.0.0.1(含 .env 密钥编辑，绝不监听公网)。职责：
  - 提供脚本 schema / .env 配置 给前端渲染表单
  - 把表单提交拼成命令行，subprocess 后台跑，SSE 实时推 stdout
  - 探测 BitBrowser / Clash 在线状态 + 当前节点

启动：  python -m uvicorn webui.server:app --port 8799   (或用 start.bat)
"""
import asyncio
import os
import sys
import time
import urllib.request

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

# 项目根 = webui 的上一级
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBUI = os.path.join(ROOT, "webui")
ENV_PATH = os.path.join(ROOT, ".env")
ENV_EXAMPLE = os.path.join(ROOT, ".env.example")

sys.path.insert(0, WEBUI)
sys.path.insert(0, ROOT)
import scripts as schema  # noqa: E402

app = FastAPI(title="reg-factory WebUI")

# 运行中的任务：run_id -> {proc, lines:[], done:bool, script, cmd, started}
RUNS = {}
_run_seq = [0]


# ============================================================ 配置/状态读取
def _read_config_val(key, default=""):
    """从环境/.env 读一个值(用于探测 Clash/BitBrowser 地址)。"""
    val = os.environ.get(key)
    if val:
        return val
    try:
        for line in open(ENV_PATH, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                if k.strip() == key:
                    return v.strip().strip('"').strip("'") or default
    except Exception:
        pass
    return default


def _http_alive(url, timeout=3):
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status < 500
    except urllib.error.HTTPError:
        return True  # 4xx = 服务活着(拒绝裸请求)
    except Exception:
        return False


# ============================================================ .env 读写(保留注释/顺序)
def _parse_env_file(path):
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, _, v = s.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def _write_env_file(path, updates):
    """把 updates(dict) 写回 .env：已存在的行原地改值(保留注释/顺序)，新 key 追加到末尾。"""
    lines = []
    seen = set()
    if os.path.isfile(path):
        lines = open(path, encoding="utf-8").read().splitlines()
    out = []
    for line in lines:
        s = line.strip()
        if s and not s.startswith("#") and "=" in s:
            k = s.partition("=")[0].strip()
            if k in updates:
                out.append(f"{k}={updates[k]}")
                seen.add(k)
                continue
        out.append(line)
    # 新增的 key
    extra = [k for k in updates if k not in seen]
    if extra:
        out.append("")
        out.append("# ---- 由 WebUI 配置页新增 ----")
        for k in extra:
            out.append(f"{k}={updates[k]}")
    # 原子写
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, path)


# ============================================================ API
@app.get("/api/scripts")
def api_scripts():
    return {"scripts": schema.SCRIPTS}


@app.get("/api/status")
def api_status():
    bb = _read_config_val("BITBROWSER_API", "http://127.0.0.1:54345")
    clash = _read_config_val("CLASH_API", "http://127.0.0.1:9097")
    node = None
    try:
        from common import proxy_switch as ps
        node = ps.current_node()
    except Exception:
        node = None
    return {
        "bitbrowser": _http_alive(bb),
        "clash": _http_alive(clash),
        "node": node,
        "running": sum(1 for r in RUNS.values() if not r["done"]),
    }


@app.get("/api/env")
def api_env_get():
    # 若无 .env 用模板兜底
    cur = _parse_env_file(ENV_PATH)
    if not cur and os.path.isfile(ENV_EXAMPLE):
        cur = _parse_env_file(ENV_EXAMPLE)
    groups = []
    for g in schema.ENV_SCHEMA:
        items = []
        for it in g["items"]:
            items.append({
                "key": it["key"],
                "value": cur.get(it["key"], ""),
                "required": it.get("required", False),
                "secret": it.get("secret", False),
                "help": it.get("help", ""),
                "default": it.get("default", ""),
            })
        groups.append({"group": g["group"], "items": items})
    return {"groups": groups, "env_exists": os.path.isfile(ENV_PATH)}


@app.post("/api/env")
async def api_env_set(request: Request):
    data = await request.json()
    updates = data.get("env") or {}
    # 只接受 schema 里声明的 key，避免写入垃圾
    allowed = set(schema.env_keys())
    updates = {k: ("" if v is None else str(v)) for k, v in updates.items() if k in allowed}
    if not os.path.isfile(ENV_PATH) and os.path.isfile(ENV_EXAMPLE):
        # 首次保存：以模板为底
        import shutil
        shutil.copy(ENV_EXAMPLE, ENV_PATH)
    _write_env_file(ENV_PATH, updates)
    return {"ok": True, "saved": len(updates)}


def _build_cmd(script, args):
    """把前端提交的 args(dict) 按 schema 拼成命令行 list。"""
    cmd = [sys.executable, "-u", os.path.join(ROOT, script["file"])]
    positional = []
    by_flag = {a["flag"]: a for a in script["args"]}
    for flag, spec in by_flag.items():
        if flag not in args:
            continue
        val = args[flag]
        typ = spec["type"]
        if spec.get("positional"):
            if val not in (None, "", []):
                positional.append(str(val))
            continue
        if typ == "bool":
            if val:
                cmd.append(flag)
        elif typ == "multi":
            if val:
                cmd.append(flag)
                cmd.extend(str(v) for v in val)
        else:
            if val not in (None, "", []):
                cmd.append(flag)
                cmd.append(str(val))
    cmd.extend(positional)
    return cmd


def _child_env():
    """子进程环境：注入 PYTHONUNBUFFERED + 代理(对齐 run_full_flow.build_child_env)。
    proxy 走 .env 的 CLASH_PROXY；localhost API 直连(NO_PROXY)。"""
    env = dict(os.environ)
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    proxy = _read_config_val("CLASH_PROXY", "http://127.0.0.1:7897")
    if proxy:
        env["HTTP_PROXY"] = env["HTTPS_PROXY"] = proxy
        env["http_proxy"] = env["https_proxy"] = proxy
        env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost,::1"
    return env


@app.post("/api/run")
async def api_run(request: Request):
    data = await request.json()
    sid = data.get("script")
    args = data.get("args") or {}
    script = schema.script_by_id(sid)
    if not script:
        return JSONResponse({"error": f"未知脚本: {sid}"}, status_code=400)
    cmd = _build_cmd(script, args)
    proc = await asyncio.create_subprocess_exec(
        *cmd, cwd=ROOT, env=_child_env(),
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    _run_seq[0] += 1
    run_id = f"r{_run_seq[0]}"
    rec = {"proc": proc, "lines": [], "done": False, "script": sid,
           "cmd": " ".join(cmd), "started": time.strftime("%H:%M:%S")}
    RUNS[run_id] = rec

    async def _pump():
        try:
            async for raw in proc.stdout:
                rec["lines"].append(raw.decode("utf-8", "replace").rstrip("\n"))
                if len(rec["lines"]) > 5000:
                    rec["lines"] = rec["lines"][-4000:]
        except Exception as e:
            rec["lines"].append(f"[webui] 读取输出异常: {e}")
        finally:
            await proc.wait()
            rec["done"] = True
            rec["lines"].append(f"[webui] 进程结束 exit={proc.returncode}")

    asyncio.create_task(_pump())
    return {"run_id": run_id, "cmd": rec["cmd"]}


@app.get("/api/logs/{run_id}")
async def api_logs(run_id: str):
    rec = RUNS.get(run_id)
    if not rec:
        return JSONResponse({"error": "无此任务"}, status_code=404)

    async def _stream():
        idx = 0
        while True:
            lines = rec["lines"]
            while idx < len(lines):
                yield f"data: {lines[idx]}\n\n"
                idx += 1
            if rec["done"] and idx >= len(rec["lines"]):
                yield "event: done\ndata: end\n\n"
                break
            await asyncio.sleep(0.4)

    return StreamingResponse(_stream(), media_type="text/event-stream")


@app.post("/api/stop/{run_id}")
async def api_stop(run_id: str):
    rec = RUNS.get(run_id)
    if not rec:
        return JSONResponse({"error": "无此任务"}, status_code=404)
    if not rec["done"]:
        try:
            rec["proc"].terminate()
        except Exception:
            pass
    return {"ok": True}


@app.get("/", response_class=HTMLResponse)
def index():
    return open(os.path.join(WEBUI, "static", "index.html"), encoding="utf-8").read()


app.mount("/static", StaticFiles(directory=os.path.join(WEBUI, "static")), name="static")
