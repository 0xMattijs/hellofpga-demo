// Color tracker: finds the pixels whose color falls inside a YCbCr box and
// sums their count and coordinates over a frame, so the Cortex-M3 can take
// the centroid. It also sums the colors inside a calibration box, so the
// firmware can fit the YCbCr box to an object held there.
//
// YCbCr is full-range BT.601 (JPEG):
//   Y  =       ( 77 R + 150 G +  29 B) / 256
//   Cb = 128 + (-43 R -  85 G + 128 B) / 256
//   Cr = 128 + (128 R - 107 G -  21 B) / 256
// The limits are inclusive.
//
// The sums of a frame appear at its closing frame_tick (VSYNC rise) and
// hold for the whole next frame. VSYNC rises lines after the last pixel,
// so no pixel is in the pipeline then. The limits and the box must not
// change during a frame: game_top.v copies them at frame_tick.
module color_track #(
    parameter XW = 11,
    parameter YW = 10
) (
    input  wire          clk,
    input  wire          rst_n,

    input  wire          frame_tick,
    input  wire          pix_valid,
    input  wire [XW-1:0] pix_x,
    input  wire [YW-1:0] pix_y,
    input  wire [7:0]    pix_r,
    input  wire [7:0]    pix_g,
    input  wire [7:0]    pix_b,

    input  wire [7:0]    y_min,
    input  wire [7:0]    y_max,
    input  wire [7:0]    cb_min,
    input  wire [7:0]    cb_max,
    input  wire [7:0]    cr_min,
    input  wire [7:0]    cr_max,

    // Calibration box: x0 <= x < x1, y0 <= y < y1
    input  wire [XW-1:0] box_x0,
    input  wire [XW-1:0] box_x1,
    input  wire [YW-1:0] box_y0,
    input  wire [YW-1:0] box_y1,

    // Last complete frame
    output reg  [31:0]   match_n,     // pixels inside the YCbCr box
    output reg  [31:0]   match_sx,    // sum of their x
    output reg  [31:0]   match_sy,    // sum of their y
    output reg  [31:0]   box_r,       // color sums inside the calibration box
    output reg  [31:0]   box_g,
    output reg  [31:0]   box_b,
    output reg  [31:0]   box_n
);

    // Each sum is offset so it can't go negative: 0 .. 65535.
    wire [17:0] r = pix_r, g = pix_g, b = pix_b;
    wire [17:0] y_sum  =          77 * r + 150 * g +  29 * b;
    wire [17:0] cb_sum = 32768 -  43 * r -  85 * g + 128 * b;
    wire [17:0] cr_sum = 32768 + 128 * r - 107 * g -  21 * b;

    // Stage 1: color conversion and the box test.
    reg          s1_valid, s1_in_box;
    reg [XW-1:0] s1_x;
    reg [YW-1:0] s1_y;
    reg [7:0]    s1_r, s1_g, s1_b, s1_luma, s1_cb, s1_cr;

    // Stage 2: the match test.
    reg          s2_valid, s2_match, s2_in_box;
    reg [XW-1:0] s2_x;
    reg [YW-1:0] s2_y;
    reg [7:0]    s2_r, s2_g, s2_b;

    // Running sums of the frame in progress
    reg [31:0] acc_n, acc_sx, acc_sy, acc_r, acc_g, acc_b, acc_bn;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 0; s1_in_box <= 0; s1_x <= 0; s1_y <= 0;
            s1_r <= 0; s1_g <= 0; s1_b <= 0; s1_luma <= 0; s1_cb <= 0; s1_cr <= 0;
            s2_valid <= 0; s2_match <= 0; s2_in_box <= 0; s2_x <= 0; s2_y <= 0;
            s2_r <= 0; s2_g <= 0; s2_b <= 0;
            acc_n <= 0; acc_sx <= 0; acc_sy <= 0;
            acc_r <= 0; acc_g <= 0; acc_b <= 0; acc_bn <= 0;
            match_n <= 0; match_sx <= 0; match_sy <= 0;
            box_r <= 0; box_g <= 0; box_b <= 0; box_n <= 0;
        end else begin
            s1_valid  <= pix_valid;
            s1_x <= pix_x; s1_y <= pix_y;
            s1_r <= pix_r; s1_g <= pix_g; s1_b <= pix_b;
            s1_luma   <= y_sum[15:8];
            s1_cb     <= cb_sum[15:8];
            s1_cr     <= cr_sum[15:8];
            s1_in_box <= pix_x >= box_x0 && pix_x < box_x1 &&
                         pix_y >= box_y0 && pix_y < box_y1;

            s2_valid  <= s1_valid;
            s2_x <= s1_x; s2_y <= s1_y;
            s2_r <= s1_r; s2_g <= s1_g; s2_b <= s1_b;
            s2_in_box <= s1_in_box;
            s2_match  <= s1_luma >= y_min  && s1_luma <= y_max &&
                         s1_cb   >= cb_min && s1_cb   <= cb_max &&
                         s1_cr   >= cr_min && s1_cr   <= cr_max;

            if (frame_tick) begin
                match_n <= acc_n; match_sx <= acc_sx; match_sy <= acc_sy;
                box_r <= acc_r; box_g <= acc_g; box_b <= acc_b; box_n <= acc_bn;
                acc_n <= 0; acc_sx <= 0; acc_sy <= 0;
                acc_r <= 0; acc_g <= 0; acc_b <= 0; acc_bn <= 0;
            end else if (s2_valid) begin
                if (s2_match) begin
                    acc_n  <= acc_n + 1'b1;
                    acc_sx <= acc_sx + s2_x;
                    acc_sy <= acc_sy + s2_y;
                end
                if (s2_in_box) begin
                    acc_r  <= acc_r + s2_r;
                    acc_g  <= acc_g + s2_g;
                    acc_b  <= acc_b + s2_b;
                    acc_bn <= acc_bn + 1'b1;
                end
            end
        end
    end

endmodule
