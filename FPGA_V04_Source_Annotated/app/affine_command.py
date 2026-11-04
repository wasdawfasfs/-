# 将角度、缩放和平移转换为逆向采样矩阵；线性项 Q16、平移项 Q12。

"""G生成逆仿射系数；**不对相机像素做变换**。本文件仅负责生成系数；"""
import argparse, math, json
from pathlib import Path


# 函数 coefficients(angle,scale,tx,ty,cx,cy)：生成输出坐标到输入坐标的逆仿射系数并量化为协议定点格式。

# 坐标变换以输出图为起点寻找输入采样位置；采用逆矩阵而非把输入正向撒点。
def coefficients(angle, scale=1.0, tx=0.0, ty=0.0, cx=959.5, cy=539.5):
    if not math.isfinite(scale) or scale <= 0: raise ValueError('scale must be positive')
    if not all(math.isfinite(v) for v in [angle, tx, ty, cx, cy]): raise ValueError('nonfinite parameter')
    # Visual image rotation in screen coordinates; inverse map R(-angle)/scale.
    t = math.radians(angle);
    a = math.cos(t) / scale;
    b = math.sin(t) / scale;
    d = -b;
    e = a
    c = cx - a * (cx + tx) - b * (cy + ty);
    f = cy - d * (cx + tx) - e * (cy + ty)
    values = [round(a * 65536), round(b * 65536), round(c * 4096), round(d * 65536), round(e * 65536), round(f * 4096)]
    if any(not -2 ** 31 <= v < 2 ** 31 for v in values): raise ValueError('coefficient overflow')
    return dict(zip(['a_q16', 'b_q16', 'c_q12', 'd_q16', 'e_q16', 'f_q12'], values))


# 入口分支：依据命令行/运行条件选择对应执行路径。
if __name__ == '__main__':
    p = argparse.ArgumentParser();
    p.add_argument('--angle', type=float, default=0);
    p.add_argument('--scale', type=float, default=1);
    p.add_argument('--tx', type=float, default=0);
    p.add_argument('--ty', type=float, default=0);
    p.add_argument('--output', type=Path);
    args = p.parse_args()
    r = {'angle_degrees': args.angle, 'scale': args.scale, 'translation_pixels': [args.tx, args.ty],
         'inverse_matrix': coefficients(args.angle, args.scale, args.tx, args.ty),
         'status': 'coefficient generation only; not sent to FPGA'}
    text = json.dumps(r, indent=2);
    print(text)
    if args.output: args.output.write_text(text, encoding='utf8')
