# 冻结板上输出，接收整帧 RGB565 数据，校验 CRC 并保存 PNG/原始数据/元信息。

"""针对 R 行签名为 F1xx（V01/V28/V23X/V24）的任意比特流，导出 FPGA 显示帧。
该签名仅用于确认开发板正常工作、且运行了带有导出模块的固件；
真正的兼容性校验依据是 FPGA24 导出文件头（包含版本、格式、尺寸、循环冗余校验 CRC 信息）。
**上位机端不会对像素做任何校正处理。**"""
from pathlib import Path
import time, struct, zlib, json, hashlib, re

MAGIC = b'FPGA24\r\n'


# 函数 crc16(data)：按现有协议的多项式和位序计算校验值，不能改变其参数。
def crc16(data):
    c = 65535

    for b in data:
        c ^= b << 8

        for _ in range(8): c = ((c << 1) ^ 0x1021 if c & 0x8000 else c << 1) & 65535
    return c


# 函数 command(action,seq)：编码帧导出/恢复命令，附带现有协议要求的校验。
def command(action, seq):
    # 协议体采用小端字段，CRC 单独以大端写入，必须与 FPGA 接收器一致。
    body = struct.pack('<BBH', 1, action, seq)
    return b'\xa8\x8a' + body + struct.pack('>H', crc16(body))


# 函数 receive(uart,expected_seq,progress,cancel,expected_size)：从串口接收导出帧头与 RGB565 载荷，核对尺寸、长度和 CRC。
def receive(uart, expected_seq, progress=lambda *_: None, cancel=None, expected_size=(1920, 1080)):
    # 函数 read(n)：按所需字节数累积串口数据，处理进度、取消及超时。
    def read(n):
        data = bytearray();
        last = time.monotonic()

        while len(data) < n:
            if cancel is not None and cancel.is_set(): raise RuntimeError('已取消串口导出')

            # 一次最多读取4096字节，分批累积；短读不等同于完整帧结束。
            part = uart.read(min(n - len(data), 4096))
            if part:
                data.extend(part);last = time.monotonic()

            # 只在持续无数据超时后失败；整帧总耗时远大于单次无数据超时。
            elif time.monotonic() - last > 25:
                raise TimeoutError('串口25秒无图像数据；请检查HDMI显示通路及带整帧导出能力的位流（V01/V23X/V24/V28）')
        return bytes(data)

    window = bytearray();
    start = time.monotonic();
    line = bytearray();
    telemetry_rows = 0

    while bytes(window) != MAGIC:
        if time.monotonic() - start > 30: raise TimeoutError(
            '未收到整帧导出头；冻结电脑输入不会使旧固件具备导出功能，请确认下载了带整帧导出功能的位流（V01/V23X/V24/V28）')
        part = read(1);
        window.extend(part);
        window[:] = window[-len(MAGIC):]
        line.extend(part)
        if part == b'\n':
            if re.fullmatch(rb'R[0-9a-fA-F]{80}', line.strip()): telemetry_rows += 1
            line.clear()
        if len(line) > 512: line[:] = line[-512:]
        if telemetry_rows >= 2 and time.monotonic() - start > 1:
            raise RuntimeError(
                '导出命令后仍连续收到普通遥测，板子未进入导出；请先恢复板上视频，并确认下载的是带整帧导出功能的位流')
    header = MAGIC + read(14)
    version, fmt, seq, display_seq, w, h, length = struct.unpack('<BBHHHHI', header[8:])
    if version != 1 or fmt != 1 or seq != expected_seq or (w,
                                                           h) != expected_size or length != w * h * 2: raise ValueError(
        '图像头不匹配，拒绝保存')
    data = bytearray();
    crc = zlib.crc32(header);
    started = time.monotonic();
    notified = 0

    while len(data) < length:
        block = read(min(4096, length - len(data)));
        data.extend(block);
        crc = zlib.crc32(block, crc)
        if time.monotonic() - notified > .2 or len(data) == length:
            progress(len(data), length, time.monotonic() - started);
            notified = time.monotonic()
    expected = struct.unpack('<I', read(4))[0]
    if crc != expected: raise ValueError(f'CRC32校验失败：{crc:08x} != {expected:08x}；未保存PNG')
    return bytes(data), dict(width=w, height=h, request_sequence=seq, display_configuration_sequence=display_seq,
                             payload_bytes=length, crc32_header_and_payload=f'{crc:08x}',
                             receive_seconds=time.monotonic() - started,
                             source='FPGA protected display DDR frame, RGB565 LE; before HDMI serializer and physical monitor',
                             rgb888_expansion='zero padding, matching HDMI RTL; no geometric processing on host')


# 函数 open_port(port)：以 115200 波特率打开串口，关闭 DTR/RTS 自动控制，避免板卡误复位。
def open_port(port):
    import serial
    uart = serial.Serial(port=None, baudrate=115200, timeout=.3, write_timeout=3)
    uart.dtr = False;
    uart.rts = False;
    uart.port = port;
    uart.open();
    return uart


# 函数 resume(port)：向板端发送恢复视频指令；与主机输入冻结状态是两套控制。
def resume(port):
    # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
    with open_port(port) as uart: uart.write(command(2, 0));uart.flush()


# 函数 export(port,folder,progress,cancel,source_context)：请求冻结与整帧传输，核对帧头、长度及 CRC；返回实际保存路径。
# 串口115200传输1080P RGB565约4.15MB，耗时约6分钟；保持连接并在完成后恢复视频。
def export(port, folder, progress=lambda *_: None, cancel=None, source_context=None):
    seq = time.time_ns() & 65535;
    request_time = time.strftime('%Y-%m-%d %H:%M:%S')
    # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
    with open_port(port) as uart:
        deadline = time.monotonic() + 12;
        supported = False

        while time.monotonic() < deadline:
            if cancel is not None and cancel.is_set(): raise RuntimeError('已取消串口导出')
            row = uart.readline().strip()
            if re.fullmatch(rb'R[0-9a-fA-F]{80}', row):
                sig = row[1:5].decode().lower()
                if not re.fullmatch(r'f1[0-9a-f]{2}', sig): raise RuntimeError(
                    '需要带整帧导出能力的位流（R 行签名应为 F1xx，如 F128/F129）；当前板上版本不匹配')
                board_status = bytes.fromhex(row[1:].decode());
                board_mode = board_status[36] >> 4
                if source_context and source_context.get('requested_view_mode') is not None and board_mode != \
                        source_context['requested_view_mode']: raise RuntimeError(
                    '板上实际模式与上位机最近成功切换的模式不同，未启动导出')
                observed = dict(firmware=sig.upper(), view_mode=board_mode, telemetry_hex=row.decode(),
                                observed_at=time.strftime('%Y-%m-%d %H:%M:%S'))
                supported = True;
                break
        if not supported: raise RuntimeError('未收到 F1xx 状态帧，请检查串口及板子运行状态')
        
        try:
            uart.reset_input_buffer();
            uart.write(command(1, seq));
            uart.flush()
            payload, meta = receive(uart, seq, progress, cancel)
            meta['firmware'] = sig.upper();
            meta['board_status_before_export'] = observed
            meta['host_input_at_request'] = source_context or {'available': False}
            meta['export_request_time'] = request_time
        except Exception:
            uart.write(command(2, 0));
            uart.flush();
            raise
    
    try:
        return save_payload(payload, meta, port, folder, seq)
    except Exception:
        
        try:
            resume(port)
        except Exception:
            pass
        raise


# 函数 save_payload(payload,meta,port,folder,seq)：将 RGB565 按协议字节序解析并保存原始载荷、PNG 和 JSON 元信息。
# 导出观察点在 HDMI 发射之前，不包含显示器或线缆的光学效果。
def save_payload(payload, meta, port, folder, seq):
    meta.setdefault('firmware', 'unknown')
    import numpy as np, cv2
    folder = Path(folder);
    folder.mkdir(parents=True, exist_ok=True)
    stem = folder / (time.strftime('%Y%m%d_%H%M%S') + f'_{seq:04x}')
    words = np.frombuffer(payload, dtype='<u2').reshape(meta['height'], meta['width'])
    bgr = np.stack([(words & 31) << 3, ((words >> 5) & 63) << 2, ((words >> 11) & 31) << 3], axis=-1).astype(np.uint8)
    ok, png = cv2.imencode('.png', bgr)
    if not ok: raise RuntimeError('PNG编码失败，板上画面仍冻结，请点恢复')
    png.tofile(str(stem.with_suffix('.png')));
    stem.with_suffix('.rgb565').write_bytes(payload)
    meta.update(payload_sha256=hashlib.sha256(payload).hexdigest(), port=port, image=str(stem.with_suffix('.png')),
                board_remains_frozen=True)
    stem.with_suffix('.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')
    return meta


if __name__ == '__main__':
    import argparse

    p = argparse.ArgumentParser();
    p.add_argument('--port', default='COM11');
    p.add_argument('--resume', action='store_true');
    p.add_argument('--out', default=str(Path(__file__).resolve().parents[1] / 'exports'))
    args = p.parse_args()
    if args.resume:
        resume(args.port);print('已发送恢复显示命令')
    else:
        print(json.dumps(
            export(args.port, args.out, lambda n, total, t: print(f'{n}/{total} ({n / total:.1%}) {t:.0f}s')),
            ensure_ascii=False, indent=2))
