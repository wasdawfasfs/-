# 文件职责：通过 NVIDIA NVAPI 请求 HDMI 全动态范围，避免 0..255 被映射为 16..235。
# 维护约束：仅补充注释，不改变可执行语句、协议、算法或项目参数。
import ctypes as C,json,sys
from pathlib import Path
# 类 Data：封装本文件的状态与接口，成员方法按下列注释分工。
class Data(C.Structure):
 _fields_=[('colorFormat',C.c_ubyte),('colorimetry',C.c_ubyte),('dynamicRange',C.c_ubyte),('bpc',C.c_int),('colorSelectionPolicy',C.c_int),('depth',C.c_int)]
# 类 Color：封装本文件的状态与接口，成员方法按下列注释分工。
class Color(C.Structure):
 _fields_=[('version',C.c_uint32),('size',C.c_uint16),('cmd',C.c_ubyte),('data',Data)]
# 函数 setup()：绑定 NVIDIA NVAPI 函数并定位活动显示输出，准备读取或设置颜色范围。
def setup():
 dll=C.CDLL('nvapi64.dll');q=dll.nvapi_QueryInterface;q.argtypes=[C.c_uint32];q.restype=C.c_void_p
 # 函数 fn(n)：通过 NVAPI 函数 ID 获取指针并声明调用签名，缺失接口时报错。
 def fn(n,*args):
  ptr=q(n)
  if not ptr:raise RuntimeError('NVAPI function unavailable')
  return C.CFUNCTYPE(C.c_int,*args)(ptr)
 init=fn(0x0150e828);assert init()==0
 getid=fn(0xae457190,C.c_char_p,C.POINTER(C.c_uint32));did=C.c_uint32();status=getid(bytes([92,92,46,92])+b'DISPLAY5',C.byref(did))
 if status!=0:
  # On a moved machine, select only when exactly one NVIDIA-driven active display exists.
  enum=fn(0xe5ac921f,C.c_void_p,C.POINTER(C.c_uint32));gpus=(C.c_void_p*64)();ng=C.c_uint32();assert enum(gpus,C.byref(ng))==0
  connected=fn(0x0078dba2,C.c_void_p,C.c_void_p,C.POINTER(C.c_uint32),C.c_uint32)
  # 类 DisplayId：封装本文件的状态与接口，成员方法按下列注释分工。
  class DisplayId(C.Structure):
   _fields_=[('version',C.c_uint32),('connector',C.c_int),('displayId',C.c_uint32),('flags',C.c_uint32)]
  active=[]
  # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
  for i in range(ng.value):
   count=C.c_uint32()
   if connected(gpus[i],None,C.byref(count),0)!=0 or not count.value:continue
   arr=(DisplayId*count.value)()
   # 循环块：按以下迭代条件处理数据；退出/取消分支沿用原实现。
   for item in arr:item.version=C.sizeof(DisplayId)|(3<<16)
   if connected(gpus[i],arr,C.byref(count),0)==0:active.extend(x.displayId for x in arr if x.flags&4)
  assert len(active)==1,('Cannot identify a unique NVIDIA external display',active)
  did.value=active[0]
 control=fn(0x92f9d80d,C.c_uint32,C.POINTER(Color))
 return dll,did,control

# 函数 get(control,did)：读取当前显示输出颜色配置，NVAPI 失败时明确报错。
def get(control,did):
 v=Color();v.version=C.sizeof(v)|(5<<16);v.size=C.sizeof(v);v.cmd=1
 status=control(did,C.byref(v));assert status==0,('GET',status)
 return v

# 函数 describe(v,did)：将 NVAPI 配置结构转换为可保存的字典，包含原始字节供追溯。
def describe(v,did):return dict(display_id=did.value,structure_bytes=C.sizeof(v),**{n:getattr(v.data,n) for n,_ in Data._fields_},raw=C.string_at(C.byref(v),C.sizeof(v)).hex())
# 入口分支：依据命令行/运行条件选择对应执行路径。
if __name__=='__main__':
 dll,did,control=setup();before=get(control,did);result={'before':describe(before,did)}
 if '--set-full' in sys.argv:
  backup=Path(__file__).with_name('nvidia_color_before.json')
  if not backup.exists():backup.write_text(json.dumps(result['before'],indent=2))
  needs_change=before.data.dynamicRange!=0 or before.data.colorFormat!=0 or before.data.colorSelectionPolicy!=0
  before.cmd=2;before.data.colorFormat=0;before.data.colorimetry=0;before.data.dynamicRange=0;before.data.colorSelectionPolicy=0
  status=control(did,C.byref(before)) if needs_change else 0;result['set_status']=status;result['changed']=needs_change
  assert status==0,('SET',status)
  result['after']=describe(get(control,did),did)
 print(json.dumps(result,indent=2))
 Path(__file__).with_name('nvidia_color_last_result.json').write_text(json.dumps(result,indent=2))
