// Testbench for game_overlay: checks every pixel of a 640 x 480 frame
// against a model of the layout, without and with mirroring. Run with:
//   make sim
`timescale 1ns/1ps
module tb_game_overlay;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [10:0] x = 0;
    reg  [9:0]  y = 0;
    reg         enable = 1, mirror = 0, dim = 0;
    reg         show_ball = 1, show_paddle = 1, show_marker = 1, show_box = 1;
    reg  [27:0] digits;
    reg  [1:0]  lives;
    reg  [49:0] bricks;
    reg  [9:0]  ball_x, ball_y, pad_x, pad_w;
    reg  [10:0] marker_x, box_x0, box_x1;
    reg  [9:0]  marker_y, box_y0, box_y1;
    wire [1:0]  mode;
    wire [15:0] color;

    localparam [15:0] FG = 16'hFFE0, DIG = 16'hFE5A, MARKER = 16'h07FF;

    game_overlay dut (
        .clk(clk), .rst_n(rst_n), .x(x), .y(y),
        .enable(enable), .mirror(mirror), .dim(dim),
        .show_ball(show_ball), .show_paddle(show_paddle),
        .show_marker(show_marker), .show_box(show_box),
        .digit_segs(digits), .lives(lives), .bricks(bricks),
        .ball_x(ball_x), .ball_y(ball_y), .pad_x(pad_x), .pad_w(pad_w),
        .marker_x(marker_x), .marker_y(marker_y),
        .box_x0(box_x0), .box_x1(box_x1), .box_y0(box_y0), .box_y1(box_y1),
        .fg_color(FG), .digit_color(DIG),
        .mode(mode), .color(color)
    );

    // Seven-segment model: which segments (gfedcba) cover offset (dx, dy)
    // of a 28 x 40 digit with 8-pixel strokes.
    function [6:0] seg_at(input integer dx, input integer dy);
        reg t, b, m, u, l, lf, rt;
        begin
            t = dy < 8; b = dy >= 32; m = dy >= 16 && dy < 24;
            u = dy < 24; l = dy >= 16; lf = dx < 8; rt = dx >= 20;
            seg_at = {m, lf & u, lf & l, b, rt & l, rt & u, t};
        end
    endfunction

    function [15:0] row_color(input integer r);
        row_color = r == 0 ? 16'hF800 : r == 1 ? 16'hFA00 : r == 2 ? 16'hFB00 :
                    r == 3 ? 16'h07E0 : 16'h041F;
    endfunction

    // Expected {mode, color} for camera pixel (cx, cy).
    function [17:0] expect_at(input integer cx, input integer cy);
        integer sx, d, dx, dy, i, col, row;
        reg [6:0] segs;
        begin
            sx = mirror ? 639 - cx : cx;
            expect_at = {2'd0, 16'h0};
            segs = 0;
            d = (sx - 16) / 40; dx = (sx - 16) % 40; dy = cy - 8;
            if (sx >= 16 && d < 4 && dx < 28 && dy >= 0 && dy < 40)
                segs = seg_at(dx, dy) & (digits >> (7 * d));
            i = (sx - 540) / 32;
            col = sx / 64; row = (cy - 72) / 32;
            if (!enable)
                expect_at = {2'd0, 16'h0};
            else if (segs != 0)
                expect_at = {2'd1, DIG};
            else if (sx >= 540 && (sx - 540) % 32 < 20 && i < lives &&
                     cy >= 18 && cy < 36)
                expect_at = {2'd1, FG};
            else if (show_ball && sx >= ball_x && sx < ball_x + 16 &&
                     cy >= ball_y && cy < ball_y + 16)
                expect_at = {2'd1, FG};
            else if (show_paddle && sx >= pad_x && sx < pad_x + pad_w &&
                     cy >= 440 && cy < 456)
                expect_at = {2'd1, FG};
            else if (show_marker && cx + 8 >= marker_x && cx < marker_x + 8 &&
                     cy + 8 >= marker_y && cy < marker_y + 8)
                expect_at = {2'd1, MARKER};
            else if (show_box && cx >= box_x0 - 8 && cx < box_x1 + 8 &&
                     cy >= box_y0 - 6 && cy < box_y1 + 6 &&
                     !(cx >= box_x0 && cx < box_x1 && cy >= box_y0 && cy < box_y1))
                expect_at = {2'd1, DIG};
            else if (cy >= 72 && cy < 232 && sx % 64 >= 4 && sx % 64 < 60 &&
                     (cy - 72) % 32 >= 4 && (cy - 72) % 32 < 28 &&
                     bricks[10 * row + col])
                expect_at = {2'd1, row_color(row)};
            else if (cy < 56 || dim)
                expect_at = {2'd2, 16'h0};
        end
    endfunction

    integer errors = 0, painted, i;
    integer cx, cy;
    reg [17:0] want;

    task sweep(input [8*16-1:0] name);
        begin
            painted = 0;
            for (cy = 0; cy < 480; cy = cy + 1)
                for (cx = 0; cx < 640; cx = cx + 1) begin
                    @(negedge clk) begin x = cx; y = cy; end
                    @(negedge clk);
                    @(negedge clk);
                    want = expect_at(cx, cy);
                    if ({mode, color} !== want) begin
                        if (errors < 20)
                            $display("FAIL %0s: (%0d,%0d) mode %0d color %h, expected %0d %h",
                                     name, cx, cy, mode, color, want[17:16], want[15:0]);
                        errors = errors + 1;
                    end
                    if (mode == 1) painted = painted + 1;
                end
            $display("%0s: %0d pixels painted", name, painted);
        end
    endtask

    initial begin
        // 1, 2, 3, 4
        digits = {7'h66, 7'h4F, 7'h5B, 7'h06};
        lives = 2;
        // A checkerboard, with the corners set so the edges get checked.
        for (i = 0; i < 50; i = i + 1)
            bricks[i] = ((i / 10) + (i % 10)) % 2 == 0;
        bricks[9] = 1; bricks[40] = 1;
        ball_x = 300; ball_y = 250;
        pad_x = 200; pad_w = 112;
        marker_x = 100; marker_y = 300;
        box_x0 = 280; box_x1 = 360; box_y0 = 200; box_y1 = 280;
        #100 rst_n = 1;

        sweep("plain");
        mirror = 1; dim = 1;
        sweep("mirrored, dim");
        // Edges: the ball and paddle at the screen edges, the marker at the
        // top-left corner (no underflow), three lives.
        mirror = 0; dim = 0; lives = 3; show_box = 0;
        ball_x = 624; ball_y = 0; pad_x = 0; pad_w = 80;
        marker_x = 3; marker_y = 2;
        sweep("edges");
        enable = 0;
        sweep("off");

        if (errors == 0) $display("PASS");
        else $display("%0d errors", errors);
        $finish;
    end
endmodule
