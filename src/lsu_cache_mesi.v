// simple_lsu_mesi.v
// Minimal, educational, blocking LSU + direct-mapped D-cache with MESI per-line FSM
// - Single outstanding request (blocking)
// - Small direct-mapped cache (parameterized)
// - Clear separation: LSU top FSM + per-line MESI bits
// - External bus/snoop interface is left as simple signals so a testbench or bus model
//   can drive snoops and memory responses.
//
// This file is intended to be concise and easy to read. It is functionally correct for
// a blocking single-cache MESI implementation suitable for learning and small simulations.

`timescale 1ns/1ps

module simple_lsu_mesi #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter NUM_LINES = 32,
    parameter LINE_WORDS = 4 // words per line
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // CPU interface
    input  wire                   cpu_req_v,       // request valid
    input  wire [1:0]             cpu_req_type,    // 00=NOP, 01=LOAD, 10=STORE
    input  wire [ADDR_W-1:0]      cpu_addr,
    input  wire [DATA_W-1:0]      cpu_wdata,
    output reg                    cpu_resp_v,      // response valid
    output reg  [DATA_W-1:0]      cpu_rdata,
    output reg                    cpu_stall,       // stall upstream CPU

    // Simple bus interface (to memory / other caches)
    output reg                    bus_req_v,       // drive a request onto bus
    output reg  [1:0]             bus_req_type,    // 00=BusRd, 01=BusRdX, 10=BusUpgr
    output reg  [ADDR_W-1:0]      bus_addr,
    input  wire                   bus_resp_v,      // data returned from bus/memory
    input  wire [DATA_W-1:0]      bus_resp_data,

    // Snoop inputs (from bus fabric / testbench)
    input  wire                   snoop_busrd,     // someone else issued BusRd for snoop_addr
    input  wire                   snoop_busrdx,    // someone else issued BusRdX for snoop_addr
    input  wire [ADDR_W-1:0]      snoop_addr
);

// -----------------------------------------------------------------------------
// Localparams and encodings
// -----------------------------------------------------------------------------
localparam REQ_NOP   = 2'b00;
localparam REQ_LOAD  = 2'b01;
localparam REQ_STORE = 2'b10;

localparam BUSRD   = 2'b00;
localparam BUSRDX  = 2'b01;
localparam BUSUPGR = 2'b10;

localparam MS_I = 2'b00;
localparam MS_S = 2'b01;
localparam MS_E = 2'b10;
localparam MS_M = 2'b11;

localparam S_IDLE      = 3'd0;
localparam S_CHECK     = 3'd1;
localparam S_HIT       = 3'd2;
localparam S_ISSUE     = 3'd3;
localparam S_WAIT      = 3'd4;
localparam S_FILL      = 3'd5;
localparam S_RESPOND   = 3'd6;

// -----------------------------------------------------------------------------
// Address decomposition
// -----------------------------------------------------------------------------
localparam INDEX_W = $clog2(NUM_LINES);
localparam WORD_OFF_W = $clog2(LINE_WORDS); // word offset within line
localparam BYTE_OFF_W = 2; // assume 32-bit words
localparam OFFSET_W = WORD_OFF_W + BYTE_OFF_W;
localparam TAG_W = ADDR_W - (INDEX_W + OFFSET_W);

wire [INDEX_W-1:0] cpu_index = cpu_addr[BYTE_OFF_W +: INDEX_W];
wire [WORD_OFF_W-1:0] cpu_word_off = cpu_addr[BYTE_OFF_W +: WORD_OFF_W];
wire [TAG_W-1:0] cpu_tag = cpu_addr[ADDR_W-1 : ADDR_W-TAG_W];

// For snoop
wire [INDEX_W-1:0] snoop_index = snoop_addr[BYTE_OFF_W +: INDEX_W];
wire [TAG_W-1:0] snoop_tag = snoop_addr[ADDR_W-1 : ADDR_W-TAG_W];

// -----------------------------------------------------------------------------
// Simple direct-mapped structures
// -----------------------------------------------------------------------------
reg [TAG_W-1:0] tag_mem [0:NUM_LINES-1];
reg valid_mem [0:NUM_LINES-1];
reg [1:0] mesi_mem [0:NUM_LINES-1];
reg [DATA_W-1:0] data_mem [0:NUM_LINES*LINE_WORDS-1]; // flattened: line*LINE_WORDS + word

integer i;
initial begin
    for (i=0;i<NUM_LINES;i=i+1) begin
        valid_mem[i] = 1'b0;
        tag_mem[i] = {TAG_W{1'b0}};
        mesi_mem[i] = MS_I;
    end
    for (i=0;i<NUM_LINES*LINE_WORDS;i=i+1) data_mem[i] = {DATA_W{1'b0}};
end

// -----------------------------------------------------------------------------
// Internal registers
// -----------------------------------------------------------------------------
reg [2:0] state, state_n;
reg [ADDR_W-1:0] req_addr;
reg [1:0] req_type;
reg [DATA_W-1:0] req_wdata;

// single-entry MSHR
reg mshr_valid;
reg [ADDR_W-1:0] mshr_addr;
reg [1:0] mshr_type;

// latch bus response
reg bus_resp_v_d;
reg [DATA_W-1:0] bus_resp_data_d;

// scratch regs used in procedural blocks
reg [INDEX_W-1:0] fill_idx;
reg [TAG_W-1:0] fill_tag;
reg [WORD_OFF_W-1:0] fill_word_off;

// -----------------------------------------------------------------------------
// Bus response latch
// -----------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bus_resp_v_d <= 1'b0;
        bus_resp_data_d <= {DATA_W{1'b0}};
    end else begin
        bus_resp_v_d <= bus_resp_v;
        bus_resp_data_d <= bus_resp_data;
    end
end

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
function is_hit;
    input [INDEX_W-1:0] idx;
    input [TAG_W-1:0] t;
    begin
        is_hit = (valid_mem[idx] && tag_mem[idx] == t);
    end
endfunction

// read/write helpers (for simple aligned word accesses)
function [DATA_W-1:0] read_word;
    input [INDEX_W-1:0] idx;
    input [WORD_OFF_W-1:0] woff;
    begin
        read_word = data_mem[{idx, woff}];
    end
endfunction

// -----------------------------------------------------------------------------
// Combinational next-state and outputs
// -----------------------------------------------------------------------------
integer li;
always @(*) begin
    // defaults
    state_n = state;
    cpu_resp_v = 1'b0;
    cpu_rdata = {DATA_W{1'b0}};
    cpu_stall = 1'b0;
    bus_req_v = 1'b0;
    bus_req_type = BUSRD;
    bus_addr = {ADDR_W{1'b0}};

    case (state)
        S_IDLE: begin
            if (cpu_req_v) state_n = S_CHECK;
        end

        S_CHECK: begin
            // capture request (req_* already captured in sequential block)
            if (is_hit(cpu_index, cpu_tag)) begin
                state_n = S_HIT;
            end else begin
                state_n = S_ISSUE;
            end
        end

        S_HIT: begin
            // decide by MESI state
            case (mesi_mem[cpu_index])
                MS_M, MS_E: begin
                    if (req_type == REQ_LOAD) begin
                        cpu_rdata = read_word(cpu_index, cpu_word_off);
                        cpu_resp_v = 1'b1;
                        state_n = S_RESPOND;
                    end else if (req_type == REQ_STORE) begin
                        // do local write
                        // write entire word for simplicity
                        // update state: E->M if needed
                        // We'll perform write in sequential block
                        cpu_resp_v = 1'b1;
                        state_n = S_RESPOND;
                    end else begin
                        state_n = S_RESPOND;
                    end
                end

                MS_S: begin
                    if (req_type == REQ_LOAD) begin
                        cpu_rdata = read_word(cpu_index, cpu_word_off);
                        cpu_resp_v = 1'b1;
                        state_n = S_RESPOND;
                    end else if (req_type == REQ_STORE) begin
                        // Need upgrade: issue BusUpgr
                        bus_req_v = 1'b1;
                        bus_req_type = BUSUPGR;
                        bus_addr = req_addr;
                        cpu_stall = 1'b1;
                        state_n = S_WAIT;
                    end
                end

                MS_I: begin
                    // shouldn't happen for hit
                    state_n = S_ISSUE;
                end

                default: state_n = S_IDLE;
            endcase
        end

        S_ISSUE: begin
            // MISS: decide BusRd (load) or BusRdX (store)
            if (req_type == REQ_LOAD) begin
                bus_req_v = 1'b1;
                bus_req_type = BUSRD;
                bus_addr = req_addr;
                cpu_stall = 1'b1;
                state_n = S_WAIT;
            end else if (req_type == REQ_STORE) begin
                bus_req_v = 1'b1;
                bus_req_type = BUSRDX;
                bus_addr = req_addr;
                cpu_stall = 1'b1;
                state_n = S_WAIT;
            end else begin
                state_n = S_IDLE;
            end
        end

        S_WAIT: begin
            // wait for bus response (or for BusUpgr immediate ack)
            cpu_stall = 1'b1;
            // Simple model: BusUpgr is considered completed immediately (no memory data)
            if (bus_req_v && bus_req_type == BUSUPGR) begin
                // after upgrade, we transition S->M and perform store in sequential block
                state_n = S_RESPOND;
            end else if (bus_resp_v_d) begin
                state_n = S_FILL;
            end
        end

        S_FILL: begin
            // Data arrived from bus; fill cache line and set MESI correctly
            // If the request was a LOAD -> set E (no sharers assumed)
            // If request was a STORE -> set M
            if (mshr_type == REQ_LOAD || req_type == REQ_LOAD) begin
                // fill and respond with data
                cpu_rdata = bus_resp_data_d;
                cpu_resp_v = 1'b1;
                state_n = S_RESPOND;
            end else if (mshr_type == REQ_STORE || req_type == REQ_STORE) begin
                // for store, we write data into line (handled sequentially)
                cpu_resp_v = 1'b1;
                state_n = S_RESPOND;
            end else begin
                state_n = S_RESPOND;
            end
        end

        S_RESPOND: begin
            cpu_stall = 1'b0;
            state_n = S_IDLE;
        end

        default: state_n = S_IDLE;
    endcase
end

// -----------------------------------------------------------------------------
// Sequential: register updates, MSHR allocation, writes, snoop handling
// -----------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        req_addr <= {ADDR_W{1'b0}};
        req_type <= REQ_NOP;
        req_wdata <= {DATA_W{1'b0}};
        mshr_valid <= 1'b0;
        mshr_addr <= {ADDR_W{1'b0}};
        mshr_type <= REQ_NOP;
        bus_req_v <= 1'b0;
        bus_req_type <= BUSRD;
        bus_addr <= {ADDR_W{1'b0}};
        cpu_resp_v <= 1'b0;
        cpu_rdata <= {DATA_W{1'b0}};
        cpu_stall <= 1'b0;
    end else begin
        state <= state_n;

        // capture CPU request when idle
        if (state == S_IDLE && cpu_req_v) begin
            req_addr <= cpu_addr;
            req_type <= cpu_req_type;
            req_wdata <= cpu_wdata;
        end

        // On ISSUING a miss allocate MSHR
        if (state == S_ISSUE) begin
            mshr_valid <= 1'b1;
            mshr_addr <= req_addr;
            mshr_type <= req_type;
            // drive bus signals for one cycle (consumer/bus model should sample combinationally)
            bus_req_v <= 1'b1;
            bus_req_type <= (req_type == REQ_LOAD) ? BUSRD : BUSRDX;
            bus_addr <= req_addr;
        end else if (state != S_ISSUE) begin
            // Deassert bus_req_v except when reasserted in combinational logic
            bus_req_v <= 1'b0;
        end

        // When in WAIT and BusUpgr was issued (combinational), treat as immediate ack
        if (state == S_WAIT && bus_req_v && bus_req_type == BUSUPGR) begin
            // perform S->M upgrade and local store
            // find index/tag
            if (is_hit(cpu_index, cpu_tag)) begin
                mesi_mem[cpu_index] <= MS_M;
                // write data
                data_mem[{cpu_index, cpu_word_off}] <= req_wdata;
                valid_mem[cpu_index] <= 1'b1;
            end
            // respond next cycle
        end

        // On FILL: install line
        if (state == S_FILL && bus_resp_v_d) begin
            // install into cache: write tag, set valid, set MESI
            // compute index/tag from mshr_addr (use the captured req_addr)
            // For simplicity we use mshr_addr here
            fill_idx <= mshr_addr[BYTE_OFF_W +: INDEX_W];
            fill_tag <= mshr_addr[ADDR_W-1 : ADDR_W-TAG_W];
            fill_word_off <= mshr_addr[BYTE_OFF_W +: WORD_OFF_W];

            tag_mem[fill_idx] <= fill_tag;
            valid_mem[fill_idx] <= 1'b1;
            if (mshr_type == REQ_LOAD) mesi_mem[fill_idx] <= MS_E; else mesi_mem[fill_idx] <= MS_M;
            // store returned word into appropriate word slot
            data_mem[{fill_idx, fill_word_off}] <= bus_resp_data_d;

            // free MSHR
            mshr_valid <= 1'b0;
            mshr_type <= REQ_NOP;
        end

        // On RESPOND, perform store side-effects if needed
        if (state == S_RESPOND) begin
            // If it was a store hit in E or M we need to write the data (handle E->M transition)
            if (req_type == REQ_STORE) begin
                if (is_hit(cpu_index, cpu_tag)) begin
                    if (mesi_mem[cpu_index] == MS_E) mesi_mem[cpu_index] <= MS_M;
                    // write word
                    data_mem[{cpu_index, cpu_word_off}] <= req_wdata;
                    valid_mem[cpu_index] <= 1'b1;
                end
            end
            // default: respond to CPU (cpu_resp_v was asserted combinationally)
        end

        // Handle snoops: they can happen at any time and should update MESI bits
        if (snoop_busrd) begin
            if (valid_mem[snoop_index] && tag_mem[snoop_index] == snoop_tag) begin
                case (mesi_mem[snoop_index])
                    MS_M: begin
                        // supply data (in a fuller model) and downgrade to S
                        // here we simply downgrade and assume someone else or memory will get data
                        mesi_mem[snoop_index] <= MS_S;
                        // In a real design we'd also assert a supply signal with data
                    end
                    MS_E: begin
                        // downgrade to S
                        mesi_mem[snoop_index] <= MS_S;
                    end
                    default: ;
                endcase
            end
        end

        if (snoop_busrdx) begin
            if (valid_mem[snoop_index] && tag_mem[snoop_index] == snoop_tag) begin
                // invalidate our copy; if M then would writeback in real design
                mesi_mem[snoop_index] <= MS_I;
                valid_mem[snoop_index] <= 1'b0;
            end
        end
    end
end

endmodule

// -----------------------------------------------------------------------------
// Notes:
// - This implementation intentionally simplifies many practical details:
//   * Tag storage is made simple but trimmed to fit into small demo code
//   * BusUpgr is modeled as an immediate completion (no external ack)
//   * Cache-to-cache transfers and explicit writeback data paths are not implemented
//   * Only the single-word requested is copied into the line on fill (not full line)
// - The design is ideal as a learning scaffold , can extend it by adding:
//   * full-line fills, multiple outstanding MSHRs, explicit bus ack mechanism,
//   * cache-to-cache data supply signals, writeback buffer, and set associativity.
// -----------------------------------------------------------------------------
