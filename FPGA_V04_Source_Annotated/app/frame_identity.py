# 在输入中生成帧身份标记，辅助测量；不将处理配置序号解释为帧号。

"""仅传输帧标识；上位机不执行像素几何运算处理"""
import numpy as np

MAGIC = 0xA55A


# 函数 stamp(frame,sequence)：在输入帧指定位置写入帧身份标记，辅助区分重复帧。
def stamp(frame, sequence):
    n = int(sequence) & 65535
    word = (MAGIC << 32) | (n << 16) | ((~n) & 65535)
    # Small 384x4 source-edge barcode. Crop projection does not use this edge band.

    for i in range(48): frame[16:20, 16 + 8 * i:24 + 8 * i] = 255 if (word >> (47 - i)) & 1 else 0
    return frame
