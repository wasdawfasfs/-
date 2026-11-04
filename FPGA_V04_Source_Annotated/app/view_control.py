# 静态视图命令与板端确认；模式号必须与 RTL 中的选择器一致。

"""由 FPGA 控制几何视场；PC 端不对相机原始像素做校正"""
import time, re, struct
from affine_protocol import crc16
from gamma_control import control as gamma_control

SUPPORTED_SIG=(b'\xf1\x28',b'\xf1\x29',b'\xf1\x30',b'\xf1\x31',b'\xf1\x32',b'\xf1\x33',b'\xf1\x34',b'\xf1\x35',b'\xf1\x36')  # F128=V28, F129=V01, F130=V02 rational
CROP_MODE=12

# 函数 packet(mode)：按照当前控制协议编码命令和校验，不改变字段长度及字节序。
def packet(mode):
    if mode not in range(16):raise ValueError('Invalid view mode')
    body=bytes([1,mode,mode^255])
    return b'\xa7\x7a'+body+struct.pack('>H',crc16(body))

# 函数 set_view(mode,port,timeout)：发送静态视图选择指令，等待遥测确认处理后的视图与请求一致。
def set_view(mode,port,timeout=20):
    import serial
    # Geometry comparison views start with enhancement bypassed.
    if mode in (8,9,10,11,12):
        from affine_serial import send
        send(port,0.0,1.0,0.0,0.0)  # Isolate base lens correction for this view.
    if mode<=12:gamma_control(0,3,port)
    # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
    with serial.Serial(port=None,baudrate=115200,timeout=.2) as uart:
        uart.dtr=False;uart.rts=False;uart.port=port;uart.open()
        deadline=time.monotonic()+timeout
        supported=False;sent=False;confirmed=0;last_job=None;sig=None
        
        while time.monotonic()<deadline:
            row=uart.readline().strip()
            if not re.fullmatch(rb'R[0-9a-fA-F]{80}',row):continue
            data=bytes.fromhex(row[1:].decode())
            if data[:2] not in SUPPORTED_SIG:continue
            supported=True;sig=data[:2]
            if mode in (13,14) and sig not in (b'\xf1\x30',b'\xf1\x31',b'\xf1\x32',b'\xf1\x33',b'\xf1\x34',b'\xf1\x35',b'\xf1\x36'):
                raise RuntimeError('New rational views require V02/F130 firmware; current signature='+sig.hex())
            if mode==15 and sig not in (b'\xf1\x31',b'\xf1\x32',b'\xf1\x33',b'\xf1\x34',b'\xf1\x35',b'\xf1\x36'):
                raise RuntimeError('Dynamic rational view requires V02/F131 firmware')
            if mode==CROP_MODE and sig not in (b'\xf1\x29',b'\xf1\x30',b'\xf1\x31',b'\xf1\x32',b'\xf1\x33',b'\xf1\x34',b'\xf1\x35',b'\xf1\x36'):
                raise RuntimeError('View 12 requires V01/F129 or V02/F130 firmware')
            if not sent:
                uart.write(packet(mode));uart.flush();sent=True;continue
            job=int.from_bytes(data[2:6],'big')
            if data[36]>>4==mode and job!=last_job:
                confirmed+=1;last_job=job
                if confirmed>=2:return {'mode':mode,'completed_job':job,'signature':sig.hex()}
        if not supported:raise RuntimeError('需要下载已知版本位流（V28/F128 或 V01/F129 或 V02/F130）；当前未检测到匹配的版本状态')
        raise TimeoutError('未确认新的输出模式完成处理，请检查串口及 HDMI 输入')


