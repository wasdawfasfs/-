# 复制并锁定主机输入帧，避免相机后续写入覆盖同帧对照。

"""保留一份未经修改的原始帧，用于可复现的 FPGA 图像质量 A/B 对比测试"""
import hashlib,time,traceback
# 类 FrozenInput：封装本文件的状态与接口，成员方法按下列注释分工。
class FrozenInput:
    # 函数 __init__(self,on_change)：初始化实例状态、组件引用和默认配置；实际行为由后续方法执行。
    def __init__(self,on_change=None):self.on_change=on_change;self.clear()
    # 函数 clear(self)：解除本组件的冻结状态并释放缓存。
    def clear(self):
        previous=getattr(self,'digest',None);self.frame=None;self.digest=None
        self.notify('clear',previous)
    # 函数 notify(self,action,previous)：通知已注册回调当前冻结状态变化，保持显示与控制状态一致。
    def notify(self,action,previous=None):
        if self.on_change:self.on_change(dict(action=action,previous_digest=previous,digest=self.digest,time_ns=time.time_ns(),caller=traceback.format_stack(limit=5)))
    # 函数 active(self)：只读查询是否已有冻结输入帧；不是 FPGA 显示冻结标志。
    @property
    def active(self):return self.frame is not None
    # 函数 freeze(self,frame)：保存输入帧副本及摘要，后续读取返回同一冻结内容。
    def freeze(self,frame):
        if frame is None:raise ValueError('No camera frame available')
        self.frame=frame.copy();self.digest=hashlib.sha256(self.frame.tobytes()).hexdigest();self.notify('freeze')
    # 函数 select(self,live)：依据冻结标志选择保存帧或实时帧。
    def select(self,live):return self.frame if self.active else live
