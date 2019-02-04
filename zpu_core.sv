/*
 * MODULE: zpu_core
 * DESCRIPTION: Contains ZPU cpu
 * AUTHOR: Antonio J. Anton (aj <at> anro-ingenieros.com)
 *
 * REVISION HISTORY:
 * Revision 1.0, 14/09/2009
 * Initial public release
 *
 * COPYRIGHT:
 * Copyright (c) 2009 Antonio J. Anton
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 * of the Software, and to permit persons to whom the Software is furnished to do
 * so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
`timescale 1ns / 1ps
`include "zpu_defines.sv"

// --------- MICROPROGRAMMED ZPU CORE ---------------
// all signals are polled on clk rising edge
// all signals positive

module zpu_core (
`ifdef ENABLE_CPU_INTERRUPTS
    input  wire         interrupt,      // interrupt request
`endif
    input  wire         clk,            // clock on rising edge
    input  wire         reset,          // reset on rising edge
    output wire         mem_read,       // request memory read
    output wire         mem_write,      // request memory write
    input  wire         mem_done,       // memory operation completed
    output wire [31:0]  mem_addr,       // memory address
    input  wire [31:0]  mem_data_read,  // data readed
    output wire [31:0]  mem_data_write  // data written
);

// -------- only 32 bit memory access --------
wire [31:0] mem_data_read_int;      // no byte/halfword memory access by HW
wire [31:0] mem_data_write_int;     // byte and halfword memory access must be emulated

// ----- reorder bytes due to MSB-LSB configuration -----
assign mem_data_read_int = { mem_data_read[7:0], mem_data_read[15:8], mem_data_read[23:16], mem_data_read[31:24] };
assign mem_data_write = { mem_data_write_int[7:0], mem_data_write_int[15:8], mem_data_write_int[23:16], mem_data_write_int[31:24] };

// ------ datapath registers and connections -----------
reg  [31:0] pc;                     // program counter (byte align)
reg  [31:0] sp;                     // stack counter (word align)
reg  [31:0] a;                      // operand (address_out, data_out, alu_in)
reg  [31:0] b;                      // operand (address_out)
reg         idim;                   // im opcode being processed
reg   [7:0] opcode;                 // opcode being processed
reg  [31:2] pc_cached;              // cached PC
reg  [31:0] opcode_cache;           // cached opcodes (current word)
`ifdef ENABLE_CPU_INTERRUPTS
  reg       int_requested;          // interrupt has been requested
  reg       on_interrupt;           // serving interrupt
  wire      exit_interrupt;         // microcode says this is poppc_interrupt
  wire      enter_interrupt;        // microcode says we are entering interrupt
`endif
wire  [1:0] sel_opcode = pc[1:0];   // which opcode is selected
wire        sel_read;               // mux for data-in
wire  [1:0] sel_alu;                // mux for alu
wire  [1:0] sel_addr;               // mux for addr
wire        w_pc;                   // write PC
`ifdef ENABLE_PC_INCREMENT
  wire      w_pc_increment;         // write PC+1
`endif
wire        w_sp;                   // write SP
wire        w_a;                    // write A (from ALU result)
wire        w_a_mem;                // write A (from MEM read)
wire        w_b;                    // write B
wire        w_op;                   // write OPCODE (opcode cache)
wire        set_idim;               // set IDIM
wire        clear_idim;             // clear IDIM
wire        is_op_cached = (pc[31:2] == pc_cached) ? 1'b1 : 1'b0;    // is opcode available?
wire        a_is_zero;              // A == 0
wire        a_is_neg;               // A[31] == 1
wire        busy;                   // busy signal to microcode sequencer (stalls cpu)

reg [`MC_MEM_BITS-1:0] mc_pc;       // microcode PC
initial mc_pc <= `MC_ADDR_RESET-1;
wire [`MC_BITS-1:0] mc_op;          // current microcode operation

// memory addr / write ports
assign mem_addr = (sel_addr == `SEL_ADDR_SP) ? sp :
                  (sel_addr == `SEL_ADDR_A)  ? a  :
                  (sel_addr == `SEL_ADDR_B)  ? b  : pc;
assign mem_data_write_int = a;      // only A can be written to memory

// ------- alu instantiation -------
wire [31:0] alu_a;
wire [31:0] alu_b;
wire [31:0] alu_r;
wire [`ALU_OP_WIDTH-1:0] alu_op;
wire        alu_done;

// alu inputs multiplexors
// constant in microcode is sign extended (in order to implement substractions like adds)
assign alu_a = (sel_read == `SEL_READ_DATA)   ? mem_data_read_int : mem_addr;
assign alu_b = (sel_alu == `SEL_ALU_MC_CONST) ? { {25{mc_op[`P_ADDR+6]}} , mc_op[`P_ADDR+6:`P_ADDR] } :    // most priority
               (sel_alu == `SEL_ALU_A)        ? a :
               (sel_alu == `SEL_ALU_B)        ? b : { {24{1'b0}} , opcode };    // `SEL_ALU_OPCODE is less priority

zpu_alu alu(
    .alu_a      (alu_a),
    .alu_b      (alu_b),
    .alu_r      (alu_r),
    .alu_op     (alu_op),
    .flag_idim  (idim),
    .clk        (clk),
    .done       (alu_done)
);

// -------- pc : program counter --------
always @(posedge clk)
begin
    if (w_pc)
        pc <= alu_r;
`ifdef ENABLE_PC_INCREMENT              // microcode optimization
    else if (w_pc_increment)
        pc <= pc + 1;                   // usually pc = pc + 1
`endif
end

// -------- sp : stack pointer --------
always @(posedge clk)
begin
    if (w_sp)
        sp <= alu_r;
end

// -------- a : acumulator register ---------
always @(posedge clk)
begin
    if (w_a)
        a <= alu_r;
    else if (w_a_mem)
        a <= mem_data_read_int;
end

// alu results over a register instead of alu result
// in order to improve speed
assign a_is_zero = (a == 0);
assign a_is_neg  = a[31];

// -------- b : auxiliary register ---------
always @(posedge clk)
begin
    if (w_b)
        b <= alu_r;
end

// -------- opcode and opcode_cache  --------
always @(posedge clk)
begin
    if (w_op) begin
        opcode_cache <= alu_r;          // store all opcodes in the word
        pc_cached <= pc[31:2];          // store PC address of cached opcodes
    end
end

// -------- opcode : based on pc[1:0] ---------
always @(sel_opcode or opcode_cache)    // select current opcode from
begin                    // the cached opcode word
    case (sel_opcode)
    0 : opcode <= opcode_cache[31:24];
    1 : opcode <= opcode_cache[23:16];
    2 : opcode <= opcode_cache[15:8];
    3 : opcode <= opcode_cache[7:0];
    endcase
end

// ------- idim : immediate opcode handling  ----------
always @(posedge clk)
begin
    if (set_idim)
        idim <= 1'b1;
    else if (clear_idim)
        idim <= 1'b0;
end

`ifdef ENABLE_CPU_INTERRUPTS
// ------ on interrupt status bit -----
always @(posedge clk)
begin
    if (reset | exit_interrupt)
        on_interrupt <= 1'b0;
    else if (enter_interrupt)
        on_interrupt <= 1'b1;
end
`endif

// ------ microcode execution unit --------
assign sel_read  = mc_op[`P_SEL_READ];    // map datapath signals with microcode program bits
assign sel_alu   = mc_op[`P_SEL_ALU+1:`P_SEL_ALU];
assign sel_addr  = mc_op[`P_SEL_ADDR+1:`P_SEL_ADDR];
assign alu_op    = mc_op[`P_ALU+3:`P_ALU];
assign w_sp      = mc_op[`P_W_SP] & ~busy;
assign w_pc      = mc_op[`P_W_PC] & ~busy;
assign w_a       = mc_op[`P_W_A] & ~busy;
assign w_a_mem   = mc_op[`P_W_A_MEM] & ~busy;
assign w_b       = mc_op[`P_W_B] & ~busy;
assign w_op      = mc_op[`P_W_OPCODE] & ~busy;
assign mem_read  = mc_op[`P_MEM_R];
assign mem_write = mc_op[`P_MEM_W];
assign set_idim  = mc_op[`P_SET_IDIM] & ~busy;
assign clear_idim= mc_op[`P_CLEAR_IDIM] & ~busy;
`ifdef ENABLE_BYTE_SELECT
assign byte_op   = mc_op[`P_BYTE];
assign halfw_op  = mc_op[`P_HALFWORD];
`else
assign byte_op   = 0;
assign halfw_op  = 0;
`endif
`ifdef ENABLE_PC_INCREMENT
  assign w_pc_increment = mc_op[`P_PC_INCREMENT] & ~busy;
`endif
`ifdef ENABLE_CPU_INTERRUPTS
  assign exit_interrupt  = mc_op[`P_EXIT_INT]  & ~busy;
  assign enter_interrupt = mc_op[`P_ENTER_INT] & ~busy;
`endif

wire   cond_op_not_cached = mc_op[`P_OP_NOT_CACHED];    // conditional: true if opcode not cached
wire   cond_a_zero        = mc_op[`P_A_ZERO];           // conditional: true if A is zero
wire   cond_a_neg         = mc_op[`P_A_NEG];            // conditional: true if A is negative
wire   decode             = mc_op[`P_DECODE];           // decode means jumps to apropiate microcode based on zpu opcode
wire   branch             = mc_op[`P_BRANCH];           // unconditional jump inside microcode

wire [`MC_MEM_BITS-1:0] mc_goto  = { mc_op[`P_ADDR+6:`P_ADDR], 2'b00 }; // microcode goto (goto = high 7 bits)
wire [`MC_MEM_BITS-1:0] mc_entry = { opcode[6:0], 2'b00 };              // microcode entry point for opcode
reg  [`MC_MEM_BITS-1:0] next_mc_pc;                                     // next microcode operation to be executed
initial next_mc_pc <= `MC_ADDR_RESET-1;

wire cond_branch = (cond_op_not_cached & ~is_op_cached) |       // sum of all conditionals
                   (cond_a_zero & a_is_zero) |
                   (cond_a_neg & a_is_neg);

assign busy = ((mem_read | mem_write) & ~mem_done) | ~alu_done; // busy signal for microcode sequencer

// ------- handle interrupts ---------
`ifdef ENABLE_CPU_INTERRUPTS
always @(posedge clk)
begin
    if (reset | on_interrupt)
        int_requested <= 0;
    else if (interrupt & ~on_interrupt & ~int_requested)
        int_requested <= 1;             // interrupt requested
end
`endif

// ----- calculate next microcode address (next, decode, branch, specific opcode, etc.) -----
always @(reset or mc_pc or mc_goto or opcode[7:4] or idim or
         decode or branch or cond_branch or mc_entry or busy
`ifdef ENABLE_CPU_INTERRUPTS
         or int_requested
`endif
)
begin
  // default, next microcode instruction
  next_mc_pc <= mc_pc + 1;
  if (reset)                               next_mc_pc <= `MC_ADDR_RESET;
  else if (~busy) begin
    // get next microcode instruction
    if (branch | cond_branch)              next_mc_pc <= mc_goto;
    else if (decode) begin                 // decode: entry point of a new zpu opcode

`ifdef ENABLE_CPU_INTERRUPTS
      if (int_requested & ~idim)           next_mc_pc <= `MC_ADDR_INTERRUPT;    // microde to enter interrupt mode
      else
`endif
      if (opcode[7]        == `OP_IM)      next_mc_pc <= (idim ? `MC_ADDR_IM_IDIM : `MC_ADDR_IM_NOIDIM);
      else if (opcode[7:5] == `OP_STORESP) next_mc_pc <= `MC_ADDR_STORESP;
      else if (opcode[7:5] == `OP_LOADSP)  next_mc_pc <= `MC_ADDR_LOADSP;
      else if (opcode[7:4] == `OP_ADDSP)   next_mc_pc <= `MC_ADDR_ADDSP;
      else                                 next_mc_pc <= mc_entry;    // includes EMULATE opcodes
    end
  end
  else next_mc_pc <= mc_pc;        // in case of cpu stalled (busy=1)
end

// set microcode program counter
always @(posedge clk) mc_pc <= next_mc_pc;

// ----- microcode program ------
zpu_rom microcode(
    .addr   (next_mc_pc),
    .data   (mc_op),
    .clk    (clk)
);

// -------------- ZPU debugger --------------------
`ifdef ZPU_CORE_DEBUG
//synthesis translate_off
// ---- register operation dump ----
always @(posedge clk)
begin
    if (~reset) begin
        if (w_pc) $display("zpu_core: set PC=0x%h", alu.alu_r);
`ifdef ENABLE_PC_INCREMENT
        if (w_pc_increment) $display("zpu_core: set PC=0x%h (PC+1)", pc);
`endif
        if (w_sp) $display("zpu_core: set SP=0x%h", alu.alu_r);
        if (w_a) $display("zpu_core: set A=0x%h", alu.alu_r);
        if (w_a_mem) $display("zpu_core: set A=0x%h (from MEM)", mem_data_read_int);
        if (w_b) $display("zpu_core: set B=0x%h", alu.alu_r);
        if (w_op & ~is_op_cached) $display("zpu_core: set opcode_cache=0x%h, pc_cached=0x%h", alu.alu_r, {pc[31:2], 2'b0});
`ifdef ENABLE_CPU_INTERRUPTS
        if (~busy & mc_pc == `MC_ADDR_INTERRUPT) $display("zpu_core: ***** ENTERING INTERRUPT MICROCODE ******");
        if (~busy & exit_interrupt) $display("zpu_core: ***** INTERRUPT FLAG CLEARED *****");
        if (~busy & enter_interrupt) $display("zpu_core: ***** INTERRUPT FLAG SET *****");
`endif
        if (set_idim & ~idim) $display("zpu_core: IDIM=1");
        if (clear_idim & idim) $display("zpu_core: IDIM=0");

// ---- microcode debug ----
`ifdef ZPU_CORE_DEBUG_MICROCODE
        if (~busy) begin
            $display("zpu_core: mc_op[%d]=0b%b", mc_pc, mc_op);
            if (branch)      $display("zpu_core: microcode: branch=%d", mc_goto);
            if (cond_branch) $display("zpu_core: microcode: CONDITION branch=%d", mc_goto);
            if (decode)      $display("zpu_core: decoding opcode=0x%h (0b%b) : branch to=%d ", opcode, opcode, mc_entry);
        end
        else $display("zpu_core: busy");
`endif

// ---- cpu abort in case of unaligned memory access ---
`ifdef ASSERT_NON_ALIGNMENT
        /* unaligned word access (except PC) */
        if (sel_addr != `SEL_ADDR_PC &
            mem_addr[1:0] != 2'b00 &
            (mem_read | mem_write) &
            !byte_op & !halfw_op) begin
            $display("zpu_core: unaligned word operation at addr=0x%x", mem_addr);
            $finish;
        end

        /* unaligned halfword access */
        if (mem_addr[0] & (mem_read | mem_write) & !byte_op & halfw_op) begin
            $display("zpu_core: unaligned halfword operation at addr=0x%x", mem_addr);
            $finish;
        end
`endif
    end
end

// ----- opcode dissasembler ------
always @(posedge clk) begin
    if (~busy)
        case (mc_pc)
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

        `MC_ADDR_IM_NOIDIM : $display("zpu_core: ------  im 0x%h (1st) ------", opcode[6:0] );
        `MC_ADDR_IM_IDIM   : $display("zpu_core: ------  im 0x%h (cont) ------", opcode[6:0] );
        `MC_ADDR_STORESP   : $display("zpu_core: ------  storesp 0x%h ------", { ~opcode[4], opcode[3:0], 2'b0 } );
        `MC_ADDR_LOADSP    : $display("zpu_core: ------  loadsp 0x%h ------", { ~opcode[4], opcode[3:0], 2'b0 } );
        `MC_ADDR_ADDSP     : $display("zpu_core: ------  addsp 0x%h ------", { ~opcode[4], opcode[3:0], 2'b0 } );
        `MC_ADDR_EMULATE   : $display("zpu_core: ------  emulate 0x%h ------", b[2:0]); // opcode[5:0] );

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
//synthesis translate_on
`endif
endmodule
