# 枚举 Windows 显示器，定位供给 FPGA 的 1920×1080 扩展屏。

import ctypes, json
from ctypes import wintypes as w

u = ctypes.windll.user32


# 类 RECT：封装本文件的状态与接口，成员方法按下列注释分工。
class RECT(ctypes.Structure): _fields_ = [(n, w.LONG) for n in ('left', 'top', 'right', 'bottom')]


# 类 MI：封装本文件的状态与接口，成员方法按下列注释分工。
class MI(ctypes.Structure): _fields_ = [('size', w.DWORD), ('monitor', RECT), ('work', RECT), ('flags', w.DWORD),
                                        ('device', w.WCHAR * 32)]


# 类 DM：封装本文件的状态与接口，成员方法按下列注释分工。
class DM(ctypes.Structure):
    _fields_ = [('device', w.WCHAR * 32), ('spec', w.WORD), ('driver', w.WORD), ('size', w.WORD), ('extra', w.WORD),
                ('fields', w.DWORD), ('x', w.LONG), ('y', w.LONG), ('orientation', w.DWORD), ('fixed', w.DWORD)] + [
                   (n, w.SHORT) for n in ('color', 'duplex', 'yres', 'tt', 'collate')] + [('form', w.WCHAR * 32),
                                                                                          ('logpixels', w.WORD)] + [
                   (n, w.DWORD) for n in
                   ('bits', 'width', 'height', 'flags', 'hz', 'icm', 'intent', 'media', 'dither', 'r1', 'r2', 'panw',
                    'panh')]


# 函数 monitors()：读取系统显示器位置、分辨率和主屏标志，返回显示目标列表。
def monitors():
    result = []

    # 函数 cb(h,dc,r,p)：Windows 枚举显示器回调：提取位置、尺寸和主屏标志并加入结果。
    @ctypes.WINFUNCTYPE(w.BOOL, w.HMONITOR, w.HDC, ctypes.POINTER(RECT), w.LPARAM)
    def cb(h, dc, r, p):
        a = MI();
        a.size = ctypes.sizeof(a);
        u.GetMonitorInfoW(h, ctypes.byref(a));
        r = a.monitor
        result.append(dict(device=a.device, x=r.left, y=r.top, width=r.right - r.left, height=r.bottom - r.top,
                           primary=bool(a.flags & 1)));
        return True

    u.EnumDisplayMonitors(None, None, cb, 0);
    return result


if __name__ == '__main__':
    import sys

    u.SetProcessDPIAware()
    if '--set-1080p' in sys.argv:
        targets = [m for m in monitors() if not m['primary']]
        if len(targets) != 1: raise RuntimeError('Expected exactly one external monitor')
        d = DM();
        d.size = ctypes.sizeof(d)
        if not u.EnumDisplaySettingsW(targets[0]['device'], -1, ctypes.byref(d)): raise RuntimeError('Cannot read mode')
        d.width = 1920;
        d.height = 1080;
        d.hz = 60;
        d.fields = 0x580000
        rc = u.ChangeDisplaySettingsExW(targets[0]['device'], ctypes.byref(d), None, 0, None)
        if rc: raise RuntimeError('ChangeDisplaySettingsEx returned ' + str(rc))
    print(json.dumps(monitors(), ensure_ascii=False))
