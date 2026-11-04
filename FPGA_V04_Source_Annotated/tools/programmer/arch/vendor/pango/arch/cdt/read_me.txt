
fpga_list_cd.json
   //device name  //display name   //device ID   //instruction length    //embed flash size,only use for PGC[uit size: bit]  //not use  //not use




flash_list_cd.json
    //flash name     //flash ID       //flash size[uit size: bit]        //operate flash config info                                     //flash SPI mode and address mode
   ["M25P16",        "0x00202015",    "0x1000000",                       ["5000",  "800", "3000",  "800",  "40000",  "17000", "false"],  ["SPI X1, 24-bit address"]],



    //operate flash config info 
    //page_program_max_time[uit size: ms]       //page_program_typic_time[uit size: ms]   //block_erase_max_time[uit size: ms]  //block_erase_typic_time[uit size: ms]   //chip_erase_max_time[uit size: ms]  //chip_erase_typic_time[uit size: ms]   //ext_addr_reg_support
   ["5000",                                     "800",                                    "3000",                               "800",                                   "40000",                            "17000",                               "false"]



eye_scan.json
1.因文档“xx-HSSTHP寄存器.xlsx”中的pma_reg_tx35寄存器的偏移地址错写成0x00023（实际应写为0x0023），每次使用cdt中excel表装换器将根据该表直接生成json文件时，需手动更改json文件中该寄存器的值。
2.由于存在bug配置loopback模式为Near-End PMA PLOOP模式时仍需配置寄存器"pma_config_tx"偏移地址0x0018值为0x16（默认值0x85），现直接将该操作写入json文件中，待该问题解决后应当去除。