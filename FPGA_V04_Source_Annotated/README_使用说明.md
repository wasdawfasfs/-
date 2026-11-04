## 直接运行与上板测试

1. 板卡供电，电脑HDMI接板卡HDMI-IN，HDMI-OUT接显示器二；USB串口、下载器和相机保持连接至上位机。
2. 双击 cmd\_set\\Download\_V04.cmd，下载本目录 fpga\_project\\generate\_bitstream\\newddr3\_top.sbit。它是原版F136位流，断电后需要重下；只写SRAM，不写Flash。
3. 双击 cmd\_set\\Launch\_V04.cmd 打开完整演示。
4. 新参数全视野为mode13，指定裁剪为mode14，动态仿射为mode15。选择自动/手动/旁路后点击应用Gamma。
5. 可用原始画面、新参数全视野、新参数裁剪、动态旋转/缩放/平移、Gamma旁路/自动/手动、暂停导出/恢复视频逐项进行人工验收。

## 在 Python IDE 中运行

解释器选择本目录 runtime\\python.exe（Python3.12，含匹配的二进制依赖），入口选择 launch\_camera.py。工作目录可以设本目录。
默认以Camera输入启动UI；不要直接用另一版本Python解释器运行，cv2/pygame等扩展的ABI可能不同。
启动器会把 packages、app、app\\dependencies 加入模块搜索路径。
IDE参数可填 --entry demo --mode Camera --autostart。

## 在 PDS 中打开

双击 cmd\_set\\Open\_PDS.cmd，或直接打开 fpga\_project\\v04\_source.pds。
器件 PG2L100H-6FBG676；顶层 newddr3\_top。
从Compile开始可重新构建；本次已经通过Compile和Synthesize。布局布线和新位流生成未重跑。


## 目录用途

* app：主机采集/视频输出、串口协议与控制；不是在CPU上逐像素矫正。
* scripts：实际启动链必须的HDMI全范围设置和JTAG下载脚本。
* fpga\_project：RTL、HDMI控制、厂商IP、约束、初始化数据、完整PDS及V04位流。
* parameters：新参数来源、常数与径向LUT；保留原文件及来源身份。
* runtime、packages、app\\dependencies：Python解释器和第三方依赖，保留其许可证与发行文件。
* tools\\programmer：运行下载所需的厂商工具、器件库和驱动；不代表包含完整PDS编译器。
* tests\\sharpness\_comparison\\original\_input.png：Reference输入模式必需的默认图，保留一张，不含历史拍摄集。
* cmd\_set：下载、演示、动态、Gamma、打开工程/位流目录及HDMI范围设置入口。
* docs：结构、注释边界、文件保留清单、校验结果及综合摘要；

## 验证和限制

软件自测PASS；PDS编译及综合PASS；11个应用模块Python AST与原版一致；保留Verilog的非注释内容一致；依赖和参数文件字节一致；原包10469文件校验一致。
V04位流SHA256：fa7ac36afc43f40abc1403d369670bafc64008955a5613905d8e2f5a07bf9153。
厂商FIFO IP有原有FBG484元数据与项目FBG676不同的警告；原有输入时序约束警告也仍保留。此次没有生成新IP、放宽时钟或添加false-path来掩盖警告。综合通过不等于重新完成布局布线时序验收。
V04仍有原来的画质限制，不能因整理代码宣称自适应画质提高或30fps验收通过。
运行时会重新生成锁、状态、导出PNG/JSON、下载日志和PDS构建目录，这是正常运行产物；

