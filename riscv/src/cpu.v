`default_nettype none

module cpu(
    input  wire                 clk_in,
    input  wire                 rst_in,
    input  wire                 rdy_in,

    input  wire [ 7:0]          mem_din,
    output wire [ 7:0]          mem_dout,
    output wire [31:0]          mem_a,
    output wire                 mem_wr,

    input  wire                 io_buffer_full,

    output wire [31:0]          dbgreg_dout
);

    reg [31:0] regs [31:0];
    reg [31:0] pc;
    reg [3:0] state; 
    reg [3:0] m_state;
    reg [31:0] m_addr;
    reg [31:0] m_data_in;
    reg [31:0] m_data_out;
    reg m_wr;

    assign mem_a = m_addr;
    assign mem_dout = m_data_out[7:0];
    assign mem_wr = m_wr && (m_state >= 9);

    reg [31:0] inst;
    reg [4:0] rd, rs1, rs2;
    reg [31:0] rv1, rv2, imm;
    reg [6:0] opcode;
    reg [2:0] funct3;

    integer i;
    always @(posedge clk_in) begin
        if (rst_in) begin
            pc <= 0;
            for (i = 0; i < 32; i = i + 1) regs[i] <= 0;
            state <= 0; m_state <= 0; m_wr <= 0;
        end else if (rdy_in) begin
            case (state)
                0: begin // IF
                    if (m_state == 0) begin
                        m_addr <= pc; m_wr <= 0; m_state <= 1;
                    end else if (m_state == 4) begin
                        inst <= {mem_din, m_data_in[23:0]};
                        m_state <= 0; state <= 1;
                    end else begin
                        m_data_in[(m_state-1)*8 +: 8] <= mem_din;
                        m_addr <= m_addr + 1; m_state <= m_state + 1;
                    end
                end
                1: begin // ID/EX
                    opcode = inst[6:0]; rd = inst[11:7]; funct3 = inst[14:12];
                    rs1 = inst[19:15]; rs2 = inst[24:20];
                    rv1 = (rs1 == 0) ? 0 : regs[rs1];
                    rv2 = (rs2 == 0) ? 0 : regs[rs2];
                    case (opcode)
                        7'h37: begin if (rd!=0) regs[rd] <= {inst[31:12], 12'b0}; pc <= pc+4; state <= 0; end
                        7'h17: begin if (rd!=0) regs[rd] <= pc + {inst[31:12], 12'b0}; pc <= pc+4; state <= 0; end
                        7'h6F: begin if (rd!=0) regs[rd] <= pc+4; pc <= pc + {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0}; state <= 0; end
                        7'h67: begin imm = {{20{inst[31]}}, inst[31:20]}; if (rd!=0) regs[rd] <= pc+4; pc <= (rv1+imm)&~32'h1; state <= 0; end
                        7'h63: begin 
                            imm = {{20{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
                            case (funct3)
                                3'h0: pc <= (rv1==rv2)?pc+imm:pc+4;
                                3'h1: pc <= (rv1!=rv2)?pc+imm:pc+4;
                                3'h4: pc <= ($signed(rv1)<$signed(rv2))?pc+imm:pc+4;
                                3'h5: pc <= ($signed(rv1)>=$signed(rv2))?pc+imm:pc+4;
                                3'h6: pc <= (rv1<rv2)?pc+imm:pc+4;
                                3'h7: pc <= (rv1>=rv2)?pc+imm:pc+4;
                                default: pc <= pc+4;
                            endcase
                            state <= 0;
                        end
                        7'h03: begin m_addr <= rv1 + {{20{inst[31]}}, inst[31:20]}; m_wr <= 0; m_state <= 5; state <= 2; end
                        7'h23: begin m_addr <= rv1 + {{20{inst[31]}}, inst[31:25], inst[11:7]}; m_data_out <= rv2; m_wr <= 1; m_state <= 9; state <= 3; end
                        7'h13: begin 
                            imm = {{20{inst[31]}}, inst[31:20]};
                            case (funct3)
                                3'h0: rv1 = rv1 + imm;
                                3'h1: rv1 = rv1 << imm[4:0];
                                3'h2: rv1 = ($signed(rv1)<$signed(imm))?1:0;
                                3'h3: rv1 = (rv1<imm)?1:0;
                                3'h4: rv1 = rv1 ^ imm;
                                3'h5: rv1 = inst[30]?$signed(rv1)>>>imm[4:0]:rv1>>imm[4:0];
                                3'h6: rv1 = rv1 | imm;
                                3'h7: rv1 = rv1 & imm;
                            endcase
                            if (rd!=0) regs[rd] <= rv1; pc <= pc+4; state <= 0;
                        end
                        7'h33: begin
                            case (funct3)
                                3'h0: rv1 = inst[30]?rv1-rv2:rv1+rv2;
                                3'h1: rv1 = rv1 << rv2[4:0];
                                3'h2: rv1 = ($signed(rv1)<$signed(rv2))?1:0;
                                3'h3: rv1 = (rv1<rv2)?1:0;
                                3'h4: rv1 = rv1 ^ rv2;
                                3'h5: rv1 = inst[30]?$signed(rv1)>>>rv2[4:0]:rv1>>rv2[4:0];
                                3'h6: rv1 = rv1 | rv2;
                                3'h7: rv1 = rv1 & rv2;
                            endcase
                            if (rd!=0) regs[rd] <= rv1; pc <= pc+4; state <= 0;
                        end
                        default: begin pc <= pc+4; state <= 0; end
                    endcase
                end
                2: begin // LOAD
                    if (m_state == 5 + (funct3[1:0] == 2'h2 ? 3 : (funct3[1:0] == 2'h1 ? 1 : 0))) begin
                        case (funct3)
                            3'h0: rv1 = {{24{mem_din[7]}}, mem_din};
                            3'h4: rv1 = {24'b0, mem_din};
                            3'h1: rv1 = {{16{mem_din[7]}}, mem_din, m_data_in[7:0]};
                            3'h5: rv1 = {16'b0, mem_din, m_data_in[7:0]};
                            3'h2: rv1 = {mem_din, m_data_in[23:0]};
                        endcase
                        if (rd!=0) regs[rd] <= rv1; m_state <= 0; state <= 0; pc <= pc+4;
                    end else begin
                        m_data_in[(m_state-5)*8 +: 8] <= mem_din;
                        m_addr <= m_addr + 1; m_state <= m_state + 1;
                    end
                end
                3: begin // STORE
                    if (m_state == 9 + (funct3[1:0] == 2'h2 ? 3 : (funct3[1:0] == 2'h1 ? 1 : 0))) begin
                        m_state <= 0; state <= 0; pc <= pc+4;
                    end else begin
                        m_data_out <= m_data_out >> 8;
                        m_addr <= m_addr + 1; m_state <= m_state + 1;
                    end
                end
            endcase
        end
    end
endmodule
