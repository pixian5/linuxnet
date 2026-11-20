import base64
import hashlib
import hmac
import http.client
import importlib.util
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "templates" / "traffic-guard-web.py"
SPEC = importlib.util.spec_from_file_location("traffic_guard_web", MODULE_PATH)
web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web)


class TrafficGuardWebTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        root = Path(self.temp_dir.name)
        self.config_path = root / "traffic-guard"
        self.token_path = root / "web-token"
        self.token = "test-secret-token"
        self.token_path.write_text(self.token + "\n", encoding="utf-8")
        self.config_path.write_text(
            "\n".join(
                [
                    "IFACE=definitely-not-a-real-interface",
                    "LIMIT_BYTES=1073741824",
                    "ACTION=poweroff",
                    f"STATE_FILE={root / 'baseline'}",
                    f"WEB_TOKEN_FILE={self.token_path}",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        self.original_config = web.CONFIG_FILE
        web.CONFIG_FILE = str(self.config_path)
        self.command_patch = mock.patch.object(web, "run_command", return_value=(0, "active"))
        self.command = self.command_patch.start()
        self.server = web.BoundedThreadingHTTPServer(("127.0.0.1", 0), web.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.command_patch.stop()
        web.CONFIG_FILE = self.original_config
        self.temp_dir.cleanup()

    def auth_header(self, username="admin", token=None):
        credential = f"{username}:{token or self.token}".encode()
        return "Basic " + base64.b64encode(credential).decode()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        payload = response.read()
        result = response.status, dict(response.getheaders()), payload
        connection.close()
        return result

    def test_authentication_is_required_and_username_is_checked(self):
        self.assertEqual(self.request("GET", "/")[0], 401)
        headers = {"Authorization": self.auth_header(username="someone")}
        self.assertEqual(self.request("GET", "/", headers=headers)[0], 401)
        headers = {"Authorization": self.auth_header()}
        self.assertEqual(self.request("GET", "/", headers=headers)[0], 200)

    def test_valid_csrf_updates_config_and_starts_check(self):
        csrf = hmac.new(self.token.encode(), b"update-threshold", hashlib.sha256).hexdigest()
        body = f"limit_mib=64&csrf={csrf}".encode()
        headers = {
            "Authorization": self.auth_header(),
            "Content-Type": "application/x-www-form-urlencoded",
        }
        status, response_headers, _ = self.request("POST", "/update-threshold", body, headers)
        self.assertEqual(status, 303)
        self.assertIn("message=", response_headers["Location"])
        config = web.read_env_file(self.config_path)
        self.assertEqual(config["LIMIT_BYTES"], str(64 * 1024 * 1024))
        self.assertEqual(config["WEB_TOKEN_FILE"], str(self.token_path))
        self.command.assert_any_call(["systemctl", "start", "traffic-guard.service"])

    def test_invalid_csrf_does_not_change_config(self):
        body = b"limit_mib=1&csrf=invalid"
        headers = {
            "Authorization": self.auth_header(),
            "Content-Type": "application/x-www-form-urlencoded",
        }
        status, response_headers, _ = self.request("POST", "/update-threshold", body, headers)
        self.assertEqual(status, 303)
        self.assertIn("error=", response_headers["Location"])
        self.assertEqual(web.read_env_file(self.config_path)["LIMIT_BYTES"], "1073741824")

    def test_failed_immediate_check_is_reported_as_error(self):
        self.command.return_value = (1, "service failed")
        csrf = hmac.new(self.token.encode(), b"update-threshold", hashlib.sha256).hexdigest()
        body = f"limit_mib=32&csrf={csrf}".encode()
        headers = {
            "Authorization": self.auth_header(),
            "Content-Type": "application/x-www-form-urlencoded",
        }
        status, response_headers, _ = self.request("POST", "/update-threshold", body, headers)
        self.assertEqual(status, 303)
        self.assertIn("error=", response_headers["Location"])

    def test_limit_above_shell_integer_range_is_rejected(self):
        csrf = hmac.new(self.token.encode(), b"update-threshold", hashlib.sha256).hexdigest()
        body = f"limit_mib={web.MAX_LIMIT_MIB + 1}&csrf={csrf}".encode()
        headers = {
            "Authorization": self.auth_header(),
            "Content-Type": "application/x-www-form-urlencoded",
        }
        status, response_headers, _ = self.request("POST", "/update-threshold", body, headers)
        self.assertEqual(status, 303)
        self.assertIn("error=", response_headers["Location"])
        self.assertEqual(web.read_env_file(self.config_path)["LIMIT_BYTES"], "1073741824")

    def test_oversized_and_wrong_content_type_requests_are_rejected(self):
        auth = {"Authorization": self.auth_header()}
        headers = {**auth, "Content-Type": "application/octet-stream"}
        self.assertEqual(self.request("POST", "/update-threshold", b"x", headers)[0], 415)
        headers = {
            **auth,
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": str(web.MAX_BODY_BYTES + 1),
        }
        self.assertEqual(self.request("POST", "/update-threshold", b"", headers)[0], 413)

    def test_invalid_limit_returns_controlled_error(self):
        content = self.config_path.read_text(encoding="utf-8")
        self.config_path.write_text(content.replace("LIMIT_BYTES=1073741824", "LIMIT_BYTES=bad"), encoding="utf-8")
        headers = {"Authorization": self.auth_header()}
        self.assertEqual(self.request("GET", "/", headers=headers)[0], 500)

    def test_write_env_file_keeps_unknown_keys(self):
        self.config_path.write_text(
            "\n".join(
                [
                    "IFACE=eth0",
                    "LIMIT_BYTES=1073741824",
                    "ACTION=poweroff",
                    "WARN_PERCENT=80",
                    f"STATE_FILE={self.temp_dir.name}/baseline",
                    f"WEB_TOKEN_FILE={self.token_path}",
                    "EXTRA_FLAG=keep-me",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        config = web.read_env_file(self.config_path)
        config["LIMIT_BYTES"] = str(128 * 1024 * 1024)
        web.write_env_file(self.config_path, config)
        text = self.config_path.read_text(encoding="utf-8")
        self.assertIn("EXTRA_FLAG=keep-me", text)
        self.assertIn("WARN_PERCENT=80", text)
        self.assertEqual(web.read_env_file(self.config_path)["LIMIT_BYTES"], str(128 * 1024 * 1024))

    def test_live_usage_matches_checker(self):
        root = Path(self.temp_dir.name)
        period = web.datetime.now().strftime("%Y-%m")
        (root / "boot_id").write_text("boot-b\n", encoding="ascii")
        for saved_period, saved_boot, current, expected in [
            (period, "boot-a", 100, 1100),
            (period, "boot-a", 800, 1800),
            (period, "boot-b", 800, 1300),
            (period, "boot-b", 100, 1000),
            (period, "", 800, 1300),
            ("2000-01", "boot-a", 800, 0),
        ]:
            with self.subTest(saved_period=saved_period, saved_boot=saved_boot, current=current):
                (root / "baseline").write_text(
                    f"PERIOD={saved_period}\nBOOT_ID={saved_boot}\nTOTAL_BYTES=1000\nLAST_COUNTER=500\nWARNED=1\n",
                    encoding="ascii",
                )
                with mock.patch.object(web, "read_int", return_value=current), mock.patch.object(
                    web, "BOOT_ID_FILE", root / "boot_id"
                ):
                    snapshot = web.collect_state()
                self.assertEqual(snapshot["used"], expected)
                self.assertEqual(snapshot["period"], period)
                self.assertEqual(snapshot["warned"], saved_period == period)

    def test_state_accumulates_across_counter_reset(self):
        state_path = self.temp_dir.name + "/baseline"
        Path(state_path).write_text(
            "PERIOD=2026-11\nTOTAL_BYTES=1000\nLAST_COUNTER=500\nWARNED=0\nALERTED=0\n",
            encoding="utf-8",
        )
        state = web.read_state(state_path)
        self.assertEqual(state["total"], 1000)
        self.assertEqual(state["last_counter"], 500)
        self.assertFalse(state["warned"])
        Path(state_path).write_text("600\n", encoding="utf-8")
        legacy = web.read_state(state_path)
        self.assertIsNone(legacy["total"])
        self.assertEqual(legacy["last_counter"], 600)

    def test_reset_shutdown_marker_clears_only_shutdown_flags(self):
        state_path = Path(self.temp_dir.name) / "baseline"
        state_path.write_text(
            "PERIOD=2026-11\nBOOT_ID=boot-a\nTOTAL_BYTES=52000000000\nLAST_COUNTER=900\n"
            "WARNED=1\nALERTED=1\nSHUTDOWN_DONE=2\n",
            encoding="utf-8",
        )
        self.assertTrue(web.reset_shutdown_marker(str(state_path)))
        state = web.read_state(str(state_path))
        # 已用流量与预警标记保留，只恢复自动关机
        self.assertEqual(state["total"], 52000000000)
        self.assertEqual(state["last_counter"], 900)
        self.assertTrue(state["warned"])
        self.assertFalse(state["alerted"])
        self.assertEqual(state["shutdown_done"], 0)
        self.assertEqual(oct(state_path.stat().st_mode & 0o777), "0o600")

    def test_reset_shutdown_marker_rejects_missing_state(self):
        self.assertFalse(web.reset_shutdown_marker(str(Path(self.temp_dir.name) / "no-such-file")))

    def test_reset_endpoint_requires_its_own_csrf(self):
        state_path = Path(self.temp_dir.name) / "baseline"
        state_path.write_text(
            f"PERIOD={web.datetime.now().strftime('%Y-%m')}\nBOOT_ID=boot-a\nTOTAL_BYTES=2000000000\n"
            "LAST_COUNTER=900\nWARNED=1\nALERTED=1\nSHUTDOWN_DONE=1\n",
            encoding="utf-8",
        )
        config = self.config_path.read_text(encoding="utf-8")
        self.assertIn(f"STATE_FILE={state_path}", config)
        headers = {
            "Authorization": self.auth_header(),
            "Content-Type": "application/x-www-form-urlencoded",
        }
        # 拿改阈值的令牌去复位必须失败，说明两个写操作各自独立校验
        threshold_csrf = hmac.new(self.token.encode(), b"update-threshold", hashlib.sha256).hexdigest()
        status, response_headers, _ = self.request("POST", "/reset-shutdown", f"csrf={threshold_csrf}".encode(), headers)
        self.assertEqual(status, 303)
        self.assertIn("error=", response_headers["Location"])
        self.assertEqual(web.read_state(str(state_path))["shutdown_done"], 1)

        reset_csrf = hmac.new(self.token.encode(), b"reset-shutdown", hashlib.sha256).hexdigest()
        status, response_headers, _ = self.request("POST", "/reset-shutdown", f"csrf={reset_csrf}".encode(), headers)
        self.assertEqual(status, 303)
        self.assertIn("message=", response_headers["Location"])
        self.assertEqual(web.read_state(str(state_path))["shutdown_done"], 0)


if __name__ == "__main__":
    unittest.main()
