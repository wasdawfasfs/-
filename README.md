# pds-
本作品基于紫光同创 Logos2 PG2L100H-6FBG676，实现 1920×1080 视频的镜头畸变矫正、指定窗口裁剪、动态仿射与自适应预处理，并提供主机冻结与板端串口整帧导出。系统以 rational 定点镜头映射、4 个 tile worker 并行取样、DDR3 三源槽/三结果槽帧管理构成几何主线：镜头模型经 25 视角、1925 角点标定，重投影 RMS 0.3834 像素；硬件以 Q8 主点、Q16 轴向半径权重、862 项 Q15 径向表与Q32 切向项完成逐像素逆映射，再以四邻域双线性重采样输出；整幅画面按 256×32 条带划分、32×32 输出块流水推进。输入侧集成近黑保护、有界公共 RGB 增量与相邻亮度曲线 1/16 步渐变的自适应增强。


## 项目文件与运行入口

完整项目位于 [`FPGA_V04_Source_Annotated`](FPGA_V04_Source_Annotated)，运行说明见 [README_使用说明.md](FPGA_V04_Source_Annotated/README_使用说明.md)。

- Python 入口：`FPGA_V04_Source_Annotated/launch_camera.py`；源码在 `app/`。
- PDS 工程：`FPGA_V04_Source_Annotated/fpga_project/v04_source.pds`。
- 原目录中的位流备份：`FPGA_V04_Source_Annotated/fpga_project/generate_bitstream/bak/newddr3_top.sbit`。当前原目录缺少启动脚本默认引用的 `generate_bitstream/newddr3_top.sbit`；这里按原目录现状保留，未擅自用备份替换默认位流。
- Windows 启动与下载脚本：`FPGA_V04_Source_Annotated/cmd_set/`。
- 随包保留 Python runtime、第三方依赖及下载工具；使用前请阅读其中的许可证。

上传副本排除了本机虚拟环境、IDE缓存、PDS中间构建数据库、锁文件和运行日志；项目源码、参数与已有位流未改写。实际运行仍需兼容的 Windows、FPGA板卡、相机、HDMI链路及设备驱动；PDS重新编译需要本机安装PDS及相应许可。

项目包含运行依赖，推荐用 Git 克隆或下载 ZIP 后解压整个目录，不要只下载单个启动脚本。

