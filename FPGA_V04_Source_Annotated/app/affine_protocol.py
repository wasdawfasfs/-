# 仿射命令编码和 CRC16，保证与 FPGA 串口解析字段一致。

"""指令协议；导入操作不会产生传输侧效应."""
import struct


# 函数 crc16(data)：按现有协议的多项式和位序计算校验值，不能改变其参数。
# CRC 与 RTL 解析器配套；修改多项式、初值或字节序会导致命令被拒绝。
def crc16(data):
    # CRC 初值0xFFFF；每字节进入高8位，按0x1021多项式迭代8次。

    c = 0xffff

    for b in data:
        c ^= b << 8

        for _ in range(8): c = ((c << 1) ^ 0x1021 if c & 0x8000 else c << 1) & 0xffff
    return c


# 函数 encode(sequence,matrix)：按固定字段顺序和字节序编码串口命令，并附加 CRC。
def encode(sequence, matrix):
    if not 0 <= sequence <= 65535: raise ValueError('sequence out of range')
    values = [matrix[k] for k in ['a_q16', 'b_q16', 'c_q12', 'd_q16', 'e_q16', 'f_q12']]

    # 先组装协议体，再对协议体计算校验；头标志不混入该校验范围。
    body = struct.pack('>BH6i', 1, sequence, *values)
    return b'\xa5\x5a' + body + struct.pack('>H', crc16(body))


# 函数 decode(packet)：解析定长仿射命令字段并验证 CRC，返回与 encode 对应的数据。
def decode(packet):
    if len(packet) != 31 or packet[:2] != b'\xa5\x5a': raise ValueError('bad frame')

    # 先组装协议体，再对协议体计算校验；头标志不混入该校验范围。
    body = packet[2:-2]
    if crc16(body) != int.from_bytes(packet[-2:], 'big'): raise ValueError('bad CRC')
    version, seq, *values = struct.unpack('>BH6i', body)
    if version != 1: raise ValueError('unsupported version')
    return seq, dict(zip(['a_q16', 'b_q16', 'c_q12', 'd_q16', 'e_q16', 'f_q12'], values))
