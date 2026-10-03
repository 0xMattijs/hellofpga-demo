// Fabric block of the camera breakout demo: camera adapter, color tracker,
// game overlay, UART, and buttons, behind an APB target. One instance goes
// into the reference design's TOP SmartDesign (see libero/game_top.tcl).
//
// APB: shares the MSS FIC_0 master with the LCD's apb3_if. That block
// decodes only PADDR[11:0], so this one claims PADDR[12] and hides those
// cycles from it. Registers, from 0x30001000:
//
//   0x00 CTRL       RW [0] overlay on, [1] mirror x, [2] dim the video,
//                      [3] ball, [4] paddle, [5] tracker marker,
//                      [6] calibration box shown (game_overlay.v)
//   0x04 FRAME      R  frame counter
//   0x08 BUTTONS    R  [0] SW1, [1] SW2, [2] SW3 pressed (synchronized, not
//                      debounced beyond the board's RC filter)
//   0x0C UART       W  [7:0] byte to send; R [0] busy, [1] host seen
//   0x10 UART_RX    R  [7:0] oldest received byte, [8] valid, [9] FIFO
//                      overflowed since reset. Reading a valid byte removes it.
//   0x14 COLOR_GAIN RW [9:0] red, [19:10] green, [29:20] blue gain of the
//                      reference's Image_Enhancement, 0x80 = 1.0
//   0x18 TRACK_C    RW [7:0] Cb min, [15:8] Cb max, [23:16] Cr min,
//                      [31:24] Cr max (color_track.v)
//   0x1C TRACK_Y    RW [7:0] Y min, [15:8] Y max
//   0x20 TRACK_N    R  pixels inside the YCbCr box, last frame
//   0x24 TRACK_SX   R  sum of their x
//   0x28 TRACK_SY   R  sum of their y
//   0x2C BOX_X      RW [10:0] x0, [26:16] x1 (x1 exclusive), camera
//   0x30 BOX_Y      RW [9:0] y0, [25:16] y1          coordinates
//   0x34 BOX_R      R  red sum inside the calibration box, last frame
//   0x38 BOX_G      R
//   0x3C BOX_B      R
//   0x40 BOX_N      R  pixels inside the calibration box
//   0x44 BALL       RW [9:0] x, [25:16] y of the ball's top left, screen
//   0x48 PADDLE     RW [9:0] x of the left end, [25:16] width, screen
//   0x4C MARKER     RW [10:0] x, [25:16] y of the marker's center, camera
//   0x50 DIGITS     RW [27:0] four digits, gfedcba each, leftmost first
//   0x54 LIVES      RW [1:0] squares shown, 0..3
//   0x58 BRICKS0    RW [9:0] bricks in row 0 (top), bit 0 leftmost on screen
//   0x5C BRICKS1    RW
//   0x60 BRICKS2    RW
//   0x64 BRICKS3    RW
//   0x68 BRICKS4    RW
//   0x6C COLORS     RW [15:0] ball, paddle, and lives; [31:16] score and
//                      calibration box; RGB565
//
// The overlay and tracker registers take effect at the next VSYNC rise, so
// a frame never shows half an update. Tracker results update at each VSYNC
// rise and hold for a whole frame.
//
// Host seen: the RX pin (PC -> PIC32 -> FPGA) has carried a start bit since
// reset. The PIC32 relays FPGA bytes only after the PC sends it '&', and a
// byte that arrives before then overruns its UART, which then stops
// receiving for good. So the firmware stays quiet until the PC has sent '&'
// and then any byte, which the PIC32 relays here.
//
// There is no interrupt line: the MSS fabric interrupts and GPIO_0 sit
// inside the System Builder block, which Libero 2026.1 cannot regenerate
// without an older FCCC core. The Cortex-M3 polls FRAME instead.
module game_top (
    input  wire        clk,
    input  wire        rst_n,

    // Camera pins
    input  wire        cam_pclk_i,
    input  wire        cam_href_i,
    input  wire        cam_vsync_i,
    input  wire [7:0]  cam_data_i,

    // To line_write_read
    output wire        lcd_pclk_o,
    output wire        lcd_href_o,
    output wire        lcd_vsync_o,
    output wire [7:0]  lcd_data_o,

    // APB from the MSS FIC_0 master
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [31:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output reg  [31:0] prdata_o,
    // PSEL for apb3_if; its PREADY and PSLVERR stay wired to the master,
    // since both blocks are always ready and never fail.
    output wire        lcd_psel_o,

    input  wire        uart_rx_i,
    output wire        uart_tx_o,

    // Push buttons SW1-SW3, low when pressed
    input  wire        sw1_n_i,
    input  wire        sw2_n_i,
    input  wire        sw3_n_i,

    // Color constants for line_write_read (Image_Enhancement)
    output reg  [9:0]  red_const_o,
    output reg  [9:0]  green_const_o,
    output reg  [9:0]  blue_const_o,
    output wire [19:0] common_const_o
);
    assign common_const_o = 20'd0;

    localparam XW = 11, YW = 10;

    // Registers as written, and the copies used for the current frame.
    reg [6:0]    ctrl,       act_ctrl;
    reg [27:0]   digits,     act_digits;
    reg [1:0]    lives,      act_lives;
    reg [49:0]   bricks,     act_bricks;
    reg [9:0]    ball_x,     act_ball_x;
    reg [9:0]    ball_y,     act_ball_y;
    reg [9:0]    pad_x,      act_pad_x;
    reg [9:0]    pad_w,      act_pad_w;
    reg [XW-1:0] marker_x,   act_marker_x;
    reg [YW-1:0] marker_y,   act_marker_y;
    reg [XW-1:0] box_x0,     act_box_x0;
    reg [XW-1:0] box_x1,     act_box_x1;
    reg [YW-1:0] box_y0,     act_box_y0;
    reg [YW-1:0] box_y1,     act_box_y1;
    reg [7:0]    y_min, y_max, cb_min, cb_max, cr_min, cr_max;
    reg [7:0]    act_y_min, act_y_max, act_cb_min, act_cb_max, act_cr_min, act_cr_max;
    reg [15:0]   fg_color, digit_color;

    wire          frame_tick, pix_valid;
    wire [XW-1:0] pix_x, line_pixels;
    wire [YW-1:0] pix_y, frame_lines;
    wire [7:0]    pix_r, pix_g, pix_b;
    wire [XW-1:0] ovl_x;
    wire [YW-1:0] ovl_y;
    wire [1:0]    ovl_mode;
    wire [15:0]   ovl_color;

    cam_bus #(.XW(XW), .YW(YW)) u_cam (
        .clk(clk), .rst_n(rst_n),
        .pclk_i(cam_pclk_i), .href_i(cam_href_i),
        .vsync_i(cam_vsync_i), .data_i(cam_data_i),
        .pclk_o(lcd_pclk_o), .href_o(lcd_href_o),
        .vsync_o(lcd_vsync_o), .data_o(lcd_data_o),
        .ovl_x(ovl_x), .ovl_y(ovl_y), .ovl_mode(ovl_mode), .ovl_color(ovl_color),
        .frame_tick(frame_tick), .pix_valid(pix_valid),
        .pix_x(pix_x), .pix_y(pix_y),
        .pix_r(pix_r), .pix_g(pix_g), .pix_b(pix_b),
        .frame_lines(frame_lines), .line_pixels(line_pixels)
    );

    reg [31:0] frame_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_count <= 0;
            act_ctrl <= 0; act_digits <= 0; act_lives <= 0; act_bricks <= 0;
            act_ball_x <= 0; act_ball_y <= 0; act_pad_x <= 0; act_pad_w <= 0;
            act_marker_x <= 0; act_marker_y <= 0;
            act_box_x0 <= 0; act_box_x1 <= 0; act_box_y0 <= 0; act_box_y1 <= 0;
            act_y_min <= 0; act_y_max <= 0; act_cb_min <= 0; act_cb_max <= 0;
            act_cr_min <= 0; act_cr_max <= 0;
        end else if (frame_tick) begin
            frame_count <= frame_count + 1'b1;
            act_ctrl <= ctrl; act_digits <= digits; act_lives <= lives;
            act_bricks <= bricks;
            act_ball_x <= ball_x; act_ball_y <= ball_y;
            act_pad_x <= pad_x; act_pad_w <= pad_w;
            act_marker_x <= marker_x; act_marker_y <= marker_y;
            act_box_x0 <= box_x0; act_box_x1 <= box_x1;
            act_box_y0 <= box_y0; act_box_y1 <= box_y1;
            act_y_min <= y_min;   act_y_max <= y_max;
            act_cb_min <= cb_min; act_cb_max <= cb_max;
            act_cr_min <= cr_min; act_cr_max <= cr_max;
        end
    end

    wire [31:0] match_n, match_sx, match_sy, box_r, box_g, box_b, box_n;
    color_track #(.XW(XW), .YW(YW)) u_track (
        .clk(clk), .rst_n(rst_n),
        .frame_tick(frame_tick), .pix_valid(pix_valid),
        .pix_x(pix_x), .pix_y(pix_y),
        .pix_r(pix_r), .pix_g(pix_g), .pix_b(pix_b),
        .y_min(act_y_min), .y_max(act_y_max),
        .cb_min(act_cb_min), .cb_max(act_cb_max),
        .cr_min(act_cr_min), .cr_max(act_cr_max),
        .box_x0(act_box_x0), .box_x1(act_box_x1),
        .box_y0(act_box_y0), .box_y1(act_box_y1),
        .match_n(match_n), .match_sx(match_sx), .match_sy(match_sy),
        .box_r(box_r), .box_g(box_g), .box_b(box_b), .box_n(box_n)
    );

    game_overlay #(.XW(XW), .YW(YW)) u_ovl (
        .clk(clk), .rst_n(rst_n),
        .x(ovl_x), .y(ovl_y),
        .enable(act_ctrl[0]), .mirror(act_ctrl[1]), .dim(act_ctrl[2]),
        .show_ball(act_ctrl[3]), .show_paddle(act_ctrl[4]),
        .show_marker(act_ctrl[5]), .show_box(act_ctrl[6]),
        .digit_segs(act_digits), .lives(act_lives), .bricks(act_bricks),
        .ball_x(act_ball_x), .ball_y(act_ball_y),
        .pad_x(act_pad_x), .pad_w(act_pad_w),
        .marker_x(act_marker_x), .marker_y(act_marker_y),
        .box_x0(act_box_x0), .box_x1(act_box_x1),
        .box_y0(act_box_y0), .box_y1(act_box_y1),
        .fg_color(fg_color), .digit_color(digit_color),
        .mode(ovl_mode), .color(ovl_color)
    );

    // APB target
    wire       mine   = paddr_i[12];
    wire       sel    = psel_i & mine;
    wire       wr     = sel & penable_i & pwrite_i;
    wire       is_reg = paddr_i[11:7] == 5'd0;
    wire [4:0] reg_ix = paddr_i[6:2];
    assign lcd_psel_o = psel_i & ~mine;

    // A start bit: RX low for half a bit time, so glitches don't count.
    reg [1:0] rx_s;
    reg [7:0] rx_low;
    reg       host_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s <= 2'b11; rx_low <= 0; host_seen <= 1'b0;
        end else begin
            rx_s <= {rx_s[0], uart_rx_i};
            if (rx_s[1])
                rx_low <= 0;
            else if (rx_low != 8'hFF)
                rx_low <= rx_low + 1'b1;
            if (rx_low == 8'd217)       // 100 MHz / 230400 / 2
                host_seen <= 1'b1;
        end
    end

    // Push buttons, synchronized
    reg [2:0] sw_s1, sw_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_s1 <= 0; sw_s2 <= 0;
        end else begin
            sw_s1 <= ~{sw3_n_i, sw2_n_i, sw1_n_i};
            sw_s2 <= sw_s1;
        end
    end

    // Bytes from the PC. Reading UART_RX pops the byte it returns.
    wire [7:0] rx_head;
    wire       rx_empty, rx_overflow;
    uart_rx u_rx (
        .clk(clk), .rst_n(rst_n), .rx(uart_rx_i),
        .pop(sel && penable_i && !pwrite_i && is_reg && reg_ix == 5'h04),
        .head(rx_head), .empty(rx_empty), .overflow(rx_overflow)
    );

    wire uart_busy;
    uart_tx u_uart (
        .clk(clk), .rst_n(rst_n),
        .start(wr && is_reg && reg_ix == 5'h03), .data(pwdata_i[7:0]),
        .busy(uart_busy), .tx(uart_tx_o)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl <= 0; digits <= 0; lives <= 0; bricks <= 0;
            ball_x <= 0; ball_y <= 0; pad_x <= 0; pad_w <= 0;
            marker_x <= 0; marker_y <= 0;
            box_x0 <= 0; box_x1 <= 0; box_y0 <= 0; box_y1 <= 0;
            // Matches nothing until the firmware calibrates.
            y_min <= 8'hFF; y_max <= 0; cb_min <= 8'hFF; cb_max <= 0;
            cr_min <= 8'hFF; cr_max <= 0;
            fg_color <= 16'hFFFF; digit_color <= 16'hFFFF;
            red_const_o <= 10'h80; green_const_o <= 10'h80; blue_const_o <= 10'h80;
        end else if (wr && is_reg) begin
            case (reg_ix)
                5'h00: ctrl <= pwdata_i[6:0];
                5'h05: begin red_const_o <= pwdata_i[9:0]; green_const_o <= pwdata_i[19:10];
                            blue_const_o <= pwdata_i[29:20]; end
                5'h06: begin cb_min <= pwdata_i[7:0];   cb_max <= pwdata_i[15:8];
                            cr_min <= pwdata_i[23:16]; cr_max <= pwdata_i[31:24]; end
                5'h07: begin y_min <= pwdata_i[7:0]; y_max <= pwdata_i[15:8]; end
                5'h0B: begin box_x0 <= pwdata_i[XW-1:0]; box_x1 <= pwdata_i[16+XW-1:16]; end
                5'h0C: begin box_y0 <= pwdata_i[YW-1:0]; box_y1 <= pwdata_i[16+YW-1:16]; end
                5'h11: begin ball_x <= pwdata_i[9:0]; ball_y <= pwdata_i[25:16]; end
                5'h12: begin pad_x <= pwdata_i[9:0]; pad_w <= pwdata_i[25:16]; end
                5'h13: begin marker_x <= pwdata_i[XW-1:0]; marker_y <= pwdata_i[16+YW-1:16]; end
                5'h14: digits <= pwdata_i[27:0];
                5'h15: lives <= pwdata_i[1:0];
                5'h16: bricks[9:0]   <= pwdata_i[9:0];
                5'h17: bricks[19:10] <= pwdata_i[9:0];
                5'h18: bricks[29:20] <= pwdata_i[9:0];
                5'h19: bricks[39:30] <= pwdata_i[9:0];
                5'h1A: bricks[49:40] <= pwdata_i[9:0];
                5'h1B: begin fg_color <= pwdata_i[15:0]; digit_color <= pwdata_i[31:16]; end
                default: ;
            endcase
        end
    end

    always @(*) begin
        prdata_o = 32'h0;
        if (sel && is_reg) begin
            case (reg_ix)
                5'h00: prdata_o = {25'b0, ctrl};
                5'h01: prdata_o = frame_count;
                5'h02: prdata_o = {29'b0, sw_s2};
                5'h03: prdata_o = {30'b0, host_seen, uart_busy};
                5'h04: prdata_o = {22'b0, rx_overflow, !rx_empty, rx_head};
                5'h05: prdata_o = {2'b0, blue_const_o, green_const_o, red_const_o};
                5'h06: prdata_o = {cr_max, cr_min, cb_max, cb_min};
                5'h07: prdata_o = {16'b0, y_max, y_min};
                5'h08: prdata_o = match_n;
                5'h09: prdata_o = match_sx;
                5'h0A: prdata_o = match_sy;
                5'h0B: prdata_o = {5'b0, box_x1, 5'b0, box_x0};
                5'h0C: prdata_o = {6'b0, box_y1, 6'b0, box_y0};
                5'h0D: prdata_o = box_r;
                5'h0E: prdata_o = box_g;
                5'h0F: prdata_o = box_b;
                5'h10: prdata_o = box_n;
                5'h11: prdata_o = {6'b0, ball_y, 6'b0, ball_x};
                5'h12: prdata_o = {6'b0, pad_w, 6'b0, pad_x};
                5'h13: prdata_o = {6'b0, marker_y, 5'b0, marker_x};
                5'h14: prdata_o = {4'b0, digits};
                5'h15: prdata_o = {30'b0, lives};
                5'h16: prdata_o = {22'b0, bricks[9:0]};
                5'h17: prdata_o = {22'b0, bricks[19:10]};
                5'h18: prdata_o = {22'b0, bricks[29:20]};
                5'h19: prdata_o = {22'b0, bricks[39:30]};
                5'h1A: prdata_o = {22'b0, bricks[49:40]};
                5'h1B: prdata_o = {digit_color, fg_color};
                default: ;
            endcase
        end
    end

endmodule
