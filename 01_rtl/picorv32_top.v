/*
 *  PicoRV32 -- A Small RISC-V (RV32I) Processor Core
 *
 *  Copyright (C) 2015  Claire Xenia Wolf <claire@yosyshq.com>
 *
 *  Permission to use, copy, modify, and/or distribute this software for any
 *  purpose with or without fee is hereby granted, provided that the above
 *  copyright notice and this permission notice appear in all copies.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 *  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 *  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 *  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 *  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 *  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 *  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 */
/* verilator lint_off WIDTH */
/* verilator lint_off PINMISSING */
/* verilator lint_off CASEOVERLAP */
/* verilator lint_off CASEINCOMPLETE */
// `default_nettype none
// `define DEBUGNETS
// `define DEBUGREGS
// `define DEBUGASM
// `define DEBUG
  
  
    
  
  
// uncomment this for register file in extra module
// `define PICORV32_REGS picorv32_regs
// this macro can be used to check if the verilog files in your
// design are read in the correct order.
/***************************************************************
 * picorv32
 ***************************************************************/
module picorv32 #(
	parameter [ 0:0] ENABLE_COUNTERS = 1,
	parameter [ 0:0] ENABLE_COUNTERS64 = 1,
	parameter [ 0:0] ENABLE_REGS_16_31 = 1,
	parameter [ 0:0] ENABLE_REGS_DUALPORT = 1,
	parameter [ 0:0] LATCHED_MEM_RDATA = 0,
	parameter [ 0:0] TWO_STAGE_SHIFT = 1,
	parameter [ 0:0] BARREL_SHIFTER = 0,
	parameter [ 0:0] TWO_CYCLE_COMPARE = 0,
	parameter [ 0:0] TWO_CYCLE_ALU = 0,
	parameter [ 0:0] COMPRESSED_ISA = 0,
	parameter [ 0:0] CATCH_MISALIGN = 1,
	parameter [ 0:0] CATCH_ILLINSN = 1,
	parameter [ 0:0] ENABLE_PCPI = 0,
	parameter [ 0:0] ENABLE_MUL = 0,
	parameter [ 0:0] ENABLE_FAST_MUL = 0,
	parameter [ 0:0] ENABLE_DIV = 0,
	parameter [ 0:0] ENABLE_IRQ = 0,
	parameter [ 0:0] ENABLE_IRQ_QREGS = 1,
	parameter [ 0:0] ENABLE_IRQ_TIMER = 1,
	parameter [ 0:0] ENABLE_TRACE = 0,
	parameter [ 0:0] REGS_INIT_ZERO = 0,
	parameter [31:0] MASKED_IRQ = 32'h 0000_0000,
	parameter [31:0] LATCHED_IRQ = 32'h ffff_ffff,
	parameter [31:0] PROGADDR_RESET = 32'h 0000_0000,
	parameter [31:0] PROGADDR_IRQ = 32'h 0000_0010,
	parameter [31:0] STACKADDR = 32'h ffff_ffff
) (
	input clk, resetn,
	output reg trap,
	output reg        mem_valid,
	output reg        mem_instr,
	input             mem_ready,
	output reg [31:0] mem_addr,
	output reg [31:0] mem_wdata,
	output reg [ 3:0] mem_wstrb,
	input      [31:0] mem_rdata,
	// Look-Ahead Interface
	output            mem_la_read,
	output            mem_la_write,
	output     [31:0] mem_la_addr,
	output reg [31:0] mem_la_wdata,
	output reg [ 3:0] mem_la_wstrb,
	// Pico Co-Processor Interface (PCPI)
	output reg        pcpi_valid,
	output reg [31:0] pcpi_insn,
	output     [31:0] pcpi_rs1,
	output     [31:0] pcpi_rs2,
	input             pcpi_wr,
	input      [31:0] pcpi_rd,
	input             pcpi_wait,
	input             pcpi_ready,
	// IRQ Interface
	input      [31:0] irq,
	output reg [31:0] eoi,
	// Trace Interface
	output reg        trace_valid,
	output reg [35:0] trace_data
);
	localparam integer irq_timer = 0;
	localparam integer irq_ebreak = 1;
	localparam integer irq_buserror = 2;
	localparam integer irqregs_offset = ENABLE_REGS_16_31 ? 32 : 16;
	localparam integer regfile_size = (ENABLE_REGS_16_31 ? 32 : 16) + 4*ENABLE_IRQ*ENABLE_IRQ_QREGS;
	localparam integer regindex_bits = (ENABLE_REGS_16_31 ? 5 : 4) + ENABLE_IRQ*ENABLE_IRQ_QREGS;
	localparam WITH_PCPI = ENABLE_PCPI || ENABLE_MUL || ENABLE_FAST_MUL || ENABLE_DIV;
	localparam [35:0] TRACE_BRANCH = {4'b 0001, 32'b 0};
	localparam [35:0] TRACE_ADDR   = {4'b 0010, 32'b 0};
	localparam [35:0] TRACE_IRQ    = {4'b 1000, 32'b 0};
	reg [63:0] count_cycle, count_instr;
	reg [31:0] reg_pc, reg_next_pc, reg_op1, reg_op2, reg_out;
	reg [4:0] reg_sh;
	reg [31:0] next_insn_opcode;
	reg [31:0] dbg_insn_opcode;
	reg [31:0] dbg_insn_addr;
	wire dbg_mem_valid = mem_valid;
	wire dbg_mem_instr = mem_instr;
	wire dbg_mem_ready = mem_ready;
	wire [31:0] dbg_mem_addr  = mem_addr;
	wire [31:0] dbg_mem_wdata = mem_wdata;
	wire [ 3:0] dbg_mem_wstrb = mem_wstrb;
	wire [31:0] dbg_mem_rdata = mem_rdata;
	assign pcpi_rs1 = reg_op1;
	assign pcpi_rs2 = reg_op2;
	wire [31:0] next_pc;
	reg irq_delay;
	reg irq_active;
	reg [31:0] irq_mask;
	reg [31:0] irq_pending;
	reg [31:0] timer;
	reg [31:0] cpuregs [0:regfile_size-1];
	integer i;
	initial begin
		if (REGS_INIT_ZERO) begin
			for (i = 0; i < regfile_size; i = i+1)
				cpuregs[i] = 0;
		end
	end
	task empty_statement;
		// This task is used by the `assert directive in non-formal mode to
		// avoid empty statement (which are unsupported by plain Verilog syntax).
		begin end
	endtask
	// Internal PCPI Cores
	wire        pcpi_mul_wr;
	wire [31:0] pcpi_mul_rd;
	wire        pcpi_mul_wait;
	wire        pcpi_mul_ready;
	wire        pcpi_div_wr;
	wire [31:0] pcpi_div_rd;
	wire        pcpi_div_wait;
	wire        pcpi_div_ready;
	reg        pcpi_int_wr;
	reg [31:0] pcpi_int_rd;
	reg        pcpi_int_wait;
	reg        pcpi_int_ready;
	generate if (ENABLE_FAST_MUL) begin
		picorv32_pcpi_fast_mul pcpi_mul (
			.clk       (clk            ),
			.resetn    (resetn         ),
			.pcpi_valid(pcpi_valid     ),
			.pcpi_insn (pcpi_insn      ),
			.pcpi_rs1  (pcpi_rs1       ),
			.pcpi_rs2  (pcpi_rs2       ),
			.pcpi_wr   (pcpi_mul_wr    ),
			.pcpi_rd   (pcpi_mul_rd    ),
			.pcpi_wait (pcpi_mul_wait  ),
			.pcpi_ready(pcpi_mul_ready )
		);
	end else if (ENABLE_MUL) begin
		picorv32_pcpi_mul pcpi_mul (
			.clk       (clk            ),
			.resetn    (resetn         ),
			.pcpi_valid(pcpi_valid     ),
			.pcpi_insn (pcpi_insn      ),
			.pcpi_rs1  (pcpi_rs1       ),
			.pcpi_rs2  (pcpi_rs2       ),
			.pcpi_wr   (pcpi_mul_wr    ),
			.pcpi_rd   (pcpi_mul_rd    ),
			.pcpi_wait (pcpi_mul_wait  ),
			.pcpi_ready(pcpi_mul_ready )
		);
	end else begin
		assign pcpi_mul_wr = 0;
		assign pcpi_mul_rd = 32'bx;
		assign pcpi_mul_wait = 0;
		assign pcpi_mul_ready = 0;
	end endgenerate
	generate if (ENABLE_DIV) begin
		picorv32_pcpi_div pcpi_div (
			.clk       (clk            ),
			.resetn    (resetn         ),
			.pcpi_valid(pcpi_valid     ),
			.pcpi_insn (pcpi_insn      ),
			.pcpi_rs1  (pcpi_rs1       ),
			.pcpi_rs2  (pcpi_rs2       ),
			.pcpi_wr   (pcpi_div_wr    ),
			.pcpi_rd   (pcpi_div_rd    ),
			.pcpi_wait (pcpi_div_wait  ),
			.pcpi_ready(pcpi_div_ready )
		);
	end else begin
		assign pcpi_div_wr = 0;
		assign pcpi_div_rd = 32'bx;
		assign pcpi_div_wait = 0;
		assign pcpi_div_ready = 0;
	end endgenerate
	always @* begin
		pcpi_int_wr = 0;
		pcpi_int_rd = 32'bx;
		pcpi_int_wait  = |{ENABLE_PCPI && pcpi_wait,  (ENABLE_MUL || ENABLE_FAST_MUL) && pcpi_mul_wait,  ENABLE_DIV && pcpi_div_wait};
		pcpi_int_ready = |{ENABLE_PCPI && pcpi_ready, (ENABLE_MUL || ENABLE_FAST_MUL) && pcpi_mul_ready, ENABLE_DIV && pcpi_div_ready};
		(* parallel_case *)
		case (1'b1)
			ENABLE_PCPI && pcpi_ready: begin
				pcpi_int_wr = ENABLE_PCPI ? pcpi_wr : 0;
				pcpi_int_rd = ENABLE_PCPI ? pcpi_rd : 0;
			end
			(ENABLE_MUL || ENABLE_FAST_MUL) && pcpi_mul_ready: begin
				pcpi_int_wr = pcpi_mul_wr;
				pcpi_int_rd = pcpi_mul_rd;
			end
			ENABLE_DIV && pcpi_div_ready: begin
				pcpi_int_wr = pcpi_div_wr;
				pcpi_int_rd = pcpi_div_rd;
			end
		endcase
	end
	// Memory Interface
	reg [1:0] mem_state;
	reg [1:0] mem_wordsize;
	reg [31:0] mem_rdata_word;
	reg [31:0] mem_rdata_q;
	reg mem_do_prefetch;
	reg mem_do_rinst;
	reg mem_do_rdata;
	reg mem_do_wdata;
	wire mem_xfer;
	reg mem_la_secondword, mem_la_firstword_reg, last_mem_valid;
	wire mem_la_firstword = COMPRESSED_ISA && (mem_do_prefetch || mem_do_rinst) && next_pc[1] && !mem_la_secondword;
	wire mem_la_firstword_xfer = COMPRESSED_ISA && mem_xfer && (!last_mem_valid ? mem_la_firstword : mem_la_firstword_reg);
	reg prefetched_high_word;
	reg clear_prefetched_high_word;
	reg [15:0] mem_16bit_buffer;
	wire [31:0] mem_rdata_latched_noshuffle;
	wire [31:0] mem_rdata_latched;
	wire mem_la_use_prefetched_high_word = COMPRESSED_ISA && mem_la_firstword && prefetched_high_word && !clear_prefetched_high_word;
	assign mem_xfer = (mem_valid && mem_ready) || (mem_la_use_prefetched_high_word && mem_do_rinst);
	wire mem_busy = |{mem_do_prefetch, mem_do_rinst, mem_do_rdata, mem_do_wdata};
	wire mem_done = resetn && ((mem_xfer && |mem_state && (mem_do_rinst || mem_do_rdata || mem_do_wdata)) || (&mem_state && mem_do_rinst)) &&
			(!mem_la_firstword || (~&mem_rdata_latched[1:0] && mem_xfer));
	assign mem_la_write = resetn && !mem_state && mem_do_wdata;
	assign mem_la_read = resetn && ((!mem_la_use_prefetched_high_word && !mem_state && (mem_do_rinst || mem_do_prefetch || mem_do_rdata)) ||
			(COMPRESSED_ISA && mem_xfer && (!last_mem_valid ? mem_la_firstword : mem_la_firstword_reg) && !mem_la_secondword && &mem_rdata_latched[1:0]));
	assign mem_la_addr = (mem_do_prefetch || mem_do_rinst) ? {next_pc[31:2] + mem_la_firstword_xfer, 2'b00} : {reg_op1[31:2], 2'b00};
	assign mem_rdata_latched_noshuffle = (mem_xfer || LATCHED_MEM_RDATA) ? mem_rdata : mem_rdata_q;
	assign mem_rdata_latched = COMPRESSED_ISA && mem_la_use_prefetched_high_word ? {16'bx, mem_16bit_buffer} :
			COMPRESSED_ISA && mem_la_secondword ? {mem_rdata_latched_noshuffle[15:0], mem_16bit_buffer} :
			COMPRESSED_ISA && mem_la_firstword ? {16'bx, mem_rdata_latched_noshuffle[31:16]} : mem_rdata_latched_noshuffle;
	always @(posedge clk) begin
		if (!resetn) begin
			mem_la_firstword_reg <= 0;
			last_mem_valid <= 0;
		end else begin
			if (!last_mem_valid)
				mem_la_firstword_reg <= mem_la_firstword;
			last_mem_valid <= mem_valid && !mem_ready;
		end
	end
	always @* begin
		(* full_case *)
		case (mem_wordsize)
			0: begin
				mem_la_wdata = reg_op2;
				mem_la_wstrb = 4'b1111;
				mem_rdata_word = mem_rdata;
			end
			1: begin
				mem_la_wdata = {2{reg_op2[15:0]}};
				mem_la_wstrb = reg_op1[1] ? 4'b1100 : 4'b0011;
				case (reg_op1[1])
					1'b0: mem_rdata_word = {16'b0, mem_rdata[15: 0]};
					1'b1: mem_rdata_word = {16'b0, mem_rdata[31:16]};
				endcase
			end
			2: begin
				mem_la_wdata = {4{reg_op2[7:0]}};
				mem_la_wstrb = 4'b0001 << reg_op1[1:0];
				case (reg_op1[1:0])
					2'b00: mem_rdata_word = {24'b0, mem_rdata[ 7: 0]};
					2'b01: mem_rdata_word = {24'b0, mem_rdata[15: 8]};
					2'b10: mem_rdata_word = {24'b0, mem_rdata[23:16]};
					2'b11: mem_rdata_word = {24'b0, mem_rdata[31:24]};
				endcase
			end
		endcase
	end
	always @(posedge clk) begin
		if (mem_xfer) begin
			mem_rdata_q <= COMPRESSED_ISA ? mem_rdata_latched : mem_rdata;
			next_insn_opcode <= COMPRESSED_ISA ? mem_rdata_latched : mem_rdata;
		end
		if (COMPRESSED_ISA && mem_done && (mem_do_prefetch || mem_do_rinst)) begin
			case (mem_rdata_latched[1:0])
				2'b00: begin // Quadrant 0
					case (mem_rdata_latched[15:13])
						3'b000: begin // C.ADDI4SPN
							mem_rdata_q[14:12] <= 3'b000;
							mem_rdata_q[31:20] <= {2'b0, mem_rdata_latched[10:7], mem_rdata_latched[12:11], mem_rdata_latched[5], mem_rdata_latched[6], 2'b00};
						end
						3'b010: begin // C.LW
							mem_rdata_q[31:20] <= {5'b0, mem_rdata_latched[5], mem_rdata_latched[12:10], mem_rdata_latched[6], 2'b00};
							mem_rdata_q[14:12] <= 3'b 010;
						end
						3'b 110: begin // C.SW
							{mem_rdata_q[31:25], mem_rdata_q[11:7]} <= {5'b0, mem_rdata_latched[5], mem_rdata_latched[12:10], mem_rdata_latched[6], 2'b00};
							mem_rdata_q[14:12] <= 3'b 010;
						end
					endcase
				end
				2'b01: begin // Quadrant 1
					case (mem_rdata_latched[15:13])
						3'b 000: begin // C.ADDI
							mem_rdata_q[14:12] <= 3'b000;
							mem_rdata_q[31:20] <= $signed({mem_rdata_latched[12], mem_rdata_latched[6:2]});
						end
						3'b 010: begin // C.LI
							mem_rdata_q[14:12] <= 3'b000;
							mem_rdata_q[31:20] <= $signed({mem_rdata_latched[12], mem_rdata_latched[6:2]});
						end
						3'b 011: begin
							if (mem_rdata_latched[11:7] == 2) begin // C.ADDI16SP
								mem_rdata_q[14:12] <= 3'b000;
								mem_rdata_q[31:20] <= $signed({mem_rdata_latched[12], mem_rdata_latched[4:3],
										mem_rdata_latched[5], mem_rdata_latched[2], mem_rdata_latched[6], 4'b 0000});
							end else begin // C.LUI
								mem_rdata_q[31:12] <= $signed({mem_rdata_latched[12], mem_rdata_latched[6:2]});
							end
						end
						3'b100: begin
							if (mem_rdata_latched[11:10] == 2'b00) begin // C.SRLI
								mem_rdata_q[31:25] <= 7'b0000000;
								mem_rdata_q[14:12] <= 3'b 101;
							end
							if (mem_rdata_latched[11:10] == 2'b01) begin // C.SRAI
								mem_rdata_q[31:25] <= 7'b0100000;
								mem_rdata_q[14:12] <= 3'b 101;
							end
							if (mem_rdata_latched[11:10] == 2'b10) begin // C.ANDI
								mem_rdata_q[14:12] <= 3'b111;
								mem_rdata_q[31:20] <= $signed({mem_rdata_latched[12], mem_rdata_latched[6:2]});
							end
							if (mem_rdata_latched[12:10] == 3'b011) begin // C.SUB, C.XOR, C.OR, C.AND
								if (mem_rdata_latched[6:5] == 2'b00) mem_rdata_q[14:12] <= 3'b000;
								if (mem_rdata_latched[6:5] == 2'b01) mem_rdata_q[14:12] <= 3'b100;
								if (mem_rdata_latched[6:5] == 2'b10) mem_rdata_q[14:12] <= 3'b110;
								if (mem_rdata_latched[6:5] == 2'b11) mem_rdata_q[14:12] <= 3'b111;
								mem_rdata_q[31:25] <= mem_rdata_latched[6:5] == 2'b00 ? 7'b0100000 : 7'b0000000;
							end
						end
						3'b 110: begin // C.BEQZ
							mem_rdata_q[14:12] <= 3'b000;
							{ mem_rdata_q[31], mem_rdata_q[7], mem_rdata_q[30:25], mem_rdata_q[11:8] } <=
									$signed({mem_rdata_latched[12], mem_rdata_latched[6:5], mem_rdata_latched[2],
											mem_rdata_latched[11:10], mem_rdata_latched[4:3]});
						end
						3'b 111: begin // C.BNEZ
							mem_rdata_q[14:12] <= 3'b001;
							{ mem_rdata_q[31], mem_rdata_q[7], mem_rdata_q[30:25], mem_rdata_q[11:8] } <=
									$signed({mem_rdata_latched[12], mem_rdata_latched[6:5], mem_rdata_latched[2],
											mem_rdata_latched[11:10], mem_rdata_latched[4:3]});
						end
					endcase
				end
				2'b10: begin // Quadrant 2
					case (mem_rdata_latched[15:13])
						3'b000: begin // C.SLLI
							mem_rdata_q[31:25] <= 7'b0000000;
							mem_rdata_q[14:12] <= 3'b 001;
						end
						3'b010: begin // C.LWSP
							mem_rdata_q[31:20] <= {4'b0, mem_rdata_latched[3:2], mem_rdata_latched[12], mem_rdata_latched[6:4], 2'b00};
							mem_rdata_q[14:12] <= 3'b 010;
						end
						3'b100: begin
							if (mem_rdata_latched[12] == 0 && mem_rdata_latched[6:2] == 0) begin // C.JR
								mem_rdata_q[14:12] <= 3'b000;
								mem_rdata_q[31:20] <= 12'b0;
							end
							if (mem_rdata_latched[12] == 0 && mem_rdata_latched[6:2] != 0) begin // C.MV
								mem_rdata_q[14:12] <= 3'b000;
								mem_rdata_q[31:25] <= 7'b0000000;
							end
							if (mem_rdata_latched[12] != 0 && mem_rdata_latched[11:7] != 0 && mem_rdata_latched[6:2] == 0) begin // C.JALR
								mem_rdata_q[14:12] <= 3'b000;
								mem_rdata_q[31:20] <= 12'b0;
							end
							if (mem_rdata_latched[12] != 0 && mem_rdata_latched[6:2] != 0) begin // C.ADD
								mem_rdata_q[14:12] <= 3'b000;
								mem_rdata_q[31:25] <= 7'b0000000;
							end
						end
						3'b110: begin // C.SWSP
							{mem_rdata_q[31:25], mem_rdata_q[11:7]} <= {4'b0, mem_rdata_latched[8:7], mem_rdata_latched[12:9], 2'b00};
							mem_rdata_q[14:12] <= 3'b 010;
						end
					endcase
				end
			endcase
		end
	end
	always @(posedge clk) begin
		if (resetn && !trap) begin
			if (mem_do_prefetch || mem_do_rinst || mem_do_rdata)
				empty_statement;
			if (mem_do_prefetch || mem_do_rinst)
				empty_statement;
			if (mem_do_rdata)
				empty_statement;
			if (mem_do_wdata)
				empty_statement;
			if (mem_state == 2 || mem_state == 3)
				empty_statement;
		end
	end
	always @(posedge clk) begin
		if (!resetn || trap) begin
			if (!resetn)
				mem_state <= 0;
			if (!resetn || mem_ready)
				mem_valid <= 0;
			mem_la_secondword <= 0;
			prefetched_high_word <= 0;
		end else begin
			if (mem_la_read || mem_la_write) begin
				mem_addr <= mem_la_addr;
				mem_wstrb <= mem_la_wstrb & {4{mem_la_write}};
			end
			if (mem_la_write) begin
				mem_wdata <= mem_la_wdata;
			end
			case (mem_state)
				0: begin
					if (mem_do_prefetch || mem_do_rinst || mem_do_rdata) begin
						mem_valid <= !mem_la_use_prefetched_high_word;
						mem_instr <= mem_do_prefetch || mem_do_rinst;
						mem_wstrb <= 0;
						mem_state <= 1;
					end
					if (mem_do_wdata) begin
						mem_valid <= 1;
						mem_instr <= 0;
						mem_state <= 2;
					end
				end
				1: begin
					empty_statement;
					empty_statement;
					empty_statement;
					empty_statement;
					if (mem_xfer) begin
						if (COMPRESSED_ISA && mem_la_read) begin
							mem_valid <= 1;
							mem_la_secondword <= 1;
							if (!mem_la_use_prefetched_high_word)
								mem_16bit_buffer <= mem_rdata[31:16];
						end else begin
							mem_valid <= 0;
							mem_la_secondword <= 0;
							if (COMPRESSED_ISA && !mem_do_rdata) begin
								if (~&mem_rdata[1:0] || mem_la_secondword) begin
									mem_16bit_buffer <= mem_rdata[31:16];
									prefetched_high_word <= 1;
								end else begin
									prefetched_high_word <= 0;
								end
							end
							mem_state <= mem_do_rinst || mem_do_rdata ? 0 : 3;
						end
					end
				end
				2: begin
					empty_statement;
					empty_statement;
					if (mem_xfer) begin
						mem_valid <= 0;
						mem_state <= 0;
					end
				end
				3: begin
					empty_statement;
					empty_statement;
					if (mem_do_rinst) begin
						mem_state <= 0;
					end
				end
			endcase
		end
		if (clear_prefetched_high_word)
			prefetched_high_word <= 0;
	end
	// Instruction Decoder
	reg instr_lui, instr_auipc, instr_jal, instr_jalr;
	reg instr_beq, instr_bne, instr_blt, instr_bge, instr_bltu, instr_bgeu;
	reg instr_lb, instr_lh, instr_lw, instr_lbu, instr_lhu, instr_sb, instr_sh, instr_sw;
	reg instr_addi, instr_slti, instr_sltiu, instr_xori, instr_ori, instr_andi, instr_slli, instr_srli, instr_srai;
	reg instr_add, instr_sub, instr_sll, instr_slt, instr_sltu, instr_xor, instr_srl, instr_sra, instr_or, instr_and;
	reg instr_rdcycle, instr_rdcycleh, instr_rdinstr, instr_rdinstrh, instr_ecall_ebreak, instr_fence;
	reg instr_getq, instr_setq, instr_retirq, instr_maskirq, instr_waitirq, instr_timer;
	wire instr_trap;
	reg [regindex_bits-1:0] decoded_rd, decoded_rs1, decoded_rs2;
	reg [31:0] decoded_imm, decoded_imm_j;
	reg decoder_trigger;
	reg decoder_trigger_q;
	reg decoder_pseudo_trigger;
	reg decoder_pseudo_trigger_q;
	reg compressed_instr;
	reg is_lui_auipc_jal;
	reg is_lb_lh_lw_lbu_lhu;
	reg is_slli_srli_srai;
	reg is_jalr_addi_slti_sltiu_xori_ori_andi;
	reg is_sb_sh_sw;
	reg is_sll_srl_sra;
	reg is_lui_auipc_jal_jalr_addi_add_sub;
	reg is_slti_blt_slt;
	reg is_sltiu_bltu_sltu;
	reg is_beq_bne_blt_bge_bltu_bgeu;
	reg is_lbu_lhu_lw;
	reg is_alu_reg_imm;
	reg is_alu_reg_reg;
	reg is_compare;
	assign instr_trap = (CATCH_ILLINSN || WITH_PCPI) && !{instr_lui, instr_auipc, instr_jal, instr_jalr,
			instr_beq, instr_bne, instr_blt, instr_bge, instr_bltu, instr_bgeu,
			instr_lb, instr_lh, instr_lw, instr_lbu, instr_lhu, instr_sb, instr_sh, instr_sw,
			instr_addi, instr_slti, instr_sltiu, instr_xori, instr_ori, instr_andi, instr_slli, instr_srli, instr_srai,
			instr_add, instr_sub, instr_sll, instr_slt, instr_sltu, instr_xor, instr_srl, instr_sra, instr_or, instr_and,
			instr_rdcycle, instr_rdcycleh, instr_rdinstr, instr_rdinstrh, instr_fence,
			instr_getq, instr_setq, instr_retirq, instr_maskirq, instr_waitirq, instr_timer};
	wire is_rdcycle_rdcycleh_rdinstr_rdinstrh;
	assign is_rdcycle_rdcycleh_rdinstr_rdinstrh = |{instr_rdcycle, instr_rdcycleh, instr_rdinstr, instr_rdinstrh};
	reg [63:0] new_ascii_instr;
	 reg [63:0] dbg_ascii_instr;
	 reg [31:0] dbg_insn_imm;
	 reg [4:0] dbg_insn_rs1;
	 reg [4:0] dbg_insn_rs2;
	 reg [4:0] dbg_insn_rd;
	 reg [31:0] dbg_rs1val;
	 reg [31:0] dbg_rs2val;
	 reg dbg_rs1val_valid;
	 reg dbg_rs2val_valid;
	always @* begin
		new_ascii_instr = "";
		if (instr_lui)      new_ascii_instr = "lui";
		if (instr_auipc)    new_ascii_instr = "auipc";
		if (instr_jal)      new_ascii_instr = "jal";
		if (instr_jalr)     new_ascii_instr = "jalr";
		if (instr_beq)      new_ascii_instr = "beq";
		if (instr_bne)      new_ascii_instr = "bne";
		if (instr_blt)      new_ascii_instr = "blt";
		if (instr_bge)      new_ascii_instr = "bge";
		if (instr_bltu)     new_ascii_instr = "bltu";
		if (instr_bgeu)     new_ascii_instr = "bgeu";
		if (instr_lb)       new_ascii_instr = "lb";
		if (instr_lh)       new_ascii_instr = "lh";
		if (instr_lw)       new_ascii_instr = "lw";
		if (instr_lbu)      new_ascii_instr = "lbu";
		if (instr_lhu)      new_ascii_instr = "lhu";
		if (instr_sb)       new_ascii_instr = "sb";
		if (instr_sh)       new_ascii_instr = "sh";
		if (instr_sw)       new_ascii_instr = "sw";
		if (instr_addi)     new_ascii_instr = "addi";
		if (instr_slti)     new_ascii_instr = "slti";
		if (instr_sltiu)    new_ascii_instr = "sltiu";
		if (instr_xori)     new_ascii_instr = "xori";
		if (instr_ori)      new_ascii_instr = "ori";
		if (instr_andi)     new_ascii_instr = "andi";
		if (instr_slli)     new_ascii_instr = "slli";
		if (instr_srli)     new_ascii_instr = "srli";
		if (instr_srai)     new_ascii_instr = "srai";
		if (instr_add)      new_ascii_instr = "add";
		if (instr_sub)      new_ascii_instr = "sub";
		if (instr_sll)      new_ascii_instr = "sll";
		if (instr_slt)      new_ascii_instr = "slt";
		if (instr_sltu)     new_ascii_instr = "sltu";
		if (instr_xor)      new_ascii_instr = "xor";
		if (instr_srl)      new_ascii_instr = "srl";
		if (instr_sra)      new_ascii_instr = "sra";
		if (instr_or)       new_ascii_instr = "or";
		if (instr_and)      new_ascii_instr = "and";
		if (instr_rdcycle)  new_ascii_instr = "rdcycle";
		if (instr_rdcycleh) new_ascii_instr = "rdcycleh";
		if (instr_rdinstr)  new_ascii_instr = "rdinstr";
		if (instr_rdinstrh) new_ascii_instr = "rdinstrh";
		if (instr_fence)    new_ascii_instr = "fence";
		if (instr_getq)     new_ascii_instr = "getq";
		if (instr_setq)     new_ascii_instr = "setq";
		if (instr_retirq)   new_ascii_instr = "retirq";
		if (instr_maskirq)  new_ascii_instr = "maskirq";
		if (instr_waitirq)  new_ascii_instr = "waitirq";
		if (instr_timer)    new_ascii_instr = "timer";
	end
	reg [63:0] q_ascii_instr;
	reg [31:0] q_insn_imm;
	reg [31:0] q_insn_opcode;
	reg [4:0] q_insn_rs1;
	reg [4:0] q_insn_rs2;
	reg [4:0] q_insn_rd;
	reg dbg_next;
	wire launch_next_insn;
	reg dbg_valid_insn;
	reg [63:0] cached_ascii_instr;
	reg [31:0] cached_insn_imm;
	reg [31:0] cached_insn_opcode;
	reg [4:0] cached_insn_rs1;
	reg [4:0] cached_insn_rs2;
	reg [4:0] cached_insn_rd;
	always @(posedge clk) begin
		q_ascii_instr <= dbg_ascii_instr;
		q_insn_imm <= dbg_insn_imm;
		q_insn_opcode <= dbg_insn_opcode;
		q_insn_rs1 <= dbg_insn_rs1;
		q_insn_rs2 <= dbg_insn_rs2;
		q_insn_rd <= dbg_insn_rd;
		dbg_next <= launch_next_insn;
		if (!resetn || trap)
			dbg_valid_insn <= 0;
		else if (launch_next_insn)
			dbg_valid_insn <= 1;
		if (decoder_trigger_q) begin
			cached_ascii_instr <= new_ascii_instr;
			cached_insn_imm <= decoded_imm;
			if (&next_insn_opcode[1:0])
				cached_insn_opcode <= next_insn_opcode;
			else
				cached_insn_opcode <= {16'b0, next_insn_opcode[15:0]};
			cached_insn_rs1 <= decoded_rs1;
			cached_insn_rs2 <= decoded_rs2;
			cached_insn_rd <= decoded_rd;
		end
		if (launch_next_insn) begin
			dbg_insn_addr <= next_pc;
		end
	end
	always @* begin
		dbg_ascii_instr = q_ascii_instr;
		dbg_insn_imm = q_insn_imm;
		dbg_insn_opcode = q_insn_opcode;
		dbg_insn_rs1 = q_insn_rs1;
		dbg_insn_rs2 = q_insn_rs2;
		dbg_insn_rd = q_insn_rd;
		if (dbg_next) begin
			if (decoder_pseudo_trigger_q) begin
				dbg_ascii_instr = cached_ascii_instr;
				dbg_insn_imm = cached_insn_imm;
				dbg_insn_opcode = cached_insn_opcode;
				dbg_insn_rs1 = cached_insn_rs1;
				dbg_insn_rs2 = cached_insn_rs2;
				dbg_insn_rd = cached_insn_rd;
			end else begin
				dbg_ascii_instr = new_ascii_instr;
				if (&next_insn_opcode[1:0])
					dbg_insn_opcode = next_insn_opcode;
				else
					dbg_insn_opcode = {16'b0, next_insn_opcode[15:0]};
				dbg_insn_imm = decoded_imm;
				dbg_insn_rs1 = decoded_rs1;
				dbg_insn_rs2 = decoded_rs2;
				dbg_insn_rd = decoded_rd;
			end
		end
	end
	always @(posedge clk) begin
		is_lui_auipc_jal <= |{instr_lui, instr_auipc, instr_jal};
		is_lui_auipc_jal_jalr_addi_add_sub <= |{instr_lui, instr_auipc, instr_jal, instr_jalr, instr_addi, instr_add, instr_sub};
		is_slti_blt_slt <= |{instr_slti, instr_blt, instr_slt};
		is_sltiu_bltu_sltu <= |{instr_sltiu, instr_bltu, instr_sltu};
		is_lbu_lhu_lw <= |{instr_lbu, instr_lhu, instr_lw};
		is_compare <= |{is_beq_bne_blt_bge_bltu_bgeu, instr_slti, instr_slt, instr_sltiu, instr_sltu};
		if (mem_do_rinst && mem_done) begin
			instr_lui     <= mem_rdata_latched[6:0] == 7'b0110111;
			instr_auipc   <= mem_rdata_latched[6:0] == 7'b0010111;
			instr_jal     <= mem_rdata_latched[6:0] == 7'b1101111;
			instr_jalr    <= mem_rdata_latched[6:0] == 7'b1100111 && mem_rdata_latched[14:12] == 3'b000;
			instr_retirq  <= mem_rdata_latched[6:0] == 7'b0001011 && mem_rdata_latched[31:25] == 7'b0000010 && ENABLE_IRQ;
			instr_waitirq <= mem_rdata_latched[6:0] == 7'b0001011 && mem_rdata_latched[31:25] == 7'b0000100 && ENABLE_IRQ;
			is_beq_bne_blt_bge_bltu_bgeu <= mem_rdata_latched[6:0] == 7'b1100011;
			is_lb_lh_lw_lbu_lhu          <= mem_rdata_latched[6:0] == 7'b0000011;
			is_sb_sh_sw                  <= mem_rdata_latched[6:0] == 7'b0100011;
			is_alu_reg_imm               <= mem_rdata_latched[6:0] == 7'b0010011;
			is_alu_reg_reg               <= mem_rdata_latched[6:0] == 7'b0110011;
			{ decoded_imm_j[31:20], decoded_imm_j[10:1], decoded_imm_j[11], decoded_imm_j[19:12], decoded_imm_j[0] } <= $signed({mem_rdata_latched[31:12], 1'b0});
			decoded_rd <= mem_rdata_latched[11:7];
			decoded_rs1 <= mem_rdata_latched[19:15];
			decoded_rs2 <= mem_rdata_latched[24:20];
			if (mem_rdata_latched[6:0] == 7'b0001011 && mem_rdata_latched[31:25] == 7'b0000000 && ENABLE_IRQ && ENABLE_IRQ_QREGS)
				decoded_rs1[regindex_bits-1] <= 1; // instr_getq
			if (mem_rdata_latched[6:0] == 7'b0001011 && mem_rdata_latched[31:25] == 7'b0000010 && ENABLE_IRQ)
				decoded_rs1 <= ENABLE_IRQ_QREGS ? irqregs_offset : 3; // instr_retirq
			compressed_instr <= 0;
			if (COMPRESSED_ISA && mem_rdata_latched[1:0] != 2'b11) begin
				compressed_instr <= 1;
				decoded_rd <= 0;
				decoded_rs1 <= 0;
				decoded_rs2 <= 0;
				{ decoded_imm_j[31:11], decoded_imm_j[4], decoded_imm_j[9:8], decoded_imm_j[10], decoded_imm_j[6],
				  decoded_imm_j[7], decoded_imm_j[3:1], decoded_imm_j[5], decoded_imm_j[0] } <= $signed({mem_rdata_latched[12:2], 1'b0});
				case (mem_rdata_latched[1:0])
					2'b00: begin // Quadrant 0
						case (mem_rdata_latched[15:13])
							3'b000: begin // C.ADDI4SPN
								is_alu_reg_imm <= |mem_rdata_latched[12:5];
								decoded_rs1 <= 2;
								decoded_rd <= 8 + mem_rdata_latched[4:2];
							end
							3'b010: begin // C.LW
								is_lb_lh_lw_lbu_lhu <= 1;
								decoded_rs1 <= 8 + mem_rdata_latched[9:7];
								decoded_rd <= 8 + mem_rdata_latched[4:2];
							end
							3'b110: begin // C.SW
								is_sb_sh_sw <= 1;
								decoded_rs1 <= 8 + mem_rdata_latched[9:7];
								decoded_rs2 <= 8 + mem_rdata_latched[4:2];
							end
						endcase
					end
					2'b01: begin // Quadrant 1
						case (mem_rdata_latched[15:13])
							3'b000: begin // C.NOP / C.ADDI
								is_alu_reg_imm <= 1;
								decoded_rd <= mem_rdata_latched[11:7];
								decoded_rs1 <= mem_rdata_latched[11:7];
							end
							3'b001: begin // C.JAL
								instr_jal <= 1;
								decoded_rd <= 1;
							end
							3'b 010: begin // C.LI
								is_alu_reg_imm <= 1;
								decoded_rd <= mem_rdata_latched[11:7];
								decoded_rs1 <= 0;
							end
							3'b 011: begin
								if (mem_rdata_latched[12] || mem_rdata_latched[6:2]) begin
									if (mem_rdata_latched[11:7] == 2) begin // C.ADDI16SP
										is_alu_reg_imm <= 1;
										decoded_rd <= mem_rdata_latched[11:7];
										decoded_rs1 <= mem_rdata_latched[11:7];
									end else begin // C.LUI
										instr_lui <= 1;
										decoded_rd <= mem_rdata_latched[11:7];
										decoded_rs1 <= 0;
									end
								end
							end
							3'b100: begin
								if (!mem_rdata_latched[11] && !mem_rdata_latched[12]) begin // C.SRLI, C.SRAI
									is_alu_reg_imm <= 1;
									decoded_rd <= 8 + mem_rdata_latched[9:7];
									decoded_rs1 <= 8 + mem_rdata_latched[9:7];
									decoded_rs2 <= {mem_rdata_latched[12], mem_rdata_latched[6:2]};
								end
								if (mem_rdata_latched[11:10] == 2'b10) begin // C.ANDI
									is_alu_reg_imm <= 1;
									decoded_rd <= 8 + mem_rdata_latched[9:7];
									decoded_rs1 <= 8 + mem_rdata_latched[9:7];
								end
								if (mem_rdata_latched[12:10] == 3'b011) begin // C.SUB, C.XOR, C.OR, C.AND
									is_alu_reg_reg <= 1;
									decoded_rd <= 8 + mem_rdata_latched[9:7];
									decoded_rs1 <= 8 + mem_rdata_latched[9:7];
									decoded_rs2 <= 8 + mem_rdata_latched[4:2];
								end
							end
							3'b101: begin // C.J
								instr_jal <= 1;
							end
							3'b110: begin // C.BEQZ
								is_beq_bne_blt_bge_bltu_bgeu <= 1;
								decoded_rs1 <= 8 + mem_rdata_latched[9:7];
								decoded_rs2 <= 0;
							end
							3'b111: begin // C.BNEZ
								is_beq_bne_blt_bge_bltu_bgeu <= 1;
								decoded_rs1 <= 8 + mem_rdata_latched[9:7];
								decoded_rs2 <= 0;
							end
						endcase
					end
					2'b10: begin // Quadrant 2
						case (mem_rdata_latched[15:13])
							3'b000: begin // C.SLLI
								if (!mem_rdata_latched[12]) begin
									is_alu_reg_imm <= 1;
									decoded_rd <= mem_rdata_latched[11:7];
									decoded_rs1 <= mem_rdata_latched[11:7];
									decoded_rs2 <= {mem_rdata_latched[12], mem_rdata_latched[6:2]};
								end
							end
							3'b010: begin // C.LWSP
								if (mem_rdata_latched[11:7]) begin
									is_lb_lh_lw_lbu_lhu <= 1;
									decoded_rd <= mem_rdata_latched[11:7];
									decoded_rs1 <= 2;
								end
							end
							3'b100: begin
								if (mem_rdata_latched[12] == 0 && mem_rdata_latched[11:7] != 0 && mem_rdata_latched[6:2] == 0) begin // C.JR
									instr_jalr <= 1;
									decoded_rd <= 0;
									decoded_rs1 <= mem_rdata_latched[11:7];
								end
								if (mem_rdata_latched[12] == 0 && mem_rdata_latched[6:2] != 0) begin // C.MV
									is_alu_reg_reg <= 1;
									decoded_rd <= mem_rdata_latched[11:7];
									decoded_rs1 <= 0;
									decoded_rs2 <= mem_rdata_latched[6:2];
								end
								if (mem_rdata_latched[12] != 0 && mem_rdata_latched[11:7] != 0 && mem_rdata_latched[6:2] == 0) begin // C.JALR
									instr_jalr <= 1;
									decoded_rd <= 1;
									decoded_rs1 <= mem_rdata_latched[11:7];
								end
								if (mem_rdata_latched[12] != 0 && mem_rdata_latched[6:2] != 0) begin // C.ADD
									is_alu_reg_reg <= 1;
									decoded_rd <= mem_rdata_latched[11:7];
									decoded_rs1 <= mem_rdata_latched[11:7];
									decoded_rs2 <= mem_rdata_latched[6:2];
								end
							end
							3'b110: begin // C.SWSP
								is_sb_sh_sw <= 1;
								decoded_rs1 <= 2;
								decoded_rs2 <= mem_rdata_latched[6:2];
							end
						endcase
					end
				endcase
			end
		end
		if (decoder_trigger && !decoder_pseudo_trigger) begin
			pcpi_insn <= WITH_PCPI ? mem_rdata_q : 'bx;
			instr_beq   <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b000;
			instr_bne   <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b001;
			instr_blt   <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b100;
			instr_bge   <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b101;
			instr_bltu  <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b110;
			instr_bgeu  <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b111;
			instr_lb    <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b000;
			instr_lh    <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b001;
			instr_lw    <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b010;
			instr_lbu   <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b100;
			instr_lhu   <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b101;
			instr_sb    <= is_sb_sh_sw && mem_rdata_q[14:12] == 3'b000;
			instr_sh    <= is_sb_sh_sw && mem_rdata_q[14:12] == 3'b001;
			instr_sw    <= is_sb_sh_sw && mem_rdata_q[14:12] == 3'b010;
			instr_addi  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b000;
			instr_slti  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b010;
			instr_sltiu <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b011;
			instr_xori  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b100;
			instr_ori   <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b110;
			instr_andi  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b111;
			instr_slli  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b001 && mem_rdata_q[31:25] == 7'b0000000;
			instr_srli  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0000000;
			instr_srai  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0100000;
			instr_add   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b000 && mem_rdata_q[31:25] == 7'b0000000;
			instr_sub   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b000 && mem_rdata_q[31:25] == 7'b0100000;
			instr_sll   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b001 && mem_rdata_q[31:25] == 7'b0000000;
			instr_slt   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b010 && mem_rdata_q[31:25] == 7'b0000000;
			instr_sltu  <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b011 && mem_rdata_q[31:25] == 7'b0000000;
			instr_xor   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b100 && mem_rdata_q[31:25] == 7'b0000000;
			instr_srl   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0000000;
			instr_sra   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0100000;
			instr_or    <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b110 && mem_rdata_q[31:25] == 7'b0000000;
			instr_and   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b111 && mem_rdata_q[31:25] == 7'b0000000;
			instr_rdcycle  <= ((mem_rdata_q[6:0] == 7'b1110011 && mem_rdata_q[31:12] == 'b11000000000000000010) ||
			                   (mem_rdata_q[6:0] == 7'b1110011 && mem_rdata_q[31:12] == 'b11000000000100000010)) && ENABLE_COUNTERS;
			instr_rdcycleh <= ((mem_rdata_q[6:0] == 7'b1110011 && mem_rdata_q[31:12] == 'b11001000000000000010) ||
			                   (mem_rdata_q[6:0] == 7'b1110011 && mem_rdata_q[31:12] == 'b11001000000100000010)) && ENABLE_COUNTERS && ENABLE_COUNTERS64;
			instr_rdinstr  <=  (mem_rdata_q[6:0] == 7'b1110011 && mem_rdata_q[31:12] == 'b11000000001000000010) && ENABLE_COUNTERS;
			instr_rdinstrh <=  (mem_rdata_q[6:0] == 7'b1110011 && mem_rdata_q[31:12] == 'b11001000001000000010) && ENABLE_COUNTERS && ENABLE_COUNTERS64;
			instr_ecall_ebreak <= ((mem_rdata_q[6:0] == 7'b1110011 && !mem_rdata_q[31:21] && !mem_rdata_q[19:7]) ||
					(COMPRESSED_ISA && mem_rdata_q[15:0] == 16'h9002));
			instr_fence <= (mem_rdata_q[6:0] == 7'b0001111 && !mem_rdata_q[14:12]);
			instr_getq    <= mem_rdata_q[6:0] == 7'b0001011 && mem_rdata_q[31:25] == 7'b0000000 && ENABLE_IRQ && ENABLE_IRQ_QREGS;
			instr_setq    <= mem_rdata_q[6:0] == 7'b0001011 && mem_rdata_q[31:25] == 7'b0000001 && ENABLE_IRQ && ENABLE_IRQ_QREGS;
			instr_maskirq <= mem_rdata_q[6:0] == 7'b0001011 && mem_rdata_q[31:25] == 7'b0000011 && ENABLE_IRQ;
			instr_timer   <= mem_rdata_q[6:0] == 7'b0001011 && mem_rdata_q[31:25] == 7'b0000101 && ENABLE_IRQ && ENABLE_IRQ_TIMER;
			is_slli_srli_srai <= is_alu_reg_imm && |{
				mem_rdata_q[14:12] == 3'b001 && mem_rdata_q[31:25] == 7'b0000000,
				mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0000000,
				mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0100000
			};
			is_jalr_addi_slti_sltiu_xori_ori_andi <= instr_jalr || is_alu_reg_imm && |{
				mem_rdata_q[14:12] == 3'b000,
				mem_rdata_q[14:12] == 3'b010,
				mem_rdata_q[14:12] == 3'b011,
				mem_rdata_q[14:12] == 3'b100,
				mem_rdata_q[14:12] == 3'b110,
				mem_rdata_q[14:12] == 3'b111
			};
			is_sll_srl_sra <= is_alu_reg_reg && |{
				mem_rdata_q[14:12] == 3'b001 && mem_rdata_q[31:25] == 7'b0000000,
				mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0000000,
				mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0100000
			};
			is_lui_auipc_jal_jalr_addi_add_sub <= 0;
			is_compare <= 0;
			(* parallel_case *)
			case (1'b1)
				instr_jal:
					decoded_imm <= decoded_imm_j;
				|{instr_lui, instr_auipc}:
					decoded_imm <= mem_rdata_q[31:12] << 12;
				|{instr_jalr, is_lb_lh_lw_lbu_lhu, is_alu_reg_imm}:
					decoded_imm <= $signed(mem_rdata_q[31:20]);
				is_beq_bne_blt_bge_bltu_bgeu:
					decoded_imm <= $signed({mem_rdata_q[31], mem_rdata_q[7], mem_rdata_q[30:25], mem_rdata_q[11:8], 1'b0});
				is_sb_sh_sw:
					decoded_imm <= $signed({mem_rdata_q[31:25], mem_rdata_q[11:7]});
				default:
					decoded_imm <= 1'bx;
			endcase
		end
		if (!resetn) begin
			is_beq_bne_blt_bge_bltu_bgeu <= 0;
			is_compare <= 0;
			instr_beq   <= 0;
			instr_bne   <= 0;
			instr_blt   <= 0;
			instr_bge   <= 0;
			instr_bltu  <= 0;
			instr_bgeu  <= 0;
			instr_addi  <= 0;
			instr_slti  <= 0;
			instr_sltiu <= 0;
			instr_xori  <= 0;
			instr_ori   <= 0;
			instr_andi  <= 0;
			instr_add   <= 0;
			instr_sub   <= 0;
			instr_sll   <= 0;
			instr_slt   <= 0;
			instr_sltu  <= 0;
			instr_xor   <= 0;
			instr_srl   <= 0;
			instr_sra   <= 0;
			instr_or    <= 0;
			instr_and   <= 0;
			instr_fence <= 0;
		end
	end
	// Main State Machine
	localparam cpu_state_trap   = 8'b10000000;
	localparam cpu_state_fetch  = 8'b01000000;
	localparam cpu_state_ld_rs1 = 8'b00100000;
	localparam cpu_state_ld_rs2 = 8'b00010000;
	localparam cpu_state_exec   = 8'b00001000;
	localparam cpu_state_shift  = 8'b00000100;
	localparam cpu_state_stmem  = 8'b00000010;
	localparam cpu_state_ldmem  = 8'b00000001;
	reg [7:0] cpu_state;
	reg [1:0] irq_state;
	 reg [127:0] dbg_ascii_state;
	always @* begin
		dbg_ascii_state = "";
		if (cpu_state == cpu_state_trap)   dbg_ascii_state = "trap";
		if (cpu_state == cpu_state_fetch)  dbg_ascii_state = "fetch";
		if (cpu_state == cpu_state_ld_rs1) dbg_ascii_state = "ld_rs1";
		if (cpu_state == cpu_state_ld_rs2) dbg_ascii_state = "ld_rs2";
		if (cpu_state == cpu_state_exec)   dbg_ascii_state = "exec";
		if (cpu_state == cpu_state_shift)  dbg_ascii_state = "shift";
		if (cpu_state == cpu_state_stmem)  dbg_ascii_state = "stmem";
		if (cpu_state == cpu_state_ldmem)  dbg_ascii_state = "ldmem";
	end
	reg set_mem_do_rinst;
	reg set_mem_do_rdata;
	reg set_mem_do_wdata;
	reg latched_store;
	reg latched_stalu;
	reg latched_branch;
	reg latched_compr;
	reg latched_trace;
	reg latched_is_lu;
	reg latched_is_lh;
	reg latched_is_lb;
	reg [regindex_bits-1:0] latched_rd;
	reg [31:0] current_pc;
	assign next_pc = latched_store && latched_branch ? reg_out & ~1 : reg_next_pc;
	reg [3:0] pcpi_timeout_counter;
	reg pcpi_timeout;
	reg [31:0] next_irq_pending;
	reg do_waitirq;
	reg [31:0] alu_out, alu_out_q;
	reg alu_out_0, alu_out_0_q;
	reg alu_wait, alu_wait_2;
	reg [31:0] alu_add_sub;
	reg [31:0] alu_shl, alu_shr;
	reg alu_eq, alu_ltu, alu_lts;
	generate if (TWO_CYCLE_ALU) begin
		always @(posedge clk) begin
			alu_add_sub <= instr_sub ? reg_op1 - reg_op2 : reg_op1 + reg_op2;
			alu_eq <= reg_op1 == reg_op2;
			alu_lts <= $signed(reg_op1) < $signed(reg_op2);
			alu_ltu <= reg_op1 < reg_op2;
			alu_shl <= reg_op1 << reg_op2[4:0];
			alu_shr <= $signed({instr_sra || instr_srai ? reg_op1[31] : 1'b0, reg_op1}) >>> reg_op2[4:0];
		end
	end else begin
		always @* begin
			alu_add_sub = instr_sub ? reg_op1 - reg_op2 : reg_op1 + reg_op2;
			alu_eq = reg_op1 == reg_op2;
			alu_lts = $signed(reg_op1) < $signed(reg_op2);
			alu_ltu = reg_op1 < reg_op2;
			alu_shl = reg_op1 << reg_op2[4:0];
			alu_shr = $signed({instr_sra || instr_srai ? reg_op1[31] : 1'b0, reg_op1}) >>> reg_op2[4:0];
		end
	end endgenerate
	always @* begin
		alu_out_0 = 'bx;
		(* parallel_case, full_case *)
		case (1'b1)
			instr_beq:
				alu_out_0 = alu_eq;
			instr_bne:
				alu_out_0 = !alu_eq;
			instr_bge:
				alu_out_0 = !alu_lts;
			instr_bgeu:
				alu_out_0 = !alu_ltu;
			is_slti_blt_slt && (!TWO_CYCLE_COMPARE || !{instr_beq,instr_bne,instr_bge,instr_bgeu}):
				alu_out_0 = alu_lts;
			is_sltiu_bltu_sltu && (!TWO_CYCLE_COMPARE || !{instr_beq,instr_bne,instr_bge,instr_bgeu}):
				alu_out_0 = alu_ltu;
		endcase
		alu_out = 'bx;
		(* parallel_case, full_case *)
		case (1'b1)
			is_lui_auipc_jal_jalr_addi_add_sub:
				alu_out = alu_add_sub;
			is_compare:
				alu_out = alu_out_0;
			instr_xori || instr_xor:
				alu_out = reg_op1 ^ reg_op2;
			instr_ori || instr_or:
				alu_out = reg_op1 | reg_op2;
			instr_andi || instr_and:
				alu_out = reg_op1 & reg_op2;
			BARREL_SHIFTER && (instr_sll || instr_slli):
				alu_out = alu_shl;
			BARREL_SHIFTER && (instr_srl || instr_srli || instr_sra || instr_srai):
				alu_out = alu_shr;
		endcase
	end
	reg clear_prefetched_high_word_q;
	always @(posedge clk) clear_prefetched_high_word_q <= clear_prefetched_high_word;
	always @* begin
		clear_prefetched_high_word = clear_prefetched_high_word_q;
		if (!prefetched_high_word)
			clear_prefetched_high_word = 0;
		if (latched_branch || irq_state || !resetn)
			clear_prefetched_high_word = COMPRESSED_ISA;
	end
	reg cpuregs_write;
	reg [31:0] cpuregs_wrdata;
	reg [31:0] cpuregs_rs1;
	reg [31:0] cpuregs_rs2;
	reg [regindex_bits-1:0] decoded_rs;
	always @* begin
		cpuregs_write = 0;
		cpuregs_wrdata = 'bx;
		if (cpu_state == cpu_state_fetch) begin
			(* parallel_case *)
			case (1'b1)
				latched_branch: begin
					cpuregs_wrdata = reg_pc + (latched_compr ? 2 : 4);
					cpuregs_write = 1;
				end
				latched_store && !latched_branch: begin
					cpuregs_wrdata = latched_stalu ? alu_out_q : reg_out;
					cpuregs_write = 1;
				end
				ENABLE_IRQ && irq_state[0]: begin
					cpuregs_wrdata = reg_next_pc | latched_compr;
					cpuregs_write = 1;
				end
				ENABLE_IRQ && irq_state[1]: begin
					cpuregs_wrdata = irq_pending & ~irq_mask;
					cpuregs_write = 1;
				end
			endcase
		end
	end
	always @(posedge clk) begin
		if (resetn && cpuregs_write && latched_rd)
			cpuregs[latched_rd] <= cpuregs_wrdata;
	end
	always @* begin
		decoded_rs = 'bx;
		if (ENABLE_REGS_DUALPORT) begin
			cpuregs_rs1 = decoded_rs1 ? cpuregs[decoded_rs1] : 0;
			cpuregs_rs2 = decoded_rs2 ? cpuregs[decoded_rs2] : 0;
		end else begin
			decoded_rs = (cpu_state == cpu_state_ld_rs2) ? decoded_rs2 : decoded_rs1;
			cpuregs_rs1 = decoded_rs ? cpuregs[decoded_rs] : 0;
			cpuregs_rs2 = cpuregs_rs1;
		end
	end
	assign launch_next_insn = cpu_state == cpu_state_fetch && decoder_trigger && (!ENABLE_IRQ || irq_delay || irq_active || !(irq_pending & ~irq_mask));
	always @(posedge clk) begin
		trap <= 0;
		reg_sh <= 'bx;
		reg_out <= 'bx;
		set_mem_do_rinst = 0;
		set_mem_do_rdata = 0;
		set_mem_do_wdata = 0;
		alu_out_0_q <= alu_out_0;
		alu_out_q <= alu_out;
		alu_wait <= 0;
		alu_wait_2 <= 0;
		if (launch_next_insn) begin
			dbg_rs1val <= 'bx;
			dbg_rs2val <= 'bx;
			dbg_rs1val_valid <= 0;
			dbg_rs2val_valid <= 0;
		end
		if (WITH_PCPI && CATCH_ILLINSN) begin
			if (resetn && pcpi_valid && !pcpi_int_wait) begin
				if (pcpi_timeout_counter)
					pcpi_timeout_counter <= pcpi_timeout_counter - 1;
			end else
				pcpi_timeout_counter <= ~0;
			pcpi_timeout <= !pcpi_timeout_counter;
		end
		if (ENABLE_COUNTERS) begin
			count_cycle <= resetn ? count_cycle + 1 : 0;
			if (!ENABLE_COUNTERS64) count_cycle[63:32] <= 0;
		end else begin
			count_cycle <= 'bx;
			count_instr <= 'bx;
		end
		next_irq_pending = ENABLE_IRQ ? irq_pending & LATCHED_IRQ : 'bx;
		if (ENABLE_IRQ && ENABLE_IRQ_TIMER && timer) begin
			timer <= timer - 1;
		end
		decoder_trigger <= mem_do_rinst && mem_done;
		decoder_trigger_q <= decoder_trigger;
		decoder_pseudo_trigger <= 0;
		decoder_pseudo_trigger_q <= decoder_pseudo_trigger;
		do_waitirq <= 0;
		trace_valid <= 0;
		if (!ENABLE_TRACE)
			trace_data <= 'bx;
		if (!resetn) begin
			reg_pc <= PROGADDR_RESET;
			reg_next_pc <= PROGADDR_RESET;
			if (ENABLE_COUNTERS)
				count_instr <= 0;
			latched_store <= 0;
			latched_stalu <= 0;
			latched_branch <= 0;
			latched_trace <= 0;
			latched_is_lu <= 0;
			latched_is_lh <= 0;
			latched_is_lb <= 0;
			pcpi_valid <= 0;
			pcpi_timeout <= 0;
			irq_active <= 0;
			irq_delay <= 0;
			irq_mask <= ~0;
			next_irq_pending = 0;
			irq_state <= 0;
			eoi <= 0;
			timer <= 0;
			if (~STACKADDR) begin
				latched_store <= 1;
				latched_rd <= 2;
				reg_out <= STACKADDR;
			end
			cpu_state <= cpu_state_fetch;
		end else
		(* parallel_case, full_case *)
		case (cpu_state)
			cpu_state_trap: begin
				trap <= 1;
			end
			cpu_state_fetch: begin
				mem_do_rinst <= !decoder_trigger && !do_waitirq;
				mem_wordsize <= 0;
				current_pc = reg_next_pc;
				(* parallel_case *)
				case (1'b1)
					latched_branch: begin
						current_pc = latched_store ? (latched_stalu ? alu_out_q : reg_out) & ~1 : reg_next_pc;
						
					end
					latched_store && !latched_branch: begin
						
					end
					ENABLE_IRQ && irq_state[0]: begin
						current_pc = PROGADDR_IRQ;
						irq_active <= 1;
						mem_do_rinst <= 1;
					end
					ENABLE_IRQ && irq_state[1]: begin
						eoi <= irq_pending & ~irq_mask;
						next_irq_pending = next_irq_pending & irq_mask;
					end
				endcase
				if (ENABLE_TRACE && latched_trace) begin
					latched_trace <= 0;
					trace_valid <= 1;
					if (latched_branch)
						trace_data <= (irq_active ? TRACE_IRQ : 0) | TRACE_BRANCH | (current_pc & 32'hfffffffe);
					else
						trace_data <= (irq_active ? TRACE_IRQ : 0) | (latched_stalu ? alu_out_q : reg_out);
				end
				reg_pc <= current_pc;
				reg_next_pc <= current_pc;
				latched_store <= 0;
				latched_stalu <= 0;
				latched_branch <= 0;
				latched_is_lu <= 0;
				latched_is_lh <= 0;
				latched_is_lb <= 0;
				latched_rd <= decoded_rd;
				latched_compr <= compressed_instr;
				if (ENABLE_IRQ && ((decoder_trigger && !irq_active && !irq_delay && |(irq_pending & ~irq_mask)) || irq_state)) begin
					irq_state <=
						irq_state == 2'b00 ? 2'b01 :
						irq_state == 2'b01 ? 2'b10 : 2'b00;
					latched_compr <= latched_compr;
					if (ENABLE_IRQ_QREGS)
						latched_rd <= irqregs_offset | irq_state[0];
					else
						latched_rd <= irq_state[0] ? 4 : 3;
				end else
				if (ENABLE_IRQ && (decoder_trigger || do_waitirq) && instr_waitirq) begin
					if (irq_pending) begin
						latched_store <= 1;
						reg_out <= irq_pending;
						reg_next_pc <= current_pc + (compressed_instr ? 2 : 4);
						mem_do_rinst <= 1;
					end else
						do_waitirq <= 1;
				end else
				if (decoder_trigger) begin
					
					irq_delay <= irq_active;
					reg_next_pc <= current_pc + (compressed_instr ? 2 : 4);
					if (ENABLE_TRACE)
						latched_trace <= 1;
					if (ENABLE_COUNTERS) begin
						count_instr <= count_instr + 1;
						if (!ENABLE_COUNTERS64) count_instr[63:32] <= 0;
					end
					if (instr_jal) begin
						mem_do_rinst <= 1;
						reg_next_pc <= current_pc + decoded_imm_j;
						latched_branch <= 1;
					end else begin
						mem_do_rinst <= 0;
						mem_do_prefetch <= !instr_jalr && !instr_retirq;
						cpu_state <= cpu_state_ld_rs1;
					end
				end
			end
			cpu_state_ld_rs1: begin
				reg_op1 <= 'bx;
				reg_op2 <= 'bx;
				(* parallel_case *)
				case (1'b1)
					(CATCH_ILLINSN || WITH_PCPI) && instr_trap: begin
						if (WITH_PCPI) begin
							
							reg_op1 <= cpuregs_rs1;
							dbg_rs1val <= cpuregs_rs1;
							dbg_rs1val_valid <= 1;
							if (ENABLE_REGS_DUALPORT) begin
								pcpi_valid <= 1;
								
								reg_sh <= cpuregs_rs2;
								reg_op2 <= cpuregs_rs2;
								dbg_rs2val <= cpuregs_rs2;
								dbg_rs2val_valid <= 1;
								if (pcpi_int_ready) begin
									mem_do_rinst <= 1;
									pcpi_valid <= 0;
									reg_out <= pcpi_int_rd;
									latched_store <= pcpi_int_wr;
									cpu_state <= cpu_state_fetch;
								end else
								if (CATCH_ILLINSN && (pcpi_timeout || instr_ecall_ebreak)) begin
									pcpi_valid <= 0;
									
									if (ENABLE_IRQ && !irq_mask[irq_ebreak] && !irq_active) begin
										next_irq_pending[irq_ebreak] = 1;
										cpu_state <= cpu_state_fetch;
									end else
										cpu_state <= cpu_state_trap;
								end
							end else begin
								cpu_state <= cpu_state_ld_rs2;
							end
						end else begin
							
							if (ENABLE_IRQ && !irq_mask[irq_ebreak] && !irq_active) begin
								next_irq_pending[irq_ebreak] = 1;
								cpu_state <= cpu_state_fetch;
							end else
								cpu_state <= cpu_state_trap;
						end
					end
					ENABLE_COUNTERS && is_rdcycle_rdcycleh_rdinstr_rdinstrh: begin
						(* parallel_case, full_case *)
						case (1'b1)
							instr_rdcycle:
								reg_out <= count_cycle[31:0];
							instr_rdcycleh && ENABLE_COUNTERS64:
								reg_out <= count_cycle[63:32];
							instr_rdinstr:
								reg_out <= count_instr[31:0];
							instr_rdinstrh && ENABLE_COUNTERS64:
								reg_out <= count_instr[63:32];
						endcase
						latched_store <= 1;
						cpu_state <= cpu_state_fetch;
					end
					is_lui_auipc_jal: begin
						reg_op1 <= instr_lui ? 0 : reg_pc;
						reg_op2 <= decoded_imm;
						if (TWO_CYCLE_ALU)
							alu_wait <= 1;
						else
							mem_do_rinst <= mem_do_prefetch;
						cpu_state <= cpu_state_exec;
					end
					ENABLE_IRQ && ENABLE_IRQ_QREGS && instr_getq: begin
						
						reg_out <= cpuregs_rs1;
						dbg_rs1val <= cpuregs_rs1;
						dbg_rs1val_valid <= 1;
						latched_store <= 1;
						cpu_state <= cpu_state_fetch;
					end
					ENABLE_IRQ && ENABLE_IRQ_QREGS && instr_setq: begin
						
						reg_out <= cpuregs_rs1;
						dbg_rs1val <= cpuregs_rs1;
						dbg_rs1val_valid <= 1;
						latched_rd <= latched_rd | irqregs_offset;
						latched_store <= 1;
						cpu_state <= cpu_state_fetch;
					end
					ENABLE_IRQ && instr_retirq: begin
						eoi <= 0;
						irq_active <= 0;
						latched_branch <= 1;
						latched_store <= 1;
						
						reg_out <= CATCH_MISALIGN ? (cpuregs_rs1 & 32'h fffffffe) : cpuregs_rs1;
						dbg_rs1val <= cpuregs_rs1;
						dbg_rs1val_valid <= 1;
						cpu_state <= cpu_state_fetch;
					end
					ENABLE_IRQ && instr_maskirq: begin
						latched_store <= 1;
						reg_out <= irq_mask;
						
						irq_mask <= cpuregs_rs1 | MASKED_IRQ;
						dbg_rs1val <= cpuregs_rs1;
						dbg_rs1val_valid <= 1;
						cpu_state <= cpu_state_fetch;
					end
					ENABLE_IRQ && ENABLE_IRQ_TIMER && instr_timer: begin
						latched_store <= 1;
						reg_out <= timer;
						
						timer <= cpuregs_rs1;
						dbg_rs1val <= cpuregs_rs1;
						dbg_rs1val_valid <= 1;
						cpu_state <= cpu_state_fetch;
					end
					is_lb_lh_lw_lbu_lhu && !instr_trap: begin
						
						reg_op1 <= cpuregs_rs1;
						dbg_rs1val <= cpuregs_rs1;
						dbg_rs1val_valid <= 1;
						cpu_state <= cpu_state_ldmem;
						mem_do_rinst <= 1;
					end
					is_slli_srli_srai && !BARREL_SHIFTER: begin
						
						reg_op1 <= cpuregs_rs1;
						dbg_rs1val <= cpuregs_rs1;
						dbg_rs1val_valid <= 1;
						reg_sh <= decoded_rs2;
						cpu_state <= cpu_state_shift;
					end
					is_jalr_addi_slti_sltiu_xori_ori_andi, is_slli_srli_srai && BARREL_SHIFTER: begin
						
						reg_op1 <= cpuregs_rs1;
						dbg_rs1val <= cpuregs_rs1;
						dbg_rs1val_valid <= 1;
						reg_op2 <= is_slli_srli_srai && BARREL_SHIFTER ? decoded_rs2 : decoded_imm;
						if (TWO_CYCLE_ALU)
							alu_wait <= 1;
						else
							mem_do_rinst <= mem_do_prefetch;
						cpu_state <= cpu_state_exec;
					end
					default: begin
						
						reg_op1 <= cpuregs_rs1;
						dbg_rs1val <= cpuregs_rs1;
						dbg_rs1val_valid <= 1;
						if (ENABLE_REGS_DUALPORT) begin
							
							reg_sh <= cpuregs_rs2;
							reg_op2 <= cpuregs_rs2;
							dbg_rs2val <= cpuregs_rs2;
							dbg_rs2val_valid <= 1;
							(* parallel_case *)
							case (1'b1)
								is_sb_sh_sw: begin
									cpu_state <= cpu_state_stmem;
									mem_do_rinst <= 1;
								end
								is_sll_srl_sra && !BARREL_SHIFTER: begin
									cpu_state <= cpu_state_shift;
								end
								default: begin
									if (TWO_CYCLE_ALU || (TWO_CYCLE_COMPARE && is_beq_bne_blt_bge_bltu_bgeu)) begin
										alu_wait_2 <= TWO_CYCLE_ALU && (TWO_CYCLE_COMPARE && is_beq_bne_blt_bge_bltu_bgeu);
										alu_wait <= 1;
									end else
										mem_do_rinst <= mem_do_prefetch;
									cpu_state <= cpu_state_exec;
								end
							endcase
						end else
							cpu_state <= cpu_state_ld_rs2;
					end
				endcase
			end
			cpu_state_ld_rs2: begin
				
				reg_sh <= cpuregs_rs2;
				reg_op2 <= cpuregs_rs2;
				dbg_rs2val <= cpuregs_rs2;
				dbg_rs2val_valid <= 1;
				(* parallel_case *)
				case (1'b1)
					WITH_PCPI && instr_trap: begin
						pcpi_valid <= 1;
						if (pcpi_int_ready) begin
							mem_do_rinst <= 1;
							pcpi_valid <= 0;
							reg_out <= pcpi_int_rd;
							latched_store <= pcpi_int_wr;
							cpu_state <= cpu_state_fetch;
						end else
						if (CATCH_ILLINSN && (pcpi_timeout || instr_ecall_ebreak)) begin
							pcpi_valid <= 0;
							
							if (ENABLE_IRQ && !irq_mask[irq_ebreak] && !irq_active) begin
								next_irq_pending[irq_ebreak] = 1;
								cpu_state <= cpu_state_fetch;
							end else
								cpu_state <= cpu_state_trap;
						end
					end
					is_sb_sh_sw: begin
						cpu_state <= cpu_state_stmem;
						mem_do_rinst <= 1;
					end
					is_sll_srl_sra && !BARREL_SHIFTER: begin
						cpu_state <= cpu_state_shift;
					end
					default: begin
						if (TWO_CYCLE_ALU || (TWO_CYCLE_COMPARE && is_beq_bne_blt_bge_bltu_bgeu)) begin
							alu_wait_2 <= TWO_CYCLE_ALU && (TWO_CYCLE_COMPARE && is_beq_bne_blt_bge_bltu_bgeu);
							alu_wait <= 1;
						end else
							mem_do_rinst <= mem_do_prefetch;
						cpu_state <= cpu_state_exec;
					end
				endcase
			end
			cpu_state_exec: begin
				reg_out <= reg_pc + decoded_imm;
				if ((TWO_CYCLE_ALU || TWO_CYCLE_COMPARE) && (alu_wait || alu_wait_2)) begin
					mem_do_rinst <= mem_do_prefetch && !alu_wait_2;
					alu_wait <= alu_wait_2;
				end else
				if (is_beq_bne_blt_bge_bltu_bgeu) begin
					latched_rd <= 0;
					latched_store <= TWO_CYCLE_COMPARE ? alu_out_0_q : alu_out_0;
					latched_branch <= TWO_CYCLE_COMPARE ? alu_out_0_q : alu_out_0;
					if (mem_done)
						cpu_state <= cpu_state_fetch;
					if (TWO_CYCLE_COMPARE ? alu_out_0_q : alu_out_0) begin
						decoder_trigger <= 0;
						set_mem_do_rinst = 1;
					end
				end else begin
					latched_branch <= instr_jalr;
					latched_store <= 1;
					latched_stalu <= 1;
					cpu_state <= cpu_state_fetch;
				end
			end
			cpu_state_shift: begin
				latched_store <= 1;
				if (reg_sh == 0) begin
					reg_out <= reg_op1;
					mem_do_rinst <= mem_do_prefetch;
					cpu_state <= cpu_state_fetch;
				end else if (TWO_STAGE_SHIFT && reg_sh >= 4) begin
					(* parallel_case, full_case *)
					case (1'b1)
						instr_slli || instr_sll: reg_op1 <= reg_op1 << 4;
						instr_srli || instr_srl: reg_op1 <= reg_op1 >> 4;
						instr_srai || instr_sra: reg_op1 <= $signed(reg_op1) >>> 4;
					endcase
					reg_sh <= reg_sh - 4;
				end else begin
					(* parallel_case, full_case *)
					case (1'b1)
						instr_slli || instr_sll: reg_op1 <= reg_op1 << 1;
						instr_srli || instr_srl: reg_op1 <= reg_op1 >> 1;
						instr_srai || instr_sra: reg_op1 <= $signed(reg_op1) >>> 1;
					endcase
					reg_sh <= reg_sh - 1;
				end
			end
			cpu_state_stmem: begin
				if (ENABLE_TRACE)
					reg_out <= reg_op2;
				if (!mem_do_prefetch || mem_done) begin
					if (!mem_do_wdata) begin
						(* parallel_case, full_case *)
						case (1'b1)
							instr_sb: mem_wordsize <= 2;
							instr_sh: mem_wordsize <= 1;
							instr_sw: mem_wordsize <= 0;
						endcase
						if (ENABLE_TRACE) begin
							trace_valid <= 1;
							trace_data <= (irq_active ? TRACE_IRQ : 0) | TRACE_ADDR | ((reg_op1 + decoded_imm) & 32'hffffffff);
						end
						reg_op1 <= reg_op1 + decoded_imm;
						set_mem_do_wdata = 1;
					end
					if (!mem_do_prefetch && mem_done) begin
						cpu_state <= cpu_state_fetch;
						decoder_trigger <= 1;
						decoder_pseudo_trigger <= 1;
					end
				end
			end
			cpu_state_ldmem: begin
				latched_store <= 1;
				if (!mem_do_prefetch || mem_done) begin
					if (!mem_do_rdata) begin
						(* parallel_case, full_case *)
						case (1'b1)
							instr_lb || instr_lbu: mem_wordsize <= 2;
							instr_lh || instr_lhu: mem_wordsize <= 1;
							instr_lw: mem_wordsize <= 0;
						endcase
						latched_is_lu <= is_lbu_lhu_lw;
						latched_is_lh <= instr_lh;
						latched_is_lb <= instr_lb;
						if (ENABLE_TRACE) begin
							trace_valid <= 1;
							trace_data <= (irq_active ? TRACE_IRQ : 0) | TRACE_ADDR | ((reg_op1 + decoded_imm) & 32'hffffffff);
						end
						reg_op1 <= reg_op1 + decoded_imm;
						set_mem_do_rdata = 1;
					end
					if (!mem_do_prefetch && mem_done) begin
						(* parallel_case, full_case *)
						case (1'b1)
							latched_is_lu: reg_out <= mem_rdata_word;
							latched_is_lh: reg_out <= $signed(mem_rdata_word[15:0]);
							latched_is_lb: reg_out <= $signed(mem_rdata_word[7:0]);
						endcase
						decoder_trigger <= 1;
						decoder_pseudo_trigger <= 1;
						cpu_state <= cpu_state_fetch;
					end
				end
			end
		endcase
		if (ENABLE_IRQ) begin
			next_irq_pending = next_irq_pending | irq;
			if(ENABLE_IRQ_TIMER && timer)
				if (timer - 1 == 0)
					next_irq_pending[irq_timer] = 1;
		end
		if (CATCH_MISALIGN && resetn && (mem_do_rdata || mem_do_wdata)) begin
			if (mem_wordsize == 0 && reg_op1[1:0] != 0) begin
				
				if (ENABLE_IRQ && !irq_mask[irq_buserror] && !irq_active) begin
					next_irq_pending[irq_buserror] = 1;
				end else
					cpu_state <= cpu_state_trap;
			end
			if (mem_wordsize == 1 && reg_op1[0] != 0) begin
				
				if (ENABLE_IRQ && !irq_mask[irq_buserror] && !irq_active) begin
					next_irq_pending[irq_buserror] = 1;
				end else
					cpu_state <= cpu_state_trap;
			end
		end
		if (CATCH_MISALIGN && resetn && mem_do_rinst && (COMPRESSED_ISA ? reg_pc[0] : |reg_pc[1:0])) begin
			
			if (ENABLE_IRQ && !irq_mask[irq_buserror] && !irq_active) begin
				next_irq_pending[irq_buserror] = 1;
			end else
				cpu_state <= cpu_state_trap;
		end
		if (!CATCH_ILLINSN && decoder_trigger_q && !decoder_pseudo_trigger_q && instr_ecall_ebreak) begin
			cpu_state <= cpu_state_trap;
		end
		if (!resetn || mem_done) begin
			mem_do_prefetch <= 0;
			mem_do_rinst <= 0;
			mem_do_rdata <= 0;
			mem_do_wdata <= 0;
		end
		if (set_mem_do_rinst)
			mem_do_rinst <= 1;
		if (set_mem_do_rdata)
			mem_do_rdata <= 1;
		if (set_mem_do_wdata)
			mem_do_wdata <= 1;
		irq_pending <= next_irq_pending & ~MASKED_IRQ;
		if (!CATCH_MISALIGN) begin
			if (COMPRESSED_ISA) begin
				reg_pc[0] <= 0;
				reg_next_pc[0] <= 0;
			end else begin
				reg_pc[1:0] <= 0;
				reg_next_pc[1:0] <= 0;
			end
		end
		current_pc = 'bx;
	end
	// Formal Verification
endmodule
/* verilator lint_on WIDTH */

/*****************************************************************************
 * Function: Single Port Memory (la_spram)
 * Copyright: Lambda Project Authors. All rights Reserved.
 * License:  MIT (see LICENSE file in Lambda repository)
 *
 * Docs:
 *
 * This is a wrapper for selecting from a set of hardened memory macros.
 *
 * A synthesizable reference model is used when the PROP is DEFAULT. The
 * synthesizable model does not implement the ctrl interface and should
 * only be used for basic testing and for synthesizing for FPGA devices.
 * Advanced ASIC development should rely on complete functional models
 * supplied on a per macro basis.
 *
 * Technology specific implementations of "la_spram" would generally include
 * one or more hardcoded instantiations of la_spram modules with a generate
 * statement relying on the "PROP" to select between the list of modules
 * at build time.
 *
 ****************************************************************************/
(* keep_hierarchy *)
module la_spram #(
    parameter DW       = 32,         // Memory width
    parameter AW       = 10,         // Address width (derived)
    parameter BYTEMASK = 0,          // 1=byte mask, 0=bit mask
    parameter PROP     = "DEFAULT",  // Pass through variable for hard macro
    parameter CTRLW    = 32,         // Width of ctrl interface
    parameter STATUSW  = 32          // Width of status interface
) (  // Memory interface
    input clk,  // write clock
    input ce,  // chip enable
    input we,  // write enable
    input [(BYTEMASK?DW/8 : DW)-1:0] wmask,  // bit or byte write mask
    input [AW-1:0] addr,  //write address
    input [DW-1:0] din,  //write data
    output [DW-1:0] dout,  //read output data
    // Technology interfaces
    input selctrl,  // selects control interface
    input [CTRLW-1:0] ctrl,  // pass through control interface
    output [STATUSW-1:0] status  // pass through status interface
);
  // Total number of bits
  localparam TOTAL_BITS = (2 ** AW) * DW;
  // Determine which memory to select
  //verilator lint_off WIDTHEXPAND
  localparam MEM_PROP = (PROP != "DEFAULT") ? PROP : "sky130_sram_2kbyte_1rw1r_32x512_8";
  //verilator lint_on WIDTHEXPAND
  localparam MEM_WIDTH = (MEM_PROP == "sky130_sram_2kbyte_1rw1r_32x512_8") ? 32 : 0;
  localparam MEM_DEPTH = (MEM_PROP == "sky130_sram_2kbyte_1rw1r_32x512_8") ? 9 : 0;
  generate
    if (MEM_PROP == "SOFT") begin : isoft
      la_spram_impl #(
          .DW(DW),
          .AW(AW),
          .BYTEMASK(BYTEMASK),
          .PROP(PROP),
          .CTRLW(CTRLW),
          .STATUSW(STATUSW)
      ) memory (
          .clk(clk),
          .ce(ce),
          .we(we),
          .wmask(wmask),
          .addr(addr),
          .din(din),
          .dout(dout),
          .selctrl(selctrl),
          .ctrl(ctrl),
          .status(status)
      );
    end
    if (MEM_PROP != "SOFT") begin : itech
      // Create memories
      // When AW < MEM_DEPTH, force single-macro case (MEM_ADDRS = 1)
      localparam MEM_ADDRS = (AW >= MEM_DEPTH) ? 2 ** (AW - MEM_DEPTH) : 1;
      // Generate a single bitmask
      wire [DW-1:0] wmask_int;
      genvar gwm;
      if (BYTEMASK) begin : g_wm_byte
        for (gwm = 0; gwm < DW / 8; gwm = gwm + 1) begin : g_wm_lane
          assign wmask_int[gwm*8+:8] = {8{wmask[gwm]}};
        end
      end else begin : g_wm_bit
        assign wmask_int = wmask;
      end
      genvar o;
      for (o = 0; o < DW; o = o + 1) begin : OUTPUTS
        wire [MEM_ADDRS-1:0] mem_outputs;
        assign dout[o] = |mem_outputs;
      end
      genvar a;
      for (a = 0; a < MEM_ADDRS; a = a + 1) begin : ADDR
        wire selected;
        reg selected_reg;
        wire [MEM_DEPTH-1:0] mem_addr;
        if (MEM_ADDRS == 1) begin : FITS
          assign selected = 1'b1;
        end else begin : NOFITS
          assign selected = addr[AW-1:MEM_DEPTH] == a;
        end
        // Handle address width mismatch between wrapper and macro
        if (AW > MEM_DEPTH) begin : ADDR_ADAPT
          // Truncate address to macro width
          assign mem_addr = addr[MEM_DEPTH-1:0];
        end
        if (AW == MEM_DEPTH) begin : ADDR_MATCH
          // Address width matches
          assign mem_addr = addr;
        end
        if (AW < MEM_DEPTH) begin : ADDR_EXTEND
          // Single-macro forced case: zero-extend address to macro width
          // Since AW < MEM_DEPTH, MEM_ADDRS is forced to 1, collapsing to single macro
          assign mem_addr = {{(MEM_DEPTH - AW) {1'b0}}, addr};
        end
        always @(posedge clk) begin
          selected_reg <= selected;
        end
        genvar n;
        for (n = 0; n < DW; n = n + MEM_WIDTH) begin : WORD
          wire [MEM_WIDTH-1:0] mem_din;
          wire [MEM_WIDTH-1:0] mem_dout;
          wire [MEM_WIDTH-1:0] mem_wmask;
          genvar i;
          for (i = 0; i < MEM_WIDTH; i = i + 1) begin : WORD_SELECT
            if (n + i < DW) begin : ACTIVE
              assign mem_din[i] = din[n+i];
              assign mem_wmask[i] = wmask_int[n+i];
              assign OUTPUTS[n+i].mem_outputs[a] = selected_reg ? mem_dout[i] : 1'b0;
            end else begin : INACTIVE
              assign mem_din[i]   = 1'b0;
              assign mem_wmask[i] = 1'b0;
            end
          end
          wire ce_in;
          wire we_in;
          assign ce_in = ce && selected;
          assign we_in = we && selected;
          if (MEM_PROP == "sky130_sram_2kbyte_1rw1r_32x512_8") begin: isky130_sram_2kbyte_1rw1r_32x512_8
            wire [0:0] mem_ctrl;
            assign mem_ctrl = selctrl ? ctrl[0:0] : 1'b0;
            sky130_sram_2kbyte_1rw1r_32x512_8 memory (
                .addr0 (mem_addr),
                .addr1 (mem_addr),
                .clk0  (clk),
                .clk1  (clk),
                .csb0  (~(ce_in && we_in)),   // active low
                .csb1  (~(ce_in && ~we_in)),  // active low
                .din0  (mem_din),
                .dout0 (),
                .dout1 (mem_dout),
                .web0  (~(ce_in && we_in)),   // active low
                .wmask0({mem_wmask[24], mem_wmask[16], mem_wmask[8], mem_wmask[0]})
            );
          end
        end
      end
      // Drive status to zero by default for tech-specific memories
      assign status = {STATUSW{1'b0}};
    end
  endgenerate
endmodule

(* keep_hierarchy *)
module la_iobidir #(
    parameter PROP  = "DEFAULT",  // cell type
    parameter SIDE  = "NO",       // "NO", "SO", "EA", "WE"
    parameter CFGW  = 16,         // width of core config bus
    parameter RINGW = 8           // width of io ring
) (  // io pad signals
    inout              pad,     // bidirectional pad signal
    inout              vdd,     // core supply
    inout              vss,     // core ground
    inout              vddio,   // io supply
    inout              vssio,   // io ground
    // core facing signals
    input              a,       // input from core
    output             z,       // output to core
    input              ie,      // input enable, 1 = active
    input              oe,      // output enable, 1 = active
    input              pe,      // pull enable, 1 = enable
    input              ps,      // pull select, 1 = pullup, 0 = pulldown
    input              schmitt, // schmitt cfg, 1 = active
    input              fast,    // 1 = fast slew rate
    input  [1:0]       ds,      // drive strength, 0=weakest
    inout  [RINGW-1:0] ioring,  // generic io ring
    input  [ CFGW-1:0] cfg      // generic config interface
);
  wire oen;
  assign oen = ~oe;
  sky130_ef_io__gpiov2_pad_wrapped gpio (
      .VDDIO(vddio),
      .VCCD(vdd),
      .VSSD(vss),
      .VSSIO(vssio),
      .VDDIO_Q(ioring[0]),
      .VSWITCH(ioring[1]),
      .VCCHIB(ioring[2]),
      .VSSIO_Q(ioring[3]),
      .AMUXBUS_A(ioring[4]),
      .AMUXBUS_B(ioring[5]),
      .VDDA(ioring[6]),
      .VSSA(ioring[7]),
      .IN(z),
      .OUT(a),
      .OE_N(oen),
      .INP_DIS(~ie),  // INP_DIS is active high: disable input when ie low
      .PAD(pad),
      .HLD_H_N(cfg[0]),  // if 0, hold outputs at current state
      .ENABLE_H(cfg[1]),  // if 0, hold outputs at hi-z (used on power-up)
      .ENABLE_INP_H(cfg[2]),  // val doesn't matter when enable_h = 1
      .ENABLE_VDDA_H(cfg[3]),
      .ENABLE_VSWITCH_H(cfg[4]),
      .ENABLE_VDDIO(cfg[5]),
      .IB_MODE_SEL(cfg[6]),  // use vddio based threshold
      .VTRIP_SEL(cfg[7]),  // use cmos threshold
      .SLOW(~fast),
      .HLD_OVR(cfg[9]),  // don't care when hld_h_n = 1
      .ANALOG_EN(cfg[10]),  // disable analog functionality
      .ANALOG_SEL(cfg[11]),  // don't care
      .ANALOG_POL(cfg[12]),  // don't care
      .DM(cfg[15:13]),  // strong pull-up, strong pull-down
      // unused
      .PAD_A_NOESD_H(),
      .PAD_A_ESD_0_H(),
      .PAD_A_ESD_1_H(),
      .IN_H(),
      .TIE_HI_ESD(),
      .TIE_LO_ESD()
  );
endmodule

(* keep_hierarchy *)
module la_iovddio #(
    parameter PROP  = "DEFAULT",  // cell type
    parameter SIDE  = "NO",       // "NO", "SO", "EA", "WE"
    parameter RINGW = 8           // width of io ring
) (
    inout             vdd,    // core supply
    inout             vss,    // core ground
    inout             vddio,  // io supply
    inout             vssio,  // io ground
    inout [RINGW-1:0] ioring  // generic io-ring interface
);
  sky130_ef_io__vddio_hvc_pad iovddio (
      .VDDIO(vddio),
      .VDDIO_Q(ioring[0]),
      .VDDA(ioring[6]),
      .VCCD(vdd),
      .VSWITCH(ioring[1]),
      .VCCHIB(ioring[2]),
      .VSSA(ioring[7]),
      .VSSD(vss),
      .VSSIO_Q(ioring[3]),
      .VSSIO(vssio),
      .AMUXBUS_A(ioring[4]),
      .AMUXBUS_B(ioring[5])
  );
endmodule


(* keep_hierarchy *)
module la_iovssio #(
    parameter PROP  = "DEFAULT",  // cell type
    parameter SIDE  = "NO",       // "NO", "SO", "EA", "WE"
    parameter RINGW = 8           // width of io ring
) (
    inout             vdd,    // core supply
    inout             vss,    // core ground
    inout             vddio,  // io supply
    inout             vssio,  // io ground
    inout [RINGW-1:0] ioring  // generic io-ring interface
);
  sky130_ef_io__vssio_hvc_pad iovssio (
      .VDDIO(vddio),
      .VDDIO_Q(ioring[0]),
      .VDDA(ioring[6]),
      .VCCD(vdd),
      .VSWITCH(ioring[1]),
      .VCCHIB(ioring[2]),
      .VSSA(ioring[7]),
      .VSSD(vss),
      .VSSIO_Q(ioring[3]),
      .VSSIO(vssio),
      .AMUXBUS_A(ioring[4]),
      .AMUXBUS_B(ioring[5])
  );
endmodule

(* keep_hierarchy *)
module la_iovdd #(
    parameter PROP  = "DEFAULT",  // cell type
    parameter SIDE  = "NO",       // "NO", "SO", "EA", "WE"
    parameter RINGW = 8           // width of io ring
) (
    inout             vdd,    // core supply
    inout             vss,    // core ground
    inout             vddio,  // io supply
    inout             vssio,  // io ground
    inout [RINGW-1:0] ioring  // generic io-ring interface
);
  sky130_ef_io__vccd_hvc_pad iovdd (
      .VDDIO(vddio),
      .VDDIO_Q(ioring[0]),
      .VDDA(ioring[6]),
      .VCCD(vdd),
      .VSWITCH(ioring[1]),
      .VCCHIB(ioring[2]),
      .VSSA(ioring[7]),
      .VSSD(vss),
      .VSSIO_Q(ioring[3]),
      .VSSIO(vssio),
      .AMUXBUS_A(ioring[4]),
      .AMUXBUS_B(ioring[5])
  );
endmodule

(* keep_hierarchy *)
module la_iovss #(
    parameter PROP  = "DEFAULT",  // cell type
    parameter SIDE  = "NO",       // "NO", "SO", "EA", "WE"
    parameter RINGW = 8           // width of io ring
) (
    inout             vdd,    // core supply
    inout             vss,    // core ground
    inout             vddio,  // io supply
    inout             vssio,  // io ground
    inout [RINGW-1:0] ioring  // generic io-ring interface
);
  sky130_ef_io__vssd_hvc_pad iovss (
      .VDDIO(vddio),
      .VDDIO_Q(ioring[0]),
      .VDDA(ioring[6]),
      .VCCD(vdd),
      .VSWITCH(ioring[1]),
      .VCCHIB(ioring[2]),
      .VSSA(ioring[7]),
      .VSSD(vss),
      .VSSIO_Q(ioring[3]),
      .VSSIO(vssio),
      .AMUXBUS_A(ioring[4]),
      .AMUXBUS_B(ioring[5])
  );
endmodule


/*****************************************************************************
 * Function: Padring Generator
 * Copyright: Lambda Project Authors. All rights Reserved.
 * License:  MIT (see LICENSE file in Lambda repository)
 *
 * Documentation:
 *
 * - See "../README.md" for complete information
 *
 * ------------------------------------------------------------------------
 *
 * CELLMAP[79:0] = {PROP[15:0],SECTION[15:0],CELL[15:0],COMP[15:0],PIN[15:0]}
 *
 * PIN[15:0] = pin number connected to cell
 *
 * COMP[15:0] = pin number for negative leg for differential cells
 *
 * CELL[15:0] = cell type (see ./la_padring.vh)
 *
 * SECTION[15:0] = padring power section number connected to cell
 *
 * PROP[15:0] = property passed to technology specific iolib implementation
 *
 * Cell Map Example:
 *
 * CELLMAP[159:0] = {{NULL,  NULL, LA_RXDIFF, PIN_RXN, PIN_RXP}
 *                   {NULL,  NULL, LA_BIDIR,  NULL,    PIN_IO0}}
 *
 * Testing:
 *
 * >> iverilog la_iopadring.v -DTB_LA_IOPADRING -y . -y ../../iolib/rtl
 * >> ./a.out
 *
 ****************************************************************************/
module la_padring
  #(// global padring params
    parameter [15:0]       MAX = 256,        // max cells
    parameter [15:0]       CFGW = 8,         // config width
    parameter [15:0]       RINGW = 8,        // ioring width
    // per side parameters
    parameter [15:0]       NO_NPINS = 16,    // pins per side
    parameter [15:0]       NO_NCELLS = 32,   // cells per side (io, gnd, cut..)
    parameter [15:0]       NO_NSECTIONS = 1, // sections per side
    parameter [MAX*80-1:0] NO_CELLMAP = 0,   // see ../README.md
    parameter [15:0]       EA_NPINS = 16,
    parameter [15:0]       EA_NCELLS = 32,
    parameter [15:0]       EA_NSECTIONS = 1,
    parameter [MAX*80-1:0] EA_CELLMAP = 0,
    parameter [15:0]       SO_NPINS = 16,
    parameter [15:0]       SO_NCELLS = 32,
    parameter [15:0]       SO_NSECTIONS = 1,
    parameter [MAX*80-1:0] SO_CELLMAP = 0,
    parameter [15:0]       WE_NPINS = 16,
    parameter [15:0]       WE_NCELLS = 32,
    parameter [15:0]       WE_NSECTIONS = 1,
    parameter [MAX*80-1:0] WE_CELLMAP = 0
    )
   (// CONTINUOUS GROUND
    inout                          vss,
    // NORTH
    inout [NO_NPINS-1:0]           no_pad,     // pad
    inout [NO_NPINS*3-1:0]         no_aio,     // analog inout
    output [NO_NPINS-1:0]          no_zp,      // output to core (positive)
    output [NO_NPINS-1:0]          no_zn,      // output to core (negative)
    input [NO_NPINS-1:0]           no_a,       // input from core
    input [NO_NPINS-1:0]           no_ie,      // input enable, 1 = active
    input [NO_NPINS-1:0]           no_oe,      // output enable, 1 = active
    input [NO_NPINS-1:0]           no_pe,      // pull enable, 1 = enable
    input [NO_NPINS-1:0]           no_ps,      // pull select, 1 = pullup
    input [NO_NPINS-1:0]           no_schmitt, // schmitt cfg, 1 = active
    input [NO_NPINS-1:0]           no_fast,    // slew rate, 1 = fast
    input [NO_NPINS*2-1:0]         no_ds,      // drive strength, 11=strongest
    input [NO_NPINS*CFGW-1:0]      no_cfg,     // generic config interface
    inout [NO_NSECTIONS-1:0]       no_vdd,     // core supply
    inout [NO_NSECTIONS-1:0]       no_vddio,   // io/analog supply
    inout [NO_NSECTIONS-1:0]       no_vssio,   // io/analog ground
    inout [NO_NSECTIONS*RINGW-1:0] no_ioring,  // io ring
    // EAST
    inout [EA_NPINS-1:0]           ea_pad,
    inout [EA_NPINS*3-1:0]         ea_aio,
    output [EA_NPINS-1:0]          ea_zp,
    output [EA_NPINS-1:0]          ea_zn,
    input [EA_NPINS-1:0]           ea_a,
    input [EA_NPINS-1:0]           ea_ie,
    input [EA_NPINS-1:0]           ea_oe,
    input [EA_NPINS-1:0]           ea_pe,
    input [EA_NPINS-1:0]           ea_ps,
    input [EA_NPINS-1:0]           ea_schmitt,
    input [EA_NPINS-1:0]           ea_fast,
    input [EA_NPINS*2-1:0]         ea_ds,
    input [EA_NPINS*CFGW-1:0]      ea_cfg,
    inout [EA_NSECTIONS-1:0]       ea_vdd,
    inout [EA_NSECTIONS-1:0]       ea_vddio,
    inout [EA_NSECTIONS-1:0]       ea_vssio,
    inout [EA_NSECTIONS*RINGW-1:0] ea_ioring,
    // SOUTH
    inout [SO_NPINS-1:0]           so_pad,
    inout [SO_NPINS*3-1:0]         so_aio,
    output [SO_NPINS-1:0]          so_zp,
    output [SO_NPINS-1:0]          so_zn,
    input [SO_NPINS-1:0]           so_a,
    input [SO_NPINS-1:0]           so_ie,
    input [SO_NPINS-1:0]           so_oe,
    input [SO_NPINS-1:0]           so_pe,
    input [SO_NPINS-1:0]           so_ps,
    input [SO_NPINS-1:0]           so_schmitt,
    input [SO_NPINS-1:0]           so_fast,
    input [SO_NPINS*2-1:0]         so_ds,
    input [SO_NPINS*CFGW-1:0]      so_cfg,
    inout [SO_NSECTIONS-1:0]       so_vdd,
    inout [SO_NSECTIONS-1:0]       so_vddio,
    inout [SO_NSECTIONS-1:0]       so_vssio,
    inout [SO_NSECTIONS*RINGW-1:0] so_ioring,
    // WEST
    inout [WE_NPINS-1:0]           we_pad,
    inout [WE_NPINS*3-1:0]         we_aio,
    output [WE_NPINS-1:0]          we_zp,
    output [WE_NPINS-1:0]          we_zn,
    input [WE_NPINS-1:0]           we_a,
    input [WE_NPINS-1:0]           we_ie,
    input [WE_NPINS-1:0]           we_oe,
    input [WE_NPINS-1:0]           we_pe,
    input [WE_NPINS-1:0]           we_ps,
    input [WE_NPINS-1:0]           we_schmitt,
    input [WE_NPINS-1:0]           we_fast,
    input [WE_NPINS*2-1:0]         we_ds,
    input [WE_NPINS*CFGW-1:0]      we_cfg,
    inout [WE_NSECTIONS-1:0]       we_vdd,
    inout [WE_NSECTIONS-1:0]       we_vddio,
    inout [WE_NSECTIONS-1:0]       we_vssio,
    inout [WE_NSECTIONS*RINGW-1:0] we_ioring
    );
/*****************************************************************************
 * Function: Padring Generator Enumeration
 * Copyright: Lambda Project Authors. All rights Reserved.
 * License:  MIT (see LICENSE file in Lambda repository)
 ****************************************************************************/
// NULL (place holder)
localparam [15:0] NULL      = 16'h00;
// io cells
localparam [15:0] LA_BIDIR  = 16'h01;
localparam [15:0] LA_INPUT  = 16'h02;
localparam [15:0] LA_OUTPUT = 16'h03;
localparam [15:0] LA_ANALOG = 16'h04;
localparam [15:0] LA_XTAL   = 16'h05;
localparam [15:0] LA_RXDIFF = 16'h06;
localparam [15:0] LA_TXDIFF = 16'h07;
// supply cells
localparam [15:0] LA_VDDIO  = 16'h10;
localparam [15:0] LA_VSSIO  = 16'h11;
localparam [15:0] LA_VDD    = 16'h12;
localparam [15:0] LA_VSS    = 16'h13;
localparam [15:0] LA_VDDA   = 16'h14;
localparam [15:0] LA_VSSA   = 16'h15;
localparam [15:0] LA_POC    = 16'h16;
localparam [15:0] LA_CUT    = 16'h17;
localparam [15:0] LA_CLAMP  = 16'h18;
   // NORTH
   la_padside #(.SIDE("NO"),
                .NPINS(NO_NPINS),
                .NCELLS(NO_NCELLS),
                .NSECTIONS(NO_NSECTIONS),
                .CELLMAP(NO_CELLMAP),
                .RINGW(RINGW),
                .CFGW(CFGW),
                .MAX(MAX))
   inorth (// Outputs
           .zp     (no_zp),
           .zn     (no_zn),
           // Inouts
           .pad    (no_pad),
           .aio    (no_aio),
           .vss    (vss),
           .vdd    (no_vdd),
           .vddio  (no_vddio),
           .vssio  (no_vssio),
           .ioring (no_ioring),
           // Inputs
           .a      (no_a),
           .ie     (no_ie),
           .oe     (no_oe),
           .pe     (no_pe),
           .ps     (no_ps),
           .schmitt(no_schmitt),
           .fast   (no_fast),
           .ds     (no_ds),
           .cfg    (no_cfg));
   // EAST
   la_padside #(.SIDE("EA"),
                .NPINS(EA_NPINS),
                .NCELLS(EA_NCELLS),
                .NSECTIONS(EA_NSECTIONS),
                .CELLMAP(EA_CELLMAP),
                .RINGW(RINGW),
                .CFGW(CFGW),
                .MAX(MAX))
   ieast (// Outputs
          .zp     (ea_zp),
          .zn     (ea_zn),
          // Inouts
          .pad    (ea_pad),
          .aio    (ea_aio),
          .vss    (vss),
          .vdd    (ea_vdd),
          .vddio  (ea_vddio),
          .vssio  (ea_vssio),
          .ioring (ea_ioring),
          // Inputs
          .a      (ea_a),
          .ie     (ea_ie),
          .oe     (ea_oe),
          .pe     (ea_pe),
          .ps     (ea_ps),
          .schmitt(ea_schmitt),
          .fast   (ea_fast),
          .ds     (ea_ds),
          .cfg    (ea_cfg));
   // WEST
   la_padside #(.SIDE("WE"),
                .NPINS(WE_NPINS),
                .NCELLS(WE_NCELLS),
                .NSECTIONS(WE_NSECTIONS),
                .CELLMAP(WE_CELLMAP),
                .RINGW(RINGW),
                .CFGW(CFGW),
                .MAX(MAX))
   iwest (// Outputs
          .zp     (we_zp),
          .zn     (we_zn),
          // Inouts
          .pad    (we_pad),
          .aio    (we_aio),
          .vss    (vss),
          .vdd    (we_vdd),
          .vddio  (we_vddio),
          .vssio  (we_vssio),
          .ioring (we_ioring),
          // Inputs
          .a      (we_a),
          .ie     (we_ie),
          .oe     (we_oe),
          .pe     (we_pe),
          .ps     (we_ps),
          .schmitt(we_schmitt),
          .fast   (we_fast),
          .ds     (we_ds),
          .cfg    (we_cfg));
   // SOUTH
   la_padside #(.SIDE("SO"),
                .NPINS(SO_NPINS),
                .NCELLS(SO_NCELLS),
                .NSECTIONS(SO_NSECTIONS),
                .CELLMAP(SO_CELLMAP),
                .RINGW(RINGW),
                .CFGW(CFGW),
                .MAX(MAX))
   isouth (// Outputs
           .zp     (so_zp),
           .zn     (so_zn),
           // Inouts
           .pad    (so_pad),
           .aio    (so_aio),
           .vss    (vss),
           .vdd    (so_vdd),
           .vddio  (so_vddio),
           .vssio  (so_vssio),
           .ioring (so_ioring),
           // Inputs
           .a      (so_a),
           .ie     (so_ie),
           .oe     (so_oe),
           .pe     (so_pe),
           .ps     (so_ps),
           .schmitt(so_schmitt),
           .fast   (so_fast),
           .ds     (so_ds),
           .cfg    (so_cfg));
endmodule

//#####################################################################
// A SIMPLE TESTBENCH
//#####################################################################
/**************************************************************************
 * Function: Padring Side Module
 * Copyright: Lambda Project Authors. All rights Reserved.
 * License:  MIT (see LICENSE file in Lambda repository)
 *
 * Documentation:
 *
 * See "../README.md" for complete information
 *
 **************************************************************/
module la_padside
  #(// per side parameters
    parameter [15:0]       SIDE = "NO",   // "NO", "SO", "EA", "WE"
    parameter [15:0]       MAX = 256,     // max cells
    parameter [15:0]       NPINS = 32,    // total pins per side (<256)
    parameter [15:0]       NCELLS = 64,   // total cells per side (<256)
    parameter [15:0]       NSECTIONS = 1, // total power sections (<256)
    parameter [MAX*80-1:0] CELLMAP = 0,   // see ../README.md
    parameter [15:0]       RINGW = 1,     // width of io ring
    parameter [15:0]       CFGW = 1       // config width
    )
   (// io pad signals
    inout [NPINS-1:0]           pad,     // pad
    //core facing signals
    inout [NPINS*3-1:0]         aio,     // analog inout
    output [NPINS-1:0]          zp,      // positive output to core
    output [NPINS-1:0]          zn,      // negative output to core
    input [NPINS-1:0]           a,       // input from core
    input [NPINS-1:0]           ie,      // input enable, 1 = active
    input [NPINS-1:0]           oe,      // output enable, 1 = active
    input [NPINS-1:0]           pe,      // pull enable, 1 = enable
    input [NPINS-1:0]           ps,      // pull select, 1 = pullup
    input [NPINS-1:0]           schmitt, // schmitt cfg, 1 = active
    input [NPINS-1:0]           fast,    // slew rate, 1 = fast
    input [NPINS*2-1:0]         ds,      // drive strength, 11=strongest
    input [NPINS*CFGW-1:0]      cfg,     // generic config interface
    // supplies/ring (per cell)
    inout                       vss,     // common ground
    inout [NSECTIONS-1:0]       vdd,     // core supply
    inout [NSECTIONS-1:0]       vddio,   // io supply
    inout [NSECTIONS-1:0]       vssio,   // io ground
    inout [NSECTIONS*RINGW-1:0] ioring   // generic io-ring
    );
   // Field width
   localparam FW            = 16;     // field width
   localparam CMW           = 5 * FW; // cell map
   localparam INDEX_COMP    = 1 * FW; // complimentary pin index
   localparam INDEX_CELL    = 2 * FW; // cell index
   localparam INDEX_SECTION = 3 * FW; // section index
   localparam INDEX_PROP    = 4 * FW; // property index
   //#######################################################################
   // Safe to disable check b/c MAX cells should be consistent with the
   // CELLMAP, which should be generated.
   //#######################################################################
   /* verilator lint_off WIDTHTRUNC */
/*****************************************************************************
 * Function: Padring Generator Enumeration
 * Copyright: Lambda Project Authors. All rights Reserved.
 * License:  MIT (see LICENSE file in Lambda repository)
 ****************************************************************************/
// NULL (place holder)
localparam [15:0] NULL      = 16'h00;
// io cells
localparam [15:0] LA_BIDIR  = 16'h01;
localparam [15:0] LA_INPUT  = 16'h02;
localparam [15:0] LA_OUTPUT = 16'h03;
localparam [15:0] LA_ANALOG = 16'h04;
localparam [15:0] LA_XTAL   = 16'h05;
localparam [15:0] LA_RXDIFF = 16'h06;
localparam [15:0] LA_TXDIFF = 16'h07;
// supply cells
localparam [15:0] LA_VDDIO  = 16'h10;
localparam [15:0] LA_VSSIO  = 16'h11;
localparam [15:0] LA_VDD    = 16'h12;
localparam [15:0] LA_VSS    = 16'h13;
localparam [15:0] LA_VDDA   = 16'h14;
localparam [15:0] LA_VSSA   = 16'h15;
localparam [15:0] LA_POC    = 16'h16;
localparam [15:0] LA_CUT    = 16'h17;
localparam [15:0] LA_CLAMP  = 16'h18;
   genvar i;
   for (i = 0; i < NCELLS; i = i + 1)
     begin : ipad
        // LA_BIDIR
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_BIDIR)
          begin : gbidir
             la_iobidir #(.SIDE(SIDE),
                          .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                          .CFGW(CFGW),
                          .RINGW(RINGW))
             i0 (// pad
                 .pad(pad[CELLMAP[(i*CMW)+:FW]]),
                 // core signals
                 .z(zp[CELLMAP[(i*CMW)+:FW]]),
                 .a(a[CELLMAP[(i*CMW)+:FW]]),
                 .ie(ie[CELLMAP[(i*CMW)+:FW]]),
                 .oe(oe[CELLMAP[(i*CMW)+:FW]]),
                 .pe(pe[CELLMAP[(i*CMW)+:FW]]),
                 .ps(ps[CELLMAP[(i*CMW)+:FW]]),
                 .schmitt(schmitt[CELLMAP[(i*CMW)+:FW]]),
                 .fast(fast[CELLMAP[(i*CMW)+:FW]]),
                 .ds(ds[CELLMAP[(i*CMW)+:FW]*2+:2]),
                 .cfg(cfg[CELLMAP[(i*CMW)+:FW]*CFGW+:CFGW]),
                 // supplies
                 .vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 // ring
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_INPUT
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_INPUT)
          begin : ginput
             la_ioinput #(.SIDE(SIDE),
                          .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                          .CFGW(CFGW),
                          .RINGW(RINGW))
             i0 (// pad
                 .pad(pad[CELLMAP[(i*CMW)+:FW]]),
                 // core signals
                 .z(zp[CELLMAP[(i*CMW)+:FW]]),
                 .ie(ie[CELLMAP[(i*CMW)+:FW]]),
                 .pe(pe[CELLMAP[(i*CMW)+:FW]]),
                 .ps(ps[CELLMAP[(i*CMW)+:FW]]),
                 .schmitt(schmitt[CELLMAP[(i*CMW)+:FW]]),
                 .cfg(cfg[CELLMAP[(i*CMW)+:FW]*CFGW+:CFGW]),
                 // supplies
                 .vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 // ring
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_ANALOG
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_ANALOG)
          begin : ganalog
             la_ioanalog #(.SIDE(SIDE),
                           .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                           .RINGW(RINGW))
             i0 (// pad
                 .pad(pad[CELLMAP[(i*CMW)+:FW]]),
                 // core signals
                 .aio(aio[CELLMAP[(i*CMW)+:FW]*3+:3]),
                 // supplies
                 .vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 // ring
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_XTAL
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_XTAL)
          begin : gxtal
             la_ioxtal #(.SIDE(SIDE),
                         .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                         .CFGW(CFGW),
                         .RINGW(RINGW))
             i0 (// pad
                 .padi(pad[CELLMAP[(i*CMW)+:FW]]),
                 .pado(pad[CELLMAP[(i*CMW+INDEX_COMP)+:FW]]),
                 // core
                 .z(zp[CELLMAP[(i*CMW)+:FW]]),
                 .cfg(cfg[CELLMAP[(i*CMW)+:FW]*CFGW+:CFGW]),
                 // supplies
                 .vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 // ring
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_RXDIFF
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_RXDIFF)
          begin : grxdiff
             la_iorxdiff #(.SIDE(SIDE),
                           .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                           .CFGW(CFGW),
                           .RINGW(RINGW))
             i0 (// pad
                 .padp(pad[CELLMAP[(i*CMW)+:FW]]),
                 .padn(pad[CELLMAP[(i*CMW+INDEX_COMP)+:FW]]),
                 // core
                 .zp(zp[CELLMAP[(i*CMW)+:FW]]),
                 .zn(zn[CELLMAP[(i*CMW)+:FW]]),
                 .ie(ie[CELLMAP[(i*CMW)+:FW]]),
                 .cfg(cfg[CELLMAP[(i*CMW)+:FW]*CFGW+:CFGW]),
                 // supplies
                 .vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 // ring
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_TXDIFF
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_TXDIFF)
          begin : gtxdiff
             la_iotxdiff #(.SIDE(SIDE),
                           .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                           .CFGW(CFGW),
                           .RINGW(RINGW))
             i0 (// pad
                 .padp(pad[CELLMAP[(i*CMW)+:FW]]),
                 .padn(pad[CELLMAP[(i*CMW+INDEX_COMP)+:FW]]),
                 // core
                 .a(a[CELLMAP[(i*CMW)+:FW]]),
                 .oe(oe[CELLMAP[(i*CMW)+:FW]]),
                 .cfg(cfg[CELLMAP[(i*CMW)+:FW]*CFGW+:CFGW]),
                 // supplies
                 .vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_POC
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_POC)
          begin : gpoc
             la_iopoc #(.SIDE(SIDE),
                        .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                        .CFGW(CFGW),
                        .RINGW(RINGW))
             i0 (.cfg(cfg[CELLMAP[(i*CMW)+:FW]*CFGW+:CFGW]),
                 .vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_CUT
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_CUT)
          begin : icut
             if (i - 1 < 0 && i + 1 == NCELLS)
              begin: icut_invalid
              end
             if (i - 1 < 0 && i + 1 <= NCELLS - 1)
              begin: icut_start
                la_iocut #(.SIDE(SIDE),
                           .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                           .RINGW(RINGW))
                i0 (.vss(vss),
                    .vdd0(),
                    .vdd1(vdd[CELLMAP[((i+1)*CMW+INDEX_SECTION)+:FW]]),
                    .vddio0(),
                    .vddio1(vddio[CELLMAP[((i+1)*CMW+INDEX_SECTION)+:FW]]),
                    .vssio0(),
                    .vssio1(vssio[CELLMAP[((i+1)*CMW+INDEX_SECTION)+:FW]]),
                    .ioring0(),
                    .ioring1(ioring[CELLMAP[((i+1)*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
              end
             if (i - 1 >= 0 && i + 1 <= NCELLS - 1)
              begin: icut_middle
                la_iocut #(.SIDE(SIDE),
                           .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                           .RINGW(RINGW))
                i0 (.vss(vss),
                    .vdd0(vdd[CELLMAP[((i-1)*CMW+INDEX_SECTION)+:FW]]),
                    .vdd1(vdd[CELLMAP[((i+1)*CMW+INDEX_SECTION)+:FW]]),
                    .vddio0(vddio[CELLMAP[((i-1)*CMW+INDEX_SECTION)+:FW]]),
                    .vddio1(vddio[CELLMAP[((i+1)*CMW+INDEX_SECTION)+:FW]]),
                    .vssio0(vssio[CELLMAP[((i-1)*CMW+INDEX_SECTION)+:FW]]),
                    .vssio1(vssio[CELLMAP[((i+1)*CMW+INDEX_SECTION)+:FW]]),
                    .ioring0(ioring[CELLMAP[((i-1)*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]),
                    .ioring1(ioring[CELLMAP[((i+1)*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
              end
             if (i - 1 >= 0 && i + 1 == NCELLS)
              begin: icut_end
                la_iocut #(.SIDE(SIDE),
                           .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                           .RINGW(RINGW))
                i0 (.vss(vss),
                    .vdd0(vdd[CELLMAP[((i-1)*CMW+INDEX_SECTION)+:FW]]),
                    .vdd1(),
                    .vddio0(vddio[CELLMAP[((i-1)*CMW+INDEX_SECTION)+:FW]]),
                    .vddio1(),
                    .vssio0(vssio[CELLMAP[((i-1)*CMW+INDEX_SECTION)+:FW]]),
                    .vssio1(),
                    .ioring0(ioring[CELLMAP[((i-1)*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]),
                    .ioring1());
              end
          end
        // LA_VDDIO
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_VDDIO)
          begin : gvddio
             la_iovddio #(.SIDE(SIDE),
                          .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                          .RINGW(RINGW))
             i0 (// supplies
                 .vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_VSSIO
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_VSSIO)
          begin : gvssio
             la_iovssio #(.SIDE(SIDE),
                          .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                          .RINGW(RINGW))
             i0 (.vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_VDD
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_VDD)
          begin : gvdd
             la_iovdd #(.SIDE(SIDE),
                        .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                        .RINGW(RINGW))
             i0 (.vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_VSS
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_VSS)
          begin : gvss
            la_iovss #(.SIDE(SIDE),
                       .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                       .RINGW(RINGW))
             i0 (.vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_VDDA
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_VDDA)
          begin : gvdda
            la_iovdda #(.SIDE(SIDE),
                        .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                        .RINGW(RINGW))
             i0 (.vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_VSSA
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_VSSA)
          begin : gvssa
            la_iovssa #(.SIDE(SIDE),
                        .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                        .RINGW(RINGW))
             i0 (.vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
        // LA_CLAMP
        if (CELLMAP[(i*CMW+INDEX_CELL)+:FW] == LA_CLAMP)
          begin : gclamp
            la_ioclamp #(.SIDE(SIDE),
                         .PROP(CELLMAP[(i*CMW+INDEX_PROP)+:FW]),
                         .RINGW(RINGW))
             i0 (.pad(pad[CELLMAP[(i*CMW)+:FW]]),
                 .vss(vss),
                 .vdd(vdd[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vddio(vddio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .vssio(vssio[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]]),
                 .ioring(ioring[CELLMAP[(i*CMW+INDEX_SECTION)+:FW]*RINGW+:RINGW]));
          end
     end
endmodule

//#################################################################
// A RISC-V processor, its memory, and the pad ring that bonds it out.
//
// This is the module that becomes the die. Everything is in one file
// because the three parts only exist in relation to each other: the
// processor, the pad buses it drives, and the ring that turns those
// buses into physical pads.
//
// The ports are the pads. They are named for what they carry rather
// than for where they sit in the ring, which is how a chip top is
// normally written -- nobody debugging a board wants to look up which
// bit of no_pad is the clock.
//
// Each one also declares the direction it is actually used in. The cells
// in the ring are all bidirectional, but a pin on the finished part is
// not: clock goes in, the memory bus comes out. Only the supplies are
// genuinely inout, because a supply pad is neither driver nor load. The
// oen and ie settings further down have to agree with these directions --
// they are the same fact stated once electrically and once in the
// interface.
//
// The ring comes from lambdalib's la_padring generator, which builds the
// four sides from CELLMAP and instantiates the technology's IO cells, so
// nothing here names a sky130 cell.
//#################################################################
module picorv32_top (
    // Supplies. Core and IO are separate domains.
    inout vdd,
    inout vss,
    inout vddio,
    inout vssio,
    // Clock and reset in.
    input clk,
    input resetn,
    // Processor status out.
    output trap,
    // Memory bus, brought out so the processor can be watched on a bench.
    output        mem_valid,
    output        mem_la_read,
    output        mem_la_write,
    output [ 3:0] mem_la_wstrb,
    output [29:0] mem_addr  // word address: mem_la_addr[31:2]
);
    localparam NPINS = 10;  // signal pins per side
    localparam CFGW = 18;  // technology config bits per pad
    localparam RINGW = 8;  // width of the configuration ring
    //#################################################################
    // Pad assignment
    //
    // West takes the two inputs and the bus control; the other three
    // sides take the address, ten bits each. This is the only place that
    // maps a named signal onto a position in the ring, which is why the
    // CELLMAP below can stay uniform across all four sides.
    //#################################################################
    // The named ports are wired straight into the ring below rather than through
    // intermediate wires. The ring's pad ports are inout, and driving one from
    // an assign here would make the top level a second driver of it.
    //#################################################################
    // Core to ring buses
    //
    //   din      - value seen at the pad, driven into the logic
    //   dout     - value the logic wants to drive out
    //   oen      - output enable, active low
    //   ie       - input enable
    //   tech_cfg - technology specific pad configuration
    //#################################################################
    wire [NPINS-1:0] no_din, no_dout, no_oen, no_ie;
    wire [NPINS-1:0] ea_din, ea_dout, ea_oen, ea_ie;
    wire [NPINS-1:0] so_din, so_dout, so_oen, so_ie;
    wire [NPINS-1:0] we_din, we_dout, we_oen, we_ie;
    wire [CFGW*NPINS-1:0] tech_cfg;
    // The two west inputs are the only pads read back into the logic.
    wire                  clk_int = we_din[0];
    wire                  resetn_int = we_din[1];
    wire                  trap_int;
    wire                  mem_valid_int;
    wire                  mem_la_read_int;
    wire                  mem_la_write_int;
    wire [           3:0] mem_la_wstrb_int;
    wire [          31:0] mem_la_addr;
    assign no_dout = mem_la_addr[NPINS+1:2];
    assign ea_dout = mem_la_addr[2*NPINS+1:NPINS+2];
    assign so_dout = mem_la_addr[3*NPINS+1:2*NPINS+2];
    assign we_dout = {
        mem_la_wstrb_int, mem_la_write_int, mem_la_read_int, mem_valid_int, trap_int, 2'b00
    };
    // oen is active low, so 0 enables the pad driver. ie enables the input
    // path, wanted only on the two west pads carrying clock and reset -- an
    // output pad with its input enabled just burns power.
    assign no_oen = {NPINS{1'b0}};
    assign ea_oen = {NPINS{1'b0}};
    assign so_oen = {NPINS{1'b0}};
    assign we_oen = {{(NPINS - 2) {1'b0}}, 2'b11};
    assign no_ie = {NPINS{1'b0}};
    assign ea_ie = {NPINS{1'b0}};
    assign so_ie = {NPINS{1'b0}};
    assign we_ie = {{(NPINS - 2) {1'b0}}, 2'b11};
    //#################################################################
    // Processor and memory
    //
    // The bus is as simple as it can be: the memory answers in one cycle,
    // so ready is just valid delayed. The coprocessor and interrupt inputs
    // are tied off rather than left open, because an undriven input is a
    // synthesis warning at best and an X at worst.
    //#################################################################
    reg         mem_ready;
    wire        mem_instr;
    wire [31:0] mem_addr_int;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;
    always @(posedge clk_int) mem_ready <= mem_valid_int;
    picorv32 cpu (
        .clk(clk_int),
        .resetn(resetn_int),
        .trap(trap_int),
        .mem_valid(mem_valid_int),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr (mem_addr_int),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_la_read (mem_la_read_int),
        .mem_la_write(mem_la_write_int),
        .mem_la_addr (mem_la_addr),
        .mem_la_wdata(),
        .mem_la_wstrb(mem_la_wstrb_int),
        // Coprocessor interface, disabled.
        .pcpi_valid(),
        .pcpi_insn(),
        .pcpi_rs1(),
        .pcpi_rs2(),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'b0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        // Interrupts, disabled.
        .irq(32'b0),
        .eoi()
    );
    // A single port SRAM from lambdalib, which the target maps onto whichever
    // macro the technology provides. 256 words of 32 bits, which on sky130 is
    // one macro: ask for twice the depth and it becomes two, and two of them
    // will not fit inside a ring this size.
    //
    // The processor drives a byte address and the memory takes a word index, so
    // the low two bits are dropped rather than passed through. Wiring
    // mem_addr[7:0] straight in would reach only every fourth word and alias
    // every 256 bytes.
    la_spram #(
        .DW(32),
        .AW(8),
        .BYTEMASK(1)
    ) sram (
        .clk(clk_int),
        .ce(1'b1),
        .we(mem_wstrb != 4'b0),
        .wmask(mem_wstrb),
        .addr(mem_addr_int[9:2]),  // byte address -> word index
        .din(mem_wdata),
        .dout(mem_rdata),
        .selctrl(1'b0),
        .ctrl('b0),
        .status()
    );
    //#################################################################
    // Pad configuration
    //
    // These bits are specific to this technology's IO library, which is why
    // they travel as an opaque bus rather than as named ports: another
    // library carries a different set, and the ring does not interpret them.
    // A real design would drive them from configuration registers so software
    // could retune the pads after boot; here they are tied to one setting.
    //
    // sky130 uses the low 16 bits and leaves its TIE_LO_ESD/TIE_HI_ESD
    // outputs unconnected, so bits 17:16 of the 18-bit bus are unused in this
    // technology and are tied low rather than left floating.
    //#################################################################
    localparam [CFGW-1:0] PadCfg = {
        2'b00,  // 17:16 unused by this technology
        3'b110,  // 15:13 DM, strong pull-up and pull-down
        1'b0,  // 12    ANALOG_POL,   don't care
        1'b0,  // 11    ANALOG_SEL,   don't care
        1'b0,  // 10    ANALOG_EN,    analog path disabled
        1'b0,  // 9     HLD_OVR,      don't care while HLD_H_N is 1
        1'b0,  // 8     unused: la_iobidir takes slew from the fast input, tied 0 (slow slew)
        1'b0,  // 7     VTRIP_SEL,    CMOS threshold
        1'b0,  // 6     IB_MODE_SEL,  vddio based threshold
        1'b1,  // 5     ENABLE_VDDIO
        1'b1,  // 4     ENABLE_VSWITCH_H
        1'b1,  // 3     ENABLE_VDDA_H
        1'b0,  // 2     ENABLE_INP_H, don't care while ENABLE_H is 1
        1'b1,  // 1     ENABLE_H,     0 would hold the outputs at hi-z
        1'b1  // 0     HLD_H_N,      0 would freeze the outputs
    };
    assign tech_cfg = {NPINS{PadCfg}};
    //#################################################################
    // PAD RING
    //
    // CELLMAP describes one side, cell by cell, in the order they abut.
    // Each entry is 80 bits:
    //
    //   {PROP[15:0], SECTION[15:0], CELL[15:0], COMP[15:0], PIN[15:0]}
    //
    //   PIN     - which signal pin of the side connects to this cell
    //   COMP    - negative leg for differential cells, unused here
    //   CELL    - cell type, from la_padring.vh
    //   SECTION - power section, one per side here
    //   PROP    - property passed through to the technology IO library
    //
    // All four sides use the same map. A cell carrying no signal, such as a
    // supply pad, uses PIN_NONE.
    //#################################################################
    // Cell type constants (LA_VSS, LA_BIDIR, ...) come from the generator's
    // own header, which its fileset puts on the include path.
    /*****************************************************************************
 * Function: Padring Generator Enumeration
 * Copyright: Lambda Project Authors. All rights Reserved.
 * License:  MIT (see LICENSE file in Lambda repository)
 ****************************************************************************/
// NULL (place holder)
localparam [15:0] NULL      = 16'h00;
// io cells
localparam [15:0] LA_BIDIR  = 16'h01;
localparam [15:0] LA_INPUT  = 16'h02;
localparam [15:0] LA_OUTPUT = 16'h03;
localparam [15:0] LA_ANALOG = 16'h04;
localparam [15:0] LA_XTAL   = 16'h05;
localparam [15:0] LA_RXDIFF = 16'h06;
localparam [15:0] LA_TXDIFF = 16'h07;
// supply cells
localparam [15:0] LA_VDDIO  = 16'h10;
localparam [15:0] LA_VSSIO  = 16'h11;
localparam [15:0] LA_VDD    = 16'h12;
localparam [15:0] LA_VSS    = 16'h13;
localparam [15:0] LA_VDDA   = 16'h14;
localparam [15:0] LA_VSSA   = 16'h15;
localparam [15:0] LA_POC    = 16'h16;
localparam [15:0] LA_CUT    = 16'h17;
localparam [15:0] LA_CLAMP  = 16'h18;
    localparam NCELLS = NPINS + 4;  // signal pads plus four supplies
    localparam [15:0] PIN_NONE = 16'h00FF;
    localparam [80*NCELLS-1:0] CELLMAP = {
        {16'h0000, 16'h0000, LA_VSS, 16'h0000, PIN_NONE},
        {16'h0000, 16'h0000, LA_VDD, 16'h0000, PIN_NONE},
        {16'h0000, 16'h0000, LA_VDDIO, 16'h0000, PIN_NONE},
        {16'h0000, 16'h0000, LA_VSSIO, 16'h0000, PIN_NONE},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd0},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd1},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd2},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd3},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd4},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd5},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd6},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd7},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd8},
        {16'h0000, 16'h0000, LA_BIDIR, 16'h0000, 16'd9}
    };
    // Carries the pad configuration between neighbouring cells by abutment,
    // which is why it is one bus shared by all four sides.
    wire [RINGW-1:0] ioring;
    la_padring #(
        .RINGW(RINGW),
        .CFGW(CFGW),
        .NO_NPINS(NPINS),
        .NO_NCELLS(NCELLS),
        .NO_NSECTIONS(1),
        .NO_CELLMAP(CELLMAP),
        .EA_NPINS(NPINS),
        .EA_NCELLS(NCELLS),
        .EA_NSECTIONS(1),
        .EA_CELLMAP(CELLMAP),
        .SO_NPINS(NPINS),
        .SO_NCELLS(NCELLS),
        .SO_NSECTIONS(1),
        .SO_CELLMAP(CELLMAP),
        .WE_NPINS(NPINS),
        .WE_NCELLS(NCELLS),
        .WE_NSECTIONS(1),
        .WE_CELLMAP(CELLMAP)
    ) padring (
        // pads, the only nets that leave the die. This is where a named signal
        // becomes a position in the ring, and the only place it happens.
        .no_pad(mem_addr[NPINS-1:0]),
        .ea_pad(mem_addr[2*NPINS-1:NPINS]),
        .so_pad(mem_addr[3*NPINS-1:2*NPINS]),
        .we_pad({mem_la_wstrb, mem_la_write, mem_la_read, mem_valid, trap, resetn, clk}),
        // analog pass-through, unused here
        .no_aio(),
        .ea_aio(),
        .so_aio(),
        .we_aio(),
        // supplies
        .vss(vss),
        .no_vdd(vdd),
        .ea_vdd(vdd),
        .so_vdd(vdd),
        .we_vdd(vdd),
        .no_vddio(vddio),
        .ea_vddio(vddio),
        .so_vddio(vddio),
        .we_vddio(vddio),
        .no_vssio(vssio),
        .ea_vssio(vssio),
        .so_vssio(vssio),
        .we_vssio(vssio),
        // configuration ring, connected by abutment during floorplanning
        .no_ioring(ioring),
        .ea_ioring(ioring),
        .so_ioring(ioring),
        .we_ioring(ioring),
        // pad to logic, the received value
        .no_zp(no_din),
        .ea_zp(ea_din),
        .so_zp(so_din),
        .we_zp(we_din),
        .no_zn(),
        .ea_zn(),
        .so_zn(),
        .we_zn(),
        // logic to pad. oe is active high, so it inverts oen.
        .no_a (no_dout),
        .ea_a (ea_dout),
        .so_a (so_dout),
        .we_a (we_dout),
        .no_oe(~no_oen),
        .ea_oe(~ea_oen),
        .so_oe(~so_oen),
        .we_oe(~we_oen),
        .no_ie(no_ie),
        .ea_ie(ea_ie),
        .so_ie(so_ie),
        .we_ie(we_ie),
        // per-pad options this design does not use
        .no_pe('b0),
        .ea_pe('b0),
        .so_pe('b0),
        .we_pe('b0),
        .no_ps('b0),
        .ea_ps('b0),
        .so_ps('b0),
        .we_ps('b0),
        .no_schmitt('b0),
        .ea_schmitt('b0),
        .so_schmitt('b0),
        .we_schmitt('b0),
        .no_fast('b0),
        .ea_fast('b0),
        .so_fast('b0),
        .we_fast('b0),
        .no_ds('b0),
        .ea_ds('b0),
        .so_ds('b0),
        .we_ds('b0),
        // technology configuration
        .no_cfg(tech_cfg),
        .ea_cfg(tech_cfg),
        .so_cfg(tech_cfg),
        .we_cfg(tech_cfg)
    );
endmodule

////////////////////////////////////////////////////////////////
