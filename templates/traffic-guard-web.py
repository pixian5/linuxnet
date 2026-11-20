#!/usr/bin/env python3
import base64
import binascii
import hashlib
import html
import hmac
import os
import subprocess
import tempfile
import threading
from datetime import datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

CONFIG_FILE = "/etc/default/traffic-guard"
BOOT_ID_FILE = "/proc/sys/kernel/random/boot_id"
DEFAULTS = {
    "IFACE": "eth0",
    "LIMIT_BYTES": str(1024 * 1024 * 1024),
    "ACTION": "poweroff",
    "WARN_PERCENT": "80",
    "HARD_LIMIT_PERCENT": "150",
    "STATE_FILE": "/var/lib/traffic-guard/eth0.baseline",
    "WEB_TOKEN_FILE": "/etc/traffic-guard/web-token",
}
# 写回配置时保持这个顺序，其余未知键原样追加，避免抹掉管理员手工加的变量
CONFIG_KEY_ORDER = [
    "IFACE",
    "LIMIT_BYTES",
    "ACTION",
    "WARN_PERCENT",
    "HARD_LIMIT_PERCENT",
    "STATE_FILE",
    "WEB_TOKEN_FILE",
]
MAX_BODY_BYTES = 16 * 1024
MAX_WORKERS = 32
SOCKET_TIMEOUT_SECONDS = 5
MAX_LIMIT_MIB = (2**63 - 1) // (1024 * 1024)


class ConfigError(ValueError):
    pass


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
    lines = []
    for key in CONFIG_KEY_ORDER:
        if key in data:
            lines.append(f"{key}={data[key]}")
    # 保留安装脚本或管理员写入的其它键，避免保存阈值时静默丢失
    for key in sorted(data):
        if key not in CONFIG_KEY_ORDER:
            lines.append(f"{key}={data[key]}")
    directory = os.path.dirname(path) or "."
    fd, temp_path = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)
    except Exception:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        raise


def read_state(path):
    """读取流量守卫状态文件。

    新格式为 KEY=VALUE 多行（PERIOD/BOOT_ID/TOTAL_BYTES/LAST_COUNTER/WARNED/ALERTED/SHUTDOWN_DONE），
    旧格式是单行整数（只记录内核计数器基线）。两种格式都兼容，无法解析的字段保持 None。
    """
    state = {
        "period": "",
        "boot_id": "",
        "total": None,
        "last_counter": None,
        "warned": False,
        "alerted": False,
        "shutdown_done": 0,
    }
    try:
        with open(path, "r", encoding="utf-8") as fh:
            content = fh.read()
    except OSError:
        return state
    text = content.strip()
    if not text:
        return state
    if "=" not in text:
        try:
            state["last_counter"] = int(text)
        except ValueError:
            return state
        return state
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key == "PERIOD":
            state["period"] = value
        elif key == "BOOT_ID":
            state["boot_id"] = value
        elif key in ("TOTAL_BYTES", "LAST_COUNTER"):
            try:
                state["total" if key == "TOTAL_BYTES" else "last_counter"] = int(value)
            except ValueError:
                continue
        elif key == "WARNED":
            state["warned"] = value == "1"
        elif key == "ALERTED":
            state["alerted"] = value == "1"
        elif key == "SHUTDOWN_DONE":
            try:
                state["shutdown_done"] = int(value)
            except ValueError:
                continue
    return state


def read_int(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return None


def reset_shutdown_marker(path):
    """清除本周期“已自动关机”标记，让人工处理完后恢复自动关机保护。

    只复位 ALERTED 与 SHUTDOWN_DONE：预警已经发过就不再重复打扰，
    但下一次自动关机必须重新发一封关机邮件。
    状态文件不存在或无法解析时返回 False，由调用方提示。
    """
    state = read_state(path)
    if state["last_counter"] is None:
        return False
    period = state["period"] or datetime.now().strftime("%Y-%m")
    boot_id = state["boot_id"] or ""
    total = state["total"] if state["total"] is not None else 0
    warned = 1 if state["warned"] else 0
    lines = [
        f"PERIOD={period}",
        f"BOOT_ID={boot_id}",
        f"TOTAL_BYTES={total}",
        f"LAST_COUNTER={state['last_counter']}",
        f"WARNED={warned}",
        "ALERTED=0",
        "SHUTDOWN_DONE=0",
    ]
    directory = os.path.dirname(path) or "."
    fd, temp_path = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)
    except Exception:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        raise
    return True


def run_command(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=False, timeout=3)
    except subprocess.TimeoutExpired:
        return 124, "command timed out"
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
    try:
        limit = int(config["LIMIT_BYTES"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ConfigError("LIMIT_BYTES 配置无效") from exc
    if limit <= 0 or limit > MAX_LIMIT_MIB * 1024 * 1024:
        raise ConfigError("LIMIT_BYTES 超出有效范围")
    try:
        warn_percent = int(config.get("WARN_PERCENT", 80))
    except (TypeError, ValueError):
        warn_percent = 0
    if warn_percent < 0 or warn_percent >= 100:
        warn_percent = 0
    state_file = config["STATE_FILE"]
    tx_file = f"/sys/class/net/{iface}/statistics/tx_bytes"
    current = read_int(tx_file)
    state = read_state(state_file)
    now = datetime.now()
    period = now.strftime("%Y-%m")
    new_period = (state["period"] or (period if state["last_counter"] is not None else "")) != period
    used = None
    if current is not None:
        if new_period:
            used = 0
        else:
            try:
                with open(BOOT_ID_FILE, encoding="ascii") as fh:
                    boot_id = fh.read().strip()
            except OSError:
                boot_id = ""
            if boot_id:
                # 与检查脚本一致：换启动全计，无旧启动标识时沿用差值策略
                last = state["last_counter"]
                if last is not None and state["boot_id"] and boot_id != state["boot_id"]:
                    last = 0
                used = (state["total"] or 0) + (max(current - last, 0) if last is not None else 0)
    remaining = None if used is None else max(limit - used, 0)
    percent = None if used is None or limit <= 0 else min(used / limit * 100, 100)
    # 硬顶百分比只在大于 100 的整数时有意义，否则视为关闭
    try:
        hard_percent = int(config.get("HARD_LIMIT_PERCENT", 150))
    except (TypeError, ValueError):
        hard_percent = 0
    if hard_percent <= 100:
        hard_percent = 0
    _, timer_active = run_command(["systemctl", "is-active", "traffic-guard.timer"])
    _, service_active = run_command(["systemctl", "is-active", "traffic-guard.service"])
    _, service_result = run_command(["systemctl", "show", "traffic-guard.service", "-p", "Result", "--value"])
    _, timer_substate = run_command(["systemctl", "show", "traffic-guard.timer", "-p", "SubState", "--value"])
    return {
        "now": now.strftime("%Y-%m-%d %H:%M:%S"),
        "iface": iface,
        "limit": limit,
        "limit_mib": max(limit // (1024 * 1024), 1),
        "action": config["ACTION"],
        "warn_percent": warn_percent,
        "hard_limit_percent": hard_percent,
        "period": period,
        "warned": state["warned"] and not new_period,
        "shutdown_done": 0 if new_period else state["shutdown_done"],
        "state_file": state_file,
        "current": current,
        "last_counter": state["last_counter"],
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
    server_version = "TrafficGuard/1.0"

    def setup(self):
        super().setup()
        self.request.settimeout(SOCKET_TIMEOUT_SECONDS)

    def token(self):
        config = read_env_file(CONFIG_FILE)
        try:
            with open(config["WEB_TOKEN_FILE"], "r", encoding="utf-8") as fh:
                return fh.read().strip()
        except (OSError, KeyError):
            return ""

    def authorized(self):
        expected = self.token()
        if not expected:
            return False
        header = self.headers.get("Authorization", "")
        supplied = ""
        if header.startswith("Bearer "):
            supplied = header[7:].strip()
        elif header.startswith("Basic "):
            try:
                decoded = base64.b64decode(header[6:], validate=True).decode("utf-8")
                username, supplied = decoded.split(":", 1)
                if username != "admin":
                    supplied = ""
            except (ValueError, UnicodeError, binascii.Error):
                supplied = ""
        return hmac.compare_digest(supplied, expected)

    def require_auth(self):
        if self.authorized():
            return True
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self.send_header("WWW-Authenticate", 'Basic realm="traffic-guard"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def send_text_error(self, status, message):
        payload = (
            "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\">"
            f"<title>{status.value} {html.escape(status.phrase)}</title>"
            f"<h1>{status.value} {html.escape(status.phrase)}</h1>"
            f"<p>{html.escape(message)}</p></html>"
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def csrf_value(self, action="update-threshold"):
        # 每个写操作单独的 CSRF 令牌，避免拿“改阈值”的令牌去提交复位
        return hmac.new(self.token().encode(), action.encode(), hashlib.sha256).hexdigest()

    def render_page(self, message="", error=""):
        try:
            data = collect_state(message=message, error=error)
        except ConfigError as exc:
            self.send_text_error(HTTPStatus.INTERNAL_SERVER_ERROR, str(exc))
            return
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
button.warn {{ background:#f59e0b; color:#3b2003; }}
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
    <div class=\"label\">超限关机保护</div>
    <div class=\"sub\" style=\"margin:0 0 10px;\">本周期已自动关机 {data['shutdown_done']} 次。自动关机一次后不再自动关机，方便你登录处理；累计达到硬顶 {html.escape(str(data['hard_limit_percent']))}%（0 表示关闭）时再强制关机一次。</div>
    <form method=\"post\" action=\"/reset-shutdown\">
      <input type=\"hidden\" name=\"csrf\" value=\"{self.csrf_value('reset-shutdown')}\">
      <button type=\"submit\" class=\"warn\">人工复位（恢复自动关机）</button>
    </form>
    <div class=\"sub\">复位只清除“已自动关机”标记，不清空本月已用流量。请先确认已处理超量原因。</div>
  </div>
  <div class=\"card\" style=\"margin-bottom:18px;\">
    <div class=\"label\">修改阈值</div>
    <form method=\"post\" action=\"/update-threshold\">
      <label>
        <div class=\"sub\" style=\"margin:0 0 8px;\">阈值（MiB）</div>
        <input type=\"number\" name=\"limit_mib\" min=\"1\" max=\"{MAX_LIMIT_MIB}\" step=\"1\" value=\"{data['limit_mib']}\" required>
      </label>
      <input type=\"hidden\" name=\"csrf\" value=\"{self.csrf_value()}\">
      <button type=\"submit\">保存并立即检查</button>
    </form>
    <div class=\"sub\">当前阈值 {format_bytes(data['limit'])}。如果当前已用出站已经超过新阈值，服务器会立即关机。</div>
  </div>
  <div class=\"grid\">
    <div class=\"card\"><div class=\"label\">网卡</div><div class=\"value\">{html.escape(data['iface'])}</div><div class=\"sub\">更新时间 {html.escape(data['now'])}</div></div>
    <div class=\"card\"><div class=\"label\">阈值</div><div class=\"value\">{format_bytes(data['limit'])}</div><div class=\"sub\">原始值 {data['limit']} bytes</div></div>
    <div class=\"card\"><div class=\"label\">已用出站</div><div class=\"value\">{format_bytes(data['used'])}</div><div class=\"sub\">统计周期 {html.escape(data['period'])}</div></div>
    <div class=\"card\"><div class=\"label\">剩余流量</div><div class=\"value\">{format_bytes(data['remaining'])}</div><div class=\"sub\">当前 tx_bytes {format_bytes(data['current'])}</div></div>
  </div>
  <div class=\"card\" style=\"margin-bottom:18px;\">
    <div class=\"label\">使用进度</div>
    <div class=\"value\">{percent:.2f}%</div>
    <div class=\"sub\">预警线 {data['warn_percent']}%（已发送 {data['warned']}） | 状态文件: {html.escape(data['state_file'])} | 上次计数器={data['last_counter'] if data['last_counter'] is not None else 'N/A'}</div>
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
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if not self.require_auth():
            return
        parsed = urlparse(self.path)
        if parsed.path not in ("/", "/index.html"):
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        params = parse_qs(parsed.query)
        self.render_page(message=params.get("message", [""])[0], error=params.get("error", [""])[0])

    def do_POST(self):
        if self.path not in ("/update-threshold", "/reset-shutdown"):
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        if not self.require_auth():
            return
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/x-www-form-urlencoded":
            self.send_error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE)
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_text_error(HTTPStatus.BAD_REQUEST, "Content-Length 无效")
            return
        if content_length < 0 or content_length > MAX_BODY_BYTES:
            self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
            return
        payload = self.rfile.read(content_length).decode("utf-8", errors="replace")
        form = parse_qs(payload)
        if self.path == "/reset-shutdown":
            self.handle_reset_shutdown(form)
        else:
            self.handle_update_threshold(form)

    def handle_reset_shutdown(self, form):
        if not hmac.compare_digest(form.get("csrf", [""])[0], self.csrf_value("reset-shutdown")):
            self.redirect(error="CSRF 校验失败")
            return
        config = read_env_file(CONFIG_FILE)
        try:
            ok = reset_shutdown_marker(config["STATE_FILE"])
        except OSError as exc:
            self.redirect(error=f"复位失败：{exc}")
            return
        if not ok:
            self.redirect(error="状态文件不存在或无法解析，未做任何修改")
            return
        self.redirect(message="已清除“本周期已自动关机”标记，自动关机保护已恢复")

    def handle_update_threshold(self, form):
        raw_limit = form.get("limit_mib", [""])[0].strip()
        if not raw_limit:
            self.redirect(error="阈值不能为空")
            return
        try:
            limit_mib = int(raw_limit)
        except ValueError:
            self.redirect(error="阈值必须是整数 MiB")
            return
        if limit_mib <= 0 or limit_mib > MAX_LIMIT_MIB:
            self.redirect(error=f"阈值必须在 1 到 {MAX_LIMIT_MIB} MiB 之间")
            return
        if not hmac.compare_digest(form.get("csrf", [""])[0], self.csrf_value()):
            self.redirect(error="CSRF 校验失败")
            return
        config = read_env_file(CONFIG_FILE)
        config["LIMIT_BYTES"] = str(limit_mib * 1024 * 1024)
        try:
            write_env_file(CONFIG_FILE, config)
        except OSError as exc:
            self.redirect(error=f"保存配置失败：{exc}")
            return
        returncode, output = run_command(["systemctl", "start", "traffic-guard.service"])
        if returncode != 0:
            self.redirect(error=f"阈值已保存，但立即检查失败：{first_line(output) or returncode}")
            return
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


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, server_address, request_handler_class):
        self._worker_slots = threading.BoundedSemaphore(MAX_WORKERS)
        super().__init__(server_address, request_handler_class)

    def process_request(self, request, client_address):
        self._worker_slots.acquire()
        try:
            super().process_request(request, client_address)
        except Exception:
            self._worker_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._worker_slots.release()


if __name__ == "__main__":
    host = os.getenv("HOST", "127.0.0.1")
    port = int(os.getenv("PORT", "5101"))
    BoundedThreadingHTTPServer((host, port), Handler).serve_forever()
