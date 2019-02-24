//
// Run the processor with memory attached.
//
// Copyright (c) 2018 Serge Vakulenko
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
`default_nettype none
`include "zpu_defines.sv"

module testbench();

// Global time parameters.
timeunit 1ns / 1ps;

// Inputs.
logic        clk, reset;
logic        i_interrupt;   // interrupt request
logic        i_done;        // memory operation completed
logic [31:0] i_data_read;   // data from memory

// Outputs.
logic        o_read;        // read op
logic        o_write;       // write op
logic [31:0] o_addr;        // address output
logic [31:0] o_data_write;  // data to memory

// Instantiate CPU.
zpu_core cpu(
    i_interrupt,            // interrupt request
    clk,                    // clock on rising edge
    reset,                  // reset on rising edge
    o_read,                 // request memory read
    o_write,
    i_done,                 // memory operation completed
    o_addr,                 // memory address
    i_data_read,            // data read
    o_data_write            // data written
);

// 1Mword x 32bit of RAM.
memory ram(
    clk,                    // clock on rising edge
    o_addr[19:0],           // input address
    o_read,                 // input read request
    o_write,                // input write request
    o_data_write,           // input data to memory
    i_data_read,            // output data from memory
    i_done                  // output r/w operation completed
);

string tracefile = "output.trace";
int limit;
int trace;                  // Trace level
int tracefd;                // Trace file descriptor
time ctime;                 // Current time

//
// Generate clock 500MHz.
//
always #1 clk = ~clk;

//
// Main loop.
//
initial begin
    $display("");
    $display("--------------------------------");

    // Dump waveforms.
    if ($test$plusargs("dump")) begin
        $dumpfile("output.vcd");
        $dumpvars();
    end

    // Enable detailed instruction trace to file.
    trace = 2;
    $display("Generate trace file %0S", tracefile);
    tracefd = $fopen(tracefile, "w");

    // Limit the simulation by specified number of cycles.
    if (! $value$plusargs("limit=%d", limit)) begin
        // Default limit value.
        limit = 100000;
        $display("Limit: %0d", limit);
        $fdisplay(tracefd, "Limit: %0d", limit);
    end

    // Start with reset active
    clk = 1;
    reset = 1;

    // Hold reset for a while.
    #2 reset = 0;

    // Run until limit.
    #limit begin
        message("Time Limit Exceeded");
        $finish;
    end
end

//
// Print a message to stdout and trace file
//
task message(input string msg);
    $display("*** %s", msg);
    $fdisplay(tracefd, "(%0d) *** %s", ctime, msg);
endtask

// Get time at the rising edge of the clock.
always @(posedge clk) begin
    ctime = $time;
end

//
// ZPU debugger
//

// ---- register operation dump ----
always @(posedge clk)
begin
    if (~reset) begin
        if (cpu.w_pc) $display("zpu_core: set PC=0x%h", cpu.alu.alu_r);
`ifdef ENABLE_PC_INCREMENT
        if (cpu.w_pc_increment) $display("zpu_core: set PC=0x%h (PC+1)", pc);
`endif
        if (cpu.w_sp) $display("zpu_core: set SP=0x%h", cpu.alu.alu_r);
        if (cpu.w_a) $display("zpu_core: set A=0x%h", cpu.alu.alu_r);
        if (cpu.w_a_mem) $display("zpu_core: set A=0x%h (from MEM)", cpu.mem_data_read_int);
        if (cpu.w_b) $display("zpu_core: set B=0x%h", cpu.alu.alu_r);
        if (cpu.w_op & ~cpu.is_op_cached) $display("zpu_core: set opcode_cache=0x%h, pc_cached=0x%h", cpu.alu.alu_r, {cpu.pc[31:2], 2'b0});
`ifdef ENABLE_CPU_INTERRUPTS
        if (~cpu.busy & cpu.mc_pc == `MC_ADDR_INTERRUPT) $display("zpu_core: ***** ENTERING INTERRUPT MICROCODE ******");
        if (~cpu.busy & cpu.exit_interrupt) $display("zpu_core: ***** INTERRUPT FLAG CLEARED *****");
        if (~cpu.busy & cpu.enter_interrupt) $display("zpu_core: ***** INTERRUPT FLAG SET *****");
`endif
        if (cpu.set_idim & ~cpu.idim) $display("zpu_core: IDIM=1");
        if (cpu.clear_idim & cpu.idim) $display("zpu_core: IDIM=0");

// ---- microcode debug ----
`ifdef ZPU_CORE_DEBUG_MICROCODE
        if (~cpu.busy) begin
            $display("zpu_core: mc_op[%d]=0b%b", cpu.mc_pc, cpu.mc_op);
            if (cpu.branch)      $display("zpu_core: microcode: branch=%d", cpu.mc_goto);
            if (cpu.cond_branch) $display("zpu_core: microcode: CONDITION branch=%d", cpu.mc_goto);
            if (cpu.decode)      $display("zpu_core: decoding opcode=0x%h (0b%b) : branch to=%d ", cpu.opcode, cpu.opcode, cpu.mc_entry);
        end
        else $display("zpu_core: busy");
`endif

// ---- cpu abort in case of unaligned memory access ---
`ifdef ASSERT_NON_ALIGNMENT
        /* unaligned word access (except PC) */
        if (cpu.sel_addr != `SEL_ADDR_PC &
            cpu.mem_addr[1:0] != 2'b00 &
            (cpu.mem_read | cpu.mem_write) &
            !cpu.byte_op & !cpu.halfw_op) begin
            $display("zpu_core: unaligned word operation at addr=0x%x", cpu.mem_addr);
            $finish;
        end

        /* unaligned halfword access */
        if (cpu.mem_addr[0] & (cpu.mem_read | cpu.mem_write) & !cpu.byte_op & cpu.halfw_op) begin
            $display("zpu_core: unaligned halfword operation at addr=0x%x", cpu.mem_addr);
            $finish;
        end
`endif
    end
end

// ----- opcode dissasembler ------
always @(posedge clk) begin
    if (~cpu.busy)
        case (cpu.mc_pc)
        0 : begin
            $display("zpu_core: ------  breakpoint ------");
            $finish;
        end
        4 : $display("zpu_core: ------  shiftleft ------");
        8 : $display("zpu_core: ------  pushsp ------");
        12 : $display("zpu_core: ------  popint ------");
        16 : $display("zpu_core: ------  poppc ------");
        20 : $display("zpu_core: ------  add ------");
        24 : $display("zpu_core: ------  and ------");
        28 : $display("zpu_core: ------  or ------");
        32 : $display("zpu_core: ------  load ------");
        36 : $display("zpu_core: ------  not ------");
        40 : $display("zpu_core: ------  flip ------");
        44 : $display("zpu_core: ------  nop ------");
        48 : $display("zpu_core: ------  store ------");
        52 : $display("zpu_core: ------  popsp ------");
        56 : $display("zpu_core: ------  ipsum ------");
        60 : $display("zpu_core: ------  sncpy ------");

        `MC_ADDR_IM_NOIDIM : $display("zpu_core: ------  im 0x%h (1st) ------", cpu.opcode[6:0] );
        `MC_ADDR_IM_IDIM   : $display("zpu_core: ------  im 0x%h (cont) ------", cpu.opcode[6:0] );
        `MC_ADDR_STORESP   : $display("zpu_core: ------  storesp 0x%h ------", { ~cpu.opcode[4], cpu.opcode[3:0], 2'b0 } );
        `MC_ADDR_LOADSP    : $display("zpu_core: ------  loadsp 0x%h ------", { ~cpu.opcode[4], cpu.opcode[3:0], 2'b0 } );
        `MC_ADDR_ADDSP     : $display("zpu_core: ------  addsp 0x%h ------", { ~cpu.opcode[4], cpu.opcode[3:0], 2'b0 } );
        `MC_ADDR_EMULATE   : $display("zpu_core: ------  emulate 0x%h ------", cpu.b[2:0]); // opcode[5:0] );

        128 : $display("zpu_core: ------  mcpy ------");
        132 : $display("zpu_core: ------  mset ------");
        136 : $display("zpu_core: ------  loadh ------");
        140 : $display("zpu_core: ------  storeh ------");
        144 : $display("zpu_core: ------  lessthan ------");
        148 : $display("zpu_core: ------  lessthanorequal ------");
        152 : $display("zpu_core: ------  ulessthan ------");
        156 : $display("zpu_core: ------  ulessthanorequal ------");
        160 : $display("zpu_core: ------  swap ------");
        164 : $display("zpu_core: ------  mult ------");
        168 : $display("zpu_core: ------  lshiftright ------");
        172 : $display("zpu_core: ------  ashiftleft ------");
        176 : $display("zpu_core: ------  ashiftright ------");
        180 : $display("zpu_core: ------  call ------");
        184 : $display("zpu_core: ------  eq ------");
        188 : $display("zpu_core: ------  neq ------");
        192 : $display("zpu_core: ------  neg ------");
        196 : $display("zpu_core: ------  sub ------");
        200 : $display("zpu_core: ------  xor ------");
        204 : $display("zpu_core: ------  loadb ------");
        208 : $display("zpu_core: ------  storeb ------");
        212 : $display("zpu_core: ------  div ------");
        216 : $display("zpu_core: ------  mod ------");
        220 : $display("zpu_core: ------  eqbranch ------");
        224 : $display("zpu_core: ------  neqbranch ------");
        228 : $display("zpu_core: ------  poppcrel ------");
        232 : $display("zpu_core: ------  config ------");
        236 : $display("zpu_core: ------  pushpc ------");
        240 : $display("zpu_core: ------  syscall_emulate ------");
        244 : $display("zpu_core: ------  pushspadd ------");
        248 : $display("zpu_core: ------  halfmult ------");
        252 : $display("zpu_core: ------  callpcrel ------");
      //default : $display("zpu_core: mc_pc=0x%h", decode_mcpc);
        endcase
end

endmodule
