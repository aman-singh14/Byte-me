// =============================================================================
// omni_rear.v  -  Omni Glasses rear collision detector on the Tang Nano 20K
//
//   OV2640 -> ESP32-CAM (80x60 grayscale) --SPI--> this FPGA --SPI status--> ESP32-CAM
//                                                    ^
//                                     MPU6050 gyro --I2C
//
// Every frame:
//   1. head turning?  |gyro| > TURN_DPS deg/s (held TURN_HOLD_MS)  -> check nothing
//   2. LGMD layers (P, I, S) + box around the moving pixels
//   3. TRACKING  = a moving object is in view (box exists and K > K_MIN)  -> ESP streams video
//   4. COLLISION = the box keeps growing around its own centre             -> ESP sounds the horn
//   Same integer steps as lgmd_tuner.py (LiveDetector); settings from tuned_params.json.
//
// SPI (ESP32 = master, mode 0, MSB first, CS active low):
//   frame  : 0xA1, seq_lo, seq_hi, 4800 pixels (row-major), crc_lo, crc_hi      (4805 bytes, <= 4 MHz)
//            crc = CRC-16/CCITT-FALSE (0x1021, init 0xFFFF) over seq + pixels
//   status : 0xB2 then 15 more bytes, <= 1 MHz. MISO returns the 16-byte status of
//            the last processed frame during the first 16 bytes of ANY transaction:
//            b0  0x5A
//            b1  flags: 0 tracking  1 COLLISION  2 head turning  3 IMU ok
//                       4 last frame CRC ok  5 growing  6 box present
//            b2-3   seq of the processed frame (LE)
//            b4-5   gyro rate |deg/s * 65.5| used for the gate (LE)
//            b6-7   smoothed box size Es (LE)      b8-9  box size E (LE)
//            b10-12 K (LE)                         b13   growing frames in WINDOW
//            b14    bad-frame counter              b15   XOR of b0..b14
//   MISO is high-Z while CS is high (ESP32-CAM GPIO2 is a boot strap pin).
//
// LEDs (active low): LED0 heartbeat  LED1 frame received  LED2 COLLISION
//                    LED3 tracking   LED4 head turning     LED5 IMU ok
// =============================================================================
`default_nettype none

module top #(
    parameter integer CLK_HZ            = 27_000_000,
    // ---- detector: tuned_params.json
    parameter integer P_MIN             = 20,
    parameter integer W_SHIFT           = 3,
    parameter integer S_MIN             = 24,
    parameter integer K_MIN             = 4800,
    parameter integer F_MAX             = 24000,
    parameter integer SMOOTH            = 1,
    parameter integer GROW_FRAMES       = 4,     // 1..15
    parameter integer GROW_PCT          = 15,
    parameter integer EXPAND            = 1,
    parameter integer IN_A_ROW          = 1,
    parameter integer WINDOW            = 2,     // 1..16, >= IN_A_ROW
    // ---- head-turn gate (MPU6050 at +-500 deg/s = 65.5 LSB per deg/s)
    parameter integer TURN_DPS          = 90,
    parameter integer GYRO_AXIS         = 3,     // 0 = X, 1 = Y, 2 = Z, 3 = fastest of the three
    parameter integer TURN_HOLD_MS      = 300,
    // ---- tracking flag stays on this many frames after the object is gone
    parameter integer TRACK_HOLD_FRAMES = 30
)(
    input  wire       clk,          // 27 MHz          pin 4
    input  wire       spi_sck,      // ESP32 GPIO14
    input  wire       spi_mosi,     // ESP32 GPIO13
    input  wire       spi_cs_n,     // ESP32 GPIO15
    output wire       spi_miso,     // ESP32 GPIO2 (high-Z when CS high)
    inout  wire       i2c_scl,      // MPU6050 SCL
    inout  wire       i2c_sda,      // MPU6050 SDA
    output wire [5:0] led
);
    // ------------------------------------------------------------------ reset
    reg [7:0] por = 8'd0;
    reg       rst = 1'b1;
    always @(posedge clk) begin
        if (por != 8'hFF) por <= por + 8'd1;
        rst <= (por != 8'hFF);
    end

    // ------------------------------------------------------------------ IMU + head-turn gate
    wire signed [15:0] gx, gy, gz;
    wire               imu_ok, imu_sample;
    wire               scl_low, sda_low;
    wire               sda_in = i2c_sda;
    assign i2c_scl = scl_low ? 1'b0 : 1'bz;
    assign i2c_sda = sda_low ? 1'b0 : 1'bz;

    mpu6050_gyro #(.CLK_HZ(CLK_HZ)) u_imu (
        .clk(clk), .rst(rst), .sda_in(sda_in), .scl_low(scl_low), .sda_low(sda_low),
        .gx(gx), .gy(gy), .gz(gz), .ok(imu_ok), .sample(imu_sample)
    );

    function [15:0] absval;
        input signed [15:0] v;
        absval = v[15] ? ((v == -16'sd32768) ? 16'd32767 : -v) : v;
    endfunction
    wire [15:0] ax = absval(gx), ay = absval(gy), az = absval(gz);
    wire [15:0] axy  = (ax > ay) ? ax : ay;
    wire [15:0] amax = (axy > az) ? axy : az;
    wire [15:0] rate = (GYRO_AXIS == 0) ? ax : (GYRO_AXIS == 1) ? ay : (GYRO_AXIS == 2) ? az : amax;

    localparam integer TURN_LSB  = TURN_DPS * 655 / 10;
    localparam integer HOLD_CYC  = CLK_HZ / 1000 * TURN_HOLD_MS;
    reg [23:0] turn_hold = 24'd0;
    reg        turning   = 1'b0;
    always @(posedge clk) begin
        if (rst || !imu_ok) begin
            turn_hold <= 24'd0;
            turning   <= 1'b0;
        end else begin
            if (rate > TURN_LSB)          turn_hold <= HOLD_CYC;
            else if (turn_hold != 24'd0) turn_hold <= turn_hold - 24'd1;
            turning <= (rate > TURN_LSB) || (turn_hold != 24'd0);
        end
    end

    // ------------------------------------------------------------------ SPI slave
    wire        pk_we, pk_wbuf;
    wire [12:0] pk_wa;
    wire [7:0]  pk_wd;
    wire        frame_ok, frame_ok_buf, frame_bad;
    wire [15:0] frame_ok_seq;
    reg  [1:0]  buf_release = 2'b00;
    wire [127:0] status_bits;
    wire        miso_bit, miso_oe;
    assign spi_miso = miso_oe ? miso_bit : 1'bz;

    spi_frame_slave u_spi (
        .clk(clk), .rst(rst), .sck(spi_sck), .mosi(spi_mosi), .cs_n(spi_cs_n),
        .miso_bit(miso_bit), .miso_oe(miso_oe), .status(status_bits),
        .buf_release(buf_release),
        .wr_en(pk_we), .wr_buf(pk_wbuf), .wr_addr(pk_wa), .wr_data(pk_wd),
        .frame_ok(frame_ok), .frame_buf(frame_ok_buf), .frame_seq(frame_ok_seq), .frame_bad(frame_bad)
    );

    // ------------------------------------------------------------------ LGMD engine + memories
    reg         eng_start = 1'b0;
    reg         cur_sel   = 1'b0;
    wire [12:0] g_ra;
    wire [7:0]  cur_rd, prev_rd;
    wire        prev_we;
    wire [12:0] prev_wa;
    wire [7:0]  prev_wd;
    wire [10:0] p_ra0, p_ra1, p_ra2;
    wire [7:0]  p_rd0, p_rd1, p_rd2;
    wire        p_we;
    wire [1:0]  p_wbank;
    wire [10:0] p_wa;
    wire [7:0]  p_wd;
    wire        pset, eng_busy, eng_done;
    wire [23:0] k_sum, f_sum;
    wire        px_v;
    wire [6:0]  px_x;
    wire [5:0]  px_y;
    wire [7:0]  px_s;

    frame_buffers u_mem (
        .clk(clk), .pk_we(pk_we), .pk_wbuf(pk_wbuf), .pk_wa(pk_wa), .pk_wd(pk_wd),
        .cur_sel(cur_sel), .g_ra(g_ra), .cur_rd(cur_rd), .prev_rd(prev_rd),
        .prev_we(prev_we), .prev_wa(prev_wa), .prev_wd(prev_wd),
        .pset(pset), .p_ra0(p_ra0), .p_ra1(p_ra1), .p_ra2(p_ra2), .p_rd0(p_rd0), .p_rd1(p_rd1), .p_rd2(p_rd2),
        .p_we(p_we), .p_wbank(p_wbank), .p_wa(p_wa), .p_wd(p_wd)
    );

    lgmd_engine #(.P_MIN(P_MIN), .W_SHIFT(W_SHIFT)) u_lgmd (
        .clk(clk), .rst(rst), .start(eng_start),
        .g_ra(g_ra), .cur_rd(cur_rd), .prev_rd(prev_rd),
        .prev_we(prev_we), .prev_wa(prev_wa), .prev_wd(prev_wd),
        .p_ra0(p_ra0), .p_ra1(p_ra1), .p_ra2(p_ra2), .p_rd0(p_rd0), .p_rd1(p_rd1), .p_rd2(p_rd2),
        .p_we(p_we), .p_wbank(p_wbank), .p_wa(p_wa), .p_wd(p_wd),
        .px_v(px_v), .px_x(px_x), .px_y(px_y), .px_s(px_s),
        .pset(pset), .busy(eng_busy), .done(eng_done), .k_sum(k_sum), .f_sum(f_sum)
    );

    wire        dec_valid, dec_alarm, dec_track, dec_cand, dec_box;
    wire [12:0] dec_e, dec_es;
    wire [4:0]  dec_inrow;

    looming_decider #(
        .S_MIN(S_MIN), .K_MIN(K_MIN), .F_MAX(F_MAX), .SMOOTH(SMOOTH), .GROW_FRAMES(GROW_FRAMES),
        .GROW_PCT(GROW_PCT), .EXPAND(EXPAND), .IN_A_ROW(IN_A_ROW), .WINDOW(WINDOW),
        .TRACK_HOLD_FRAMES(TRACK_HOLD_FRAMES)
    ) u_dec (
        .clk(clk), .rst(rst), .frame_start(eng_start), .px_v(px_v), .px_x(px_x), .px_y(px_y), .px_s(px_s),
        .frame_done(eng_done), .k(k_sum), .f(f_sum), .turning(turning),
        .valid(dec_valid), .alarm(dec_alarm), .tracking(dec_track), .cand(dec_cand), .box(dec_box),
        .e(dec_e), .es(dec_es), .in_row(dec_inrow)
    );

    // ------------------------------------------------------------------ frame queue / engine control
    reg        q_v = 1'b0, q_b = 1'b0;
    reg [15:0] q_s = 16'd0;
    reg        proc_active = 1'b0, proc_buf = 1'b0;
    reg [15:0] proc_seq = 16'd0;
    reg [15:0] res_seq = 16'd0;
    reg [7:0]  bad_cnt = 8'd0;
    reg        last_ok = 1'b0;
    always @(posedge clk) begin
        eng_start   <= 1'b0;
        buf_release <= 2'b00;
        if (rst) begin
            q_v <= 1'b0; proc_active <= 1'b0; bad_cnt <= 8'd0; last_ok <= 1'b0;
        end else begin
            if (!proc_active && (q_v || frame_ok)) begin
                eng_start   <= 1'b1;
                proc_active <= 1'b1;
                proc_buf    <= q_v ? q_b : frame_ok_buf;
                proc_seq    <= q_v ? q_s : frame_ok_seq;
                cur_sel     <= q_v ? q_b : frame_ok_buf;
                q_v <= q_v && frame_ok;
                if (q_v && frame_ok) begin q_b <= frame_ok_buf; q_s <= frame_ok_seq; end
            end else if (frame_ok) begin
                q_v <= 1'b1; q_b <= frame_ok_buf; q_s <= frame_ok_seq;
            end
            if (dec_valid) begin
                proc_active           <= 1'b0;
                buf_release[proc_buf] <= 1'b1;
                res_seq               <= proc_seq;
            end
            if (frame_ok)  last_ok <= 1'b1;
            if (frame_bad) begin
                last_ok <= 1'b0;
                if (bad_cnt != 8'hFF) bad_cnt <= bad_cnt + 8'd1;
            end
        end
    end

    // ------------------------------------------------------------------ status block for the ESP32
    wire [7:0]  flags = {1'b0, dec_box, dec_cand, last_ok, imu_ok, turning, dec_alarm, dec_track};
    wire [15:0] es16  = {3'd0, dec_es};
    wire [15:0] e16   = {3'd0, dec_e};
    reg  [23:0] k_res = 24'd0;
    always @(posedge clk) if (dec_valid) k_res <= k_sum;
    wire [7:0] b0 = 8'h5A, b1 = flags, b2 = res_seq[7:0], b3 = res_seq[15:8], b4 = rate[7:0], b5 = rate[15:8],
               b6 = es16[7:0], b7 = es16[15:8], b8 = e16[7:0], b9 = e16[15:8],
               b10 = k_res[7:0], b11 = k_res[15:8], b12 = k_res[23:16], b13 = {3'd0, dec_inrow}, b14 = bad_cnt;
    wire [7:0] b15 = b0 ^ b1 ^ b2 ^ b3 ^ b4 ^ b5 ^ b6 ^ b7 ^ b8 ^ b9 ^ b10 ^ b11 ^ b12 ^ b13 ^ b14;
    assign status_bits = {b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15};

    // ------------------------------------------------------------------ LEDs (active low)
    reg [24:0] hb = 25'd0;
    reg [24:0] fr_cnt = 25'd0, col_cnt = 25'd0;
    always @(posedge clk) begin
        hb <= hb + 25'd1;
        if (frame_ok)               fr_cnt <= CLK_HZ / 40;
        else if (fr_cnt != 25'd0)   fr_cnt <= fr_cnt - 25'd1;
        if (dec_valid && dec_alarm) col_cnt <= CLK_HZ;              // 1 s
        else if (col_cnt != 25'd0)  col_cnt <= col_cnt - 25'd1;
    end
    assign led = ~{imu_ok, turning, dec_track, (col_cnt != 25'd0) & hb[21], fr_cnt != 25'd0, hb[24]};
endmodule


// =============================================================================
// SPI slave, mode 0, sampled with the 27 MHz clock (SCK <= ~4 MHz for frames,
// <= ~1 MHz for status reads so MISO has time to change after each falling edge).
// =============================================================================
module spi_frame_slave #(
    parameter integer NPIX = 4800
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         sck,
    input  wire         mosi,
    input  wire         cs_n,
    output wire         miso_bit,
    output wire         miso_oe,
    input  wire [127:0] status,
    input  wire [1:0]   buf_release,
    output reg          wr_en,
    output reg          wr_buf,
    output reg  [12:0]  wr_addr,
    output reg  [7:0]   wr_data,
    output reg          frame_ok,
    output reg          frame_buf,
    output reg  [15:0]  frame_seq,
    output reg          frame_bad
);
    localparam [7:0] CMD_FRAME = 8'hA1;
    localparam integer FRAME_BYTES = 1 + 2 + NPIX + 2;

    reg [2:0] sck_s = 3'b000, cs_s = 3'b111;
    reg [1:0] mosi_s = 2'b00;
    always @(posedge clk) begin
        sck_s  <= {sck_s[1:0], sck};
        cs_s   <= {cs_s[1:0], cs_n};
        mosi_s <= {mosi_s[0], mosi};
    end
    wire sck_rise = (sck_s[2:1] == 2'b01);
    wire sck_fall = (sck_s[2:1] == 2'b10);
    wire cs_fall  = (cs_s[2:1] == 2'b10);
    wire cs_rise  = (cs_s[2:1] == 2'b01);
    wire active   = ~cs_s[1];

    reg [127:0] out_sh = 128'd0;
    assign miso_bit = out_sh[127];
    assign miso_oe  = active;

    reg [2:0]  bitn  = 3'd0;
    reg [7:0]  sh    = 8'd0;
    reg [12:0] nbyte = 13'd0;
    reg [7:0]  cmd   = 8'd0;
    reg [15:0] seq   = 16'd0;
    reg [15:0] crc   = 16'hFFFF;
    reg [7:0]  crc_lo = 8'd0;
    reg [15:0] got_crc = 16'd0;
    reg [1:0]  busy  = 2'b00;
    reg        have_buf = 1'b0, cur_buf = 1'b0;
    reg [1:0]  busy_n;
    wire [7:0] byte_in = {sh[6:0], mosi_s[1]};
    wire [15:0] crc_nx;
    crc16_ccitt_byte u_crc (.crc_in(crc), .d(byte_in), .crc_out(crc_nx));

    initial begin wr_en = 1'b0; frame_ok = 1'b0; frame_bad = 1'b0; end

    always @(posedge clk) begin
        wr_en     <= 1'b0;
        frame_ok  <= 1'b0;
        frame_bad <= 1'b0;
        busy_n = busy & ~buf_release;
        if (rst) begin
            busy_n = 2'b00;
            have_buf <= 1'b0;
            nbyte <= 13'd0;
        end else begin
            if (cs_fall) begin
                out_sh <= status;            // snapshot for this transaction
                bitn   <= 3'd0;
                nbyte  <= 13'd0;
                crc    <= 16'hFFFF;
            end else if (active && sck_fall) begin
                out_sh <= {out_sh[126:0], 1'b0};
            end
            if (active && sck_rise) begin
                sh   <= byte_in;
                bitn <= bitn + 3'd1;
                if (bitn == 3'd7) begin      // a full byte
                    if (nbyte != 13'h1FFF) nbyte <= nbyte + 13'd1;
                    if (nbyte == 13'd0) begin
                        cmd <= byte_in;
                        if (byte_in == CMD_FRAME) begin
                            if (!busy_n[0])      begin cur_buf <= 1'b0; have_buf <= 1'b1; busy_n[0] = 1'b1; end
                            else if (!busy_n[1]) begin cur_buf <= 1'b1; have_buf <= 1'b1; busy_n[1] = 1'b1; end
                            else have_buf <= 1'b0;
                        end
                    end else if (cmd == CMD_FRAME) begin
                        if (nbyte <= NPIX + 2) crc <= crc_nx;
                        if (nbyte == 13'd1) seq[7:0]  <= byte_in;
                        if (nbyte == 13'd2) seq[15:8] <= byte_in;
                        if (nbyte >= 13'd3 && nbyte <= NPIX + 2) begin
                            wr_en   <= have_buf;
                            wr_buf  <= cur_buf;
                            wr_addr <= nbyte - 13'd3;
                            wr_data <= byte_in;
                        end
                        if (nbyte == NPIX + 3) crc_lo <= byte_in;
                        if (nbyte == NPIX + 4) got_crc <= {byte_in, crc_lo};
                    end
                end
            end
            if (cs_rise && cmd == CMD_FRAME && nbyte != 13'd0) begin
                cmd <= 8'd0;
                if (nbyte == FRAME_BYTES && got_crc == crc && have_buf) begin
                    frame_ok  <= 1'b1;
                    frame_buf <= cur_buf;
                    frame_seq <= seq;
                end else begin
                    frame_bad <= 1'b1;
                    if (have_buf) busy_n[cur_buf] = 1'b0;
                end
                have_buf <= 1'b0;
            end
        end
        busy <= busy_n;
    end
endmodule


// =============================================================================
// MPU6050 gyro reader (I2C master, 100 kHz, open drain). Wakes the chip, sets
// +-500 deg/s and the 44 Hz filter, then reads GYRO_X/Y/Z ~200 times a second.
// No ACK -> ok = 0 and it retries every 100 ms (the head-turn gate is then off).
// =============================================================================
module mpu6050_gyro #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer I2C_HZ = 100_000
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               sda_in,
    output reg                scl_low,
    output reg                sda_low,
    output reg signed [15:0]  gx,
    output reg signed [15:0]  gy,
    output reg signed [15:0]  gz,
    output reg                ok,
    output reg                sample
);
    localparam integer QDIV = CLK_HZ / (I2C_HZ * 4);
    localparam [7:0] ADDR_W = 8'hD0, ADDR_R = 8'hD1;
    localparam [2:0] OP_START = 3'd1, OP_STOP = 3'd2, OP_WR = 3'd3, OP_RD = 3'd4;

    // ---- bit engine
    reg [1:0] sda_s = 2'b11;
    always @(posedge clk) sda_s <= {sda_s[0], sda_in};
    reg [7:0] qcnt = 8'd0;
    wire      qt = (qcnt == QDIV - 1);
    always @(posedge clk) qcnt <= qt ? 8'd0 : qcnt + 8'd1;

    reg        op_go = 1'b0;
    reg [2:0]  op = 3'd0;
    reg [7:0]  op_data = 8'd0;
    reg        op_nack = 1'b0;
    reg        op_done = 1'b0;
    reg        ack_ok = 1'b0;
    reg [7:0]  rbyte = 8'd0;

    localparam [2:0] E_IDLE = 3'd0, E_START = 3'd1, E_STOP = 3'd2, E_BIT = 3'd3;
    reg [2:0] es = E_IDLE;
    reg [1:0] q = 2'd0;
    reg [3:0] bitn = 4'd0;
    reg [7:0] sh = 8'd0;
    reg       is_rd = 1'b0, last = 1'b0;

    initial begin scl_low = 1'b0; sda_low = 1'b0; ok = 1'b0; sample = 1'b0; gx = 0; gy = 0; gz = 0; end

    always @(posedge clk) begin
        op_done <= 1'b0;
        if (rst) begin
            es <= E_IDLE; scl_low <= 1'b0; sda_low <= 1'b0;
        end else case (es)
            E_IDLE: if (op_go) begin
                q <= 2'd0;
                case (op)
                    OP_START: es <= E_START;
                    OP_STOP:  es <= E_STOP;
                    OP_WR:    begin sh <= op_data; bitn <= 4'd0; is_rd <= 1'b0; es <= E_BIT; end
                    default:  begin sh <= 8'd0; bitn <= 4'd0; is_rd <= 1'b1; last <= op_nack; es <= E_BIT; end
                endcase
            end
            E_START: if (qt) begin                       // SDA falls while SCL is high
                case (q)
                    2'd0: begin sda_low <= 1'b0; scl_low <= 1'b0; end
                    2'd1: sda_low <= 1'b1;
                    2'd2: scl_low <= 1'b1;
                    2'd3: begin es <= E_IDLE; op_done <= 1'b1; end
                endcase
                q <= q + 2'd1;
            end
            E_STOP: if (qt) begin                        // SDA rises while SCL is high
                case (q)
                    2'd0: begin scl_low <= 1'b1; sda_low <= 1'b1; end
                    2'd1: scl_low <= 1'b0;
                    2'd2: sda_low <= 1'b0;
                    2'd3: begin es <= E_IDLE; op_done <= 1'b1; end
                endcase
                q <= q + 2'd1;
            end
            E_BIT: if (qt) begin
                case (q)
                    2'd0: begin
                        scl_low <= 1'b1;
                        if (bitn < 4'd8) sda_low <= is_rd ? 1'b0 : ~sh[7];
                        else             sda_low <= is_rd ? ~last : 1'b0;      // ACK slot
                    end
                    2'd1: scl_low <= 1'b0;
                    2'd2: begin
                        if (bitn < 4'd8) sh <= {sh[6:0], is_rd ? sda_s[1] : 1'b0};
                        else if (!is_rd) ack_ok <= ~sda_s[1];
                    end
                    2'd3: begin
                        scl_low <= 1'b1;
                        if (bitn == 4'd8) begin
                            es <= E_IDLE; op_done <= 1'b1; rbyte <= sh;
                            if (is_rd) ack_ok <= 1'b1;
                        end else bitn <= bitn + 4'd1;
                    end
                endcase
                q <= q + 2'd1;
            end
            default: es <= E_IDLE;
        endcase
    end

    // ---- sequencer
    localparam [2:0] S_INIT = 3'd0, S_READ = 3'd1, S_WAIT = 3'd2, S_ESTOP = 3'd3, S_EWAIT = 3'd4;
    localparam integer WAIT_CYC = CLK_HZ / 200;      // ~200 samples per second (minus bus time)
    localparam integer ERR_CYC  = CLK_HZ / 10;
    reg [2:0]  st = S_INIT;
    reg [3:0]  step = 4'd0;
    reg [1:0]  widx = 2'd0;
    reg        issued = 1'b0;
    reg [23:0] tmr = 24'd0;
    reg [7:0]  rb [0:5];

    function [7:0] wreg;  input [1:0] i; wreg = (i == 2'd0) ? 8'h6B : (i == 2'd1) ? 8'h1B : 8'h1A; endfunction
    function [7:0] wval;  input [1:0] i; wval = (i == 2'd0) ? 8'h00 : (i == 2'd1) ? 8'h08 : 8'h03; endfunction

    always @(posedge clk) begin
        op_go  <= 1'b0;
        sample <= 1'b0;
        if (rst) begin
            st <= S_INIT; step <= 4'd0; widx <= 2'd0; issued <= 1'b0; ok <= 1'b0; tmr <= 24'd0;
        end else case (st)
            S_INIT, S_READ, S_ESTOP: begin
                if (!issued && es == E_IDLE && !op_go) begin
                    issued <= 1'b1;
                    op_go  <= 1'b1;
                    op_nack <= 1'b0;
                    if (st == S_ESTOP) op <= OP_STOP;
                    else if (st == S_INIT) begin
                        case (step)
                            4'd0: op <= OP_START;
                            4'd1: begin op <= OP_WR; op_data <= ADDR_W; end
                            4'd2: begin op <= OP_WR; op_data <= wreg(widx); end
                            4'd3: begin op <= OP_WR; op_data <= wval(widx); end
                            default: op <= OP_STOP;
                        endcase
                    end else begin
                        case (step)
                            4'd0, 4'd3: op <= OP_START;
                            4'd1: begin op <= OP_WR; op_data <= ADDR_W; end
                            4'd2: begin op <= OP_WR; op_data <= 8'h43; end       // GYRO_XOUT_H
                            4'd4: begin op <= OP_WR; op_data <= ADDR_R; end
                            4'd11: op <= OP_STOP;
                            default: begin op <= OP_RD; op_nack <= (step == 4'd10); end
                        endcase
                    end
                end
                if (op_done) begin
                    issued <= 1'b0;
                    if (op == OP_WR && !ack_ok && st != S_ESTOP) begin
                        st <= S_ESTOP; ok <= 1'b0;
                    end else if (st == S_ESTOP) begin
                        st <= S_EWAIT; tmr <= ERR_CYC;
                    end else if (st == S_INIT) begin
                        if (step == 4'd4) begin
                            step <= 4'd0;
                            if (widx == 2'd2) begin widx <= 2'd0; st <= S_READ; end
                            else widx <= widx + 2'd1;
                        end else step <= step + 4'd1;
                    end else begin
                        if (op == OP_RD) rb[step - 4'd5] <= rbyte;
                        if (step == 4'd11) begin
                            step <= 4'd0;
                            gx <= {rb[0], rb[1]};
                            gy <= {rb[2], rb[3]};
                            gz <= {rb[4], rb[5]};
                            ok <= 1'b1;
                            sample <= 1'b1;
                            st <= S_WAIT; tmr <= WAIT_CYC;
                        end else step <= step + 4'd1;
                    end
                end
            end
            S_WAIT:  if (tmr == 24'd0) st <= S_READ;  else tmr <= tmr - 24'd1;
            S_EWAIT: if (tmr == 24'd0) begin st <= S_INIT; step <= 4'd0; widx <= 2'd0; end else tmr <= tmr - 24'd1;
            default: st <= S_INIT;
        endcase
    end
endmodule


// =============================================================================
// Looming decision (once per frame). Same steps as lgmd_tuner.py LiveDetector:
//   moving pixel = S > S_MIN, box from column/row histograms trimmed by A>>4,
//   E = box area, Es = Es + ((E - Es) >>> SMOOTH),
//   grow   = Es*100 > Es[g frames ago]*(100 + GROW_PCT)
//   expand = wider and taller, no edge moved inward by > 1, centre moved <= half the widening
//   cand   = K > K_MIN and F < F_MAX and grow and expand;  alarm = >= IN_A_ROW cands in WINDOW
//   tracking = box and K > K_MIN (held TRACK_HOLD_FRAMES)
// While the head is turning: nothing is reported and the history restarts.
// =============================================================================
module looming_decider #(
    parameter integer W = 80,
    parameter integer H = 60,
    parameter integer S_MIN = 24,
    parameter integer K_MIN = 4800,
    parameter integer F_MAX = 24000,
    parameter integer SMOOTH = 1,
    parameter integer GROW_FRAMES = 4,
    parameter integer GROW_PCT = 15,
    parameter integer EXPAND = 1,
    parameter integer IN_A_ROW = 1,
    parameter integer WINDOW = 2,
    parameter integer TRACK_HOLD_FRAMES = 30
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        px_v,
    input  wire [6:0]  px_x,
    input  wire [5:0]  px_y,
    input  wire [7:0]  px_s,
    input  wire        frame_done,
    input  wire [23:0] k,
    input  wire [23:0] f,
    input  wire        turning,
    output reg         valid,
    output reg         alarm,
    output reg         tracking,
    output reg         cand,
    output reg         box,
    output reg  [12:0] e,
    output reg  [12:0] es,
    output reg  [4:0]  in_row
);
    integer i, hi_i, pi;
    // ---------------- histograms of moving pixels
    reg [5:0]  colc [0:W-1];
    reg [6:0]  rowc [0:H-1];
    reg [12:0] a_cnt = 13'd0;
    reg [6:0]  row_acc = 7'd0;
    wire       act = px_s > S_MIN;
    always @(posedge clk) begin
        if (frame_start) begin
            for (i = 0; i < W; i = i + 1) colc[i] <= 6'd0;
            for (i = 0; i < H; i = i + 1) rowc[i] <= 7'd0;
            a_cnt <= 13'd0;
            row_acc <= 7'd0;
        end else if (px_v) begin
            if (act) begin
                colc[px_x] <= colc[px_x] + 6'd1;
                a_cnt <= a_cnt + 13'd1;
            end
            if (px_x == W - 1) begin
                rowc[px_y] <= row_acc + act;
                row_acc <= 7'd0;
            end else begin
                row_acc <= row_acc + act;
            end
        end
    end

    // ---------------- per-frame decision FSM
    localparam [2:0] D_IDLE = 3'd0, D_COLS = 3'd1, D_ROWS = 3'd2, D_CALC = 3'd3, D_DEC = 3'd4;
    reg [2:0]  ds = D_IDLE;
    reg [6:0]  idx = 7'd0;
    reg [12:0] cum = 13'd0, cut = 13'd1, hi = 13'd1, a_l = 13'd0;
    reg [23:0] k_l = 24'd0, f_l = 24'd0;
    reg        f0 = 1'b0, f1 = 1'b0;
    reg [6:0]  bx0 = 7'd0, bx1 = 7'd0;
    reg [5:0]  by0 = 6'd0, by1 = 6'd0;
    reg [12:0] e_now = 13'd0, es_now = 13'd0;
    reg        bv = 1'b0;

    // history: index 0 = previous frame
    reg [12:0] h_es [0:15];
    reg [6:0]  h_x0 [0:15];
    reg [6:0]  h_x1 [0:15];
    reg [5:0]  h_y0 [0:15];
    reg [5:0]  h_y1 [0:15];
    reg        h_bv [0:15];
    reg [4:0]  hcnt = 5'd0;
    reg [15:0] cbits = 16'd0;
    reg [7:0]  thold = 8'd0;
    reg [12:0] es_reg = 13'd0;

    wire [12:0] cum_c = cum + colc[idx];
    wire [12:0] cum_r = cum + rowc[idx[5:0]];

    // decision maths on (es_now, box) vs the entry GROW_FRAMES ago
    localparam integer G = GROW_FRAMES;
    wire [12:0] pe  = h_es[G - 1];
    wire        hok = (hcnt >= G);
    wire        grow = hok && (pe != 13'd0) && ({11'd0, es_now} * 24'd100 > {11'd0, pe} * (100 + GROW_PCT));
    wire signed [8:0] x0s = {2'b00, bx0}, x1s = {2'b00, bx1}, y0s = {3'b000, by0}, y1s = {3'b000, by1};
    wire signed [8:0] px0 = {2'b00, h_x0[G - 1]}, px1 = {2'b00, h_x1[G - 1]};
    wire signed [8:0] py0 = {3'b000, h_y0[G - 1]}, py1 = {3'b000, h_y1[G - 1]};
    wire signed [9:0] dw  = (x1s - x0s) - (px1 - px0);
    wire signed [9:0] dh  = (y1s - y0s) - (py1 - py0);
    wire signed [9:0] dsum = (x0s + x1s) - (px0 + px1);
    wire [9:0]        adsum = dsum[9] ? -dsum : dsum;
    wire expd = hok && bv && h_bv[G - 1] && (dw > 0) && (dh > 0) &&
                (x0s <= px0 + 1) && (x1s >= px1 - 1) && (y0s <= py0 + 1) && (y1s >= py1 - 1) &&
                ($signed({1'b0, adsum}) * 2 <= dw);
    wire cand_now = (k_l > K_MIN) && (f_l < F_MAX) && grow && (EXPAND ? expd : 1'b1);
    wire [15:0] cbits_n = {cbits[14:0], cand_now};
    wire [15:0] wmask = (WINDOW >= 16) ? 16'hFFFF : ((16'd1 << WINDOW) - 16'd1);
    wire [15:0] wbits = cbits_n & wmask;
    reg  [4:0]  pop;
    always @(*) begin
        pop = 5'd0;
        for (pi = 0; pi < 16; pi = pi + 1) pop = pop + wbits[pi];
    end
    wire signed [14:0] diff = $signed({2'b00, e_now}) - $signed({2'b00, es_reg});
    wire signed [14:0] es_step = diff >>> SMOOTH;

    initial begin valid = 0; alarm = 0; tracking = 0; cand = 0; box = 0; e = 0; es = 0; in_row = 0; end

    always @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            ds <= D_IDLE; hcnt <= 5'd0; cbits <= 16'd0; es_reg <= 13'd0; thold <= 8'd0;
            alarm <= 1'b0; tracking <= 1'b0; cand <= 1'b0; box <= 1'b0;
        end else case (ds)
            D_IDLE: if (frame_done) begin
                a_l <= a_cnt; k_l <= k; f_l <= f;
                cut <= ((a_cnt >> 4) == 13'd0) ? 13'd1 : (a_cnt >> 4);
                hi  <= a_cnt - (((a_cnt >> 4) == 13'd0) ? 13'd1 : (a_cnt >> 4)) + 13'd1;
                idx <= 7'd0; cum <= 13'd0; f0 <= 1'b0; f1 <= 1'b0;
                ds <= D_COLS;
            end
            D_COLS: begin
                cum <= cum_c;
                if (!f0 && cum_c >= cut) begin bx0 <= idx; f0 <= 1'b1; end
                if (!f1 && cum_c >= hi)  begin bx1 <= idx; f1 <= 1'b1; end
                if (idx == W - 1) begin idx <= 7'd0; cum <= 13'd0; f0 <= 1'b0; f1 <= 1'b0; ds <= D_ROWS; end
                else idx <= idx + 7'd1;
            end
            D_ROWS: begin
                cum <= cum_r;
                if (!f0 && cum_r >= cut) begin by0 <= idx[5:0]; f0 <= 1'b1; end
                if (!f1 && cum_r >= hi)  begin by1 <= idx[5:0]; f1 <= 1'b1; end
                if (idx == H - 1) ds <= D_CALC;
                else idx <= idx + 7'd1;
            end
            D_CALC: begin
                bv    <= (a_l >= 13'd8);
                e_now <= (a_l >= 13'd8) ? ({6'd0, bx1 - bx0 + 7'd1} * {7'd0, by1 - by0 + 6'd1}) : 13'd0;
                ds    <= D_DEC;
            end
            D_DEC: begin
                // es_now is needed by grow: compute it here, use it next cycle
                es_now <= (SMOOTH == 0) ? e_now : (es_reg + es_step[12:0]);
                ds <= 3'd5;
            end
            3'd5: begin
                valid <= 1'b1;
                e  <= e_now;
                es <= es_now;
                box <= bv;
                if (turning) begin                 // head turning: check nothing, restart history
                    alarm <= 1'b0; cand <= 1'b0; tracking <= 1'b0; in_row <= 5'd0;
                    hcnt <= 5'd0; cbits <= 16'd0; es_reg <= 13'd0; thold <= 8'd0;
                end else begin
                    cand   <= cand_now;
                    cbits  <= cbits_n;
                    in_row <= pop;
                    alarm  <= (pop >= IN_A_ROW);
                    if (bv && k_l > K_MIN) thold <= TRACK_HOLD_FRAMES;
                    else if (thold != 8'd0) thold <= thold - 8'd1;
                    tracking <= (bv && k_l > K_MIN) || (thold > 8'd1);
                    es_reg <= es_now;
                    for (hi_i = 15; hi_i > 0; hi_i = hi_i - 1) begin
                        h_es[hi_i] <= h_es[hi_i - 1]; h_x0[hi_i] <= h_x0[hi_i - 1]; h_x1[hi_i] <= h_x1[hi_i - 1];
                        h_y0[hi_i] <= h_y0[hi_i - 1]; h_y1[hi_i] <= h_y1[hi_i - 1]; h_bv[hi_i] <= h_bv[hi_i - 1];
                    end
                    h_es[0] <= es_now; h_x0[0] <= bx0; h_x1[0] <= bx1; h_y0[0] <= by0; h_y1[0] <= by1; h_bv[0] <= bv;
                    if (hcnt != 5'd16) hcnt <= hcnt + 5'd1;
                end
                ds <= D_IDLE;
            end
            default: ds <= D_IDLE;
        endcase
    end
endmodule


// =============================================================================
// CRC-16/CCITT-FALSE, one byte per clock.
// =============================================================================
module crc16_ccitt_byte (
    input  wire [15:0] crc_in,
    input  wire [7:0]  d,
    output reg  [15:0] crc_out
);
    integer i;
    always @(*) begin
        crc_out = crc_in ^ {d, 8'h00};
        for (i = 0; i < 8; i = i + 1)
            crc_out = crc_out[15] ? ((crc_out << 1) ^ 16'h1021) : (crc_out << 1);
    end
endmodule


// =============================================================================
// Simple dual-port block RAM, 1 clock read latency.
// =============================================================================
module sdp_ram #(
    parameter integer AW    = 13,
    parameter integer DEPTH = 4800
)(
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire [7:0]    wd,
    input  wire [AW-1:0] ra,
    output reg  [7:0]    rd
);
    reg [7:0] mem [0:DEPTH-1] /* synthesis syn_ramstyle = "block_ram" */;
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rd <= mem[ra];
    end
endmodule


// =============================================================================
// Frame memories: two receive buffers, previous gray frame, previous/current P
// (ping-pong, split into 3 row banks so a 3-pixel column is read in one clock).
// =============================================================================
module frame_buffers (
    input  wire        clk,
    input  wire        pk_we,
    input  wire        pk_wbuf,
    input  wire [12:0] pk_wa,
    input  wire [7:0]  pk_wd,
    input  wire        cur_sel,
    input  wire [12:0] g_ra,
    output wire [7:0]  cur_rd,
    output wire [7:0]  prev_rd,
    input  wire        prev_we,
    input  wire [12:0] prev_wa,
    input  wire [7:0]  prev_wd,
    input  wire        pset,
    input  wire [10:0] p_ra0,
    input  wire [10:0] p_ra1,
    input  wire [10:0] p_ra2,
    output wire [7:0]  p_rd0,
    output wire [7:0]  p_rd1,
    output wire [7:0]  p_rd2,
    input  wire        p_we,
    input  wire [1:0]  p_wbank,
    input  wire [10:0] p_wa,
    input  wire [7:0]  p_wd
);
    wire [7:0] g0_rd, g1_rd;
    sdp_ram #(.AW(13), .DEPTH(4800)) u_g0 (.clk(clk), .we(pk_we & ~pk_wbuf), .wa(pk_wa), .wd(pk_wd), .ra(g_ra), .rd(g0_rd));
    sdp_ram #(.AW(13), .DEPTH(4800)) u_g1 (.clk(clk), .we(pk_we &  pk_wbuf), .wa(pk_wa), .wd(pk_wd), .ra(g_ra), .rd(g1_rd));
    sdp_ram #(.AW(13), .DEPTH(4800)) u_gp (.clk(clk), .we(prev_we), .wa(prev_wa), .wd(prev_wd), .ra(g_ra), .rd(prev_rd));
    assign cur_rd = cur_sel ? g1_rd : g0_rd;

    wire [7:0] a_rd0, a_rd1, a_rd2, b_rd0, b_rd1, b_rd2;
    wire we_a = p_we &  pset;
    wire we_b = p_we & ~pset;
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pa0 (.clk(clk), .we(we_a & (p_wbank == 2'd0)), .wa(p_wa), .wd(p_wd), .ra(p_ra0), .rd(a_rd0));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pa1 (.clk(clk), .we(we_a & (p_wbank == 2'd1)), .wa(p_wa), .wd(p_wd), .ra(p_ra1), .rd(a_rd1));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pa2 (.clk(clk), .we(we_a & (p_wbank == 2'd2)), .wa(p_wa), .wd(p_wd), .ra(p_ra2), .rd(a_rd2));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pb0 (.clk(clk), .we(we_b & (p_wbank == 2'd0)), .wa(p_wa), .wd(p_wd), .ra(p_ra0), .rd(b_rd0));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pb1 (.clk(clk), .we(we_b & (p_wbank == 2'd1)), .wa(p_wa), .wd(p_wd), .ra(p_ra1), .rd(b_rd1));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pb2 (.clk(clk), .we(we_b & (p_wbank == 2'd2)), .wa(p_wa), .wd(p_wd), .ra(p_ra2), .rd(b_rd2));
    assign p_rd0 = pset ? b_rd0 : a_rd0;
    assign p_rd1 = pset ? b_rd1 : a_rd1;
    assign p_rd2 = pset ? b_rd2 : a_rd2;
endmodule


// =============================================================================
// LGMD engine, one pixel per clock (4-stage pipeline), 60*81+5 clocks per frame.
//   P = |cur - prev|, 0 where P < P_MIN;  I = (8 neighbours of previous P) >> 3
//   S = max(P - (I >> W_SHIFT), 0);  K = sum S;  F = sum P
// Warm-up like lgmd.py: frame 0 -> P = 0, frame 1 -> previous P is 0.
// px_* stream every pixel's S (raster order) to the looming decider.
// =============================================================================
module lgmd_engine #(
    parameter integer W = 80,
    parameter integer H = 60,
    parameter integer P_MIN = 20,
    parameter integer W_SHIFT = 3
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output wire [12:0] g_ra,
    input  wire [7:0]  cur_rd,
    input  wire [7:0]  prev_rd,
    output wire        prev_we,
    output wire [12:0] prev_wa,
    output wire [7:0]  prev_wd,
    output wire [10:0] p_ra0,
    output wire [10:0] p_ra1,
    output wire [10:0] p_ra2,
    input  wire [7:0]  p_rd0,
    input  wire [7:0]  p_rd1,
    input  wire [7:0]  p_rd2,
    output wire        p_we,
    output wire [1:0]  p_wbank,
    output wire [10:0] p_wa,
    output wire [7:0]  p_wd,
    output wire        px_v,
    output wire [6:0]  px_x,
    output wire [5:0]  px_y,
    output wire [7:0]  px_s,
    output reg         pset,
    output reg         busy,
    output reg         done,
    output reg  [23:0] k_sum,
    output reg  [23:0] f_sum
);
    reg        issuing = 1'b0;
    reg [5:0]  y = 6'd0;
    reg [6:0]  j = 7'd0;
    reg [1:0]  ym3 = 2'd0;
    reg [10:0] yb = 11'd0;
    reg [12:0] grow = 13'd0;
    reg        use_pg = 1'b0, use_pp = 1'b0;
    reg [1:0]  fcount = 2'd0;

    wire [1:0]  bank_bot = (ym3 == 2'd2) ? 2'd0 : ym3 + 2'd1;
    wire [10:0] base_top = (y == 6'd0) ? 11'd0 : ((ym3 == 2'd0) ? yb - W : yb);
    wire [10:0] base_bot = (y == H - 1) ? yb : ((ym3 == 2'd2) ? yb + W : yb);
    wire [6:0]  jc = (j == W) ? (W - 1) : j;
    wire [10:0] a_mid = yb + jc, a_top = base_top + jc, a_bot = base_bot + jc;
    assign p_ra0 = (ym3 == 2'd0) ? a_mid : (bank_bot == 2'd0) ? a_bot : a_top;
    assign p_ra1 = (ym3 == 2'd1) ? a_mid : (bank_bot == 2'd1) ? a_bot : a_top;
    assign p_ra2 = (ym3 == 2'd2) ? a_mid : (bank_bot == 2'd2) ? a_bot : a_top;
    assign g_ra  = (j == 7'd0) ? grow : grow + j - 13'd1;

    reg        s1_v = 1'b0;
    reg [6:0]  s1_j;
    reg [5:0]  s1_y;
    reg [1:0]  s1_ym3;
    reg [10:0] s1_yb;
    reg [12:0] s1_ga;
    reg        s1_tv, s1_mv, s1_bv;

    function [7:0] pick;
        input [1:0] b;
        input [7:0] d0, d1, d2;
        pick = (b == 2'd0) ? d0 : (b == 2'd1) ? d1 : d2;
    endfunction
    wire [1:0] s1_bb = (s1_ym3 == 2'd2) ? 2'd0 : s1_ym3 + 2'd1;
    wire [1:0] s1_tb = (s1_ym3 == 2'd0) ? 2'd2 : s1_ym3 - 2'd1;
    wire       s1_cv = (s1_j != W);
    wire [7:0] col_t = (s1_tv && s1_cv) ? pick(s1_tb,  p_rd0, p_rd1, p_rd2) : 8'd0;
    wire [7:0] col_m = (s1_mv && s1_cv) ? pick(s1_ym3, p_rd0, p_rd1, p_rd2) : 8'd0;
    wire [7:0] col_b = (s1_bv && s1_cv) ? pick(s1_bb,  p_rd0, p_rd1, p_rd2) : 8'd0;
    reg [7:0] wl_t, wl_m, wl_b, wc_t, wc_m, wc_b, wr_t, wr_m, wr_b;

    reg        s2_v = 1'b0;
    reg [6:0]  s2_x;
    reg [5:0]  s2_y;
    reg [1:0]  s2_ym3;
    reg [10:0] s2_yb;
    reg [12:0] s2_ga;
    reg [7:0]  s2_cur, s2_prv;
    wire [10:0] i_sum = wl_t + wl_m + wl_b + wc_t + wc_b + wr_t + wr_m + wr_b;
    wire [7:0]  i_val = i_sum[10:3];
    wire [7:0]  i_w   = i_val >> W_SHIFT;
    wire [7:0]  p_raw = (s2_cur >= s2_prv) ? (s2_cur - s2_prv) : (s2_prv - s2_cur);
    wire [7:0]  p_val = (p_raw < P_MIN) ? 8'd0 : p_raw;
    wire [7:0]  s_val = (p_val > i_w) ? (p_val - i_w) : 8'd0;

    reg        s3_v = 1'b0, s3_last;
    reg [6:0]  s3_x;
    reg [5:0]  s3_y;
    reg [1:0]  s3_ym3;
    reg [10:0] s3_yb;
    reg [12:0] s3_ga;
    reg [7:0]  s3_cur, s3_p, s3_s;
    reg [23:0] k_acc = 24'd0, f_acc = 24'd0;
    reg        fin = 1'b0;

    assign p_we    = s3_v;
    assign p_wbank = s3_ym3;
    assign p_wa    = s3_yb + s3_x;
    assign p_wd    = s3_p;
    assign prev_we = s3_v;
    assign prev_wa = s3_ga;
    assign prev_wd = s3_cur;
    assign px_v = s3_v;
    assign px_x = s3_x;
    assign px_y = s3_y;
    assign px_s = s3_s;

    initial begin pset = 1'b0; busy = 1'b0; done = 1'b0; k_sum = 24'd0; f_sum = 24'd0; end

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            issuing <= 1'b0; busy <= 1'b0; pset <= 1'b0; fcount <= 2'd0;
            s1_v <= 1'b0; s2_v <= 1'b0; s3_v <= 1'b0; fin <= 1'b0;
        end else begin
            if (start && !busy) begin
                busy <= 1'b1; issuing <= 1'b1;
                y <= 6'd0; j <= 7'd0; ym3 <= 2'd0; yb <= 11'd0; grow <= 13'd0;
                use_pg <= (fcount != 2'd0);
                use_pp <= (fcount >= 2'd2);
                k_acc <= 24'd0; f_acc <= 24'd0;
            end else if (issuing) begin
                if (j == W) begin
                    j <= 7'd0;
                    if (y == H - 1) issuing <= 1'b0;
                    else begin
                        y <= y + 6'd1; grow <= grow + W;
                        if (ym3 == 2'd2) begin ym3 <= 2'd0; yb <= yb + W; end
                        else ym3 <= ym3 + 2'd1;
                    end
                end else j <= j + 7'd1;
            end

            s1_v <= issuing; s1_j <= j; s1_y <= y; s1_ym3 <= ym3; s1_yb <= yb; s1_ga <= g_ra;
            s1_tv <= use_pp && (y != 6'd0); s1_mv <= use_pp; s1_bv <= use_pp && (y != H - 1);

            if (s1_v) begin
                if (s1_j == 7'd0) begin
                    wl_t <= 8'd0; wl_m <= 8'd0; wl_b <= 8'd0; wc_t <= 8'd0; wc_m <= 8'd0; wc_b <= 8'd0;
                end else begin
                    wl_t <= wc_t; wl_m <= wc_m; wl_b <= wc_b; wc_t <= wr_t; wc_m <= wr_m; wc_b <= wr_b;
                end
                wr_t <= col_t; wr_m <= col_m; wr_b <= col_b;
            end
            s2_v <= s1_v && (s1_j != 7'd0);
            s2_x <= s1_j - 7'd1; s2_y <= s1_y; s2_ym3 <= s1_ym3; s2_yb <= s1_yb; s2_ga <= s1_ga;
            s2_cur <= cur_rd;
            s2_prv <= use_pg ? prev_rd : cur_rd;

            s3_v <= s2_v; s3_last <= (s2_x == W - 1) && (s2_y == H - 1);
            s3_x <= s2_x; s3_y <= s2_y; s3_ym3 <= s2_ym3; s3_yb <= s2_yb; s3_ga <= s2_ga;
            s3_cur <= s2_cur; s3_p <= p_val; s3_s <= s_val;

            if (s3_v) begin
                f_acc <= f_acc + s3_p;
                k_acc <= k_acc + s3_s;
            end
            fin <= s3_v && s3_last;
            if (fin) begin
                done <= 1'b1; busy <= 1'b0; k_sum <= k_acc; f_sum <= f_acc; pset <= ~pset;
                if (fcount != 2'd3) fcount <= fcount + 2'd1;
            end
        end
    end
endmodule

`default_nettype wire
