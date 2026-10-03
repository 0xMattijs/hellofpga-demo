// Testbench for game_top: small camera frames through the whole block.
// Run with: make sim
//
// The frame is gray except for a saturated green patch. The tracker's
// limits are set around that green, so it must find exactly the patch;
// the calibration box covers part of the patch and part of the gray.
//
// The overlay is on with the ball inside the frame; the frame's top 56
// lines are the HUD, which the overlay darkens. tb_game_overlay.v checks
// the rest of its layout.
//
// The camera model changes HREF and DATA on PCLK's falling edge, like the
// OV7725, with PCLK at 24 MHz against a 100 MHz system clock. A model of
// WRITE_LSRAM's sampling checks what the LCD path sees.
`timescale 1ns/1ps
module tb_game_top;
    localparam W = 32, H = 72;                  // frame size in pixels
    localparam PX0 = 10, PX1 = 20, PY0 = 20, PY1 = 30;   // green patch
    localparam BX0 = 16, BX1 = 26, BY0 = 24, BY1 = 34;   // calibration box
    localparam BALL_X = 8, BALL_Y = 58;
    localparam [15:0] FG = 16'hFFE0;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg pclk = 0, href = 0, vsync = 0, rx = 1;
    reg [2:0] sw_n = 3'b111;
    reg [7:0] data = 0;
    always #20.833 pclk = ~pclk;

    reg psel = 0, penable = 0, pwrite = 0;
    reg [31:0] paddr = 0, pwdata = 0;
    wire [31:0] prdata;
    wire lcd_pclk, lcd_href, lcd_vsync, lcd_psel, tx;
    wire [7:0] lcd_data;

    game_top dut (
        .clk(clk), .rst_n(rst_n),
        .cam_pclk_i(pclk), .cam_href_i(href), .cam_vsync_i(vsync), .cam_data_i(data),
        .lcd_pclk_o(lcd_pclk), .lcd_href_o(lcd_href), .lcd_vsync_o(lcd_vsync),
        .lcd_data_o(lcd_data),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .prdata_o(prdata), .lcd_psel_o(lcd_psel),
        .uart_rx_i(rx), .uart_tx_o(tx),
        .sw1_n_i(sw_n[0]), .sw2_n_i(sw_n[1]), .sw3_n_i(sw_n[2])
    );

    function in_patch(input integer x, input integer y);
        in_patch = x >= PX0 && x < PX1 && y >= PY0 && y < PY1;
    endfunction

    // Green in the patch; elsewhere a gray that steps with x.
    function [15:0] pixel(input integer x, input integer y);
        reg [4:0] v;
        begin
            v = x[4:0];
            pixel = in_patch(x, y) ? 16'h07E0 : {v, v, 1'b0, v};
        end
    endfunction

    // cam_bus's darkening: each channel halved.
    function [15:0] darken(input [15:0] p);
        darken = {1'b0, p[15:12], 1'b0, p[10:6], 1'b0, p[4:1]};
    endfunction

    integer errors = 0;
    task check(input cond, input [8*48-1:0] what);
        if (!cond) begin
            $display("FAIL: %0s", what);
            errors = errors + 1;
        end
    endtask

    // APB transfers, as the MSS issues them.
    task apb_write(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk) begin psel <= 1; paddr <= a; pwdata <= d; pwrite <= 1; end
            @(posedge clk) penable <= 1;
            @(posedge clk) begin psel <= 0; penable <= 0; pwrite <= 0; end
        end
    endtask
    reg [31:0] rd;
    task apb_read(input [31:0] a);
        begin
            @(posedge clk) begin psel <= 1; paddr <= a; pwrite <= 0; end
            @(posedge clk) penable <= 1;
            @(posedge clk) begin rd = prdata; psel <= 0; penable <= 0; end
        end
    endtask

    // One camera frame: VSYNC for 3 lines' time, then H lines of W pixels.
    task send_frame;
        integer x, y;
        reg [15:0] p;
        begin
            @(negedge pclk) vsync <= 1;
            repeat (3 * 2 * W) @(negedge pclk);
            vsync <= 0;
            repeat (20) @(negedge pclk);
            for (y = 0; y < H; y = y + 1) begin
                for (x = 0; x < W; x = x + 1) begin
                    p = pixel(x, y);
                    @(negedge pclk) begin href <= 1; data <= p[15:8]; end
                    @(negedge pclk) data <= p[7:0];
                end
                @(negedge pclk) begin href <= 0; data <= 8'hxx; end
                repeat (10) @(negedge pclk);
            end
        end
    endtask

    // Model of the LCD path: two input flops, then WRITE_LSRAM's edge detect.
    reg [1:0] l_pclk, l_href, l_vsync;
    reg [7:0] l_data1, l_data2;
    reg       l_dly, l_dly1;
    integer   l_byte, l_line;
    reg       l_href_d;
    reg [7:0] seen [0:H-1][0:2*W-1];
    always @(posedge clk) begin
        l_pclk  <= {l_pclk[0], lcd_pclk};
        l_href  <= {l_href[0], lcd_href};
        l_vsync <= {l_vsync[0], lcd_vsync};
        l_data1 <= lcd_data; l_data2 <= l_data1;
        l_dly <= l_pclk[1]; l_dly1 <= l_dly;
        l_href_d <= l_href[1];
        if (l_vsync[1]) begin
            l_line = 0; l_byte = 0;
        end else begin
            if (!l_href[1]) l_byte = 0;
            else if (l_dly && !l_dly1) begin
                if (l_line < H && l_byte < 2 * W) seen[l_line][l_byte] = l_data2;
                l_byte = l_byte + 1;
            end
            if (l_href_d && !l_href[1]) l_line = l_line + 1;
        end
    end

    // One byte into the RX pin at 230400 baud.
    task uart_send(input [7:0] b);
        integer i;
        begin
            rx = 0; #4340;
            for (i = 0; i < 8; i = i + 1) begin
                rx = b[i]; #4340;
            end
            rx = 1; #4340;
        end
    endtask

    // UART receiver for one byte at 230400 baud.
    reg [7:0] rx_byte;
    task uart_receive;
        integer i;
        begin
            @(negedge tx);
            #(4340 * 1.5);
            for (i = 0; i < 8; i = i + 1) begin
                rx_byte[i] = tx;
                #4340;
            end
            check(tx === 1'b1, "UART stop bit");
        end
    endtask

    integer x, y, n, sx, sy, br, bg, bb, bn, luma, cb, cr;
    reg [15:0] p, got;
    reg in_ball;

    initial begin
        #100 rst_n = 1;

        // The reset limits match nothing.
        apb_read(32'h30001018); check(rd == 32'h00FF_00FF, "TRACK_C reset");
        apb_read(32'h3000101C); check(rd == 32'h0000_00FF, "TRACK_Y reset");

        // YCbCr of the patch (R 0, G 252, B 0), as color_track computes it.
        luma = (150 * 252) >> 8;
        cb = (32768 - 85 * 252) >> 8;
        cr = (32768 - 107 * 252) >> 8;
        apb_write(32'h30001018, {8'(cr + 2), 8'(cr - 2), 8'(cb + 2), 8'(cb - 2)});
        apb_write(32'h3000101C, {16'h0, 8'(luma + 2), 8'(luma - 2)});
        apb_write(32'h3000102C, (BX1 << 16) | BX0);
        apb_write(32'h30001030, (BY1 << 16) | BY0);
        apb_read(32'h3000102C); check(rd == ((BX1 << 16) | BX0), "BOX_X");

        // Overlay on with only the ball shown, no digits or lives.
        apb_write(32'h30001044, (BALL_Y << 16) | BALL_X);
        apb_write(32'h3000106C, {16'hFE5A, FG});
        apb_write(32'h30001000, 32'b0001001);
        apb_read(32'h30001000); check(rd == 32'b0001001, "CTRL");
        apb_read(32'h3000106C); check(rd == {16'hFE5A, FG}, "COLORS");

        // PSEL reaches apb3_if only below 0x1000.
        @(posedge clk) begin psel <= 1; paddr <= 32'h3000070C; end
        @(posedge clk) check(lcd_psel === 1'b1, "apb3_if selected at 0x70C");
        @(posedge clk) begin paddr <= 32'h30001000; end
        @(posedge clk) check(lcd_psel === 1'b0, "apb3_if not selected at 0x1000");
        psel <= 0;

        send_frame;   // the registers take effect at this frame's VSYNC
        send_frame;   // the second VSYNC latches the first frame's sums
        @(negedge pclk) vsync <= 1;
        repeat (10) @(posedge clk);

        n = 0; sx = 0; sy = 0; br = 0; bg = 0; bb = 0; bn = 0;
        for (y = 0; y < H; y = y + 1)
            for (x = 0; x < W; x = x + 1) begin
                p = pixel(x, y);
                if (in_patch(x, y)) begin
                    n = n + 1; sx = sx + x; sy = sy + y;
                end
                if (x >= BX0 && x < BX1 && y >= BY0 && y < BY1) begin
                    br = br + {p[15:11], 3'b0};
                    bg = bg + {p[10:5], 2'b0};
                    bb = bb + {p[4:0], 3'b0};
                    bn = bn + 1;
                end
            end
        apb_read(32'h30001020); check(rd == n,  "TRACK_N");
        apb_read(32'h30001024); check(rd == sx, "TRACK_SX");
        apb_read(32'h30001028); check(rd == sy, "TRACK_SY");
        apb_read(32'h30001034); check(rd == br, "BOX_R");
        apb_read(32'h30001038); check(rd == bg, "BOX_G");
        apb_read(32'h3000103C); check(rd == bb, "BOX_B");
        apb_read(32'h30001040); check(rd == bn, "BOX_N");
        apb_read(32'h30001004); check(rd == 3, "FRAME");

        // The LCD path sees the image, the HUD darkened, and the ball.
        for (y = 0; y < H; y = y + 1)
            for (x = 0; x < W; x = x + 1) begin
                in_ball = x >= BALL_X && x < BALL_X + 16 && y >= BALL_Y && y < BALL_Y + 16;
                p = in_ball ? FG : y < 56 ? darken(pixel(x, y)) : pixel(x, y);
                got = {seen[y][2 * x], seen[y][2 * x + 1]};
                if (got !== p) begin
                    $display("FAIL: LCD pixel (%0d,%0d) = %h, expected %h", x, y, got, p);
                    errors = errors + 1;
                end
            end

        // A write in the middle of a frame shows up only from the next
        // frame on.
        vsync <= 0;
        fork
            send_frame;
            begin
                #(H / 2 * (2 * W + 11) * 41.666);
                apb_write(32'h30001000, 32'b0);
            end
        join
        for (y = 0; y < H; y = y + 1)
            for (x = 0; x < W; x = x + 1) begin
                in_ball = x >= BALL_X && x < BALL_X + 16 && y >= BALL_Y && y < BALL_Y + 16;
                p = in_ball ? FG : y < 56 ? darken(pixel(x, y)) : pixel(x, y);
                got = {seen[y][2 * x], seen[y][2 * x + 1]};
                if (got !== p) begin
                    $display("FAIL: frame with the write (%0d,%0d) = %h, expected %h",
                             x, y, got, p);
                    errors = errors + 1;
                end
            end
        send_frame;
        for (y = 0; y < H; y = y + 1)
            for (x = 0; x < W; x = x + 1) begin
                got = {seen[y][2 * x], seen[y][2 * x + 1]};
                if (got !== pixel(x, y)) begin
                    $display("FAIL: overlay off (%0d,%0d) = %h, expected %h",
                             x, y, got, pixel(x, y));
                    errors = errors + 1;
                end
            end

        // Host detection: a 100 ns glitch doesn't count, a start bit does.
        apb_read(32'h3000100C); check(rd == 0, "no host after reset");
        rx = 0; #100 rx = 1; #3000;
        apb_read(32'h3000100C); check(rd == 0, "RX glitch ignored");
        rx = 0; #4340 rx = 1; #100;
        apb_read(32'h3000100C); check(rd == 2, "host seen after a start bit");

        // UART
        fork
            apb_write(32'h3000100C, 32'hA5);
            uart_receive;
        join
        check(rx_byte == 8'hA5, "UART byte");
        #3000;
        apb_read(32'h3000100C); check(rd == 2, "UART idle after the byte");

        // UART receiver. The host-detection start bit above came in as 0xFF.
        apb_read(32'h30001010); check(rd == 32'h1FF, "RX: start bit read as 0xFF");
        uart_send(8'h6C);
        uart_send(8'h0A);
        apb_read(32'h30001010); check(rd == 32'h16C, "RX: first byte");
        apb_read(32'h30001010); check(rd == 32'h10A, "RX: second byte");
        apb_read(32'h30001010); check(rd[8] == 1'b0, "RX: empty");
        apb_read(32'h30001010); check(rd[9] == 1'b0, "RX: no overflow");

        // Color gains: 1.0 after reset, then writable.
        apb_read(32'h30001014); check(rd == {2'b0, 10'h80, 10'h80, 10'h80}, "COLOR_GAIN reset");
        apb_write(32'h30001014, {2'b0, 10'h081, 10'h082, 10'h083});
        apb_read(32'h30001014); check(rd == {2'b0, 10'h081, 10'h082, 10'h083}, "COLOR_GAIN write");

        // Bricks: each row register holds its own 10 bits.
        apb_write(32'h30001058, 32'h3FF);
        apb_write(32'h30001068, 32'h201);
        apb_read(32'h30001058); check(rd == 32'h3FF, "BRICKS0");
        apb_read(32'h3000105C); check(rd == 0, "BRICKS1");
        apb_read(32'h30001068); check(rd == 32'h201, "BRICKS4");

        // Buttons
        apb_read(32'h30001008); check(rd == 0, "no button pressed");
        sw_n = 3'b101;
        repeat (4) @(posedge clk);
        apb_read(32'h30001008); check(rd == 2, "SW2 pressed");
        sw_n = 3'b111;

        if (errors == 0) $display("PASS");
        else $display("%0d errors", errors);
        $finish;
    end
endmodule
