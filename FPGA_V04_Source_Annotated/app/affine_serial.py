# 串口矩阵传输与 R 行遥测解析；DTR/RTS 保持低，避免误复位。

"""实现 UART 传输 ，向 FPGA 发送仿射系数；等待显示帧序列应答。"""
import argparse, json, re, time, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / "dependencies"))
from affine_command import coefficients
from affine_protocol import encode

# 函数 telemetry(line)：解码 R 行遥测字段，包含固件签名、配置序号、处理状态及计数。
def telemetry(line):
    if not re.fullmatch(rb'D(?:[A-Fa-f0-9]{32}|[A-Fa-f0-9]{40})', line.strip()):
        return None
    b = bytes.fromhex(line.strip()[1:].decode('ascii'))
    if b[0] not in (0xa2,0xa3):
        return None
    result = dict(flags=b[1], width=int.from_bytes(b[2:4], 'big'),
                height=int.from_bytes(b[4:6], 'big'),
                processed_frames=int.from_bytes(b[8:12], 'big'),
                displayed_sequence=int.from_bytes(b[12:14], 'big'),
                fault=bool(b[1] & 0x10 or b[14] & 8),
                status=int.from_bytes(b[14:16], 'big'))
    if b[0]==0xa3 and len(b)==20:
        result.update(mean=b[16],curve=b[17]&7,mixed_highlight=bool(b[17]&128),gamma_mode=b[18],statistics_frames=b[19])
    return result

# 函数 send(port,angle,scale,tx,ty,sequence,timeout)：按仿射参数生成矩阵后发送，等待配置回执；不执行逐像素处理。
def send(port, angle, scale=1.0, tx=0., ty=0., sequence=None, timeout=30.):
    return send_matrix(port, coefficients(angle, scale, tx, ty), sequence, timeout)

# 函数 send_matrix(port,matrix,sequence,timeout)：发送已量化矩阵和命令序号，读取串口回执并处理超时。
def send_matrix(port, matrix, sequence=None, timeout=30.):
    """下发系数，而非像素；应答信号为配置序列"""
    import serial
    sequence = sequence if sequence is not None else (time.time_ns() % 65535 + 1)
    packet = encode(sequence, matrix)
    # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
    with serial.Serial(port=None, baudrate=115200, timeout=.25) as uart:
        uart.dtr = False
        uart.rts = False
        uart.port = port
        uart.open()
        uart.reset_input_buffer()
        uart.write(packet)
        uart.flush()
        deadline = time.monotonic() + timeout
        
        while time.monotonic() < deadline:
            status = telemetry(uart.readline())
            if status is None:
                continue
            print(json.dumps(status), flush=True)
            if status['fault']:
                raise RuntimeError('FPGA reports backend fault; command not verified')
            if status['displayed_sequence'] == sequence and status['processed_frames'] > 0:
                return dict(sequence=sequence, matrix=matrix, telemetry=status,
                            status='FPGA displayed result with requested sequence')
        raise TimeoutError('No matching V10 displayed-frame acknowledgement; check bitstream and UART')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', default='COM11')
    p.add_argument('--angle', type=float, required=True)
    p.add_argument('--scale', type=float, default=1.)
    p.add_argument('--tx', type=float, default=0.)
    p.add_argument('--ty', type=float, default=0.)
    p.add_argument('--sequence', type=int)
    p.add_argument('--timeout', type=float, default=30.)
    args = p.parse_args()
    print(json.dumps(send(args.port, args.angle, args.scale, args.tx, args.ty,
                          args.sequence, args.timeout), indent=2))
