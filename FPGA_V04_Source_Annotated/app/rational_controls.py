# 组合新参数投影与仿射系数，控制 view15。30Hz 是串口提交目标，不等于显示新鲜帧率。

"""系数仅由上位机提供；仿射变换、镜头映射与重采样均在 FPGA 端执行。"""
from pathlib import Path
from fractions import Fraction
import json, time, re, math
from affine_command import coefficients
from affine_serial import send_matrix
from view_control import set_view

# 基准矩阵：13=带黑边取景，14=指定裁剪；矩阵已包含镜头投影，不能沿用旧模型系数。
BASES = {13: (107131, 0, -2236773, 0, 107305, -1521547), 14: (78067, 0, -1076379, 0, 78193, -389051)}
# 协议顺序 a,b,c,d,e,f；a/b/d/e 的小数位为16，c/f为12。
KEYS = ('a_q16', 'b_q16', 'c_q12', 'd_q16', 'e_q16', 'f_q12')


# 函数 compose(base,angle,scale,tx,ty)：在定点域组合基准投影与目标逆仿射矩阵，检查缩放范围和 32 位系数溢出。
def compose(base, angle=0., scale=1., tx=0., ty=0.):
    if base not in BASES: raise ValueError('Select rational full view or crop')
    if not .25 <= scale <= 4: raise ValueError('scale must be 0.25..4')
    p, q, c, r, s, f = BASES[base];
    d = coefficients(angle, scale, tx, ty);
    a, b, x, g, h, y = (d[k] for k in KEYS)
    # 用精确 Fraction 执行矩阵乘法后的最近整数舍入，避免主机浮点累积误差。
    rnd = lambda n: round(Fraction(n, 65536))
    out = (rnd(p * a + q * g), rnd(p * b + q * h), c + rnd(p * x + q * y), rnd(r * a + s * g), rnd(r * b + s * h),
           f + rnd(r * x + s * y))
    if any(not -2 ** 31 <= v < 2 ** 31 for v in out): raise ValueError('coefficient overflow')
    return dict(zip(KEYS, out))


# 函数 require_f131(port,timeout)：读取 R 行固件签名，拒绝不支持新参数动态模式的板端。
def require_f131(port, timeout=4):
    import serial
    # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
    with serial.Serial(port=None, baudrate=115200, timeout=.2) as uart:
        uart.dtr = False;
        uart.rts = False;
        uart.port = port;
        uart.open();
        end = time.monotonic() + timeout
        
        while time.monotonic() < end:
            row = uart.readline().strip()
            if re.fullmatch(rb'R[0-9a-fA-F]{80}', row):
                sig = bytes.fromhex(row[1:5].decode())
                if sig not in (b'\xf1\x31', b'\xf1\x32', b'\xf1\x33', b'\xf1\x34', b'\xf1\x35',
                               b'\xf1\x36'): raise RuntimeError('动态新参数矫正需下载 V02/F131；当前=' + sig.hex())
                return sig.hex().upper()
    raise TimeoutError('No compatible F131+ telemetry')


# 函数 apply(port,base,target,initial,duration,cancel)：校验目标参数后发送一次矩阵或执行定时过渡，记录最终状态。
def apply(port, base, target, initial=(0., 1., 0., 0.), duration=0., cancel=None):
    target = tuple(float(x) for x in target)
    if not all(math.isfinite(x) for x in target): raise ValueError('Nonfinite transform')
    compose(base, *target)
    if duration < 0 or not math.isfinite(duration): raise ValueError('Invalid duration')
    if duration:
        initial = tuple(float(x) for x in initial)
        compose(base, *initial)
        result = _stream_transition(port, base, initial, target, duration, cancel)
    else:
        firmware = require_f131(port)
        result = send_matrix(port, compose(base, *target));
        set_view(15, port)
    record = dict(time=time.strftime('%Y-%m-%d %H:%M:%S'), firmware=(result.get('firmware') if duration else firmware),
                  view=15, base_view=base, angle=target[0], scale=target[1], tx=target[2], ty=target[3],
                  matrix=result['matrix'], sequence=result['sequence'], telemetry=result['telemetry'],
                  transition=result.get('transition'))
    (Path(__file__).parent / 'dynamic_state.json').write_text(json.dumps(record, ensure_ascii=False, indent=2),
                                                              encoding='utf8')
    return record


# 函数 _stream_transition(port,base,initial,target,duration,cancel)：保持一个串口会话，按时间插值目标参数；过期更新不排队，末态等待回执。
def _stream_transition(port, base, initial, target, duration, cancel=None):
    """
    单路 UART 会话；有界邮箱、定时更新，仅最终回复 ACK。
    中间配置指令可能被 FPGA 内现存的单条目帧边界邮箱覆盖或拒收。
    上位机过期命令不会累积。UART 提交速率不等同于已显示 / 新视频帧速率。
    """
    import serial
    from affine_protocol import encode
    from affine_serial import telemetry
    from view_control import packet as view_packet
    # 目标每秒提交30组参数；板端单槽邮箱允许覆盖中间状态，不保证显示30个不同变换。
    hz = 30.0
    # 用非零命令序号区分本次目标与历史回执；序号不是图像帧计数。

    seed = time.time_ns() % 65535 + 1
    rx = bytearray();
    latest = None;
    signature = False;
    signature_code = None;
    view_ok = False;
    observed = [];
    sent = 0

    # 函数 check_cancel()：检查用户取消事件，及时结束过渡而不继续积压命令。
    def check_cancel():
        if cancel is not None and cancel.is_set(): raise RuntimeError('Transition cancelled')

    # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
    with serial.Serial(port=None, baudrate=115200, timeout=0, write_timeout=1) as uart:
        uart.dtr = False;
        uart.rts = False;
        uart.port = port;
        uart.open();
        uart.reset_input_buffer()

        # 函数 pump()：非阻塞累积串口接收字节并解析遥测，更新签名/视图/序号确认状态。
        def pump():
            nonlocal latest, signature, signature_code, view_ok
            n = uart.in_waiting
            if n: rx.extend(uart.read(n))
            if len(rx) > 65536: del rx[:-4096]
            
            while b'\n' in rx:
                row, _, rest = rx.partition(b'\n');
                rx[:] = rest;
                row = row.strip()
                if re.fullmatch(rb'R[0-9a-fA-F]{80}', row):
                    b = bytes.fromhex(row[1:].decode())
                    if b[:2] not in (b'\xf1\x31', b'\xf1\x32', b'\xf1\x33', b'\xf1\x34', b'\xf1\x35',
                                     b'\xf1\x36'): raise RuntimeError('Continuous rational transition requires F131')
                    signature = True;
                    signature_code = b[:2].hex().upper();
                    view_ok = (b[36] >> 4) == 15
                state = telemetry(row)
                if state:
                    if state['fault']: raise RuntimeError('FPGA backend fault during transition')
                    latest = state
                    if not observed or observed[-1] != state['displayed_sequence']: observed.append(
                        state['displayed_sequence'])

        # 函数 wait_ack(seq,packet,timeout,need_view)：等待最终命令序号获板端确认，期间持续收取遥测并检查取消/超时。
        def wait_ack(seq, packet, timeout, need_view=False):
            deadline = time.monotonic() + timeout;
            retry = time.monotonic() + .2
            
            while time.monotonic() < deadline:
                check_cancel();
                pump()
                if latest and latest['displayed_sequence'] == seq and (view_ok or not need_view): return latest
                if time.monotonic() >= retry:
                    uart.write(packet);
                    uart.flush();
                    retry = time.monotonic() + .2
                time.sleep(.005)
            raise TimeoutError('Final affine configuration not acknowledged')

        deadline = time.monotonic() + 4
        
        while not signature:
            check_cancel();
            pump()
            if time.monotonic() >= deadline: raise TimeoutError('No F131 telemetry')
            if not signature: time.sleep(.005)
        first = compose(base, *initial);
        first_packet = encode(seed, first)
        uart.write(first_packet);
        uart.write(view_packet(15));
        uart.flush()
        wait_ack(seed, first_packet, 6, True)
        start = time.monotonic();
        due = start;
        stamp = [];
        last_seq = seed;
        last_matrix = first
        
        while True:
            check_cancel();
            pump();
            now = time.monotonic()
            if now < due:
                time.sleep(min(.005, due - now));
                continue
            # smoothstep=t²(3−2t)，使起止速度趋零；时间按单调时钟计算。
            t = min(1.0, (now - start) / duration);
            blend = t * t * (3.0 - 2.0 * t)
            values = tuple(a + (b - a) * blend for a, b in zip(initial, target))
            last_matrix = compose(base, *values);
            last_seq = (seed + sent) % 65535 + 1
            last_packet = encode(last_seq, last_matrix);
            uart.write(last_packet);
            uart.flush()
            sent += 1;
            stamp.append(time.monotonic() - start)
            if t >= 1: break
            # 跳过丢失时隙，而非将过期变换参数批量灌入 FPGA 邮箱

            # 下次截止点由总经过时间确定，不补发已经过期的中间状态。
            due = start + (math.floor((time.monotonic() - start) * hz) + 1) / hz
        submit_elapsed = time.monotonic() - start
        status = wait_ack(last_seq, last_packet, 6)
        gaps = [b - a for a, b in zip(stamp, stamp[1:])]
        return dict(sequence=last_seq, matrix=last_matrix, telemetry=status, firmware=signature_code,
                    status='Final FPGA configuration acknowledged', transition={
                'method': 'persistent_uart_time_based_smoothstep', 'requested_seconds': duration,
                'submission_seconds': round(submit_elapsed, 4), 'submitted_updates': sent,
                'target_submission_hz': hz, 'max_submission_gap_seconds': round(max(gaps, default=0), 4),
                'observed_configuration_sequences': observed,
                'note': 'Submission cadence only; intermediate mailbox updates may be superseded; monitor fresh-frame rate not measured.'})
