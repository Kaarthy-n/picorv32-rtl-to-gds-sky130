`timescale 1ns/1ps
// Boots the chip top with a tiny program, checks clock/reset pads, address pads,
// and a word store + byte-masked store + load round trip through the SRAM.
module tb_picorv32_top;
  reg clk = 0, resetn = 0;
  wire trap, mem_valid, mem_la_read, mem_la_write;
  wire [3:0] mem_la_wstrb;
  wire [29:0] mem_addr;
  wire vdd, vss, vddio, vssio;
  assign vdd = 1'b1; assign vddio = 1'b1; assign vss = 1'b0; assign vssio = 1'b0;

  picorv32_top dut (.vdd(vdd), .vss(vss), .vddio(vddio), .vssio(vssio),
    .clk(clk), .resetn(resetn), .trap(trap), .mem_valid(mem_valid),
    .mem_la_read(mem_la_read), .mem_la_write(mem_la_write),
    .mem_la_wstrb(mem_la_wstrb), .mem_addr(mem_addr));

  always #10 clk = ~clk;   // 50 MHz

  // The pad models need the shared IO-ring rails powered: {VSSA, VDDA, amuxB,
  // amuxA, VSSIO_Q, VCCHIB, VSWITCH, VDDIO_Q}. The ring nets only reach the
  // supply pads, so the bench ties them here.
  initial begin
    force dut.ioring[0] = 1'b1;  // VDDIO_Q
    force dut.ioring[1] = 1'b1;  // VSWITCH
    force dut.ioring[2] = 1'b1;  // VCCHIB
    force dut.ioring[3] = 1'b0;  // VSSIO_Q
    force dut.ioring[6] = 1'b1;  // VDDA
    force dut.ioring[7] = 1'b0;  // VSSA
  end

  `define MEM dut.sram.itech.ADDR[0].WORD[0].isky130_sram_2kbyte_1rw1r_32x512_8.memory.mem

  integer errors = 0;
  integer clk_int_edges = 0, valid_seen = 0, saw_data_addr = 0, saw_wstrb = 0;
  always @(posedge dut.clk_int) clk_int_edges = clk_int_edges + 1;
  always @(posedge clk) if (resetn) begin
    if (mem_valid) valid_seen = valid_seen + 1;
    if (mem_addr == 30'h40 && mem_la_read) saw_data_addr = 1;   // byte addr 0x100
    if (mem_la_write && mem_la_wstrb == 4'b1111) saw_wstrb = saw_wstrb | 1;
    if (mem_la_write && mem_la_wstrb == 4'b0010) saw_wstrb = saw_wstrb | 2;
  end

  initial begin
    // program
    `MEM[0] = 32'h123450B7; // lui  x1,0x12345
    `MEM[1] = 32'h67808093; // addi x1,x1,0x678
    `MEM[2] = 32'h10000113; // addi x2,x0,0x100
    `MEM[3] = 32'h0AA00193; // addi x3,x0,0xAA
    `MEM[4] = 32'h00112023; // sw   x1,0(x2)
    `MEM[5] = 32'h003100A3; // sb   x3,1(x2)
    `MEM[6] = 32'h00012203; // lw   x4,0(x2)
    `MEM[7] = 32'h0000006F; // jal  x0,0  (park)
    repeat (5) @(posedge clk);
    resetn = 1;
    repeat (600) @(posedge clk);

    if (clk_int_edges < 100) begin $display("FAIL: clk_int not toggling (%0d)", clk_int_edges); errors = errors + 1; end
    if (valid_seen == 0)     begin $display("FAIL: mem_valid never rose"); errors = errors + 1; end
    if (trap)                begin $display("FAIL: trap asserted"); errors = errors + 1; end
    if (!saw_data_addr)      begin $display("FAIL: data word address 0x40 never on mem_addr pads"); errors = errors + 1; end
    if (saw_wstrb != 3)      begin $display("FAIL: expected wstrb 1111 and 0010 on pads, saw mask %0d", saw_wstrb); errors = errors + 1; end
    if (`MEM[64] !== 32'h1234AA78) begin $display("FAIL: SRAM[64]=%h, want 1234AA78", `MEM[64]); errors = errors + 1; end
    if (dut.cpu.cpuregs[4] !== 32'h1234AA78) begin $display("FAIL: x4=%h, want 1234AA78", dut.cpu.cpuregs[4]); errors = errors + 1; end

    if (errors == 0) $display("PASS");
    else $display("%0d FAILURES", errors);
    $finish;
  end
endmodule
