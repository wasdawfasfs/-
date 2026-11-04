# Gamma 模式命令和帧级统计遥测；旁路、自动、手动由 FPGA 执行。

"""预处理指令；全部图像增强操作由 FPGA 完成"""
import argparse, sys, time, json, struct
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / 'dependencies'))
from affine_protocol import crc16
from affine_serial import telemetry

GAMMAS = [.5, .65, .8, 1, 1.2, 1.5, 1.8]


# 函数 packet(mode,curve,sequence)：按照当前控制协议编码命令和校验，不改变字段长度及字节序。
def packet(mode, curve, sequence=0):
    if mode not in (0, 1, 2) or not 0 <= curve <= 6: raise ValueError('mode/curve out of range')
    body = bytes([1, mode, curve, sequence & 255])
    return b'\xa6\x6a' + body + struct.pack('>H', crc16(body))


# 函数 control(mode,curve,port,timeout)：发送 Gamma 模式/曲线设置并等待 D 行配置回执，超时则报错。
def control(mode, curve=3, port='COM11', timeout=12):
    import serial
    # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
    with serial.Serial(port=None, baudrate=115200, timeout=.3) as uart:
        uart.dtr = False;
        uart.rts = False;
        uart.port = port;
        uart.open()
        baseline = None;
        deadline = time.monotonic() + 3
        
        while time.monotonic() < deadline:
            baseline = telemetry(uart.readline())
            if baseline and 'gamma_mode' in baseline: break
        if not baseline or 'gamma_mode' not in baseline: raise RuntimeError(
            'V11 A3 telemetry not detected; check downloaded bitstream')
        uart.write(packet(mode, curve, int(time.time()) & 255));
        uart.flush()
        deadline = time.monotonic() + timeout
        
        while time.monotonic() < deadline:
            state = telemetry(uart.readline())
            if not state: continue
            print(json.dumps(state), flush=True)
            if state['fault']: raise RuntimeError('FPGA backend fault')
            if state.get('gamma_mode') == mode and (mode != 2 or state['curve'] == curve) and state.get(
                    'statistics_frames') != baseline.get('statistics_frames'):
                return state
        raise TimeoutError('Gamma mode not confirmed')


if __name__ == '__main__':
    p = argparse.ArgumentParser();
    p.add_argument('--mode', choices=['bypass', 'auto', 'manual'], default='auto');
    p.add_argument('--curve', type=int, default=3);
    p.add_argument('--port', default='COM11');
    a = p.parse_args()
    print(json.dumps(control(['bypass', 'auto', 'manual'].index(a.mode), a.curve, a.port), indent=2))
