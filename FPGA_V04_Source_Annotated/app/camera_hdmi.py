# 摄像头采集、纯视频 HDMI 提交及 Tk 控制界面。Python 不执行逐像素畸变矫正；按钮经串口控制 FPGA。

import sys, time, json, threading, ctypes, argparse, hashlib, zlib
from pathlib import Path

# 所有项目资源路径从当前脚本位置推导，移动目录后不依赖工作目录。
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packages'))
import os

os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame
import cv2, numpy as np

cv2.setNumThreads(2)
from PIL import Image, ImageTk
from cv2_enumerate_cameras import enumerate_cameras
from display_mode import monitors
from frozen_input import FrozenInput

# 锁文件属于运行时生成状态，新交付目录不携带旧进程的锁。
LOCKFILE = Path(__file__).resolve().parent / '.instance.lock'

# 复用已运行实例时用此文件切换入口，避免相机被第二实例抢占。
REQUESTFILE = Path(__file__).resolve().parent / '.panel_request'
_lock_handle = None


# 函数 _pid_alive(pid)：查询指定进程是否仍存在，为单实例锁提供依据。
def _pid_alive(pid):
    try:
        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))
        if handle:
            ctypes.windll.kernel32.CloseHandle(handle);
            return True
        return False
    except Exception:
        return False


# 函数 _try_lock()：用进程锁避免多个演示实例争用相机和串口，处理遗留锁文件。
def _try_lock():
    global _lock_handle

    try:
        handle = open(LOCKFILE, 'x', encoding='utf8');
        handle.write(str(os.getpid()));
        handle.flush();
        _lock_handle = handle;
        return True
    except FileExistsError:

        try:
            pid = int(LOCKFILE.read_text(encoding='utf8').strip() or 0)
        except Exception:
            pid = 0
        if pid and _pid_alive(pid): return False

        try:
            LOCKFILE.unlink()
        except OSError:
            return False
        return _try_lock()
    except Exception:
        return False


# 函数 _request_panel(entry)：通知已有实例切换控制入口，避免再次打开采集设备。
def _request_panel(entry):
    try:
        REQUESTFILE.write_text(entry + '\n' + str(time.time_ns()), encoding='utf8')
    except Exception:
        pass


# 函数 _check_environment()：枚举相机和显示器，记录 Python、路径与设备信息；仅诊断，不改变 FPGA 算法。
def _check_environment():
    from serial.tools import list_ports

    try:
        cameras = [(c.index, c.name) for c in enumerate_cameras(cv2.CAP_DSHOW)]
    except Exception as exc:
        cameras = 'error: ' + str(exc)
    info = {'python': sys.executable, 'prefix': sys.prefix, 'root': str(ROOT), 'cwd': os.getcwd(),
            'app_module': __file__,
            'pygame': getattr(pygame, '__file__', None), 'cv2': getattr(cv2, '__file__', None),
            'numpy': getattr(np, '__file__', None),
            'serial': getattr(__import__('serial'), '__file__', None), 'monitors': monitors(), 'cameras': cameras,
            'serial_ports': [p.device for p in list_ports.comports()]}
    (Path(__file__).resolve().parent / 'startup_check.json').write_text(json.dumps(info, ensure_ascii=False, indent=2),
                                                                        encoding='utf8')
    print(json.dumps(info, ensure_ascii=False, indent=2))


# 函数 fill_frame(frame,w,h)：按既有画幅填充策略生成固定输出尺寸，不改变 FPGA 的矫正算法。
def fill_frame(frame, w, h):
    sh, sw = frame.shape[:2]
    if (sw, sh) == (w, h): return frame
    scale = max(w / sw, h / sh)
    nw = max(w, round(sw * scale));
    nh = max(h, round(sh * scale))
    a = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_LINEAR)
    x = (nw - w) // 2;
    y = (nh - h) // 2
    return np.ascontiguousarray(a[y:y + h, x:x + w])


SOLID_BGR = {'Black': (0, 0, 0), 'White': (255, 255, 255), 'Gray64': (64, 64, 64), 'Gray128': (128, 128, 128),
             'Gray192': (192, 192, 192), 'Red': (0, 0, 255), 'Green': (0, 255, 0), 'Blue': (255, 0, 0)}
# Reference 仅为可重复输入源，保留一张默认图；正常演示默认使用 Camera。
REFERENCE_PATH = Path(__file__).resolve().parents[1] / 'tests/sharpness_comparison/original_input.png'
REFERENCE_FRAME = cv2.imdecode(np.fromfile(REFERENCE_PATH, dtype=np.uint8),
                               cv2.IMREAD_COLOR) if REFERENCE_PATH.exists() else None
REFERENCE_SHA = hashlib.sha256(REFERENCE_FRAME.tobytes()).hexdigest() if REFERENCE_FRAME is not None else None
SOURCE_MODES = ['Reference', 'Camera', 'White', 'Checkerboard', 'Bars', 'Black', 'Gray64', 'Gray128', 'Gray192', 'Red',
                'Green', 'Blue', 'InterpolationGrid']


# 函数 pattern(mode,w,h)：生成白场、棋盘格和彩条等输入源；图案尺寸由输出宽高指定。
def pattern(mode, w, h):
    if mode == 'Reference':
        if REFERENCE_FRAME is None: raise RuntimeError('Saved reference frame missing')
        return fill_frame(REFERENCE_FRAME, w, h)
    if mode == 'InterpolationGrid':
        yy, xx = np.indices((h, w));
        grid = (((xx // 4 + yy // 4) & 1) * 255).astype(np.uint8)
        a = np.repeat(grid[:, :, None], 3, axis=2)
        cv2.putText(a, 'FPGA interpolation test', (40, 80), cv2.FONT_HERSHEY_SIMPLEX, 1.8, (0, 0, 255), 3)
        return a
    if mode in SOLID_BGR:
        a = np.empty((h, w, 3), np.uint8);
        a[:] = SOLID_BGR[mode];
        return a
    if mode == 'White': return np.full((h, w, 3), 255, np.uint8)
    if mode == 'Checkerboard':
        y, x = np.indices((h, w));
        a = (((x // 80 + y // 80) & 1) * 255).astype(np.uint8)
        return np.repeat(a[:, :, None], 3, axis=2)
    colors = np.array(
        [[255, 255, 255], [0, 255, 255], [255, 255, 0], [0, 255, 0], [255, 0, 255], [0, 0, 255], [255, 0, 0],
         [0, 0, 0]], np.uint8)
    return np.repeat(colors[np.minimum(np.arange(w) * 8 // w, 7)][None, :, :], h, axis=0)


# 类 App：封装本文件的状态与接口，成员方法按下列注释分工。
class App:
    # 函数 __init__(self,args)：初始化实例状态、组件引用和默认配置；实际行为由后续方法执行。
    def __init__(self, args):
        import tkinter as tk
        from tkinter import ttk
        ctypes.windll.winmm.timeBeginPeriod(1)
        ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(),
                                                0x8000)  # AboveNormal, this process only.
        self.tk = tk;
        self.root = tk.Tk();
        self.root.title('V04 自适应画质候选 / 新参数矫正');
        self.root.geometry('1050x960+30+15')
        self.entry = getattr(args, 'entry', 'demo');
        self.last_request = '';
        self.last_req_poll = 0
        self.frozen = FrozenInput(self.audit_input);
        self.current_view = None;
        self.frozen_path = None;
        self.out = None;
        self.latest = None;
        self.lock = threading.Lock();
        self.stop = threading.Event();
        self.worker = None;
        self.frames = 0;
        self.started = time.monotonic();
        self.lastlog = 0;
        self.error = '';
        self.capture = {};
        self.render_key = None;
        self.rendered = 0
        # 采集/提交速率仅统计主机事件，不能直接充当 FPGA 新鲜输出帧率。
        self.rate_time = time.monotonic();
        self.rate_capture = 0;
        self.rate_render = 0;
        self.unique_captures = 0;
        self.duplicate_captures = 0;
        self.previous_capture_crc = None
        self.command_seen = None;
        self.last_command = 0
        self.cameras = list(enumerate_cameras(cv2.CAP_DSHOW));
        self.displays = [m for m in monitors() if not m['primary']]
        self.camvar = tk.StringVar(value=next((c.name for c in self.cameras if 'LRCP' in c.name),
                                              self.cameras[0].name if self.cameras else ''))
        self.mode = tk.StringVar(value=args.mode);
        self.status = tk.StringVar(value='准备就绪：外接屏必须为1920×1080。摄像头必须实际输出1920×1080，同尺寸输入不裁剪。')
        ttk.Label(self.root, text='摄像头').pack(anchor='w', padx=15, pady=5)
        ttk.Combobox(self.root, textvariable=self.camvar, values=[c.name for c in self.cameras], state='readonly',
                     width=55).pack(anchor='w', padx=15)
        profiles = ttk.Frame(self.root);
        profiles.pack(anchor='w', padx=15, pady=3)
        ttk.Button(profiles, text='固定曝光：帧率优先', command=lambda: self.camera_profile(False)).pack(side='left')
        ttk.Button(profiles, text='自动曝光：亮度优先', command=lambda: self.camera_profile(True)).pack(side='left',
                                                                                                       padx=5)
        ttk.Label(self.root, text='输入源（在主屏操作；三种画面由 FPGA 输出到显示器二）').pack(anchor='w', padx=15, pady=5)
        ttk.Combobox(self.root, textvariable=self.mode, values=SOURCE_MODES, state='readonly').pack(anchor='w', padx=15)
        self.view_busy = False
        self.view_status = tk.StringVar(
            value='V02：新参数全视野/裁剪可叠加动态仿射与自适应 Gamma；动态控制需 F131及以上 位流。旧模式保留。')
        from serial.tools import list_ports
        discovered_ports = [p.device for p in list_ports.comports()]
        preferred_port = os.environ.get('FPGA_PORT')
        default_port = preferred_port or (
            'COM11' if 'COM11' in discovered_ports else discovered_ports[0] if len(discovered_ports) == 1 else '')
        self.portvar = tk.StringVar(value=default_port)
        portrow = ttk.Frame(self.root);
        portrow.pack(anchor='w', padx=15, pady=5)
        ttk.Label(portrow, text='开发板串口').pack(side='left')
        from serial.tools import list_ports
        ttk.Combobox(portrow, textvariable=self.portvar, values=[p.device for p in list_ports.comports()],
                     width=15).pack(side='left', padx=5)
        self.view_buttons = []
        groups = [('旧模型中心视野', [('原始画面', 0), ('完整矫正：双线性', 1), ('原图 / 完整矫正对比', 2)]),
                  ('旧模型畸变矫正分步',
                   [('矫正：最近邻采样', 3), ('矫正：双线性采样', 1), ('矫正：最近邻 / 双线性对比', 4)]),
                  ('仅重采样（无畸变映射，固定0.5像素偏移）', [('最近邻', 5), ('双线性', 6), ('最近邻 / 双线性对比', 7)])]
        # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
        for heading, entries in groups:
            box = ttk.LabelFrame(self.root, text=heading);
            box.pack(anchor='w', fill='x', padx=15, pady=5)
            # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
            for title, view in entries:
                button = ttk.Button(box, text=title, command=lambda m=view: self.select_view(m))
                button.pack(side='left', padx=5, pady=5);
                self.view_buttons.append(button)
        fullviewrow = ttk.Frame(self.root);
        fullviewrow.pack(anchor='w', padx=15, pady=3)
        full_button = ttk.Button(fullviewrow, text='标定鱼眼全视野（保留黑边）', command=lambda: self.select_view(8));
        full_button.pack(side='left', padx=5);
        self.view_buttons.append(full_button)
        ttk.Label(fullviewrow, text='本机棋盘格标定鱼眼模型；等比例容纳完整边界，黑区约78%；其它模式仍为原模型。').pack(
            side='left', padx=5)
        brownrow = ttk.Frame(self.root);
        brownrow.pack(anchor='w', padx=15, pady=5)
        brownbutton = ttk.Button(brownrow, text='新标定：完整视野双线性（保留黑边）', command=lambda: self.select_view(9));
        brownbutton.pack(side='left', padx=5);
        self.view_buttons.append(brownbutton)
        near_button = ttk.Button(brownrow, text='同模型完整视野：最近邻', command=lambda: self.select_view(10));
        near_button.pack(side='left', padx=5);
        self.view_buttons.append(near_button)
        cmp_button = ttk.Button(brownrow, text='同模型保比例对照：左最近邻／右双线性',
                                command=lambda: self.select_view(11));
        cmp_button.pack(side='left', padx=5);
        self.view_buttons.append(cmp_button)
        ttk.Label(brownrow, text='本轮15张照片拟合；保留源边界；高精度验收未通过').pack(side='left', padx=5)
        v01row = ttk.LabelFrame(self.root, text='V01 全视野裁剪（实时输出到显示器二；主屏只放控制UI）');
        v01row.pack(anchor='w', fill='x', padx=15, pady=5)
        fullview_v01 = ttk.Button(v01row, text='矫正后全视野（保留黑边）', command=lambda: self.select_view(9));
        fullview_v01.pack(side='left', padx=5, pady=5);
        self.view_buttons.append(fullview_v01)
        crop_v01 = ttk.Button(v01row, text='按指定中心裁剪（1920×1080）', command=lambda: self.select_view(12));
        crop_v01.pack(side='left', padx=5, pady=5);
        self.view_buttons.append(crop_v01)
        v02row = ttk.Frame(self.root);
        v02row.pack(fill='x', padx=8)
        ttk.Label(v02row, text='V02 新参数（rational）实时显示').pack(side='left', padx=5, pady=5)
        new_rational = ttk.Button(v02row, text='新参数全视野（含真实黑边）', command=lambda: self.select_view(13));
        new_rational.pack(side='left', padx=5, pady=5);
        self.view_buttons.append(new_rational)
        new_crop = ttk.Button(v02row, text='新参数指定裁剪 1920×1080（实时）', command=lambda: self.select_view(14));
        new_crop.pack(side='left', padx=5, pady=5);
        self.view_buttons.append(new_crop)
        ttk.Label(v01row,
                  text='全视野=mode9；裁剪=mode12：中心列894、上界189、下界886、H=697、16:9等比无黑边（均匀缩放，不改局部几何）').pack(
            side='left', padx=5)
        self.dynamic_values = (0., 1., 0., 0.);
        self.dynamic_base_id = 14
        self.dynamic_base = tk.StringVar(value='裁剪');
        self.dynamic_vars = {}
        dyn = ttk.LabelFrame(self.root, text='新参数动态矫正（需 F131及以上；上位机发系数，FPGA 处理画面）');
        dyn.pack(fill='x', padx=15, pady=4)
        ttk.Label(dyn, text='基准').grid(row=0, column=0)
        ttk.Combobox(dyn, textvariable=self.dynamic_base, values=['裁剪', '全视野'], state='readonly', width=7).grid(
            row=0, column=1)
        # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
        for col, (key, title, value) in enumerate(
                [('angle', '角度°', '0'), ('scale', '缩放', '1'), ('tx', '水平位移', '0'), ('ty', '垂直位移', '0'),
                 ('duration', '过渡秒', '2')]):
            var = tk.StringVar(value=value);
            self.dynamic_vars[key] = var
            ttk.Label(dyn, text=title).grid(row=0, column=2 + col * 2);
            ttk.Entry(dyn, textvariable=var, width=7).grid(row=0, column=3 + col * 2, padx=2)
        # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
        for col, (title, cmd) in enumerate(
                [('应用仿射', lambda: self.apply_dynamic()), ('平滑过渡', lambda: self.apply_dynamic(smooth=True)),
                 ('恢复 0° / 1倍', lambda: self.apply_dynamic(reset=True))]):
            button = ttk.Button(dyn, text=title, command=cmd);
            button.grid(row=1, column=col * 3, columnspan=3, pady=3);
            self.view_buttons.append(button)
        gam = ttk.LabelFrame(self.root, text='FPGA 自适应预处理（选择后点应用；新参数视图保留设置）');
        gam.pack(fill='x', padx=15, pady=4)
        self.gamma_mode = tk.StringVar(value='自动');
        self.gamma_curve = tk.StringVar(value='3: Gamma 1.0')
        ttk.Combobox(gam, textvariable=self.gamma_mode, values=['旁路', '自动', '手动'], state='readonly',
                     width=8).pack(side='left', padx=5)
        ttk.Combobox(gam, textvariable=self.gamma_curve,
                     values=[f'{i}: Gamma {g}' for i, g in enumerate([.5, .65, .8, 1., 1.2, 1.5, 1.8])],
                     state='readonly', width=18).pack(side='left', padx=5)
        button = ttk.Button(gam, text='应用 Gamma', command=self.apply_gamma);
        button.pack(side='left', padx=5);
        self.view_buttons.append(button)
        ttk.Label(gam, text='自动：近黑保护、限幅提亮、亮度平滑；手动：保留原Gamma曲线。').pack(side='left', padx=5)
        self.dyn_frame = dyn;
        self.gam_frame = gam
        if self.entry != 'demo': self.root.after(150, lambda: self.apply_entry(self.entry, announce=False))
        auto_exit = getattr(args, 'auto_exit', 0) or 0
        if auto_exit: self.root.after(max(1000, int(float(auto_exit) * 1000)), self.close)
        actions = ttk.Frame(self.root);
        actions.pack(anchor='w', padx=15, pady=5)
        ttk.Button(actions, text='停止输出', command=self.halt).pack(side='left', padx=5)
        self.freeze_button = ttk.Button(actions, text='冻结测试画面', command=self.toggle_freeze);
        self.freeze_button.pack(side='left', padx=5)
        self.dump_busy = False;
        self.board_frozen = False;
        self.dump_cancel = threading.Event()
        dump_row = ttk.Frame(self.root);
        dump_row.pack(anchor='w', padx=15, pady=5)
        self.dump_button = ttk.Button(dump_row, text='暂停板上画面并串口保存整帧', command=self.start_frame_dump);
        self.dump_button.pack(side='left', padx=5)
        self.resume_button = ttk.Button(dump_row, text='恢复板上视频', command=self.resume_frame_dump,
                                        state='disabled');
        self.resume_button.pack(side='left', padx=5)
        ttk.Label(dump_row, text='115200波特率，整帧约6分钟；保持串口连接').pack(side='left', padx=5)
        ttk.Label(self.root, textvariable=self.view_status, wraplength=910).pack(anchor='w', padx=15, pady=5)
        ttk.Label(self.root, textvariable=self.status, wraplength=640).pack(anchor='w', padx=15)
        self.root.protocol('WM_DELETE_WINDOW', self.close);
        self.root.after(5, self.tick)
        if args.autostart: self.root.after(200, self.start)

    # 函数 audit_input(self,event)：追加输入身份事件，记录冻结/恢复时刻及帧摘要，便于同帧核对。
    def audit_input(self, event):
        event.update(pid=os.getpid(), source_mode=self.mode.get() if hasattr(self, 'mode') else None)
        # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
        with (ROOT / 'app/input_events.jsonl').open('a', encoding='utf8') as f: f.write(
            json.dumps(event, ensure_ascii=False) + '\n')

    # 函数 export_input_context(self)：保存导出请求对应的主机输入快照、路径及像素摘要，供元信息关联。
    def export_input_context(self):
        mode = self.mode.get()
        if mode == 'Camera':
            if not self.frozen.active: self.toggle_freeze()
            if not self.frozen.active: raise RuntimeError('尚无摄像头图像，不能锁定导出输入')
            frame = self.frozen.frame.copy()
        else:
            frame = pattern(mode, 1920, 1080)
        folder = ROOT / 'exports/inputs';
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / (time.strftime('%Y%m%d_%H%M%S') + '_' + str(time.time_ns() % 1000000000) + '.png')
        ok, data = cv2.imencode('.png', frame)
        if not ok: raise RuntimeError('无法保存导出对应的原始输入')
        data.tofile(str(path))
        self.render_key = None
        context = dict(available=True, pid=os.getpid(), source_mode=mode, input_frozen=True,
                       input_path=str(path), raw_pixel_sha256=hashlib.sha256(frame.tobytes()).hexdigest(),
                       input_shape=list(frame.shape), requested_view_mode=self.current_view,
                       request_host_time=time.strftime('%Y-%m-%d %H:%M:%S'))
        self.audit_input(dict(action='export_input_snapshot', context=context, time_ns=time.time_ns()))
        return context

    # 函数 start_frame_dump(self)：启动异步板端整帧导出；准备输入身份并禁止冲突控制。
    def start_frame_dump(self):
        if self.view_busy or self.dump_busy: return

        try:
            self.dump_context = self.export_input_context()
        except Exception as exc:
            self.view_status.set('未启动导出：' + str(exc));
            return
        self.dump_source_mode = self.mode.get();
        self.freeze_button.configure(state='disabled')
        self.dump_busy = True;
        self.view_busy = True;
        self.board_frozen = True;
        self.dump_cancel.clear()
        self.dump_button.configure(state='disabled');
        self.resume_button.configure(state='disabled')
        # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
        for b in self.view_buttons: b.configure(state='disabled')
        self.dump_result = None;
        self.dump_progress = '正在锁定显示帧并等待V25串口数据……'
        port = self.portvar.get().strip()

        # 函数 work()：后台执行当前控制/导出工作；返回值和异常交由界面线程处理。
        def work():

            try:
                from frame_export import export
                # 函数 progress(n,total,t)：将收帧/导出进度交回界面；不参与图像像素计算。
                def progress(n, total, t):
                    eta = (total - n) * t / max(1, n)
                    self.dump_progress = f'显示帧已锁定；接收 {n / total:.1%}，已用{t:.0f}秒，预计剩余{eta:.0f}秒。'

                result = export(port, ROOT / 'exports', progress, self.dump_cancel, source_context=self.dump_context)
                self.dump_result = (True, result['image'])
            except Exception as exc:
                self.dump_result = (False, str(exc))

        self.root.after(500, lambda: (threading.Thread(target=work, daemon=True).start(), self.poll_frame_dump()))

    # 函数 poll_frame_dump(self)：在 Tk 线程处理导出进度和结束状态，更新按钮与保存提示。
    def poll_frame_dump(self):
        self.view_status.set(self.dump_progress)
        if self.dump_result is None: self.root.after(200, self.poll_frame_dump);return
        ok, message = self.dump_result;
        self.dump_busy = False
        self.freeze_button.configure(state='normal')
        self.audit_input(dict(action='export_complete', success=ok, result=message,
                              input_digest_now=self.frozen.digest, source_mode_now=self.mode.get(),
                              time_ns=time.time_ns()))
        if ok:

            try:
                meta_path = Path(message).with_suffix('.json');
                meta = json.loads(meta_path.read_text(encoding='utf8'))
                end_mode = self.mode.get();
                end_digest = self.frozen.digest if end_mode == 'Camera' else self.dump_context['raw_pixel_sha256']
                meta['host_input_at_completion'] = dict(source_mode=end_mode, raw_pixel_sha256=end_digest,
                                                        unchanged=end_mode == self.dump_context[
                                                            'source_mode'] and end_digest == self.dump_context[
                                                                      'raw_pixel_sha256'],
                                                        observed_at=time.strftime('%Y-%m-%d %H:%M:%S'))
                meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf8')
            except Exception as exc:
                self.audit_input(dict(action='export_metadata_completion_error', error=str(exc)))
            self.resume_button.configure(state='normal');
            self.view_status.set('CRC32通过，已保存：' + message + '。画面保持冻结，请点“恢复板上视频”。')
        else:
            self.board_frozen = False;
            self.view_busy = False;
            self.dump_button.configure(state='normal');
            self.resume_button.configure(state='normal')
            # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
            for b in self.view_buttons: b.configure(state='normal')
            self.view_status.set('导出失败，已尝试恢复板上视频：' + message + '。必要时再点恢复。')

    # 函数 resume_frame_dump(self)：请求 FPGA 解除显示冻结；不等同于解除主机输入冻结。
    def resume_frame_dump(self):
        if self.dump_busy: return

        try:
            from frame_export import resume
            resume(self.portvar.get().strip());
            self.board_frozen = False;
            self.view_busy = False
            self.dump_button.configure(state='normal');
            self.resume_button.configure(state='disabled')
            # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
            for b in self.view_buttons: b.configure(state='normal')
            self.view_status.set('已发送恢复板上视频命令；下一显示帧恢复更新。')
        except Exception as exc:
            self.view_status.set('恢复失败：' + str(exc))

    # 函数 select_view(self,view)：异步发送指定视图号并读取板端回执，选择 FPGA 的实际像素处理路径。
    def select_view(self, view):
        if self.view_busy: return
        self.start()
        if not self.out: return
        if view in (13, 14):
            self.dynamic_base.set('全视野' if view == 13 else '裁剪');
            self.dynamic_base_id = view;
            self.dynamic_values = (0., 1., 0., 0.)
        self.view_busy = True
        # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
        for b in self.view_buttons: b.configure(state='disabled')
        self.view_status.set('正在下发 FPGA 模式；新参数模式保留 Gamma，旧对比模式设为旁路。')
        port = self.portvar.get().strip()

        # 函数 worker()：后台执行当前闭包指定的设备控制；通过共享结果字段向 UI 报告。
        def worker():

            try:
                from view_control import set_view
                result = set_view(view, port);
                self.current_view = view;
                message = ['原始画面', '完整矫正＋双线性', '左原图／右完整矫正', '畸变及仿射映射＋最近邻',
                           '左矫正最近邻／右矫正双线性', '仅重采样：最近邻，0.5像素偏移', '仅重采样：双线性，0.5像素偏移',
                           '仅重采样：左最近邻／右双线性', '标定鱼眼全视野：0°、新标定模型、保留越界黑边',
                           '二阶径向＋切向：完整视野，保留真实黑边', '二阶径向＋切向：完整视野，最近邻采样',
                           '同模型保比例对照：左最近邻／右双线性',
                           'V01 指定中心裁剪：中心列894、H=697、16:9等比1920×1080（无黑边，板端完成处理）',
                           'V02 新参数全视野（0°基线）：同一角度场景、真实黑边、板端完成',
                           'V02 新参数指定裁剪（0°基线）：ab中心列873/H=787/16:9/1920×1080，板端完成'][view] + '；板端已完成处理。'
            except Exception as exc:
                message = '切换失败：' + str(exc)
            # Tk calls must stay on the UI thread.
            self.view_result = message

        self.view_result = None
        threading.Thread(target=worker, daemon=True).start()
        self.root.after(100, self.poll_view)

    # 函数 run_control(self,label,action)：在后台线程执行串口控制，主线程轮询结果，避免 UI 被阻塞。
    def run_control(self, label, action):
        if self.view_busy or self.dump_busy: return
        self.start()
        if not self.out: return
        self.view_busy = True;
        self.view_result = None
        # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
        for b in self.view_buttons: b.configure(state='disabled')
        self.view_status.set(label + '：等待板端确认')

        # 函数 worker()：后台执行当前闭包指定的设备控制；通过共享结果字段向 UI 报告。
        def worker():

            try:
                self.view_result = action()
            except Exception as exc:
                self.view_result = label + '失败：' + str(exc)

        threading.Thread(target=worker, daemon=True).start();
        self.root.after(100, self.poll_view)

    # 函数 apply_dynamic(self,smooth,reset)：读取 UI 仿射参数，异步提交系数；不在主线程等待串口。
    # 几何矫正、插值和帧缓存仍在 FPGA；此处只计算少量控制系数。
    def apply_dynamic(self, smooth=False, reset=False):
        if reset:
            # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
            for k, v in zip(['angle', 'scale', 'tx', 'ty'], ['0', '1', '0', '0']): self.dynamic_vars[k].set(v)

        try:
            target = tuple(float(self.dynamic_vars[k].get()) for k in ['angle', 'scale', 'tx', 'ty'])
            duration = float(self.dynamic_vars['duration'].get()) if smooth else 0.
            if not 0 <= duration <= 30: raise ValueError('过渡时间需 0..30 秒')
            base = 13 if self.dynamic_base.get() == '全视野' else 14;
            port = self.portvar.get().strip()
            from rational_controls import compose
            compose(base, *target)
        except Exception as exc:
            self.view_status.set('参数错误：' + str(exc));
            return
        initial = self.dynamic_values if self.dynamic_base_id == base else (0., 1., 0., 0.)

        # 函数 action()：执行当前按钮绑定的命令闭包；读取外层已验证参数并返回说明。
        def action():
            from rational_controls import apply
            record = apply(port, base, target, initial, duration, self.stop)
            self.current_view = 15;
            self.dynamic_values = target;
            self.dynamic_base_id = base
            return f'{record.get("firmware", "F131+")} 新参数动态矫正已确认：角度 {target[0]}°，缩放 {target[1]}，位移 {target[2:]}; Gamma 保留。旋转越界会出现真实黑区。'

        self.run_control('动态矫正', action)

    # 函数 apply_gamma(self)：提交 FPGA Gamma 模式并保存回执，处理完成后更新界面状态。
    # 自动模式使用板端帧统计，手动曲线由用户选择，旁路保持输入定义。
    def apply_gamma(self):
        # FPGA 模式编号0/1/2分别对应旁路/自动/手动，不更改手动Gamma曲线。
        # FPGA 模式编号0/1/2分别对应旁路/自动/手动，不更改手动Gamma曲线。
        # FPGA 模式编号0/1/2分别对应旁路/自动/手动，不更改手动Gamma曲线。
        mode = ['旁路', '自动', '手动'].index(self.gamma_mode.get());
        curve = int(self.gamma_curve.get().split(':')[0]);
        port = self.portvar.get().strip()

        # 函数 action()：执行当前按钮绑定的命令闭包；读取外层已验证参数并返回说明。
        def action():
            from gamma_control import control
            result = control(mode, curve, port)
            (ROOT / 'app/gamma_state.json').write_text(json.dumps(
                dict(time=time.strftime('%Y-%m-%d %H:%M:%S'), requested_mode=mode, requested_curve=curve,
                     telemetry=result), ensure_ascii=False, indent=2), encoding='utf8')
            return f'Gamma 已由 FPGA 确认：mode={mode}（0旁路/1自动/2手动），当前曲线={result.get("curve")}，亮度均值={result.get("mean")}。'

        self.run_control('Gamma 控制', action)

    # 函数 poll_view(self)：轮询后台控制结果，完成后恢复按钮状态并展示错误或回执。
    def poll_view(self):
        if self.view_result is None: self.root.after(100, self.poll_view);return
        self.view_status.set(self.view_result);
        self.view_busy = False
        # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
        for b in self.view_buttons: b.configure(state='normal')

    # 函数 start(self)：创建扩展屏纯视频输出窗口，检查外屏尺寸并启动采集/呈现流程。
    def start(self):
        if self.out: return
        self.displays = [m for m in monitors() if not m['primary']]
        if len(self.displays) != 1: self.status.set('需要且只允许一个扩展显示器。');return
        self.display = self.displays[0];
        m = self.display
        if (m['width'], m['height']) != (1920, 1080): self.status.set('外接屏不是1920×1080，已阻止启动。');return
        os.environ['SDL_VIDEO_WINDOW_POS'] = f"{m['x']},{m['y']}"
        pygame.display.init();
        pygame.display.set_caption('V02 FPGA HDMI Input')
        self.surface = pygame.display.set_mode((m['width'], m['height']), pygame.NOFRAME)
        pygame.mouse.set_visible(False);
        self.out = True
        self.stop = threading.Event();
        self.latest = None;
        self.frames = 0;
        self.started = time.monotonic();
        self.error = '';
        self.render_key = None;
        self.rendered = 0
        # 采集/提交速率仅统计主机事件，不能直接充当 FPGA 新鲜输出帧率。
        self.rate_time = time.monotonic();
        self.rate_capture = 0;
        self.rate_render = 0;
        self.unique_captures = 0;
        self.duplicate_captures = 0;
        self.previous_capture_crc = None
        self.worker = threading.Thread(target=self.capture_loop, args=(self.stop, self.camvar.get()), daemon=True);
        self.worker.start()

    # 函数 toggle_freeze(self)：在实时输入与当前帧副本之间切换，保存冻结输入原尺寸 PNG。
    def toggle_freeze(self):
        if self.dump_busy: self.status.set('导出期间输入已锁定，不能解除冻结');return
        if self.frozen.active:
            self.frozen.clear();
            self.frozen_path = None;
            self.freeze_button.configure(text='冻结测试画面');
            self.status.set('已恢复实时摄像头输入')
        else:
            if not self.out or self.mode.get() != 'Camera': self.status.set('请先启动 Camera 实时输入');return
            # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
            with self.lock:
                if self.latest is None: self.status.set('尚未收到摄像头帧');return
                self.frozen.freeze(self.latest)
            folder = Path(__file__).resolve().parents[1] / 'tests/preprocess_inputs';
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / (time.strftime('%Y%m%d_%H%M%S') + '_' + str(time.time_ns() % 1000000) + '.png')
            ok, encoded = cv2.imencode('.png', self.frozen.frame)
            if ok: encoded.tofile(path);self.frozen_path = str(path)
            self.freeze_button.configure(text='恢复实时画面');
            self.status.set('原始输入已冻结，可进行旁路/自动对比；此时只测试静态画质')
        self.render_key = None;
        self.lastlog = 0

    # 函数 camera_profile(self,automatic)：保存曝光相关配置，供下次启动读取；不修改镜头标定参数。
    def camera_profile(self, automatic):
        cfg = {'auto_exposure': automatic, 'exposure': -6, 'frame_identity_tag': True}
        (ROOT / 'app/camera_profile.json').write_text(json.dumps(cfg, indent=2), encoding='utf8')
        self.status.set('采集线程将更新曝光；以实际采集/提交速率为准。固定曝光在暗处可能更暗。')

    # 函数 capture_loop(self,stop,camera_name)：在独立线程持续读相机，更新共享帧、帧身份和采集统计。
    def capture_loop(self, stop, camera_name):
        camera = next((c for c in self.cameras if c.name == camera_name), None)
        if camera is None: self.error = '没有找到摄像头';return
        cap = cv2.VideoCapture(camera.index, cv2.CAP_DSHOW)

        try:
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920);
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080);
            cap.set(cv2.CAP_PROP_FPS, 30)
            # Size/FPS changes reset this driver to YUY2; negotiate MJPG LAST.
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
            # DirectShow uses 1 for auto; get(AUTO_EXPOSURE) may return -1 unsupported.
            settings_path = ROOT / 'app/camera_profile.json'
            settings = json.loads(settings_path.read_text(encoding='utf8')) if settings_path.exists() else {
                'auto_exposure': True}
            exposure_set_ok = None
            if settings.get('auto_exposure', True):
                auto_exposure_ok = cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 1.0)
            else:
                exposure_set_ok = cap.set(cv2.CAP_PROP_EXPOSURE, float(settings.get('exposure', -6)))
                # Set MANUAL flag LAST: OpenCV's separate exposure-value setter passes flag0.
                auto_exposure_ok = cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.0)
            # This driver resets FOURCC on other property changes; MJPG MUST be last.
            fourcc = int(cap.get(cv2.CAP_PROP_FOURCC))
            self.capture = {'fourcc': ''.join(chr((fourcc >> (8 * i)) & 255) for i in range(4)), 'camera': camera.name,
                            'width': cap.get(3), 'height': cap.get(4), 'reported_fps': cap.get(5),
                            'auto_exposure_request_ok': auto_exposure_ok,
                            'exposure_readback': cap.get(cv2.CAP_PROP_EXPOSURE), 'profile': settings,
                            'exposure_set_ok': exposure_set_ok}
            if not cap.isOpened(): self.error = '打开摄像头失败，请关闭 Windows 相机';return
            failures = 0;
            last_profile_poll = time.monotonic()
            # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
            while not stop.is_set():
                if time.monotonic() - last_profile_poll > 1:
                    last_profile_poll = time.monotonic()

                    try:
                        requested = json.loads(settings_path.read_text(encoding='utf8'))
                        if requested != settings:
                            settings = requested
                            if settings.get('auto_exposure', True):
                                cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 1)
                            else:
                                cap.set(cv2.CAP_PROP_EXPOSURE, float(settings.get('exposure', -6)));
                                cap.set(
                                    cv2.CAP_PROP_AUTO_EXPOSURE, 0)
                            self.capture.update(profile=settings, exposure_readback=cap.get(cv2.CAP_PROP_EXPOSURE));
                            self.lastlog = 0
                    except (OSError, ValueError):
                        pass
                ok, a = cap.read()
                if not ok:
                    failures += 1
                    if failures > 30: self.error = '摄像头连续读取失败';break
                    time.sleep(.03);
                    continue
                failures = 0
                if a.shape[:2] != (1080,
                                   1920): self.error = "摄像头实际分辨率不是1920×1080，已停止，避免缩放或裁剪污染标定视野";break
                sample_crc = zlib.crc32(a[::16, ::16].tobytes())
                if sample_crc == self.previous_capture_crc:
                    self.duplicate_captures += 1
                else:
                    self.unique_captures += 1
                self.previous_capture_crc = sample_crc
                if settings.get('frame_identity_tag', True):
                    from frame_identity import stamp
                    stamp(a, self.frames + 1)
                if (ROOT / 'app/fps_marker.enabled').exists():
                    ident = (self.frames + 1) % 8
                    color = tuple(255 * ((ident >> i) & 1) for i in range(3))
                    a[400:680, 800:1120] = color
                # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
                with self.lock:
                    self.latest = a;
                    self.frames += 1
        finally:
            cap.release()

    # 函数 tick(self)：周期处理输入源、外部入口请求及图像提交，并安排下一次 Tk 回调。
    def tick(self):
        shutdown = ROOT / 'app/shutdown.request'
        if shutdown.exists():
            shutdown.unlink();
            self.close();
            return
        now = time.monotonic()
        # Candidate-only unattended evidence endpoint. It never opens the camera twice.

        try:
            cp = ROOT / 'app/quality_command.json'
            qc = json.loads(cp.read_text(encoding='utf8')) if cp.exists() else {}
            if qc.get('sequence') and qc.get('sequence') != getattr(self, 'quality_sequence', None):
                self.quality_sequence = qc['sequence'];
                action = qc.get('action')
                if action in ('snapshot', 'freeze', 'test_image'):
                    if self.latest is None: raise RuntimeError('No camera pixels available')
                    # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
                    with self.lock:
                        qa = self.latest.copy()
                    if action == 'test_image':
                        testpath = Path(qc['path']).resolve()
                        if not testpath.is_relative_to(ROOT.resolve()): raise RuntimeError(
                            'Evidence input must be inside candidate folder')
                        qa = cv2.imdecode(np.fromfile(testpath, dtype=np.uint8), cv2.IMREAD_COLOR)
                        if qa is None or qa.shape[:2] != (1080, 1920): raise RuntimeError(
                            'Test input must be native 1920x1080')
                    if action in ('freeze', 'test_image'):
                        self.frozen.freeze(qa);
                        self.freeze_button.configure(text='恢复实时画面');
                        self.render_key = None
                    qdir = ROOT / 'verification/adaptive_quality/camera';
                    qdir.mkdir(parents=True, exist_ok=True)
                    qp = qdir / (str(qc['sequence']) + '.png')
                    ok, encoded = cv2.imencode('.png', qa)
                    if not ok: raise RuntimeError('PNG encode failed')
                    encoded.tofile(qp)
                    if action in ('freeze', 'test_image'): self.frozen_path = str(qp)
                    reply = {'sequence': qc['sequence'], 'action': action, 'path': str(qp),
                             'pixel_sha256': hashlib.sha256(qa.tobytes()).hexdigest(), 'capture': self.capture,
                             'frames': self.frames}
                elif action == 'live':
                    self.frozen.clear();
                    self.frozen_path = None;
                    self.freeze_button.configure(text='冻结测试画面');
                    self.render_key = None
                    reply = {'sequence': qc['sequence'], 'action': action}
                else:
                    raise RuntimeError('Unknown quality evidence command')
                (ROOT / 'app/quality_reply.json').write_text(json.dumps(reply, ensure_ascii=False, indent=2),
                                                             encoding='utf8')
        except Exception as exc:
            if getattr(self, 'quality_sequence', None):
                (ROOT / 'app/quality_reply.json').write_text(
                    json.dumps({'sequence': self.quality_sequence, 'error': str(exc)}), encoding='utf8')
        if now - self.last_req_poll > .5:
            self.last_req_poll = now

            try:
                raw = REQUESTFILE.read_text(encoding='utf8') if REQUESTFILE.exists() else ''
                request = raw.split('\n')[0].strip()
                if request in ('demo', 'dynamic', 'gamma') and raw != self.last_request:
                    self.last_request = raw;
                    self.apply_entry(request)
            except OSError:
                pass
        if now - self.last_command > .1:
            self.last_command = now

            try:
                command = json.loads((Path(__file__).parent / 'source_command.json').read_text(encoding='utf8'))
                if not self.dump_busy and command.get('sequence') != self.command_seen and command.get(
                        'mode') in SOURCE_MODES:
                    self.mode.set(command['mode']);
                    self.command_seen = command['sequence'];
                    self.render_key = None;
                    self.lastlog = 0
            except (OSError, ValueError, KeyError):
                pass
        if self.out:
            # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
            for event in pygame.event.get():
                if event.type == pygame.QUIT or (
                        event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE): self.halt();break
        if self.out:
            if self.dump_busy: self.mode.set(self.dump_source_mode)
            m = self.display;
            mode = self.mode.get();
            render_key = (mode, self.frames if mode == 'Camera' else 0)
            if mode == 'Camera':
                # 资源作用域：使用上下文管理器保证正常或异常退出时释放资源。
                with self.lock:
                    a = self.frozen.select(self.latest);
                    render_key = (mode,
                                  self.frozen.digest if self.frozen.active else self.frames)
                if render_key == self.render_key: a = None
                if a is not None: a = fill_frame(a, m['width'], m['height'])
            else:
                a = pattern(mode, m['width'], m['height']) if render_key != self.render_key else None
            if a is not None and render_key != self.render_key:
                self.render_key = render_key;
                self.rendered += 1
                frame_surface = pygame.image.frombuffer(a.tobytes(), (a.shape[1], a.shape[0]), 'BGR')
                self.surface.blit(frame_surface, (0, 0));
                pygame.display.flip()
            now = time.monotonic()
            if now - self.lastlog > 2:
                rate_dt = max(.001, now - self.rate_time);
                capture_fps = round((self.frames - self.rate_capture) / rate_dt, 2);
                render_fps = round((self.rendered - self.rate_render) / rate_dt, 2)
                self.rate_time = now;
                self.rate_capture = self.frames;
                self.rate_render = self.rendered
                info = {'process_id': os.getpid(), 'selected_view_mode': self.current_view,
                        'control_busy': self.view_busy, 'source_command_sequence': self.command_seen,
                        'known_source_bgr': SOLID_BGR.get(mode),
                        'input_frozen': mode == 'Reference' or (self.frozen.active and mode == 'Camera'),
                        'frozen_frame_sha256': REFERENCE_SHA if mode == 'Reference' else self.frozen.digest if mode == 'Camera' else None,
                        'frozen_frame_path': str(REFERENCE_PATH) if mode == 'Reference' else self.frozen_path,
                        'time': time.strftime('%Y-%m-%d %H:%M:%S'), 'mode': mode, 'display': m, 'capture': self.capture,
                        'rendered_frames': self.rendered, 'measured_render_fps': render_fps,
                        'cumulative_render_fps': round(self.rendered / max(.001, now - self.started), 2),
                        'captured_frames': self.frames, 'unique_sampled_captures': self.unique_captures,
                        'duplicate_sampled_captures': self.duplicate_captures,
                        'last_raw_sample_crc32': self.previous_capture_crc, 'measured_capture_fps': capture_fps,
                        'cumulative_capture_fps': round(self.frames / max(.001, now - self.started), 2),
                        'rate_window_seconds': round(rate_dt, 3), 'error': self.error,
                        'note': 'HDMI source only; FPGA output needs independent observation'}
                (Path(__file__).parent / 'camera_status.json').write_text(
                    json.dumps(info, ensure_ascii=False, indent=2), encoding='utf8');
                self.status.set((
                                    '【保存原图回放】 ' if mode == 'Reference' else '【已冻结原始输入】 ' if self.frozen.active and mode == 'Camera' else '') + json.dumps(
                    info['capture'], ensure_ascii=False) + ' | ' + '采集 ' + str(
                    info['measured_capture_fps']) + ' fps / HDMI提交 ' + str(
                    info['measured_render_fps']) + ' fps ' + self.error);
                self.lastlog = now
        self.root.after(5, self.tick)

    # 函数 halt(self)：停止主机视频输出，释放对应窗口资源；不重新下载 FPGA。
    def halt(self):
        if self.dump_busy: self.status.set('导出期间不能停止输入；关闭窗口可取消导出');return
        self.frozen.clear();
        self.frozen_path = None;
        self.freeze_button.configure(text='冻结测试画面')
        self.stop.set()
        if self.worker: self.worker.join(timeout=2)
        if self.worker and self.worker.is_alive(): self.status.set('等待摄像头驱动释放，请稍后重启');return
        if self.out: pygame.display.quit();self.out = None

    # 函数 close(self)：执行退出清理，终止采集/输出并释放单实例锁。
    def close(self):
        if self.dump_busy:
            self.dump_cancel.set();
            self.root.after(300, self.close);
            return
        if self.board_frozen: self.resume_frame_dump()
        self.halt();
        ctypes.windll.winmm.timeEndPeriod(1);
        self.root.destroy()

    # 函数 apply_entry(self,entry,announce)：选择总览、动态或 Gamma 控制入口，调整 UI 展示与说明。
    def apply_entry(self, entry, announce=True):
        self.entry = entry
        (Path(__file__).parent / 'panel_state.json').write_text(
            json.dumps({'process_id': os.getpid(), 'entry': entry, 'updated_ns': time.time_ns()}), encoding='utf8')

        try:
            self.root.deiconify();
            self.root.lift();
            self.root.attributes('-topmost', True)
            self.root.after(120, lambda: self.root.attributes('-topmost', False));
            self.root.focus_force()
        except Exception:
            pass
        if entry == 'dynamic':
            self.view_status.set(
                '动态矫正入口：选基准（裁剪/全视野）→ 填角度/缩放/平移 →「应用仿射」或「平滑过渡」。新参数视图保留 Gamma。')
        elif entry == 'gamma':
            self.view_status.set('自适应 Gamma 入口：选旁路/自动/手动和曲线 →「应用 Gamma」；新参数视图13/14/15保留设置。')
        else:
            self.view_status.set('演示入口：左侧按钮切视图；下方为动态矫正与自适应 Gamma 控制。')

    # 函数 run(self)：运行当前组件的事件或收发循环，直至退出条件成立。
    def run(self):
        self.root.mainloop()


# 入口分支：依据命令行/运行条件选择对应执行路径。
if __name__ == '__main__':
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
    p = argparse.ArgumentParser();
    p.add_argument('--autostart', action='store_true');
    p.add_argument('--mode', choices=SOURCE_MODES, default='Camera');
    p.add_argument('--list', action='store_true');
    p.add_argument('--self-test', action='store_true');
    p.add_argument('--entry', choices=['demo', 'dynamic', 'gamma'], default='demo');
    p.add_argument('--auto-exit', type=float, default=float(os.environ.get('V02_AUTO_EXIT', '0') or 0));
    p.add_argument('--check', action='store_true');
    args = p.parse_args()
    if args.list:
        print([(c.index, c.name) for c in enumerate_cameras(cv2.CAP_DSHOW)]);
        print(monitors())
    elif args.check:
        _check_environment()
    elif args.self_test:
        # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
        for shape in [(480, 640), (1080, 1920), (1600, 2560)]:
            a = fill_frame(np.full((*shape, 3), 173, np.uint8), 1920, 1080);
            assert a.shape == (1080, 1920, 3) and np.all(a == 173)
        # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
        for mode in ['White', 'Checkerboard', 'Bars']: assert pattern(mode, 1920, 1080).shape == (1080, 1920, 3)
        hold = FrozenInput();
        original = np.full((4, 5, 3), 73, np.uint8);
        hold.freeze(original);
        original[:] = 12;
        assert np.all(hold.select(original) == 73);
        digest = hold.digest;
        assert len(digest) == 64;
        hold.clear();
        assert hold.select(original) is original
        print('PURE_HDMI_SOURCE_AND_FROZEN_INPUT_TEST_PASS')
    else:
        if not _try_lock():
            _request_panel(args.entry);
            print('已有 V02 实例在运行；已请求切换到入口 ' + args.entry + '（请用该已打开窗口操作）。')
            sys.exit(0)
        App(args).run()
