// 由 make_fpga_params.py 自动生成，请勿手改
// 源: calib_result.json   RMS=0.3834px
// 模型: OpenCV pinhole + rational(k1..k6) + tangential(p1,p2)
// 图像: 1920x1080

localparam integer IMG_W = 1920;
localparam integer IMG_H = 1080;

// 主点，Q8（1/256 像素）
localparam signed [23:0] CX_Q8 = 24'sd241184;
localparam signed [23:0] CY_Q8 = 24'sd134513;

// 椭圆归一化系数 G=(fx/fy)^2, Q16
localparam [31:0] G_Q16 = 32'd65324;

// 径向 LUT: 512 项, 步进 4096 px^2, Q15
// 索引 = rp2 >> 20   (rp2 = dx²+G·dy², Q8)
// 插值小数 = rp2 的低 20 位

// 切向修正二次型系数, Q32（Q24 太粗，与像素乘积后会截断为 0）
localparam signed [63:0] A1_Q32 = 64'sd1367;  // 3.183877e-07  (dx*dy 项)
localparam signed [63:0] A2_Q32 = 64'sd721;  // 1.678148e-07  (dx*dx 项)
localparam signed [63:0] A3_Q32 = 64'sd239;  // 5.575761e-08  (dy*dy 项)
localparam signed [63:0] B1_Q32 = 64'sd481;  // 1.118765e-07  (dx*dy 项)
localparam signed [63:0] B2_Q32 = 64'sd686;  // 1.597096e-07  (dx*dx 项)
localparam signed [63:0] B3_Q32 = 64'sd2051;  // 4.775816e-07  (dy*dy 项)

// 计算式（全定点，移位即缩放；注意切向项用的是**整数像素** dxp/dyp）
//   dx  = (X<<8) - CX_Q8 ;  dy  = (Y<<8) - CY_Q8      // Q8 像素
//   dxp = dx >> 8        ;  dyp = dy >> 8              // 整数像素
//   rp2 = ((dx*dx)>>8) + ((G_Q16*((dy*dy)>>8))>>16)    // Q8, 单位 px^2
//   idx = rp2 >> 20 ;  frac = rp2 & 1048575
//   s   = LUT[idx] + (((LUT[idx+1]-LUT[idx])*frac) >> 20)  // Q15
//   Xs  = CX_Q8 + ((dx*s)>>15)
//               + ((A1_Q32*dxp*dyp)>>24) + ((A2_Q32*dxp*dxp)>>24)
//               + ((A3_Q32*dyp*dyp)>>24)
//   Ys  = CY_Q8 + ((dy*s)>>15)
//               + ((B1_Q32*dxp*dyp)>>24) + ((B2_Q32*dxp*dxp)>>24)
//               + ((B3_Q32*dyp*dyp)>>24)
