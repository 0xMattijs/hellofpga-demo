// Camera bus adapter, between the OV7725 pins and the reference design's
// line_write_read block, all on the 100 MHz system clock:
//   - Passes PCLK, HREF, VSYNC, and DATA on to the LCD path, three flops
//     later. Every signal gets the same delay, so the LCD path samples the
//     bus at the same phase as before, and VSYNC is now synchronized.
//   - Paints whatever game_overlay.v asks for into the LCD copy.
//   - Assembles RGB565 pixels from the untouched bytes for color_track.v.
//
// The camera sends RGB565, high byte first, 640 x 480. The LCD path keeps
// 3 in 4 pixels and 2 in 3 lines of it for the 480 x 320 panel.
module cam_bus #(
    parameter XW = 11,
    parameter YW = 10
) (
    input  wire          clk,
    input  wire          rst_n,

    // Camera pins
    input  wire          pclk_i,
    input  wire          href_i,
    input  wire          vsync_i,
    input  wire [7:0]    data_i,

    // To line_write_read
    output reg           pclk_o,
    output reg           href_o,
    output reg           vsync_o,
    output reg  [7:0]    data_o,

    // Overlay: the pixel under the bus, and what to do with it
    output wire [XW-1:0] ovl_x,
    output wire [YW-1:0] ovl_y,
    input  wire [1:0]    ovl_mode,    // game_overlay.v MODE_*
    input  wire [15:0]   ovl_color,

    // Pixel stream
    output reg           frame_tick,  // one cycle at each VSYNC rise
    output reg           pix_valid,
    output reg  [XW-1:0] pix_x,
    output reg  [YW-1:0] pix_y,
    output reg  [7:0]    pix_r,
    output reg  [7:0]    pix_g,
    output reg  [7:0]    pix_b,

    // Geometry of the last frame, for checking the camera setup
    output reg  [YW-1:0] frame_lines,
    output reg  [XW-1:0] line_pixels
);

    localparam [1:0] MODE_PASS = 2'd0, MODE_PAINT = 2'd1, MODE_DARKEN = 2'd2;

    // Synchronizers. Stage 2 is the first safe one to use; stages 3 and 4
    // find edges.
    reg [3:0] pclk_s, href_s, vsync_s;
    reg [7:0] data_s1, data_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pclk_s <= 0; href_s <= 0; vsync_s <= 0;
            data_s1 <= 0; data_s2 <= 0;
        end else begin
            pclk_s  <= {pclk_s[2:0],  pclk_i};
            href_s  <= {href_s[2:0],  href_i};
            vsync_s <= {vsync_s[2:0], vsync_i};
            data_s1 <= data_i;
            data_s2 <= data_s1;
        end
    end

    wire href  = href_s[1];
    wire vsync = vsync_s[1];
    // Byte strobe at the same phase WRITE_LSRAM uses: it sees PCLK two
    // flops in, then delays it twice more to find the rising edge, and
    // samples DATA two flops in.
    wire strobe     = pclk_s[2] & ~pclk_s[3] & href & ~vsync;
    wire href_fall  = ~href_s[1] & href_s[2];
    wire vsync_rise = vsync_s[1] & ~vsync_s[2];

    reg  [XW:0]   byte_cnt;    // bytes since HREF rose
    reg  [YW-1:0] line_cnt;    // lines since VSYNC
    reg  [7:0]    hi_byte;
    wire [XW-1:0] x = byte_cnt[XW:1];

    // game_overlay.v answers for (x, line_cnt) within 2 cycles; both hold from
    // one strobe to the next.
    assign ovl_x = x;
    assign ovl_y = line_cnt;

    // The decision for a byte, and which byte of the pixel it is, hold from
    // its strobe to the next one, so the LCD path sees it whenever it samples.
    reg  [1:0]  mode;
    reg  [15:0] color;
    reg         lo_byte;
    wire [1:0]  mode_now  = strobe ? ovl_mode  : mode;
    wire [15:0] color_now = strobe ? ovl_color : color;
    wire        lo_now    = strobe ? byte_cnt[0] : lo_byte;

    // Halves each RGB565 channel. The low byte needs G's top bit, which
    // came in the high byte.
    wire [7:0] dark = lo_now ? {hi_byte[0], data_s2[7:6], 1'b0, data_s2[4:1]}
                             : {1'b0, data_s2[7:4], 1'b0, data_s2[2:1]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pclk_o <= 0; href_o <= 0; vsync_o <= 0; data_o <= 0;
            mode <= MODE_PASS; color <= 0; lo_byte <= 0;
            byte_cnt <= 0; line_cnt <= 0; hi_byte <= 0;
            frame_tick <= 0; pix_valid <= 0;
            pix_x <= 0; pix_y <= 0; pix_r <= 0; pix_g <= 0; pix_b <= 0;
            frame_lines <= 0; line_pixels <= 0;
        end else begin
            // LCD copy: one more flop on every signal.
            pclk_o  <= pclk_s[1];
            href_o  <= href_s[1];
            vsync_o <= vsync_s[1];
            mode    <= mode_now;
            color   <= color_now;
            lo_byte <= lo_now;
            case (mode_now)
                MODE_PAINT:  data_o <= lo_now ? color_now[7:0] : color_now[15:8];
                MODE_DARKEN: data_o <= dark;
                default:     data_o <= data_s2;
            endcase

            frame_tick <= vsync_rise;
            pix_valid  <= 1'b0;

            if (!href || vsync)
                byte_cnt <= 0;
            else if (strobe) begin
                byte_cnt <= byte_cnt + 1'b1;
                if (!byte_cnt[0]) begin
                    hi_byte <= data_s2;
                end else begin
                    // {hi_byte, data_s2} is R5 G6 B5; pad each to 8 bits.
                    pix_valid <= 1'b1;
                    pix_x <= x;
                    pix_y <= line_cnt;
                    pix_r <= {hi_byte[7:3], 3'b0};
                    pix_g <= {hi_byte[2:0], data_s2[7:5], 2'b0};
                    pix_b <= {data_s2[4:0], 3'b0};
                end
            end

            if (vsync_rise) begin
                frame_lines <= line_cnt;
                line_cnt <= 0;
            end else if (href_fall) begin
                line_cnt <= line_cnt + 1'b1;
                line_pixels <= x;
            end
        end
    end

endmodule
