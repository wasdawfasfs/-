# 以本目录为根安装项目模块搜索路径，转入主程序；支持 IDE 直接运行。

from pathlib import Path
import sys,runpy
ROOT=Path(__file__).resolve().parent
sys.path[:0]=[str(ROOT/'packages'),str(ROOT/'app'),str(ROOT/'app/dependencies')]
sys.argv=[str(ROOT/'app/camera_hdmi.py'),'--mode','Camera',*sys.argv[1:]]
runpy.run_path(sys.argv[0],run_name='__main__')
