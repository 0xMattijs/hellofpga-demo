// Game overlay: draws the breakout game into the camera stream on its way
// to the LCD, so the player sees themselves behind the bricks.
//
// Works in camera coordinates (640 x 480). The LCD keeps 3 in 4 pixels and
// 2 in 3 lines, so every shape is at least 8 pixels and 6 lines thick.
//
// The game layout is in screen coordinates: with mirror set, x runs right
// to left, for a screen that shows the camera image mirrored, so the score
// reads the right way round and the paddle follows the player's hand. The
// tracker marker and the calibration box are in camera coordinates, since
// they mark places in the image.
//
//   HUD       y 0..55           video darkened
//   Score     4 seven-segment digits, 28 x 40, from x 16, y 8
//   Lives     up to 3 squares, 20 x 18, from x 540, y 18, 32 apart
//   Bricks    10 columns x 5 rows from y 72; each 56 x 24 in a 64 x 32 cell
//   Paddle    y 440..455, x pad_x .. pad_x + pad_w - 1
//   Ball      16 x 16, top left at (ball_x, ball_y)
//   Marker    16 x 16 around (marker_x, marker_y), camera coordinates
//   Box       8-pixel, 6-line outline just outside the calibration box,
//             camera coordinates
//
// With dim set, the video behind the game is darkened too.
//
// The result for pixel (x, y) is ready 2 cycles after x and y change.
// cam_bus changes them at a byte strobe and samples the result at the next
// one, which comes at least 4 cycles later.
module game_overlay #(
    parameter XW = 11,
    parameter YW = 10
) (
    input  wire          clk,
    input  wire          rst_n,

    input  wire [XW-1:0] x,
    input  wire [YW-1:0] y,

    input  wire          enable,
    input  wire          mirror,
    input  wire          dim,
    input  wire          show_ball,
    input  wire          show_paddle,
    input  wire          show_marker,
    input  wire          show_box,

    input  wire [27:0]   digit_segs,   // 4 x gfedcba, digit 0 leftmost
    input  wire [1:0]    lives,        // squares to show, 0..3
    input  wire [49:0]   bricks,       // bit 10 * row + col, row 0 at the top,
                                       // col 0 at the left of the screen
    input  wire [9:0]    ball_x,
    input  wire [9:0]    ball_y,
    input  wire [9:0]    pad_x,
    input  wire [9:0]    pad_w,
    input  wire [XW-1:0] marker_x,
    input  wire [YW-1:0] marker_y,
    input  wire [XW-1:0] box_x0,
    input  wire [XW-1:0] box_x1,
    input  wire [YW-1:0] box_y0,
    input  wire [YW-1:0] box_y1,
    input  wire [15:0]   fg_color,     // ball, paddle, lives
    input  wire [15:0]   digit_color,  // score, calibration box

    output reg  [1:0]    mode,         // MODE_*
    output reg  [15:0]   color         // for MODE_PAINT
);

    localparam [1:0] MODE_PASS = 2'd0, MODE_PAINT = 2'd1, MODE_DARKEN = 2'd2;

    localparam [15:0] MARKER_COLOR = 16'h07FF;   // cyan

    localparam HUD_H = 56;
    localparam DIG_X0 = 16, DIG_Y0 = 8, DIG_W = 28, DIG_H = 40,
               DIG_PITCH = 40, SEG_T = 8;
    localparam LIFE_X0 = 540, LIFE_Y0 = 18, LIFE_W = 20, LIFE_H = 18, LIFE_PITCH = 32;
    localparam BRICK_Y0 = 72, BRICK_ROWS = 5;
    localparam PAD_Y0 = 440, PAD_H = 16;
    localparam BALL = 16, MARK = 8, BOX_T = 8, BOX_TL = 6;
    localparam LAST_X = 639;

    // Stage 1: the mirrored x and the range checks.
    wire [XW-1:0] ox = mirror ? LAST_X - x : x;

    // Digit cell under ox, or 7 if none, and the offset into it.
    reg [2:0]    digit_c;
    reg [XW-1:0] dx_c;
    always @(*) begin
        digit_c = 3'd7;
        dx_c = 0;
        if (ox >= DIG_X0 && ox < DIG_X0 + DIG_W) begin
            digit_c = 3'd0; dx_c = ox - DIG_X0;
        end else if (ox >= DIG_X0 + DIG_PITCH && ox < DIG_X0 + DIG_PITCH + DIG_W) begin
            digit_c = 3'd1; dx_c = ox - (DIG_X0 + DIG_PITCH);
        end else if (ox >= DIG_X0 + 2 * DIG_PITCH && ox < DIG_X0 + 2 * DIG_PITCH + DIG_W) begin
            digit_c = 3'd2; dx_c = ox - (DIG_X0 + 2 * DIG_PITCH);
        end else if (ox >= DIG_X0 + 3 * DIG_PITCH && ox < DIG_X0 + 3 * DIG_PITCH + DIG_W) begin
            digit_c = 3'd3; dx_c = ox - (DIG_X0 + 3 * DIG_PITCH);
        end
        if (y < DIG_Y0 || y >= DIG_Y0 + DIG_H)
            digit_c = 3'd7;
    end

    // Life square under ox, if any: 0..2, or 3 for none.
    reg [1:0] life_c;
    always @(*) begin
        life_c = 2'd3;
        if (y >= LIFE_Y0 && y < LIFE_Y0 + LIFE_H) begin
            if (ox >= LIFE_X0 && ox < LIFE_X0 + LIFE_W)
                life_c = 2'd0;
            else if (ox >= LIFE_X0 + LIFE_PITCH && ox < LIFE_X0 + LIFE_PITCH + LIFE_W)
                life_c = 2'd1;
            else if (ox >= LIFE_X0 + 2 * LIFE_PITCH && ox < LIFE_X0 + 2 * LIFE_PITCH + LIFE_W)
                life_c = 2'd2;
        end
    end

    // Brick cell: 64 x 32, the brick inset by 4 on each side.
    wire [YW-1:0] by_full  = y - BRICK_Y0;
    wire          in_brick_rows = y >= BRICK_Y0 && y < BRICK_Y0 + 32 * BRICK_ROWS;
    wire          in_brick_cell = ox <= LAST_X && ox[5:0] >= 4 && ox[5:0] < 60 &&
                                  by_full[4:0] >= 4 && by_full[4:0] < 28;

    reg          in_hud, in_ball, in_paddle, in_marker, on_box, in_brick;
    reg [2:0]    digit, brick_row;
    reg [3:0]    brick_col;
    reg [1:0]    life;
    reg [XW-1:0] dx;
    reg [YW-1:0] dy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_hud <= 0; in_ball <= 0; in_paddle <= 0; in_marker <= 0;
            on_box <= 0; in_brick <= 0; digit <= 3'd7; life <= 2'd3;
            brick_row <= 0; brick_col <= 0; dx <= 0; dy <= 0;
        end else begin
            in_hud    <= y < HUD_H;
            in_ball   <= ox >= ball_x && ox < ball_x + BALL &&
                         y >= ball_y && y < ball_y + BALL;
            in_paddle <= ox >= pad_x && ox < pad_x + pad_w &&
                         y >= PAD_Y0 && y < PAD_Y0 + PAD_H;
            // a + MARK >= b is a >= b - MARK without underflow.
            in_marker <= x + MARK >= marker_x && x < marker_x + MARK &&
                         y + MARK >= marker_y && y < marker_y + MARK;
            on_box    <= (x + BOX_T >= box_x0 && x < box_x1 + BOX_T &&
                          y + BOX_TL >= box_y0 && y < box_y1 + BOX_TL) &&
                         !(x >= box_x0 && x < box_x1 && y >= box_y0 && y < box_y1);
            in_brick  <= in_brick_rows && in_brick_cell;
            brick_row <= by_full[7:5];
            brick_col <= ox[9:6];
            digit     <= digit_c;
            life      <= life_c;
            dx        <= dx_c;
            dy        <= y - DIG_Y0;
        end
    end

    // Stage 2: which segment covers (dx, dy), the brick bit, then the
    // final choice.
    wire top   = dy < SEG_T;
    wire bot   = dy >= DIG_H - SEG_T;
    wire mid   = dy >= DIG_H / 2 - SEG_T / 2 && dy < DIG_H / 2 + SEG_T / 2;
    wire upper = dy < DIG_H / 2 + SEG_T / 2;
    wire lower = dy >= DIG_H / 2 - SEG_T / 2;
    wire left  = dx < SEG_T;
    wire right = dx >= DIG_W - SEG_T;
    wire [6:0] on_seg = {mid, left & upper, left & lower, bot,
                         right & lower, right & upper, top};   // g..a
    wire [6:0] segs = digit == 3'd0 ? digit_segs[6:0] :
                      digit == 3'd1 ? digit_segs[13:7] :
                      digit == 3'd2 ? digit_segs[20:14] :
                      digit == 3'd3 ? digit_segs[27:21] : 7'd0;
    wire lit      = |(on_seg & segs);
    wire life_lit = life != 2'd3 && life < lives;

    wire [9:0] row_bits = brick_row == 3'd0 ? bricks[9:0]   :
                          brick_row == 3'd1 ? bricks[19:10] :
                          brick_row == 3'd2 ? bricks[29:20] :
                          brick_row == 3'd3 ? bricks[39:30] : bricks[49:40];
    wire brick_lit = in_brick && brick_col < 10 && row_bits[brick_col];

    reg [15:0] brick_color;
    always @(*) begin
        case (brick_row)
            3'd0:    brick_color = 16'hF800;   // red
            3'd1:    brick_color = 16'hFA00;   // orange on this panel
            3'd2:    brick_color = 16'hFB00;   // yellow on this panel
            3'd3:    brick_color = 16'h07E0;   // green
            default: brick_color = 16'h041F;   // blue
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= MODE_PASS; color <= 0;
        end else begin
            mode <= MODE_PASS;
            color <= 0;
            if (enable) begin
                if (lit) begin
                    mode <= MODE_PAINT; color <= digit_color;
                end else if (life_lit) begin
                    mode <= MODE_PAINT; color <= fg_color;
                end else if (show_ball && in_ball) begin
                    mode <= MODE_PAINT; color <= fg_color;
                end else if (show_paddle && in_paddle) begin
                    mode <= MODE_PAINT; color <= fg_color;
                end else if (show_marker && in_marker) begin
                    mode <= MODE_PAINT; color <= MARKER_COLOR;
                end else if (show_box && on_box) begin
                    mode <= MODE_PAINT; color <= digit_color;
                end else if (brick_lit) begin
                    mode <= MODE_PAINT; color <= brick_color;
                end else if (in_hud || dim) begin
                    mode <= MODE_DARKEN;
                end
            end
        end
    end

endmodule
