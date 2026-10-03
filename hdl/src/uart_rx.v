// UART receiver: 8N1, with a FIFO the Cortex-M3 drains over APB.
// Bytes come from the PC through the PIC32 in relay mode, at the same rate
// uart_tx sends. A byte with a bad stop bit is dropped.
module uart_rx #(
    parameter CLKS_PER_BIT = 434,   // 100 MHz / 230400 baud
    parameter DEPTH_LOG2   = 6      // FIFO of 64 bytes
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,           // idles high

    input  wire       pop,          // one cycle: drop the byte at the head
    output wire [7:0] head,         // oldest byte; valid when !empty
    output wire       empty,
    output reg        overflow      // sticky: a byte arrived with the FIFO full
);

    // Receiver
    reg [1:0]  rx_s;
    reg        busy;
    reg [8:0]  count;               // clocks to the next sample
    reg [3:0]  bit_ix;              // 0: start bit, 1-8: data, 9: stop bit
    reg [7:0]  shift;
    reg        got;                 // one cycle: shift holds a byte
    wire       rxd = rx_s[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s <= 2'b11; busy <= 0; count <= 0; bit_ix <= 0; shift <= 0; got <= 0;
        end else begin
            rx_s <= {rx_s[0], rx};
            got  <= 0;
            if (!busy) begin
                if (!rxd) begin                     // start bit: sample its middle
                    busy   <= 1;
                    count  <= CLKS_PER_BIT / 2;
                    bit_ix <= 0;
                end
            end else if (count != 0) begin
                count <= count - 1'b1;
            end else begin
                count <= CLKS_PER_BIT - 1;
                if (bit_ix == 0) begin
                    if (rxd) busy <= 0;             // a glitch, not a start bit
                end else if (bit_ix <= 8) begin
                    shift <= {rxd, shift[7:1]};     // LSB first
                end else begin
                    busy <= 0;
                    got  <= rxd;                    // keep it only with a stop bit
                end
                bit_ix <= bit_ix + 1'b1;
            end
        end
    end

    // FIFO
    localparam DEPTH = 1 << DEPTH_LOG2;
    reg [7:0]          mem [0:DEPTH-1];
    reg [DEPTH_LOG2:0] wr, rd;
    assign empty = wr == rd;
    assign head  = mem[rd[DEPTH_LOG2-1:0]];
    wire   full  = (wr - rd) == DEPTH;

    always @(posedge clk) begin
        if (got && !full)
            mem[wr[DEPTH_LOG2-1:0]] <= shift;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr <= 0; rd <= 0; overflow <= 0;
        end else begin
            if (got) begin
                if (full) overflow <= 1;
                else      wr <= wr + 1'b1;
            end
            if (pop && !empty)
                rd <= rd + 1'b1;
        end
    end

endmodule
