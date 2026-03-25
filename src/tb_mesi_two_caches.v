`timescale 1ns/1ps

module simple_lsu_mesi_tb;

    localparam ADDR_W = 32;
    localparam DATA_W = 32;

    reg clk = 0;
    reg rst_n = 0;

    // CPU interface signals
    reg                 cpu_req_v;
    reg  [1:0]          cpu_req_type;   // 01=LOAD, 10=STORE
    reg  [ADDR_W-1:0]   cpu_addr;
    reg  [DATA_W-1:0]   cpu_wdata;
    wire                cpu_resp_v;
    wire [DATA_W-1:0]   cpu_rdata;
    wire                cpu_stall;

    // Bus interface
    wire                bus_req_v;
    wire [1:0]          bus_req_type;   // 00=BusRd, 01=BusRdX, 10=BusUpgr
    wire [ADDR_W-1:0]   bus_addr;
    reg                 bus_resp_v;
    reg  [DATA_W-1:0]   bus_resp_data;

    // Snoops
    reg snoop_busrd;
    reg snoop_busrdx;
    reg [ADDR_W-1:0] snoop_addr;

    // Instantiate DUT
    simple_lsu_mesi dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_req_v(cpu_req_v),
        .cpu_req_type(cpu_req_type),
        .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata),
        .cpu_resp_v(cpu_resp_v),
        .cpu_rdata(cpu_rdata),
        .cpu_stall(cpu_stall),
        .bus_req_v(bus_req_v),
        .bus_req_type(bus_req_type),
        .bus_addr(bus_addr),
        .bus_resp_v(bus_resp_v),
        .bus_resp_data(bus_resp_data),
        .snoop_busrd(snoop_busrd),
        .snoop_busrdx(snoop_busrdx),
        .snoop_addr(snoop_addr)
    );

    // Clock
    always #5 clk = ~clk;

    // Simple memory model (always responds after a small delay)
    task memory_respond;
        input [ADDR_W-1:0] addr;
        begin
            #20;
            bus_resp_data = {4{addr[7:0]}}; // simple pattern
            bus_resp_v = 1;
            #10 bus_resp_v = 0;
        end
    endtask

    // CPU load operation
    task cpu_load;
        input [ADDR_W-1:0] addr;
        begin
            @(negedge clk);
            cpu_addr = addr;
            cpu_req_type = 2'b01;
            cpu_req_v = 1;
            @(negedge clk);
            cpu_req_v = 0;
        end
    endtask

    // CPU store operation
    task cpu_store;
        input [ADDR_W-1:0] addr;
        input [DATA_W-1:0] data;
        begin
            @(negedge clk);
            cpu_addr = addr;
            cpu_wdata = data;
            cpu_req_type = 2'b10;
            cpu_req_v = 1;
            @(negedge clk);
            cpu_req_v = 0;
        end
    endtask

    initial begin
        // Init
        bus_resp_v = 0;
        bus_resp_data = 0;
        snoop_busrd = 0;
        snoop_busrdx = 0;
        snoop_addr = 0;

        cpu_req_v = 0;
        cpu_req_type = 0;
        cpu_addr = 0;
        cpu_wdata = 0;

        #20 rst_n = 1;
        #20;

        // -------------------------------
        // Test 1: LOAD MISS → BusRd → E
        // -------------------------------
        $display("TEST1: LOAD MISS");
        cpu_load(32'h1000);

        // Wait for bus request
        wait(bus_req_v);
        if (bus_req_type == 2'b00) $display("BusRd OK"); else $display("ERROR: expected BusRd");
        memory_respond(bus_addr);

        wait(cpu_resp_v);
        $display("CPU LOAD DATA = %h", cpu_rdata);

        #50;

        // -------------------------------
        // Test 2: STORE HIT in E → M
        // -------------------------------
        $display("TEST2: STORE HIT in E → M");
        cpu_store(32'h1000, 32'hDEADBEEF);
        wait(cpu_resp_v);
        $display("CPU STORE DONE");


        #100;
        $finish;
    end

endmodule
