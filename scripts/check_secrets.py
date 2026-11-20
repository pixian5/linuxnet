#!/usr/bin/env python3
"""离线检查暂存新增行、提交说明或两个版本间引入的每个提交。"""
import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path


RULES = (
    rb'https?://api\.day\.app/[a-zA-Z0-9_-]{10,}',
    rb'[\w.+-]+@189\.cn\b',
    rb'\b(?:SMTP_PASS(?:WORD)?|BARK_(?:DEVICE_)?KEY)\s*=\s*[\x22\x27]?(?![<$\x22\x27])[^\s<>$\x22\x27]{8,}',
    rb'\b(?:hf_[A-Za-z0-9]{25,}|cfut_[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{30,})',
    rb'-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----',
)
PATTERN = re.compile(b'|'.join(RULES), re.I)
# 文档示例与占位符不应触发告警，否则任何人按 README 复制示例都会被本地钩子拦下。
# 只有明显是占位（your@ / example. / ${...} / sender@ 等）才豁免。
# <...> 只认白名单里的占位符名：否则任何写成尖括号的值都会被豁免，
# 等于留了一个“把口令改成 <任意词> 就能绕过扫描”的口子。
PLACEHOLDER_NAMES = (
    rb'SMTP_?PASS(?:WORD)?|SMTP_?USER|SMTP_?ACCOUNT|MAIL_?FROM|MAIL_?TO'
    rb'|BARK_?(?:DEVICE_)?KEY|WEB_?TOKEN|PASSWORD|TOKEN|SECRET'
)
PLACEHOLDER = re.compile(
    rb'(?:your[_-]|your@|example\.(?:com|org|invalid)|sender@|receiver@'
    rb'|<\s*(?:' + PLACEHOLDER_NAMES + rb')\s*>|\$\{[A-Za-z_]+\}|xxxx+)',
    re.I,
)
# 对无上下文的历史口令和设备密钥只保留指纹；按字符组筛选候选，含前后缀也能识别。
KNOWN = ((16, re.compile(rb'[A-Za-z0-9!#(]{16,}'), '0de46a4ea6d84272847b918658153234d84051da8dbe19354e11ecfe02cd5db1'),
         (22, re.compile(rb'[A-Za-z0-9]{22,}'), '69def5bc894fa8ca1f1030458a2795c7f936ecea9e8b06ec1e116c0fdb0ae826'))


def check(data, label):
    for line in data.splitlines():
        hit = PATTERN.search(line)
        if hit:
            # 只豁免“赋值右侧明显是占位符”的情况，避免按文档示例配置时被本地钩子拦住
            value = hit.group(0).split(b'=', 1)[-1].strip().strip(b'\'"')
            if not PLACEHOLDER.match(value):
                raise SystemExit(f'检测到疑似凭据（{label}），未显示匹配内容。')
        # 指纹比对不参与占位符豁免：真实泄露值必须始终拦截
        if any(hashlib.sha256(chunk[i:i+n]).hexdigest() == fingerprint
               for n, regex, fingerprint in KNOWN for chunk in regex.findall(line)
               for i in range(len(chunk)-n+1)):
            raise SystemExit(f'检测到疑似凭据（{label}），未显示匹配内容。')


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL)


def changes(*args, parent_count=1):
    # 合并提交只查相对全部父提交都新增的行，不把基线的旧内容算作新增。
    cmd = ('diff-tree', '--cc', '-p') if parent_count > 1 else ('diff',)
    patch = git(*cmd, '--no-ext-diff', '--no-textconv', '--text', '--no-color', '--no-renames', '-U0', *args, '--')
    in_hunk = False
    for line in patch.split(b'\n'):
        if line.startswith(b'diff '):
            in_hunk = False
        elif line.startswith(b'@' * (parent_count+1) + b' '):
            in_hunk = True
        elif in_hunk and line.startswith(b'+' * parent_count):
            check(line[parent_count:], '新增内容')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--staged', action='store_true')
    group.add_argument('--message', type=Path)
    group.add_argument('--range', nargs=2, metavar=('BASE', 'HEAD'))
    args = parser.parse_args()
    if args.staged:
        changes('--cached')
    elif args.message:
        check(args.message.read_bytes(), '提交说明')
    else:
        base, head = args.range
        # 参数先解析为提交对象，避免将事件提供的值当作 Git 选项。
        def resolve(ref):
            return git('rev-parse', '--verify', '--end-of-options', ref+'^{commit}').strip().decode()
        head = resolve(head)
        exclude = [] if base == 'ROOT' else ['^'+resolve(base)]
        for oid in git('rev-list', head, *exclude).decode().split():
            check(git('show', '-s', '--format=%B', oid), '提交说明 '+oid[:12])
            parents = git('show', '-s', '--format=%P', oid).decode().split()
            # 分支内的中间提交单独检查，合并提交也检查最终写入的内容。
            if len(parents) > 1:
                changes(oid, parent_count=len(parents))
                continue
            before = parents[0] if parents else subprocess.check_output(['git', 'hash-object', '-t', 'tree', '--stdin'], input=b'').decode().strip()
            changes(before, oid)


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError):
        sys.exit('无法读取待检查的本地提交或文件，检查未通过。')
