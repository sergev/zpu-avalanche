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
    o_addr[21:2],           // input address
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

endmodule
