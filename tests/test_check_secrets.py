import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCANNER = Path(__file__).resolve().parents[1] / 'scripts/check_secrets.py'


class SecretCheckTests(unittest.TestCase):
    def test_staged_message_and_history_boundaries(self):
        # 仅在临时仓库构造测试历史，不读取或输出真实凭据。
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)

            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, env=env, stderr=subprocess.DEVNULL).strip().decode()

            def expect(blocked, *args):
                result = subprocess.run([sys.executable, SCANNER, *args], cwd=root, env=env, capture_output=True)
                self.assertEqual(result.returncode, int(blocked))
                self.assertNotIn(fake.encode(), result.stdout + result.stderr)
                if blocked:
                    self.assertIn('疑似凭据'.encode(), result.stderr)

            fake = 'https://api.day.app/' + ('X' * 24)
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            data = root / 'sample'
            data.write_text(fake)
            git('add', 'sample')
            expect(True, '--staged')
            git('commit', '-qm', 'initial')
            base = git('rev-parse', 'HEAD')
            expect(True, '--range', 'ROOT', base)
            data.write_text('<BARK_DEVICE_KEY>')
            git('add', 'sample')
            expect(False, '--staged')
            git('commit', '-qm', 'clean')
            expect(False, '--range', base, 'HEAD')
            data.write_text('summary\n\n' + fake)
            expect(True, '--message', str(data))
            git('commit', '--allow-empty', '-qF', str(data))
            expect(True, '--range', 'HEAD^', 'HEAD')
            start = git('rev-parse', 'HEAD')
            git('add', 'sample')
            git('commit', '-qm', 'transient')
            git('rm', '-q', 'sample')
            git('commit', '-qm', 'delete')
            expect(True, '--range', start, 'HEAD')

    def test_documented_placeholders_pass_but_real_values_fail(self):
        # 文档示例与 README 里的占位符必须放行，否则按文档配置就会被本地钩子拦住。
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)

            def git(*args):
                subprocess.check_output(['git', *args], cwd=root, env=env, stderr=subprocess.DEVNULL)

            def staged(content):
                (root / 'sample').write_text(content)
                git('init', '-q') if not (root / '.git').exists() else None
                git('add', 'sample')
                return subprocess.run(
                    [sys.executable, SCANNER, '--staged'], cwd=root, env=env, capture_output=True
                ).returncode

            for placeholder in [
                'MAIL_FROM=your@189.cn',
                'SMTP_USER=your@189.cn',
                'SMTP_PASS=your_smtp_password',
                'SMTP_PASSWORD=<SMTP_PASS>\nSMTP_PASS=<SMTP_PASSWORD>',
                'SMTP_PASS=${SMTP_PASS}',
                'MAIL_FROM=sender@example.com\nMAIL_TO=receiver@example.com',
                'BARK_KEY=xxxxxxxxxxxxxxxxxxxxxxxx',
            ]:
                self.assertEqual(staged(placeholder), 0, placeholder)

            # 换成真实样式的值仍必须拦截；用拼接生成，避免本文件自身被凭据扫描误判
            at = '@'
            for real in [
                'MAIL_FROM=' + 'someone' + at + '189.cn',
                'SMTP_PASS=' + '<TEST_PASSWORD>',
            ]:
                self.assertEqual(staged(real), 1, '真实样式的值应被拦截')
