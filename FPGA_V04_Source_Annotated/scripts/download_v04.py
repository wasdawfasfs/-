# 文件职责：启动本包 JTAG 服务，校验位流 SHA256 并下载 SRAM；不写 Flash。
# 维护约束：仅补充注释，不改变可执行语句、协议、算法或项目参数。
"""Headless SRAM download of the retained V04/F136 bitstream via the Pango JTAG server.

Why a helper: cdt_cfg_shell/cdt_js are ANSI tools and cannot open files under the Chinese
version path, so the sbit and the tcl are staged under %TEMP% (ASCII) first.

Steps: start cdt_js on a free local port -> cdt_cfg_shell -ip 127.0.0.1 -port P -file dl.tcl
(dl.tcl: cfg_scan_chain, cfg_assign_file -file <staged sbit>, cfg_program) -> verify log.
Writes verification/download_log.json. No changes to RTL or host code.
"""
import json
import socket
import subprocess
import sys
# 入口分支：依据命令行/运行条件选择对应执行路径。
if hasattr(sys.stdout, "reconfigure"): sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SBIT = ROOT / 'fpga_project' / 'generate_bitstream' / 'newddr3_top.sbit'
import os
LOCAL_BIN = ROOT / 'tools/programmer/bin'
BIN = LOCAL_BIN if (LOCAL_BIN / 'cdt_js.exe').is_file() else Path(os.environ.get('PANGO_PDS_BIN') or r'D:\pango\PDS_2022.2-SP6.1\bin')
# 入口分支：依据命令行/运行条件选择对应执行路径。
if not (BIN / 'cdt_js.exe').is_file():
    raise SystemExit('未找到 PDS 下载工具: ' + str(BIN) + "\n请先安装 Pango PDS（含 Programmer），或设置环境变量 PANGO_PDS_BIN 指向其 bin 目录。")
OUT = ROOT / 'logs' / 'download_log.json'
OUT.parent.mkdir(parents=True,exist_ok=True)


# 函数 free_port()：由操作系统分配空闲本地 TCP 端口供 JTAG 服务使用。
def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


# 函数 main()：校验本包位流身份，启动本地 JTAG 服务并下载 SRAM，保存下载结果；不写 Flash。
def main():
    import hashlib
    assert SBIT.exists(), f'missing bitstream: {SBIT}'
    import shutil
    backup = ROOT / 'fpga_project' / 'generate_bitstream' / 'backups'
    backup.mkdir(exist_ok=True)
    shutil.copy2(SBIT, backup / ('before_download_' + time.strftime('%Y%m%d_%H%M%S') + '.sbit'))
    sha = hashlib.sha256(SBIT.read_bytes()).hexdigest()
    identity = ROOT / 'VERSION_PACKAGE.json'
    if identity.exists():
        expected = json.loads(identity.read_text(encoding='utf-8-sig'))['bitstream']['sha256']
    else:
        candidate = json.loads((ROOT / 'candidate_v02.json').read_text(encoding='utf-8-sig'))
        if candidate.get('firmware_target') == 'F131' and not candidate.get('timing_met'):
            raise RuntimeError('F131 尚未通过最终时序，当前目录仍保留 F130 位流；未执行下载。')
        expected = candidate['bitstream_sha256']
    if sha != expected:raise RuntimeError('位流与本版本记录不符；未执行下载。')
    tmp = Path(tempfile.mkdtemp(prefix='v02_dl_'))
    if not str(tmp).isascii():
        import os
        public = Path(os.environ.get('PUBLIC', r'C:\Users\Public')) / 'Documents' / 'FPGA_V02_Temp'
        public.mkdir(parents=True, exist_ok=True)
        tmp = Path(tempfile.mkdtemp(prefix='dl_', dir=public))
        if not str(tmp).isascii():raise RuntimeError('PDS 下载工具需要 ASCII 临时路径，请设置 TEMP 后重试。')
    staged = tmp / 'newddr3_top.sbit'
    import shutil
    shutil.copy2(SBIT, staged)
    # Stage the movable Programmer too: vendor databases cannot reliably use Unicode paths.
    local_tools = ROOT / 'tools' / 'programmer'
    if (local_tools / 'bin/cdt_js.exe').is_file():
        shutil.copytree(local_tools, tmp / 'programmer', ignore=shutil.ignore_patterns('driver', 'log'))
        tool_bin = tmp / 'programmer' / 'bin'
    else:tool_bin = BIN
    port = free_port()
    tcl = tmp / 'dl.tcl'
    tcl.write_text(
        f'set f [open "{tmp.as_posix()}/dl_log.txt" w]\n'
        'proc log {f msg} { puts $f $msg; flush $f }\n'
        'log $f "BEGIN"\n'
        'if {[catch {cfg_scan_chain} e]} { log $f "scan ERR: $e" } else { log $f "scan OK" }\n'
        f'if {{[catch {{cfg_assign_file -file {{{staged.as_posix()}}}}} e]}} {{ log $f "assign ERR: $e" }} else {{ log $f "assign OK" }}\n'
        'if {[catch {cfg_program} e]} { log $f "program ERR: $e" } else { log $f "program OK" }\n'
        'log $f "END"\n'
        'close $f\nexit\n', encoding='ascii')
    server = subprocess.Popen([str(tool_bin / 'cdt_js.exe'), '-port', str(port)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW,cwd=tool_bin)
    time.sleep(3)
    # 异常边界：下列操作可能涉及设备、文件或协议；失败按对应 except 分支处理。
    try:
        r = subprocess.run([str(tool_bin / 'cdt_cfg_shell.exe'), '-ip', '127.0.0.1', '-port', str(port),
                            '-file', str(tcl)], capture_output=True, text=True, encoding='utf-8',
                           errors='replace', timeout=90, creationflags=subprocess.CREATE_NO_WINDOW,cwd=tool_bin)
        print(r.stdout)
        if r.returncode != 0:
            print(r.stderr)
    finally:
        server.terminate()
        # 异常边界：下列操作可能涉及设备、文件或协议；失败按对应 except 分支处理。
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
    log = (tmp / 'dl_log.txt').read_text(encoding='utf-8', errors='replace') if (tmp / 'dl_log.txt').exists() else ''
    ok = 'program OK' in log and 'scan OK' in log and 'assign OK' in log
    report = dict(sbit=str(SBIT), staged=str(staged), port=port, sha256=sha,
                  command='cfg_scan_chain; cfg_assign_file -file <sbit>; cfg_program',
                  log=log.splitlines(), success=ok)
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf8')
    print(json.dumps({k: report[k] for k in ('sbit', 'sha256', 'port', 'success')}, ensure_ascii=False, indent=1))
    sys.exit(0 if ok else 1)


# 入口分支：依据命令行/运行条件选择对应执行路径。
if __name__ == '__main__':
    main()
