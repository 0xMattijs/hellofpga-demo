// 8N1 UART transmitter. The fabric TX pin goes to the PIC32, which passes
// every byte on to the PC over USB.
module uart_tx #(
    parameter DIV = 434     // clk / baud: 100 MHz / 230400
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,   // ignored while busy
    input  wire [7:0] data,
    output wire       busy,
    output wire       tx
);

    reg [9:0]  shift;          // stop, data[7:0], start; sent LSB first
    reg [3:0]  bits_left;
    reg [15:0] count;

    assign busy = bits_left != 0;
    assign tx   = busy ? shift[0] : 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift <= 10'h3FF;
            bits_left <= 0;
            count <= 0;
        end else if (!busy) begin
            if (start) begin
                shift <= {1'b1, data, 1'b0};
                bits_left <= 10;
                count <= DIV - 1;
            end
        end else if (count != 0) begin
            count <= count - 1'b1;
        end else begin
            shift <= {1'b1, shift[9:1]};
            bits_left <= bits_left - 1'b1;
            count <= DIV - 1;
        end
    end

endmodule
