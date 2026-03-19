#!/usr/bin/env python3
import html
import os
import subprocess
from datetime import datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

CONFIG_FILE = "/etc/default/traffic-guard"
DEFAULTS = {
    "IFACE": "eth0",
    "LIMIT_BYTES": str(1024 * 1024 * 1024),
    "ACTION": "poweroff",
    "STATE_FILE": "/var/lib/traffic-guard/eth0.baseline",
}


def read_env_file(path):
    data = DEFAULTS.copy()
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                data[key.strip()] = value.strip()
    return data


def write_env_file(path, data):
    lines = [
        f"IFACE={data['IFACE']}",
        f"LIMIT_BYTES={data['LIMIT_BYTES']}",
        f"ACTION={data['ACTION']}",
        f"STATE_FILE={data['STATE_FILE']}",
    ]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def read_int(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return int(fh.read().strip())
    except FileNotFoundError:
        return None


def run_command(args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    return result.returncode, result.stdout.strip() or result.stderr.strip()


def first_line(text):
    return text.splitlines()[0].strip() if text else ""


def format_bytes(value):
    if value is None:
        return "N/A"
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{value} B"


def collect_state(message="", error=""):
    config = read_env_file(CONFIG_FILE)
    iface = config["IFACE"]
    limit = int(config["LIMIT_BYTES"])
    state_file = config["STATE_FILE"]
    tx_file = f"/sys/class/net/{iface}/statistics/tx_bytes"
    current = read_int(tx_file)
    baseline = read_int(state_file)
    used = None if current is None or baseline is None else max(current - baseline, 0)
    remaining = None if used is None else max(limit - used, 0)
    percent = None if used is None or limit <= 0 else min(used / limit * 100, 100)
    _, timer_active = run_command(["systemctl", "is-active", "traffic-guard.timer"])
    _, service_active = run_command(["systemctl", "is-active", "traffic-guard.service"])
    _, service_result = run_command(["systemctl", "show", "traffic-guard.service", "-p", "Result", "--value"])
    _, timer_substate = run_command(["systemctl", "show", "traffic-guard.timer", "-p", "SubState", "--value"])
    return {
        "now": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "iface": iface,
        "limit": limit,
        "limit_mib": max(limit // (1024 * 1024), 1),
        "action": config["ACTION"],
        "state_file": state_file,
        "current": current,
        "baseline": baseline,
        "used": used,
        "remaining": remaining,
        "percent": percent,
        "timer_active": first_line(timer_active) or "unknown",
        "service_active": first_line(service_active) or "unknown",
        "service_result": first_line(service_result) or "unknown",
        "timer_substate": first_line(timer_substate) or "unknown",
        "message": message,
        "error": error,
    }


class Handler(BaseHTTPRequestHandler):
    def render_page(self, message="", error=""):
        data = collect_state(message=message, error=error)
        percent = 0 if data["percent"] is None else data["percent"]
        fill_color = "#22c55e"
        if percent >= 90:
            fill_color = "#ef4444"
        elif percent >= 70:
            fill_color = "#f59e0b"
        notice = ""
        if data["message"]:
            notice = f'<div class="notice ok">{html.escape(data["message"])}</div>'
        elif data["error"]:
            notice = f'<div class="notice err">{html.escape(data["error"])}</div>'
        body = f"""<!doctype html>
<html lang=\"zh-CN\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<meta http-equiv=\"refresh\" content=\"10\">
<title>流量守卫</title>
<style>
:root {{ --text:#e5e7eb; --muted:#94a3b8; }}
* {{ box-sizing:border-box; }}
body {{ margin:0; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:linear-gradient(160deg,#020617,#0f172a 50%,#111827); color:var(--text); }}
.main {{ max-width:1100px; margin:0 auto; padding:24px; }}
.hero {{ display:flex; justify-content:space-between; gap:16px; align-items:flex-end; margin-bottom:20px; }}
.hero h1 {{ margin:0; font-size:32px; }}
.hero p {{ margin:6px 0 0; color:var(--muted); }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:14px; margin-bottom:18px; }}
.card {{ background:rgba(17,24,39,.78); border:1px solid rgba(148,163,184,.16); border-radius:18px; padding:18px; box-shadow:0 12px 30px rgba(0,0,0,.28); }}
.label {{ color:var(--muted); font-size:13px; margin-bottom:10px; }}
.value {{ font-size:28px; font-weight:700; line-height:1.15; word-break:break-word; }}
.sub {{ margin-top:8px; color:var(--muted); font-size:13px; }}
.bar {{ height:14px; border-radius:999px; background:#0b1220; overflow:hidden; border:1px solid rgba(148,163,184,.12); margin-top:14px; }}
.fill {{ height:100%; width:{percent:.2f}%; background:{fill_color}; }}
.status {{ display:inline-block; padding:6px 10px; border-radius:999px; font-size:12px; background:rgba(34,197,94,.16); color:#86efac; }}
.notice {{ margin:0 0 18px; padding:14px 16px; border-radius:14px; font-size:14px; }}
.ok {{ background:rgba(34,197,94,.14); color:#bbf7d0; border:1px solid rgba(34,197,94,.3); }}
.err {{ background:rgba(239,68,68,.14); color:#fecaca; border:1px solid rgba(239,68,68,.3); }}
form {{ display:flex; gap:12px; flex-wrap:wrap; align-items:flex-end; }}
input[type=number] {{ width:180px; padding:12px 14px; border-radius:12px; border:1px solid rgba(148,163,184,.2); background:#0b1220; color:var(--text); font-size:16px; }}
button {{ padding:12px 18px; border:0; border-radius:12px; background:#22c55e; color:#052e16; font-weight:700; cursor:pointer; }}
button:hover {{ filter:brightness(1.08); }}
</style>
</head>
<body>
<div class=\"main\">
  <div class=\"hero\">
    <div>
      <h1>流量守卫</h1>
      <p>每 10 秒自动刷新。达到阈值后会执行 <strong>{html.escape(data['action'])}</strong>。保存阈值后会立刻触发一次检查。</p>
    </div>
    <div class=\"status\">定时器：{html.escape(data['timer_active'])}</div>
  </div>
  {notice}
  <div class=\"card\" style=\"margin-bottom:18px;\">
    <div class=\"label\">修改阈值</div>
    <form method=\"post\" action=\"/update-threshold\">
      <label>
        <div class=\"sub\" style=\"margin:0 0 8px;\">阈值（MiB）</div>
        <input type=\"number\" name=\"limit_mib\" min=\"1\" step=\"1\" value=\"{data['limit_mib']}\" required>
      </label>
      <button type=\"submit\">保存并立即检查</button>
    </form>
    <div class=\"sub\">当前阈值 {format_bytes(data['limit'])}。如果当前已用出站已经超过新阈值，服务器会立即关机。</div>
  </div>
  <div class=\"grid\">
    <div class=\"card\"><div class=\"label\">网卡</div><div class=\"value\">{html.escape(data['iface'])}</div><div class=\"sub\">更新时间 {html.escape(data['now'])}</div></div>
    <div class=\"card\"><div class=\"label\">阈值</div><div class=\"value\">{format_bytes(data['limit'])}</div><div class=\"sub\">原始值 {data['limit']} bytes</div></div>
    <div class=\"card\"><div class=\"label\">已用出站</div><div class=\"value\">{format_bytes(data['used'])}</div><div class=\"sub\">从基线开始累计</div></div>
    <div class=\"card\"><div class=\"label\">剩余流量</div><div class=\"value\">{format_bytes(data['remaining'])}</div><div class=\"sub\">当前 tx_bytes {format_bytes(data['current'])}</div></div>
  </div>
  <div class=\"card\" style=\"margin-bottom:18px;\">
    <div class=\"label\">使用进度</div>
    <div class=\"value\">{percent:.2f}%</div>
    <div class=\"sub\">基线文件: {html.escape(data['state_file'])} | baseline={data['baseline'] if data['baseline'] is not None else 'N/A'}</div>
    <div class=\"bar\"><div class=\"fill\"></div></div>
  </div>
  <div class=\"grid\">
    <div class=\"card\">
      <div class=\"label\">检查服务状态</div>
      <div class=\"value\">{html.escape(data['service_active'])}</div>
      <div class=\"sub\">最近执行结果：{html.escape(data['service_result'])}</div>
    </div>
    <div class=\"card\">
      <div class=\"label\">定时器摘要</div>
      <div class=\"value\">{html.escape(data['timer_active'])}</div>
      <div class=\"sub\">子状态：{html.escape(data['timer_substate'])}</div>
    </div>
  </div>
</div>
</body>
</html>
"""
        payload = body.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path not in ("/", "/index.html"):
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        params = parse_qs(parsed.query)
        self.render_page(message=params.get("message", [""])[0], error=params.get("error", [""])[0])

    def do_POST(self):
        if self.path != "/update-threshold":
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        content_length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(content_length).decode("utf-8", errors="replace")
        form = parse_qs(payload)
        raw_limit = form.get("limit_mib", [""])[0].strip()
        if not raw_limit:
            self.redirect(error="阈值不能为空")
            return
        try:
            limit_mib = int(raw_limit)
        except ValueError:
            self.redirect(error="阈值必须是整数 MiB")
            return
        if limit_mib <= 0:
            self.redirect(error="阈值必须大于 0")
            return
        config = read_env_file(CONFIG_FILE)
        config["LIMIT_BYTES"] = str(limit_mib * 1024 * 1024)
        write_env_file(CONFIG_FILE, config)
        run_command(["systemctl", "start", "traffic-guard.service"])
        self.redirect(message=f"阈值已更新为 {limit_mib} MiB，并已立即执行一次检查")

    def redirect(self, message="", error=""):
        params = {}
        if message:
            params["message"] = message
        if error:
            params["error"] = error
        location = "/"
        if params:
            location += "?" + urlencode(params)
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", location)
        self.end_headers()

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "5101"))
    ThreadingHTTPServer((host, port), Handler).serve_forever()
