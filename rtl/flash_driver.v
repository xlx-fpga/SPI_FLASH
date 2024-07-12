`timescale 1ns / 1ns
//****************************************VSCODE PLUG-IN**********************************// 
//---------------------------------------------------------------------------------------- 
// IDE :                   VSCODE      
// VSCODE plug-in version: Verilog-Hdl-Format-2.4.20240526
// VSCODE plug-in author : Jiang Percy 
//---------------------------------------------------------------------------------------- 
//****************************************Copyright (c)***********************************// 
// Copyright(C)            xlx_fpga
// All rights reserved      
// File name:               
// Last modified Date:     2024/07/11 13:17:10 
// Last Version:           V1.0 
// Descriptions:            
//---------------------------------------------------------------------------------------- 
// Created by:             xlx_fpga
// Created date:           2024/07/11 13:17:10 
// Version:                V1.0 
// TEXT NAME:              flash_driver.v 
// PATH:                   E:\3.xlx_fpga\7.FLASH\rtl\flash_driver.v 
// Descriptions:            
//                          
//---------------------------------------------------------------------------------------- 
//****************************************************************************************// 

module flash_driver#(
    parameter                                   BLOCK_SIZE         = 64*1024,    //一块的字节数量
    parameter                                   PAGE_SIZE          = 256   ,    // 一页的字节数量
    parameter                                   BLCOK_WIDTH        = $clog2(BLOCK_SIZE)//根据一个Black大小，计算出数据位宽  
)
(
    input                                       clk                 ,
    input                                       rst                 ,
    //***************************************************************************************
    // SPI物理端信号                                                                                    
    //***************************************************************************************
    output                                      spi_sck             ,
    output reg                                  spi_cs              ,
    output                                      spi_sdo             ,
    input                                       spi_sdi             ,
    //***************************************************************************************
    // FLASH用户端                                                                                    
    //***************************************************************************************
    input                                       flash_start         ,
    input                                       flash_wr_rd         ,//读写控制信号，0写1读
    input              [BLCOK_WIDTH-1: 0]       flash_length        ,//读写长度，最大一个块
    //地址后16位必须全0
    input              [23: 0]                  flash_addr          ,//要操作的地址
    input              [7: 0]                   flash_wr_data       ,
    output reg                                  flash_wr_req        ,//写请求，早于写数据一拍
    output reg         [7: 0]                   flash_rd_data       ,
    output reg                                  flash_rd_vld        ,
    output                                      flash_busy           
);
    //***************************************************************************************
    // FLASH操作命令                                                                                    
    //***************************************************************************************
    localparam                                  WR_EN_CMD          = 8'h06 ;//写使能
    localparam                                  RD_STATUS_CMD      = 8'h05 ;//读状态寄存器
    localparam                                  RD_DATA_CMD        = 8'h03 ;//读数据
    localparam                                  PP_WR_CMD          = 8'h02 ;//页写
    localparam                                  BERASE_CMD         = 8'hd8 ;//块擦除

    reg                [23: 0]                  flash_addr_d0       ;
    reg                [23: 0]                  flash_wr_addr       ;
    reg                [BLCOK_WIDTH-1: 0]       flash_length_d0     ;
    reg                [3: 0]                   bit_cnt             ;
    reg                [BLCOK_WIDTH: 0]       byte_cnt            ;
    reg                [31: 0]                  wr_data             ;
    reg                                         wr_busy             ;
    reg                                         rd_busy             ;
    reg                                         block_erase_done    ;//块擦除完成
    reg                                         flash_wr_req_r      ;
    reg                [BLCOK_WIDTH-1: 0]       wr_length           ;
    reg                                         spi_cs_down         ;

    //***************************************************************************************
    //  锁存地址和长度                                                                                   
    //***************************************************************************************
    always @(posedge clk )
        begin
            if(flash_start) begin
                flash_addr_d0 <= flash_addr;
                flash_length_d0 <= flash_length;
        end
            else begin
                flash_addr_d0 <= flash_addr_d0;
                flash_length_d0 <= flash_length_d0;
        end
        end

    //***************************************************************************************
    // bit_cnt                                                                                    
    //*************************************************************************************** 
    always @(posedge clk )
        begin
            if(rst) begin
                bit_cnt <= 0;
        end
            else if(bit_cnt == 7) begin
                bit_cnt <= 0;
        end
            else if(spi_cs) begin
                bit_cnt <= 0;
        end
            else begin
                bit_cnt <= bit_cnt +1;
        end
        end
    //***************************************************************************************
    // byte_cnt                                                                                    
    //*************************************************************************************** 
    always @(posedge clk )
        begin
            if(rst) begin
                byte_cnt <= 0;
        end
            else if(cur_state != next_state) begin
                byte_cnt <= 0;
        end
            else if(bit_cnt == 7) begin
                byte_cnt <= byte_cnt +1;
        end
            else begin
                byte_cnt <= byte_cnt;
        end
        end
    //***************************************************************************************
    // spi_sck                                                                                    
    //***************************************************************************************
    assign                                      spi_sck            = ~(clk & ~spi_cs);//时钟反相 
    //***************************************************************************************
    // spi_sdo                                                                                    
    //*************************************************************************************** 
    assign                                      spi_sdo            = wr_data[31];
    //***************************************************************************************
    // busy                                                                                    
    //***************************************************************************************
    always @(posedge clk )
        begin
            if(rst) begin
                wr_busy <= 0;
                rd_busy <= 0;
        end
        else if(cur_state == IDLE) begin
                wr_busy <= 0;
                rd_busy <= 0;
        end
            else if(flash_wr_rd) begin
                wr_busy <= 0;
                rd_busy <= 1;
        end
            else if(~flash_wr_rd) begin
                wr_busy <= 1;
                rd_busy <= 0;
        end
        
            else begin
                wr_busy <= wr_busy;
                rd_busy <= rd_busy;
        end
        end
    assign                                      flash_busy         = wr_busy || rd_busy;
    //***************************************************************************************
    // 状态机                                                                                    
    //*************************************************************************************** 
    localparam                                  IDLE               = 6'b000000;
    localparam                                  RD_STATUS          = 6'b000001;
    localparam                                  WR_EN              = 6'b000010;
    localparam                                  BERASE             = 6'b000100;
    localparam                                  PP_WR              = 6'b001000;
    localparam                                  RD_DATA            = 6'b010000;
    localparam                                  END                = 6'b100000;
                                                              
    reg                [5: 0]                   cur_state           ;
    reg                [5: 0]                   next_state          ;
    //同步时序描述状态转移
    always @(posedge clk )
        begin
            if(rst)
                cur_state <= IDLE;
            else 
                cur_state <= next_state;
        end
    //组合逻辑判断状态转移条件
    always @( * ) begin
            case(cur_state)
                IDLE:
        begin
            if(flash_start)
                next_state <= RD_STATUS        ;
            else 
                next_state <= IDLE;
        end
                RD_STATUS:
        begin
            if(byte_cnt >= 1 && bit_cnt == 7 && ~spi_sdi && wr_busy) begin
                next_state <= WR_EN;
        end
            else if(byte_cnt >= 1 && bit_cnt == 7 && ~spi_sdi && rd_busy) begin
                next_state <= RD_DATA;
        end
            else 
                next_state <= cur_state;
        end
                WR_EN:
        begin
            if(bit_cnt == 7 && ~block_erase_done) begin
                next_state <= BERASE;
        end
            else if(bit_cnt == 7 && block_erase_done) begin
                next_state <= PP_WR;
        end
            else 
                next_state <= cur_state;
        end
                BERASE:
        begin
            if(byte_cnt == 3 && bit_cnt == 7) begin
                next_state <= RD_STATUS;
        end
            else 
                next_state <= cur_state;
        end
                PP_WR:
        begin
                            //全部写完
            if(byte_cnt == wr_length + 3 && bit_cnt == 7) begin
                next_state <= END;
        end
                            //写完一页
            else if(byte_cnt == PAGE_SIZE +3 && bit_cnt == 7) begin
                next_state <= RD_STATUS;
        end
        end
                RD_DATA:
        begin
            if(byte_cnt == flash_length_d0 +3 && bit_cnt == 7) begin
                next_state <= END;
        end
            else 
                next_state <= cur_state;
        end
                END:
        begin
                next_state <= IDLE;
        end
                default: next_state <= IDLE;
        endcase
        end

    //***************************************************************************************
    // cs                                                                                    
    //***************************************************************************************
    always @(posedge clk) begin
            if(cur_state != next_state)
                spi_cs_down <= 1;
            else 
                spi_cs_down <= 0;
        end

    always @(posedge clk) begin
            if(rst)
                spi_cs <= 1;
            else if(cur_state == IDLE || cur_state == END)
                spi_cs <= 1;
            else if(cur_state != next_state)
                spi_cs <= 1;
            else if(spi_cs_down)
                spi_cs <= 0;
        end
    //***************************************************************************************
    // 块擦除                                                                                    
    //***************************************************************************************
    always @(posedge clk )
        begin
            if(rst) begin
                block_erase_done <= 0;
        end
            else if(BERASE && byte_cnt==3 && bit_cnt == 7) begin
                block_erase_done <= 1;
        end
            else if(cur_state == IDLE || cur_state == END) begin
                block_erase_done <= 0;
        end
            else begin
                block_erase_done <= block_erase_done;
        end
        end
    //***************************************************************************************
    // wr_length flash_wr_addr                                                                                   
    //***************************************************************************************
    always @(posedge clk )
        begin
            if(rst) begin
                wr_length <= 0;
                flash_wr_addr <= 0;
        end
            else if(flash_start) begin
                wr_length <= flash_length;
                flash_wr_addr <= flash_addr;
        end
            else if(cur_state == PP_WR && byte_cnt == PAGE_SIZE +3 && bit_cnt == 7) begin
                wr_length <= wr_length -PAGE_SIZE;
                flash_wr_addr <= flash_wr_addr + PAGE_SIZE;
        end
            else begin
                wr_length <= wr_length;
                flash_wr_addr <= flash_wr_addr;
        end
        end
    //***************************************************************************************
    // wr_data                                                                                    
    //*************************************************************************************** 
    always @(posedge clk )
        begin
            if(rst) begin
                wr_data <= 0;
        end
                                //发送读状态命令                                  
            else if(cur_state == RD_STATUS && spi_cs) begin
                wr_data <= {RD_STATUS_CMD,24'b0};
        end
                                //发送写使能命令
            else if(cur_state == WR_EN && spi_cs) begin
                wr_data <= {WR_EN_CMD,24'b0};
        end
                                //发送块擦除命令
            else if(cur_state == BERASE && spi_cs) begin
                wr_data <= {BERASE_CMD,flash_addr_d0};
        end
                                //发送页写命令
            else if(cur_state == PP_WR && spi_cs) begin
                wr_data <= {PP_WR_CMD,flash_wr_addr};
        end
                                //发送读数据命令
            else if(cur_state == RD_DATA && spi_cs) begin
                wr_data <= {RD_DATA_CMD,flash_addr_d0};
        end
                                //发送用户写数据
            else if(flash_wr_req_r) begin
                wr_data <= {flash_wr_data,24'b0};
        end
                                //数据移位                                  
            else if(~spi_cs)begin
                wr_data <= wr_data<<1;
        end
            else 
                wr_data <= wr_data;
        end
        //***************************************************************************************
        // wr_req                                                                                    
        //*************************************************************************************** 
    always @(posedge clk )
        begin
            if(rst) begin
                flash_wr_req <= 0;
        end
            else if(cur_state == PP_WR && byte_cnt >=3 && bit_cnt == 5
                                        && byte_cnt != PAGE_SIZE+3 && byte_cnt != wr_length +3) begin
                flash_wr_req <= 1;
        end
            else begin
                flash_wr_req <= 0;
        end
        end
    always @(posedge clk )
        begin
                flash_wr_req_r <= flash_wr_req;
        end
//***************************************************************************************
// rd_data                                                                                    
//*************************************************************************************** 
    always @(posedge clk) begin
            if(~spi_cs)
                flash_rd_data <= {flash_rd_data[6:0],spi_sdi};
            else 
                flash_rd_data <= flash_rd_data;
        end

    always @(posedge clk) begin
            if(cur_state == RD_DATA && bit_cnt == 7 && byte_cnt > 3)
                flash_rd_vld <= 1'b1;
            else 
                flash_rd_vld <= 0;
        end

                                                 
    

        endmodule
