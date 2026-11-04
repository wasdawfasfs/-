// 输出像素逆映射：选择基准矩阵、仿射变换、镜头映射和有效掩码；新参数使用 rational LUT，不是旧二阶模型。

// 输出理想像素坐标 → 逆仿射 → 镜头畸变采样映射。
// 变换后坐标越界无效时输出-1像素哨兵值，保持valid握手信号有效。
// 配置参数必须保持固定，直到该任务全部坐标处理完毕。

module affine_warp_coordinates_core(input clk,rst_n,input in_valid,input[11:0] u,v,
 input[191:0] matrix,output out_valid,output signed[31:0] xs_q12,ys_q12,input[3:0] view_mode);
// V01版本：9/10/11为固定全景模式；12代表镜头参数不变，但裁剪矩阵已在底层固化（指定中心裁剪）。
// 裁剪矩阵由全景矩阵通过等比例缩放加偏移得到：
 //   s=H/1080=0.64537037 (H=697), W=H*16/9=1239.1111, x0=894-W/2=274.4444
 //   a=e=round(112456*s)=72576 ; c=round(7028.5*(x0+s/2))-2444045=-512844
 //   f=round(7028.5*(189+s/2))-1581793=-251139   (top row 189, bottom 886)
 wire full_view=(view_mode==9)||(view_mode==10)||(view_mode==11)||(view_mode==12);
 wire crop_view=(view_mode==12);
 wire mode13=(view_mode==13);  
 wire mode14=(view_mode==14);  
 wire mode15=(view_mode==15); 
 wire wire_new=(mode13||mode14||mode15);
 wire[191:0] m_full={32'sd107131,32'sd0,-32'sd2236773,32'sd0,32'sd107305,-32'sd1521547};
 wire[191:0] m_crop={32'sd78067,32'sd0,-32'sd1076379,32'sd0,32'sd78193,-32'sd389051};
 wire[191:0] selected_matrix = mode15 ? matrix : mode13 ? m_full : (mode14 ? m_crop :
  (crop_view?{32'sd72576,32'sd0,-32'sd512844,32'sd0,32'sd72576,-32'sd251139}:
  (full_view?{32'sd112456,32'sd0,-32'sd2444045,32'sd0,32'sd112456,-32'sd1581793}:matrix)));

 wire av,overflow;wire signed[31:0] ax,ay;wire signed[23:0] sx,sy;wire ov1;
 affine_map affine(clk,rst_n,in_valid,$signed({u,12'b0}),$signed({v,12'b0}),
  selected_matrix[191:160],selected_matrix[159:128],selected_matrix[127:96],selected_matrix[95:64],selected_matrix[63:32],selected_matrix[31:0],av,overflow,ax,ay);
 wire loose_ok=full_view||wire_new;

 wire ideal_ok=!overflow&&(loose_ok?(ax>=-32'sd8388608&&ax<32'sd16777216&&ay>=-32'sd8388608&&ay<32'sd16777216):(ax>=0&&ay>=0&&ax<1920*4096&&ay<1080*4096));
 reg[11:0] new_mask;

 always @(posedge clk)if(!rst_n)new_mask<=0;else new_mask<={new_mask[10:0],ideal_ok};
 reg[7:0] mask;

 always @(posedge clk)if(!rst_n)mask<=0;else mask<={mask[6:0],ideal_ok};
 affine_dist_calc_q12 #(.XW(25),.AW(10),.PW(36)) lens(
 .clk(clk),.rst_n(rst_n),.cx_q(full_view?24'sd3958170:24'sd3772163),.cy_q(full_view?24'sd2271838:24'sd2183633),.p1q(full_view?-16'sd1501:-16'sd276),.p2q(full_view?-16'sd8147:16'sd883),
 .lut_we(1'b0),.lut_addr(10'd0),.lut_wdata(18'sd0),
 .u(ax[24:0]),.v(ay[24:0]),.in_valid(av),.full_view(full_view),.xs_q(sx),.ys_q(sy),.out_valid(ov1));
 wire ov2;wire signed[23:0] sx2,sy2;
 v02_lens_rat lens2(.clk(clk),.rst_n(rst_n),.in_valid(av),.ax_q12(ax[24:0]),.ay_q12(ay[24:0]),.out_valid(ov2),.xs_q(sx2),.ys_q(sy2));
 // out_valid 
 assign out_valid=wire_new?ov2:ov1;
 wire signed[23:0] sxf=wire_new?sx2:sx;wire signed[23:0] syf=wire_new?sy2:sy;
 // xs_q12 
 assign xs_q12=(wire_new?new_mask[11]:mask[7])?{{8{sxf[23]}},sxf}:-32'sd4096;
 // ys_q12 
 assign ys_q12=(wire_new?new_mask[11]:mask[7])?{{8{syf[23]}},syf}:-32'sd4096;
endmodule

// 0 raw; 1 corrected BL; 2 raw/BL; 3 corrected NN; 4 corrected NN/BL;
// 5 half-pixel NN; 6 half-pixel BL; 7 half-pixel NN/BL (without lens/affine).

module affine_warp_coordinates(input clk,rst_n,input in_valid,input[11:0] u,v,
 input[191:0] matrix,output reg out_valid,output reg signed[31:0] xs_q12,ys_q12,input[3:0] view_mode);
 reg[11:0] mx,my;reg[1:0] kind;reg nearest;
 wire dual=(view_mode==2||view_mode==4||view_mode==7||view_mode==11);

 always @*begin
  mx=u;my=v;kind=1;nearest=0;
  if(dual)begin mx=(u<960)?(u<<1):((u-12'd960)<<1);my=(v-12'd270)<<1;end

  case(view_mode)
   0:kind=0;
   2:kind=(u<960)?0:1;
   3:nearest=1;
   4:nearest=(u<960);
   5:begin kind=3;nearest=1;end
   6:kind=3;
   7:begin kind=3;nearest=(u<960);end
   10:nearest=1;
   11:nearest=(u<960);
   default:begin end
  endcase
  if(dual&&(v<270||v>=810))begin kind=2;mx=0;my=0;end
 end
 reg[26:0] tags[0:31];reg[4:0] wr,rd;
 wire[26:0] tag=tags[rd];
 wire old_cv,full_cv;wire signed[31:0] old_x,old_y,full_x,full_y;
 wire cv=(view_mode==8)?full_cv:old_cv;
 wire signed[31:0] cx=(view_mode==8)?full_x:old_x;
 wire signed[31:0] cy=(view_mode==8)?full_y:old_y;
 calibrated_fisheye_fullview calibrated(clk,rst_n,in_valid,mx,my,full_cv,full_x,full_y);
 affine_warp_coordinates_core core(clk,rst_n,in_valid,mx,my,matrix,old_cv,old_x,old_y,view_mode);

 always @(posedge clk)begin
  if(!rst_n)begin wr<=0;rd<=0;end
  else begin
   if(in_valid)begin tags[wr]<={kind,nearest,mx,my};wr<=wr+1'b1;end
   if(cv)rd<=rd+1'b1;
  end
 end
 wire signed[31:0] direct_x=$signed({8'd0,tag[23:12],12'd0});
 wire signed[31:0] direct_y=$signed({8'd0,tag[11:0],12'd0});
 wire signed[31:0] rawx=(tag[26:25]==1)?cx:(tag[26:25]==3)?direct_x+32'sd2048:direct_x;
 wire signed[31:0] rawy=(tag[26:25]==1)?cy:(tag[26:25]==3)?direct_y+32'sd2048:direct_y;

 wire world_valid=rawx>=0&&rawy>=0&&rawx<1920*4096&&rawy<1080*4096;
 wire signed[31:0] round_x=(rawx+32'sd2048)>>>12,round_y=(rawy+32'sd2048)>>>12;
 wire signed[31:0] near_x=(round_x>1919)?32'sd7860224:(round_x<<<12);
 wire signed[31:0] near_y=(round_y>1079)?32'sd4419584:(round_y<<<12);

 always @(posedge clk)begin
  if(!rst_n)begin out_valid<=0;xs_q12<=0;ys_q12<=0;end
  else begin out_valid<=cv;
   xs_q12<=(tag[26:25]==2||!world_valid)?-32'sd4096:tag[24]?near_x:rawx;
   ys_q12<=(tag[26:25]==2||!world_valid)?-32'sd4096:tag[24]?near_y:rawy;
  end
 end
endmodule





// ============================================================================
// V02有理镜头畸变模块（B通路）：理想坐标Q12 → 源坐标Q12，采用VH整数运算。
// CX、CY为Q8格式，G为Q16椭圆半径；862项Q15查找表，步长4096像素平方；
// 索引 idx = rp2>>20，小数部分取低20位；A1~B3为Q32切向系数（单位整数像素）；
// 有符号乘法与算术右移；idx>860判定无效；新版有理镜头为11级寄存器流水线，输入输出边沿相差10；旧版本逻辑保持不变。
// ============================================================================
// ============================================================================
// V02有理镜头畸变：11级寄存器流水线，输入输出边沿差10，new_mask延迟10拍。
// CX/CY Q8、G_Q16，862点Q15 LUT（步长4096 px²），idx=rp2>>20，
// frac取低20位；A1~B3 Q32切向系数，单位整数像素，有符号移位；
// idx>860时判定无效（哨兵值-16.0像素，不回卷、不静默限幅）。
// ============================================================================

module v02_lens_rat(input clk,rst_n,input in_valid,
 input signed[24:0] ax_q12,ay_q12,output reg out_valid,
 output reg signed[23:0] xs_q,ys_q);
  reg [15:0] lut [0:861];
  // 初始化块：ROM/初态定义；综合工具对初始化的支持须依原工程处理。
  initial begin
  lut[0]=16'h8000; lut[1]=16'h7FB7; lut[2]=16'h7F70; lut[3]=16'h7F28; lut[4]=16'h7EE2; lut[5]=16'h7E9B; lut[6]=16'h7E56; lut[7]=16'h7E11;
  lut[8]=16'h7DCC; lut[9]=16'h7D89; lut[10]=16'h7D45; lut[11]=16'h7D02; lut[12]=16'h7CC0; lut[13]=16'h7C7E; lut[14]=16'h7C3D; lut[15]=16'h7BFC;
  lut[16]=16'h7BBC; lut[17]=16'h7B7C; lut[18]=16'h7B3D; lut[19]=16'h7AFE; lut[20]=16'h7ABF; lut[21]=16'h7A81; lut[22]=16'h7A44; lut[23]=16'h7A07;
  lut[24]=16'h79CA; lut[25]=16'h798E; lut[26]=16'h7952; lut[27]=16'h7917; lut[28]=16'h78DC; lut[29]=16'h78A1; lut[30]=16'h7867; lut[31]=16'h782D;
  lut[32]=16'h77F4; lut[33]=16'h77BB; lut[34]=16'h7782; lut[35]=16'h774A; lut[36]=16'h7712; lut[37]=16'h76DA; lut[38]=16'h76A3; lut[39]=16'h766C;
  lut[40]=16'h7636; lut[41]=16'h75FF; lut[42]=16'h75CA; lut[43]=16'h7594; lut[44]=16'h755F; lut[45]=16'h752A; lut[46]=16'h74F6; lut[47]=16'h74C1;
  lut[48]=16'h748D; lut[49]=16'h745A; lut[50]=16'h7427; lut[51]=16'h73F4; lut[52]=16'h73C1; lut[53]=16'h738F; lut[54]=16'h735D; lut[55]=16'h732B;
  lut[56]=16'h72F9; lut[57]=16'h72C8; lut[58]=16'h7297; lut[59]=16'h7267; lut[60]=16'h7236; lut[61]=16'h7206; lut[62]=16'h71D6; lut[63]=16'h71A7;
  lut[64]=16'h7178; lut[65]=16'h7149; lut[66]=16'h711A; lut[67]=16'h70EB; lut[68]=16'h70BD; lut[69]=16'h708F; lut[70]=16'h7061; lut[71]=16'h7034;
  lut[72]=16'h7007; lut[73]=16'h6FDA; lut[74]=16'h6FAD; lut[75]=16'h6F80; lut[76]=16'h6F54; lut[77]=16'h6F28; lut[78]=16'h6EFC; lut[79]=16'h6ED0;
  lut[80]=16'h6EA5; lut[81]=16'h6E7A; lut[82]=16'h6E4F; lut[83]=16'h6E24; lut[84]=16'h6DFA; lut[85]=16'h6DCF; lut[86]=16'h6DA5; lut[87]=16'h6D7C;
  lut[88]=16'h6D52; lut[89]=16'h6D28; lut[90]=16'h6CFF; lut[91]=16'h6CD6; lut[92]=16'h6CAD; lut[93]=16'h6C85; lut[94]=16'h6C5C; lut[95]=16'h6C34;
  lut[96]=16'h6C0C; lut[97]=16'h6BE4; lut[98]=16'h6BBC; lut[99]=16'h6B95; lut[100]=16'h6B6E; lut[101]=16'h6B47; lut[102]=16'h6B20; lut[103]=16'h6AF9;
  lut[104]=16'h6AD3; lut[105]=16'h6AAC; lut[106]=16'h6A86; lut[107]=16'h6A60; lut[108]=16'h6A3A; lut[109]=16'h6A15; lut[110]=16'h69EF; lut[111]=16'h69CA;
  lut[112]=16'h69A5; lut[113]=16'h6980; lut[114]=16'h695B; lut[115]=16'h6936; lut[116]=16'h6912; lut[117]=16'h68ED; lut[118]=16'h68C9; lut[119]=16'h68A5;
  lut[120]=16'h6882; lut[121]=16'h685E; lut[122]=16'h683A; lut[123]=16'h6817; lut[124]=16'h67F4; lut[125]=16'h67D1; lut[126]=16'h67AE; lut[127]=16'h678B;
  lut[128]=16'h6769; lut[129]=16'h6746; lut[130]=16'h6724; lut[131]=16'h6702; lut[132]=16'h66E0; lut[133]=16'h66BE; lut[134]=16'h669C; lut[135]=16'h667B;
  lut[136]=16'h6659; lut[137]=16'h6638; lut[138]=16'h6617; lut[139]=16'h65F6; lut[140]=16'h65D5; lut[141]=16'h65B4; lut[142]=16'h6594; lut[143]=16'h6573;
  lut[144]=16'h6553; lut[145]=16'h6533; lut[146]=16'h6513; lut[147]=16'h64F3; lut[148]=16'h64D3; lut[149]=16'h64B3; lut[150]=16'h6494; lut[151]=16'h6474;
  lut[152]=16'h6455; lut[153]=16'h6436; lut[154]=16'h6417; lut[155]=16'h63F8; lut[156]=16'h63D9; lut[157]=16'h63BB; lut[158]=16'h639C; lut[159]=16'h637E;
  lut[160]=16'h635F; lut[161]=16'h6341; lut[162]=16'h6323; lut[163]=16'h6305; lut[164]=16'h62E7; lut[165]=16'h62C9; lut[166]=16'h62AC; lut[167]=16'h628E;
  lut[168]=16'h6271; lut[169]=16'h6254; lut[170]=16'h6237; lut[171]=16'h621A; lut[172]=16'h61FD; lut[173]=16'h61E0; lut[174]=16'h61C3; lut[175]=16'h61A6;
  lut[176]=16'h618A; lut[177]=16'h616E; lut[178]=16'h6151; lut[179]=16'h6135; lut[180]=16'h6119; lut[181]=16'h60FD; lut[182]=16'h60E1; lut[183]=16'h60C5;
  lut[184]=16'h60AA; lut[185]=16'h608E; lut[186]=16'h6073; lut[187]=16'h6057; lut[188]=16'h603C; lut[189]=16'h6021; lut[190]=16'h6006; lut[191]=16'h5FEB;
  lut[192]=16'h5FD0; lut[193]=16'h5FB5; lut[194]=16'h5F9A; lut[195]=16'h5F80; lut[196]=16'h5F65; lut[197]=16'h5F4B; lut[198]=16'h5F31; lut[199]=16'h5F16;
  lut[200]=16'h5EFC; lut[201]=16'h5EE2; lut[202]=16'h5EC8; lut[203]=16'h5EAE; lut[204]=16'h5E95; lut[205]=16'h5E7B; lut[206]=16'h5E61; lut[207]=16'h5E48;
  lut[208]=16'h5E2F; lut[209]=16'h5E15; lut[210]=16'h5DFC; lut[211]=16'h5DE3; lut[212]=16'h5DCA; lut[213]=16'h5DB1; lut[214]=16'h5D98; lut[215]=16'h5D7F;
  lut[216]=16'h5D66; lut[217]=16'h5D4E; lut[218]=16'h5D35; lut[219]=16'h5D1D; lut[220]=16'h5D04; lut[221]=16'h5CEC; lut[222]=16'h5CD4; lut[223]=16'h5CBC;
  lut[224]=16'h5CA4; lut[225]=16'h5C8C; lut[226]=16'h5C74; lut[227]=16'h5C5C; lut[228]=16'h5C44; lut[229]=16'h5C2C; lut[230]=16'h5C15; lut[231]=16'h5BFD;
  lut[232]=16'h5BE6; lut[233]=16'h5BCF; lut[234]=16'h5BB7; lut[235]=16'h5BA0; lut[236]=16'h5B89; lut[237]=16'h5B72; lut[238]=16'h5B5B; lut[239]=16'h5B44;
  lut[240]=16'h5B2D; lut[241]=16'h5B16; lut[242]=16'h5B00; lut[243]=16'h5AE9; lut[244]=16'h5AD2; lut[245]=16'h5ABC; lut[246]=16'h5AA5; lut[247]=16'h5A8F;
  lut[248]=16'h5A79; lut[249]=16'h5A63; lut[250]=16'h5A4D; lut[251]=16'h5A36; lut[252]=16'h5A20; lut[253]=16'h5A0B; lut[254]=16'h59F5; lut[255]=16'h59DF;
  lut[256]=16'h59C9; lut[257]=16'h59B3; lut[258]=16'h599E; lut[259]=16'h5988; lut[260]=16'h5973; lut[261]=16'h595D; lut[262]=16'h5948; lut[263]=16'h5933;
  lut[264]=16'h591E; lut[265]=16'h5909; lut[266]=16'h58F3; lut[267]=16'h58DE; lut[268]=16'h58C9; lut[269]=16'h58B5; lut[270]=16'h58A0; lut[271]=16'h588B;
  lut[272]=16'h5876; lut[273]=16'h5862; lut[274]=16'h584D; lut[275]=16'h5839; lut[276]=16'h5824; lut[277]=16'h5810; lut[278]=16'h57FB; lut[279]=16'h57E7;
  lut[280]=16'h57D3; lut[281]=16'h57BF; lut[282]=16'h57AB; lut[283]=16'h5797; lut[284]=16'h5783; lut[285]=16'h576F; lut[286]=16'h575B; lut[287]=16'h5747;
  lut[288]=16'h5733; lut[289]=16'h571F; lut[290]=16'h570C; lut[291]=16'h56F8; lut[292]=16'h56E5; lut[293]=16'h56D1; lut[294]=16'h56BE; lut[295]=16'h56AA;
  lut[296]=16'h5697; lut[297]=16'h5684; lut[298]=16'h5671; lut[299]=16'h565E; lut[300]=16'h564A; lut[301]=16'h5637; lut[302]=16'h5624; lut[303]=16'h5611;
  lut[304]=16'h55FF; lut[305]=16'h55EC; lut[306]=16'h55D9; lut[307]=16'h55C6; lut[308]=16'h55B4; lut[309]=16'h55A1; lut[310]=16'h558E; lut[311]=16'h557C;
  lut[312]=16'h5569; lut[313]=16'h5557; lut[314]=16'h5545; lut[315]=16'h5532; lut[316]=16'h5520; lut[317]=16'h550E; lut[318]=16'h54FC; lut[319]=16'h54E9;
  lut[320]=16'h54D7; lut[321]=16'h54C5; lut[322]=16'h54B3; lut[323]=16'h54A1; lut[324]=16'h5490; lut[325]=16'h547E; lut[326]=16'h546C; lut[327]=16'h545A;
  lut[328]=16'h5448; lut[329]=16'h5437; lut[330]=16'h5425; lut[331]=16'h5414; lut[332]=16'h5402; lut[333]=16'h53F1; lut[334]=16'h53DF; lut[335]=16'h53CE;
  lut[336]=16'h53BD; lut[337]=16'h53AB; lut[338]=16'h539A; lut[339]=16'h5389; lut[340]=16'h5378; lut[341]=16'h5367; lut[342]=16'h5356; lut[343]=16'h5345;
  lut[344]=16'h5334; lut[345]=16'h5323; lut[346]=16'h5312; lut[347]=16'h5301; lut[348]=16'h52F0; lut[349]=16'h52DF; lut[350]=16'h52CF; lut[351]=16'h52BE;
  lut[352]=16'h52AD; lut[353]=16'h529D; lut[354]=16'h528C; lut[355]=16'h527C; lut[356]=16'h526B; lut[357]=16'h525B; lut[358]=16'h524B; lut[359]=16'h523A;
  lut[360]=16'h522A; lut[361]=16'h521A; lut[362]=16'h5209; lut[363]=16'h51F9; lut[364]=16'h51E9; lut[365]=16'h51D9; lut[366]=16'h51C9; lut[367]=16'h51B9;
  lut[368]=16'h51A9; lut[369]=16'h5199; lut[370]=16'h5189; lut[371]=16'h5179; lut[372]=16'h516A; lut[373]=16'h515A; lut[374]=16'h514A; lut[375]=16'h513A;
  lut[376]=16'h512B; lut[377]=16'h511B; lut[378]=16'h510B; lut[379]=16'h50FC; lut[380]=16'h50EC; lut[381]=16'h50DD; lut[382]=16'h50CD; lut[383]=16'h50BE;
  lut[384]=16'h50AF; lut[385]=16'h509F; lut[386]=16'h5090; lut[387]=16'h5081; lut[388]=16'h5072; lut[389]=16'h5062; lut[390]=16'h5053; lut[391]=16'h5044;
  lut[392]=16'h5035; lut[393]=16'h5026; lut[394]=16'h5017; lut[395]=16'h5008; lut[396]=16'h4FF9; lut[397]=16'h4FEA; lut[398]=16'h4FDB; lut[399]=16'h4FCD;
  lut[400]=16'h4FBE; lut[401]=16'h4FAF; lut[402]=16'h4FA0; lut[403]=16'h4F92; lut[404]=16'h4F83; lut[405]=16'h4F74; lut[406]=16'h4F66; lut[407]=16'h4F57;
  lut[408]=16'h4F49; lut[409]=16'h4F3A; lut[410]=16'h4F2C; lut[411]=16'h4F1D; lut[412]=16'h4F0F; lut[413]=16'h4F01; lut[414]=16'h4EF2; lut[415]=16'h4EE4;
  lut[416]=16'h4ED6; lut[417]=16'h4EC7; lut[418]=16'h4EB9; lut[419]=16'h4EAB; lut[420]=16'h4E9D; lut[421]=16'h4E8F; lut[422]=16'h4E81; lut[423]=16'h4E73;
  lut[424]=16'h4E65; lut[425]=16'h4E57; lut[426]=16'h4E49; lut[427]=16'h4E3B; lut[428]=16'h4E2D; lut[429]=16'h4E1F; lut[430]=16'h4E11; lut[431]=16'h4E04;
  lut[432]=16'h4DF6; lut[433]=16'h4DE8; lut[434]=16'h4DDA; lut[435]=16'h4DCD; lut[436]=16'h4DBF; lut[437]=16'h4DB1; lut[438]=16'h4DA4; lut[439]=16'h4D96;
  lut[440]=16'h4D89; lut[441]=16'h4D7B; lut[442]=16'h4D6E; lut[443]=16'h4D60; lut[444]=16'h4D53; lut[445]=16'h4D46; lut[446]=16'h4D38; lut[447]=16'h4D2B;
  lut[448]=16'h4D1E; lut[449]=16'h4D11; lut[450]=16'h4D03; lut[451]=16'h4CF6; lut[452]=16'h4CE9; lut[453]=16'h4CDC; lut[454]=16'h4CCF; lut[455]=16'h4CC2;
  lut[456]=16'h4CB5; lut[457]=16'h4CA7; lut[458]=16'h4C9A; lut[459]=16'h4C8D; lut[460]=16'h4C81; lut[461]=16'h4C74; lut[462]=16'h4C67; lut[463]=16'h4C5A;
  lut[464]=16'h4C4D; lut[465]=16'h4C40; lut[466]=16'h4C33; lut[467]=16'h4C27; lut[468]=16'h4C1A; lut[469]=16'h4C0D; lut[470]=16'h4C01; lut[471]=16'h4BF4;
  lut[472]=16'h4BE7; lut[473]=16'h4BDB; lut[474]=16'h4BCE; lut[475]=16'h4BC2; lut[476]=16'h4BB5; lut[477]=16'h4BA9; lut[478]=16'h4B9C; lut[479]=16'h4B90;
  lut[480]=16'h4B83; lut[481]=16'h4B77; lut[482]=16'h4B6A; lut[483]=16'h4B5E; lut[484]=16'h4B52; lut[485]=16'h4B45; lut[486]=16'h4B39; lut[487]=16'h4B2D;
  lut[488]=16'h4B21; lut[489]=16'h4B15; lut[490]=16'h4B08; lut[491]=16'h4AFC; lut[492]=16'h4AF0; lut[493]=16'h4AE4; lut[494]=16'h4AD8; lut[495]=16'h4ACC;
  lut[496]=16'h4AC0; lut[497]=16'h4AB4; lut[498]=16'h4AA8; lut[499]=16'h4A9C; lut[500]=16'h4A90; lut[501]=16'h4A84; lut[502]=16'h4A78; lut[503]=16'h4A6C;
  lut[504]=16'h4A61; lut[505]=16'h4A55; lut[506]=16'h4A49; lut[507]=16'h4A3D; lut[508]=16'h4A31; lut[509]=16'h4A26; lut[510]=16'h4A1A; lut[511]=16'h4A0E;
  lut[512]=16'h4A03; lut[513]=16'h49F7; lut[514]=16'h49EB; lut[515]=16'h49E0; lut[516]=16'h49D4; lut[517]=16'h49C9; lut[518]=16'h49BD; lut[519]=16'h49B2;
  lut[520]=16'h49A6; lut[521]=16'h499B; lut[522]=16'h498F; lut[523]=16'h4984; lut[524]=16'h4979; lut[525]=16'h496D; lut[526]=16'h4962; lut[527]=16'h4957;
  lut[528]=16'h494B; lut[529]=16'h4940; lut[530]=16'h4935; lut[531]=16'h492A; lut[532]=16'h491E; lut[533]=16'h4913; lut[534]=16'h4908; lut[535]=16'h48FD;
  lut[536]=16'h48F2; lut[537]=16'h48E7; lut[538]=16'h48DC; lut[539]=16'h48D1; lut[540]=16'h48C6; lut[541]=16'h48BB; lut[542]=16'h48B0; lut[543]=16'h48A5;
  lut[544]=16'h489A; lut[545]=16'h488F; lut[546]=16'h4884; lut[547]=16'h4879; lut[548]=16'h486E; lut[549]=16'h4863; lut[550]=16'h4858; lut[551]=16'h484E;
  lut[552]=16'h4843; lut[553]=16'h4838; lut[554]=16'h482D; lut[555]=16'h4822; lut[556]=16'h4818; lut[557]=16'h480D; lut[558]=16'h4802; lut[559]=16'h47F8;
  lut[560]=16'h47ED; lut[561]=16'h47E3; lut[562]=16'h47D8; lut[563]=16'h47CD; lut[564]=16'h47C3; lut[565]=16'h47B8; lut[566]=16'h47AE; lut[567]=16'h47A3;
  lut[568]=16'h4799; lut[569]=16'h478E; lut[570]=16'h4784; lut[571]=16'h4779; lut[572]=16'h476F; lut[573]=16'h4765; lut[574]=16'h475A; lut[575]=16'h4750;
  lut[576]=16'h4746; lut[577]=16'h473B; lut[578]=16'h4731; lut[579]=16'h4727; lut[580]=16'h471C; lut[581]=16'h4712; lut[582]=16'h4708; lut[583]=16'h46FE;
  lut[584]=16'h46F4; lut[585]=16'h46E9; lut[586]=16'h46DF; lut[587]=16'h46D5; lut[588]=16'h46CB; lut[589]=16'h46C1; lut[590]=16'h46B7; lut[591]=16'h46AD;
  lut[592]=16'h46A3; lut[593]=16'h4699; lut[594]=16'h468F; lut[595]=16'h4685; lut[596]=16'h467B; lut[597]=16'h4671; lut[598]=16'h4667; lut[599]=16'h465D;
  lut[600]=16'h4653; lut[601]=16'h4649; lut[602]=16'h463F; lut[603]=16'h4636; lut[604]=16'h462C; lut[605]=16'h4622; lut[606]=16'h4618; lut[607]=16'h460E;
  lut[608]=16'h4605; lut[609]=16'h45FB; lut[610]=16'h45F1; lut[611]=16'h45E7; lut[612]=16'h45DE; lut[613]=16'h45D4; lut[614]=16'h45CA; lut[615]=16'h45C1;
  lut[616]=16'h45B7; lut[617]=16'h45AD; lut[618]=16'h45A4; lut[619]=16'h459A; lut[620]=16'h4591; lut[621]=16'h4587; lut[622]=16'h457E; lut[623]=16'h4574;
  lut[624]=16'h456B; lut[625]=16'h4561; lut[626]=16'h4558; lut[627]=16'h454E; lut[628]=16'h4545; lut[629]=16'h453B; lut[630]=16'h4532; lut[631]=16'h4529;
  lut[632]=16'h451F; lut[633]=16'h4516; lut[634]=16'h450D; lut[635]=16'h4503; lut[636]=16'h44FA; lut[637]=16'h44F1; lut[638]=16'h44E7; lut[639]=16'h44DE;
  lut[640]=16'h44D5; lut[641]=16'h44CC; lut[642]=16'h44C2; lut[643]=16'h44B9; lut[644]=16'h44B0; lut[645]=16'h44A7; lut[646]=16'h449E; lut[647]=16'h4494;
  lut[648]=16'h448B; lut[649]=16'h4482; lut[650]=16'h4479; lut[651]=16'h4470; lut[652]=16'h4467; lut[653]=16'h445E; lut[654]=16'h4455; lut[655]=16'h444C;
  lut[656]=16'h4443; lut[657]=16'h443A; lut[658]=16'h4431; lut[659]=16'h4428; lut[660]=16'h441F; lut[661]=16'h4416; lut[662]=16'h440D; lut[663]=16'h4404;
  lut[664]=16'h43FB; lut[665]=16'h43F2; lut[666]=16'h43EA; lut[667]=16'h43E1; lut[668]=16'h43D8; lut[669]=16'h43CF; lut[670]=16'h43C6; lut[671]=16'h43BE;
  lut[672]=16'h43B5; lut[673]=16'h43AC; lut[674]=16'h43A3; lut[675]=16'h439B; lut[676]=16'h4392; lut[677]=16'h4389; lut[678]=16'h4380; lut[679]=16'h4378;
  lut[680]=16'h436F; lut[681]=16'h4366; lut[682]=16'h435E; lut[683]=16'h4355; lut[684]=16'h434D; lut[685]=16'h4344; lut[686]=16'h433B; lut[687]=16'h4333;
  lut[688]=16'h432A; lut[689]=16'h4322; lut[690]=16'h4319; lut[691]=16'h4311; lut[692]=16'h4308; lut[693]=16'h4300; lut[694]=16'h42F7; lut[695]=16'h42EF;
  lut[696]=16'h42E6; lut[697]=16'h42DE; lut[698]=16'h42D5; lut[699]=16'h42CD; lut[700]=16'h42C5; lut[701]=16'h42BC; lut[702]=16'h42B4; lut[703]=16'h42AB;
  lut[704]=16'h42A3; lut[705]=16'h429B; lut[706]=16'h4292; lut[707]=16'h428A; lut[708]=16'h4282; lut[709]=16'h427A; lut[710]=16'h4271; lut[711]=16'h4269;
  lut[712]=16'h4261; lut[713]=16'h4259; lut[714]=16'h4250; lut[715]=16'h4248; lut[716]=16'h4240; lut[717]=16'h4238; lut[718]=16'h4230; lut[719]=16'h4227;
  lut[720]=16'h421F; lut[721]=16'h4217; lut[722]=16'h420F; lut[723]=16'h4207; lut[724]=16'h41FF; lut[725]=16'h41F7; lut[726]=16'h41EF; lut[727]=16'h41E7;
  lut[728]=16'h41DF; lut[729]=16'h41D7; lut[730]=16'h41CF; lut[731]=16'h41C6; lut[732]=16'h41BE; lut[733]=16'h41B7; lut[734]=16'h41AF; lut[735]=16'h41A7;
  lut[736]=16'h419F; lut[737]=16'h4197; lut[738]=16'h418F; lut[739]=16'h4187; lut[740]=16'h417F; lut[741]=16'h4177; lut[742]=16'h416F; lut[743]=16'h4167;
  lut[744]=16'h415F; lut[745]=16'h4158; lut[746]=16'h4150; lut[747]=16'h4148; lut[748]=16'h4140; lut[749]=16'h4138; lut[750]=16'h4131; lut[751]=16'h4129;
  lut[752]=16'h4121; lut[753]=16'h4119; lut[754]=16'h4112; lut[755]=16'h410A; lut[756]=16'h4102; lut[757]=16'h40FA; lut[758]=16'h40F3; lut[759]=16'h40EB;
  lut[760]=16'h40E3; lut[761]=16'h40DC; lut[762]=16'h40D4; lut[763]=16'h40CC; lut[764]=16'h40C5; lut[765]=16'h40BD; lut[766]=16'h40B5; lut[767]=16'h40AE;
  lut[768]=16'h40A6; lut[769]=16'h409F; lut[770]=16'h4097; lut[771]=16'h4090; lut[772]=16'h4088; lut[773]=16'h4081; lut[774]=16'h4079; lut[775]=16'h4071;
  lut[776]=16'h406A; lut[777]=16'h4063; lut[778]=16'h405B; lut[779]=16'h4054; lut[780]=16'h404C; lut[781]=16'h4045; lut[782]=16'h403D; lut[783]=16'h4036;
  lut[784]=16'h402E; lut[785]=16'h4027; lut[786]=16'h4020; lut[787]=16'h4018; lut[788]=16'h4011; lut[789]=16'h4009; lut[790]=16'h4002; lut[791]=16'h3FFB;
  lut[792]=16'h3FF3; lut[793]=16'h3FEC; lut[794]=16'h3FE5; lut[795]=16'h3FDE; lut[796]=16'h3FD6; lut[797]=16'h3FCF; lut[798]=16'h3FC8; lut[799]=16'h3FC0;
  lut[800]=16'h3FB9; lut[801]=16'h3FB2; lut[802]=16'h3FAB; lut[803]=16'h3FA3; lut[804]=16'h3F9C; lut[805]=16'h3F95; lut[806]=16'h3F8E; lut[807]=16'h3F87;
  lut[808]=16'h3F80; lut[809]=16'h3F78; lut[810]=16'h3F71; lut[811]=16'h3F6A; lut[812]=16'h3F63; lut[813]=16'h3F5C; lut[814]=16'h3F55; lut[815]=16'h3F4E;
  lut[816]=16'h3F47; lut[817]=16'h3F3F; lut[818]=16'h3F38; lut[819]=16'h3F31; lut[820]=16'h3F2A; lut[821]=16'h3F23; lut[822]=16'h3F1C; lut[823]=16'h3F15;
  lut[824]=16'h3F0E; lut[825]=16'h3F07; lut[826]=16'h3F00; lut[827]=16'h3EF9; lut[828]=16'h3EF2; lut[829]=16'h3EEB; lut[830]=16'h3EE4; lut[831]=16'h3EDD;
  lut[832]=16'h3ED6; lut[833]=16'h3ED0; lut[834]=16'h3EC9; lut[835]=16'h3EC2; lut[836]=16'h3EBB; lut[837]=16'h3EB4; lut[838]=16'h3EAD; lut[839]=16'h3EA6;
  lut[840]=16'h3E9F; lut[841]=16'h3E98; lut[842]=16'h3E92; lut[843]=16'h3E8B; lut[844]=16'h3E84; lut[845]=16'h3E7D; lut[846]=16'h3E76; lut[847]=16'h3E70;
  lut[848]=16'h3E69; lut[849]=16'h3E62; lut[850]=16'h3E5B; lut[851]=16'h3E54; lut[852]=16'h3E4E; lut[853]=16'h3E47; lut[854]=16'h3E40; lut[855]=16'h3E39;
  lut[856]=16'h3E33; lut[857]=16'h3E2C; lut[858]=16'h3E25; lut[859]=16'h3E1F; lut[860]=16'h3E18; lut[861]=16'h3E11;
  end

// 十一级寄存器流水线：常数2051移位加法拆分，ROM读取与插值通路相互隔离。

reg[10:0] valid_pipe;

always @(posedge clk)if(!rst_n)valid_pipe<=0;else valid_pipe<={valid_pipe[9:0],in_valid};

wire signed[31:0] ax32={{7{ax_q12[24]}},ax_q12},ay32={{7{ay_q12[24]}},ay_q12};
reg signed[21:0] dx0,dy0;

always @(posedge clk)begin dx0<=(ax32>>>4)-32'sd241184;dy0<=(ay32>>>4)-32'sd134513;end
wire signed[63:0] dx64=dx0,dy64=dy0;
wire signed[13:0] dxp64=dx0>>>8,dyp64=dy0>>>8;
wire signed[43:0] square_x=dx0*dx0,square_y=dy0*dy0;
reg[35:0] sx1,sy1;reg signed[27:0] xx1,xy1,yy1;reg signed[21:0] dx1,dy1;

always @(posedge clk)begin
 sx1<=square_x[43:8];sy1<=square_y[43:8];
 xx1<=dxp64*dxp64;xy1<=dxp64*dyp64;yy1<=dyp64*dyp64;
 dx1<=dx0;dy1<=dy0;
end
// 将平方DSP的输出与后续乘加DSP的输入进行隔离。
reg[35:0] sx1b,sy1b;reg signed[27:0] xx1b,xy1b,yy1b;reg signed[21:0] dx1b,dy1b;

always @(posedge clk)begin
 sx1b<=sx1;sy1b<=sy1;xx1b<=xx1;xy1b<=xy1;yy1b<=yy1;dx1b<=dx1;dy1b<=dy1;
end
reg[51:0] gyprod;reg[35:0] sx1c;reg signed[27:0] xx1c,xy1c,yy1c;reg signed[21:0] dx1c,dy1c;

always @(posedge clk)begin gyprod<=16'd65324*sy1b;sx1c<=sx1b;xx1c<=xx1b;xy1c<=xy1b;yy1c<=yy1b;dx1c<=dx1b;dy1c<=dy1b;end
wire[36:0] rwide={1'b0,sx1c}+{1'b0,gyprod[51:16]};
reg[9:0] idx2;reg dom2;reg[19:0] frac2;reg signed[21:0] dx2,dy2;
reg signed[39:0] ta2,tb2,tc2,td2,te2;
reg signed[39:0] tf2_hi,tf2_lo;

always @(posedge clk)begin
 idx2<=rwide[29:20];dom2<=(rwide[36:20]<17'd861);frac2<=rwide[19:0];dx2<=dx1c;dy2<=dy1c;
 ta2<=64'sd1367*xy1c;tb2<=64'sd721*xx1c;tc2<=64'sd239*yy1c;
 td2<=64'sd481*xy1c;te2<=64'sd686*xx1c;tf2_hi<=$signed({{12{yy1c[27]}},yy1c})<<<11;
 tf2_lo<=$signed({{12{yy1c[27]}},yy1c})+($signed({{12{yy1c[27]}},yy1c})<<<1);
end

// 额外增加一级进位合并寄存器；运算结果逐比特保持完全一致。
reg[9:0] idx2b;reg dom2b;reg[19:0] frac2b;reg signed[21:0] dx2b,dy2b;
reg signed[39:0] ta2b,tb2b,tc2b,td2b,te2b,tf2b;

always @(posedge clk)begin
 idx2b<=idx2;dom2b<=dom2;frac2b<=frac2;dx2b<=dx2;dy2b<=dy2;
 ta2b<=ta2;tb2b<=tb2;tc2b<=tc2;td2b<=td2;te2b<=te2;tf2b<=tf2_hi+tf2_lo;
end
wire[9:0] addr=dom2b?idx2b[9:0]:10'd0;
reg[15:0] base3,next3;
wire signed[16:0] delta3=$signed({1'b0,next3})-$signed({1'b0,base3});
reg[19:0] frac3;
reg signed[63:0] tx3,ty3;reg signed[21:0] dx3,dy3;reg dom3;

always @(posedge clk)begin
 base3<=lut[addr];next3<=lut[addr+10'd1];
 frac3<=frac2b;dx3<=dx2b;dy3<=dy2b;dom3<=dom2b;
 tx3<=(ta2b>>>24)+(tb2b>>>24)+(tc2b>>>24);ty3<=(td2b>>>24)+(te2b>>>24)+(tf2b>>>24);
end
reg signed[37:0] ip4;reg[15:0] base4;
reg signed[63:0] tx4,ty4;reg signed[21:0] dx4,dy4;reg dom4;

always @(posedge clk)begin
 ip4<=delta3*$signed({1'b0,frac3});base4<=base3;
 tx4<=tx3;ty4<=ty3;dx4<=dx3;dy4<=dy3;dom4<=dom3;
end
reg signed[17:0] scale5;reg signed[21:0] dx5,dy5;
reg signed[63:0] tx5,ty5;reg dom5;

always @(posedge clk)begin
 scale5<=$signed({2'b0,base4})+(ip4>>>20);
 dx5<=dx4;dy5<=dy4;tx5<=tx4;ty5<=ty4;dom5<=dom4;
end
reg signed[39:0] rx6,ry6;reg signed[63:0] tx6,ty6;reg dom6;

always @(posedge clk)begin
 rx6<=dx5*scale5;ry6<=dy5*scale5;tx6<=tx5;ty6<=ty5;dom6<=dom5;
end
reg signed[31:0] x7,y7;reg dom7;

always @(posedge clk)begin
 x7<=64'sd241184+(rx6>>>15)+tx6;y7<=64'sd134513+(ry6>>>15)+ty6;dom7<=dom6;
end
wire ok=dom7&&(x7>=0)&&(x7<64'sd491520)&&(y7>=0)&&(y7<64'sd276480);

always @(posedge clk)begin
 if(!rst_n)begin out_valid<=0;xs_q<=-4096;ys_q<=-4096;end
 else begin out_valid<=valid_pipe[10];xs_q<=ok?(x7<<<4):-24'sd4096;ys_q<=ok?(y7<<<4):-24'sd4096;end
end
endmodule
