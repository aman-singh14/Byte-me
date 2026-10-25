// =============================================================================
// hdmi_bounce.v  —  Tang Nano 20K HDMI animation (640x480 @ 60 Hz, DVI over HDMI)
//
// What you'll see: a smooth, slowly scrolling color-wave background with a
// square bouncing around the screen. The square changes color every time it
// hits a wall.
//
// Onboard LEDs:  LED0 = PLL locked (should be ON)
//                LED1-5 = frame counter (blinking = video is running)
//
// Clocks:  27 MHz crystal -> rPLL -> 126 MHz serial clock
//          126 MHz / 5 (CLKDIV) -> 25.2 MHz pixel clock
//          OSER10 shifts out 10 bits per pixel using both clock edges (DDR)
// =============================================================================
`default_nettype none

module top (
    input  wire       clk,          // 27 MHz crystal (pin 4)
    output wire       tmds_clk_p,   // HDMI clock pair
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,     // HDMI data pairs: 0 = blue, 1 = green, 2 = red
    output wire [2:0] tmds_d_n,
    output wire [5:0] led           // onboard LEDs (active low)
);

    // -------------------------------------------------------------------------
    // Clocks
    // -------------------------------------------------------------------------
    wire clk_ser;   // 126 MHz  = 27 * 14 / 3
    wire clk_pix;   // 25.2 MHz = 126 / 5
    wire pll_lock;

    rPLL #(
        .FCLKIN        ("27"),
        .DYN_IDIV_SEL  ("false"),
        .IDIV_SEL      (2),          // divide input by 3
        .DYN_FBDIV_SEL ("false"),
        .FBDIV_SEL     (13),         // multiply by 14  -> 126 MHz
        .DYN_ODIV_SEL  ("false"),
        .ODIV_SEL      (8),          // VCO = 126 * 8 = 1008 MHz
        .PSDA_SEL      ("0000"),
        .DYN_DA_EN     ("true"),
        .DUTYDA_SEL    ("1000"),
        .CLKOUT_FT_DIR (1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP (0),
        .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL     ("internal"),
        .CLKOUT_BYPASS ("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL  (2),
        .CLKOUTD_SRC   ("CLKOUT"),
        .CLKOUTD3_SRC  ("CLKOUT"),
        .DEVICE        ("GW2AR-18C")
    ) u_pll (
        .CLKOUT  (clk_ser),
        .LOCK    (pll_lock),
        .CLKOUTP (),
        .CLKOUTD (),
        .CLKOUTD3(),
        .RESET   (1'b0),
        .RESET_P (1'b0),
        .CLKIN   (clk),
        .CLKFB   (1'b0),
        .FBDSEL  (6'b0),
        .IDSEL   (6'b0),
        .ODSEL   (6'b0),
        .PSDA    (4'b0),
        .DUTYDA  (4'b0),
        .FDLY    (4'b0)
    );

    CLKDIV #(
        .DIV_MODE("5"),
        .GSREN   ("false")
    ) u_clkdiv (
        .CLKOUT(clk_pix),
        .HCLKIN(clk_ser),
        .RESETN(pll_lock),
        .CALIB (1'b0)
    );

    // -------------------------------------------------------------------------
    // 640x480 @ 60 Hz timing (standard VGA timing)
    // -------------------------------------------------------------------------
    localparam H_ACTIVE = 640, H_FP = 16, H_SYNC = 96, H_BP = 48;
    localparam V_ACTIVE = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33;
    localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 800
    localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525

    reg [9:0] hcnt = 10'd0;
    reg [9:0] vcnt = 10'd0;

    always @(posedge clk_pix) begin
        if (hcnt == H_TOTAL - 1) begin
            hcnt <= 10'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 10'd1;
        end else begin
            hcnt <= hcnt + 10'd1;
        end
    end

    wire de    = (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);          // visible area
    wire hsync = ~((hcnt >= H_ACTIVE + H_FP) && (hcnt < H_ACTIVE + H_FP + H_SYNC)); // active low
    wire vsync = ~((vcnt >= V_ACTIVE + V_FP) && (vcnt < V_ACTIVE + V_FP + V_SYNC)); // active low

    // -------------------------------------------------------------------------
    // Animation state (updated once per frame, during vertical blanking)
    // -------------------------------------------------------------------------
    localparam BOX    = 80;   // square size in pixels
    localparam SPEED  = 3;    // pixels per frame
    localparam BORDER = 4;    // white outline thickness

    reg [9:0] bx = 10'd100;   // square top-left corner
    reg [9:0] by = 10'd60;
    reg       dx = 1'b1;      // 1 = moving right
    reg       dy = 1'b1;      // 1 = moving down
    reg [2:0] hue   = 3'd0;   // square color index
    reg [7:0] frame = 8'd0;   // frame counter, drives the background scroll

    wire frame_tick = (hcnt == 10'd0) && (vcnt == V_ACTIVE);       // first blank line
    wire hit_x = dx ? (bx + BOX + SPEED >= H_ACTIVE) : (bx < SPEED);
    wire hit_y = dy ? (by + BOX + SPEED >= V_ACTIVE) : (by < SPEED);

    always @(posedge clk_pix) begin
        if (frame_tick) begin
            frame <= frame + 8'd1;

            if (hit_x) dx <= ~dx;
            else       bx <= dx ? bx + SPEED : bx - SPEED;

            if (hit_y) dy <= ~dy;
            else       by <= dy ? by + SPEED : by - SPEED;

            if (hit_x || hit_y) hue <= hue + 3'd1;
        end
    end

    // -------------------------------------------------------------------------
    // Pixel color
    // -------------------------------------------------------------------------
    // Triangle wave: 0 -> 254 -> 0, so the background has no hard seams
    function [7:0] tri8(input [7:0] x);
        tri8 = x[7] ? ~{x[6:0], 1'b0} : {x[6:0], 1'b0};
    endfunction

    wire [7:0] wave_r = tri8(hcnt[7:0] + frame);
    wire [7:0] wave_g = tri8(vcnt[7:0] + {frame[6:0], 1'b0});
    wire [7:0] wave_b = tri8(hcnt[8:1] + vcnt[8:1] - frame);

    // Background at half brightness so the square pops
    wire [7:0] bg_r = {1'b0, wave_r[7:1]};
    wire [7:0] bg_g = {1'b0, wave_g[7:1]};
    wire [7:0] bg_b = {1'b0, wave_b[7:1]};

    wire in_box   = (hcnt >= bx) && (hcnt < bx + BOX) &&
                    (vcnt >= by) && (vcnt < by + BOX);
    wire in_inner = (hcnt >= bx + BORDER) && (hcnt < bx + BOX - BORDER) &&
                    (vcnt >= by + BORDER) && (vcnt < by + BOX - BORDER);

    reg [23:0] box_rgb;
    always @* begin
        case (hue)
            3'd0: box_rgb = 24'hFF2D2D;  // red
            3'd1: box_rgb = 24'hFF9A1F;  // orange
            3'd2: box_rgb = 24'hFFE81F;  // yellow
            3'd3: box_rgb = 24'h2DFF5A;  // green
            3'd4: box_rgb = 24'h1FE8FF;  // cyan
            3'd5: box_rgb = 24'h3D5BFF;  // blue
            3'd6: box_rgb = 24'hB34DFF;  // purple
            default: box_rgb = 24'hFF4DC4; // pink
        endcase
    end

    reg [7:0] r, g, b;
    always @* begin
        if (in_inner)    {r, g, b} = box_rgb;
        else if (in_box) {r, g, b} = 24'hFFFFFF;   // outline
        else             {r, g, b} = {bg_r, bg_g, bg_b};
    end

    // -------------------------------------------------------------------------
    // TMDS encoding (8 bits -> 10 bits per color channel)
    // Blue channel carries hsync/vsync during blanking.
    // -------------------------------------------------------------------------
    wire [9:0] tmds_b, tmds_g, tmds_r;

    tmds_encoder enc_b (.clk(clk_pix), .de(de), .d(b), .c({vsync, hsync}), .q(tmds_b));
    tmds_encoder enc_g (.clk(clk_pix), .de(de), .d(g), .c(2'b00),          .q(tmds_g));
    tmds_encoder enc_r (.clk(clk_pix), .de(de), .d(r), .c(2'b00),          .q(tmds_r));

    // -------------------------------------------------------------------------
    // Serialize (10:1) and drive the differential HDMI pins
    // Channel 3 sends the pixel clock as 5 zeros then 5 ones.
    // -------------------------------------------------------------------------
    wire [39:0] words = {10'b1111100000, tmds_r, tmds_g, tmds_b};
    wire [3:0]  ser;

    genvar ch;
    generate
        for (ch = 0; ch < 4; ch = ch + 1) begin : g_ser
            OSER10 #(
                .GSREN("false"),
                .LSREN("true")
            ) u_oser (
                .Q    (ser[ch]),
                .D0   (words[ch*10 + 0]),
                .D1   (words[ch*10 + 1]),
                .D2   (words[ch*10 + 2]),
                .D3   (words[ch*10 + 3]),
                .D4   (words[ch*10 + 4]),
                .D5   (words[ch*10 + 5]),
                .D6   (words[ch*10 + 6]),
                .D7   (words[ch*10 + 7]),
                .D8   (words[ch*10 + 8]),
                .D9   (words[ch*10 + 9]),
                .PCLK (clk_pix),
                .FCLK (clk_ser),
                .RESET(~pll_lock)
            );
        end
    endgenerate

    TLVDS_OBUF u_buf_d0  (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF u_buf_d1  (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF u_buf_d2  (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    TLVDS_OBUF u_buf_clk (.I(ser[3]), .O(tmds_clk_p),  .OB(tmds_clk_n));

    // -------------------------------------------------------------------------
    // LEDs (active low): LED0 = PLL locked, LED1-5 = frame counter
    // -------------------------------------------------------------------------
    assign led = ~{frame[7:3], pll_lock};

endmodule


// =============================================================================
// TMDS encoder (DVI 1.0 spec): transition-minimized, DC-balanced 8b/10b
// =============================================================================
module tmds_encoder (
    input  wire       clk,
    input  wire       de,         // 1 = pixel data, 0 = blanking (send control code)
    input  wire [7:0] d,          // 8-bit color value
    input  wire [1:0] c,          // control bits {c1, c0}
    output reg  [9:0] q = 10'd0   // 10-bit symbol, bit 0 is sent first
);
    function [3:0] ones8(input [7:0] v);
        integer k;
        begin
            ones8 = 4'd0;
            for (k = 0; k < 8; k = k + 1) ones8 = ones8 + v[k];
        end
    endfunction

    // Stage 1: XOR or XNOR chain, whichever gives fewer transitions
    wire [3:0] n1d      = ones8(d);
    wire       use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && d[0] == 1'b0);

    function [7:0] tm_chain(input [7:0] v, input xn);
        integer k;
        begin
            tm_chain[0] = v[0];
            for (k = 1; k < 8; k = k + 1)
                tm_chain[k] = xn ? ~(tm_chain[k-1] ^ v[k]) : (tm_chain[k-1] ^ v[k]);
        end
    endfunction

    wire [8:0] qm = {~use_xnor, tm_chain(d, use_xnor)};

    // Stage 2: keep the running count of 1s vs 0s near zero (DC balance)
    wire [3:0]        n1q  = ones8(qm[7:0]);
    wire signed [5:0] diff = $signed({1'b0, n1q, 1'b0}) - 6'sd8;   // (#1s - #0s) in qm[7:0]
    wire signed [5:0] two_qm8  = qm[8]  ? 6'sd2 : 6'sd0;
    wire signed [5:0] two_nqm8 = !qm[8] ? 6'sd2 : 6'sd0;
    reg  signed [5:0] cnt = 6'sd0;

    always @(posedge clk) begin
        if (!de) begin
            cnt <= 6'sd0;
            case (c)
                2'b00:   q <= 10'b1101010100;
                2'b01:   q <= 10'b0010101011;
                2'b10:   q <= 10'b0101010100;
                default: q <= 10'b1010101011;
            endcase
        end else if (cnt == 6'sd0 || diff == 6'sd0) begin
            q   <= {~qm[8], qm[8], (qm[8] ? qm[7:0] : ~qm[7:0])};
            cnt <= qm[8] ? (cnt + diff) : (cnt - diff);
        end else if ((cnt > 6'sd0 && diff > 6'sd0) || (cnt < 6'sd0 && diff < 6'sd0)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + two_qm8 - diff;
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - two_nqm8 + diff;
        end
    end
endmodule

`default_nettype wire
