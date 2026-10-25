// =============================================================================
// omni_collision.v  —  Omni Glasses rear-collision reflex (LGMD) on Tang Nano 20K
//
//   laptop webcam -> omni_collision.py -> USB-C (onboard BL616 USB-UART) -> FPGA
//
// The laptop only shrinks the picture to 80x60 grayscale and sends it. All of
// the collision math happens here: packet sync + CRC check, double-buffered
// frame storage, the LGMD layers (P, I, S, K, F) and the fire decision.
//
// Onboard LEDs (active low):
//   LED0  heartbeat (1 Hz)             LED1  flash on every good frame
//   LED2  COLLISION: 8 Hz blink, ~1 s  LED3  link error (bad CRC / dropped / framing)
//   LED4, LED5 off
//
// ---------------------------------------------------------------------------
// Link protocol. Multi-byte fields are little-endian. CRC = CRC-16/CCITT-FALSE
// (poly 0x1021, init 0xFFFF, no reflection; Python: binascii.crc_hqx(b, 0xFFFF))
// computed over every byte after the 4-byte magic and before the CRC itself.
//
//   host -> FPGA frame   "OMNI" seq16 pixel[4800] crc16                  4808 B
//   host -> FPGA command "OMNC" seq16 cmd8 sub8 arg32 crc16                14 B
//   FPGA -> host reply   "OMN" type8 seq16 flags8 aux8 w0_32 w1_32 crc16   18 B
//
//   type 'A'  frame processed: flags = {k>T, F>=Fmax, k_valid, fire},
//             aux = rise count, w0 = K, w1 = F
//   type 'N'  frame rejected:  flags = 1 CRC, 2 BUSY (no free buffer), 3 TIMEOUT
//   type 'R'  command reply:   flags = cmd, aux = 0 ok / 1 bad arg / 2 unknown
//
//   commands: 1 PING        -> w0 = current baud, w1 = {bad[15:0], good[15:0]}
//             2 SET_BAUD    arg = new baud (MIN_BAUD..MAX_BAUD); switches after
//                           the reply has left the UART
//             3 SET_PARAM   sub 0 K threshold, 1 F max, 2 rise frames (1..15),
//                           3 ROI {y1,y0,x1,x0} bytes, 4 rise delta
//             4 RESET_LGMD  forget previous frames (re-runs the warm-up)
//
// Flow control: an 'A' ACK is sent only after the frame has been processed and
// its buffer is free again. With two receive buffers the host may keep two
// frames un-ACKed, which keeps the wire busy while one is being processed. If
// the host ever sends more, the frame is answered with a BUSY NAK instead of
// overwriting anything.
//
// Baud rate: the FPGA boots at BOOT_BAUD (115200, always works) and the host
// raises it with SET_BAUD. If no valid packet arrives for REVERT_MS while on a
// non-boot rate, the FPGA falls back to BOOT_BAUD, so trying a rate that the
// BL616 cannot do never locks you out. 27 MHz / 2 Mbaud = 13.5 clocks per bit,
// so bit timing uses a fractional (phase accumulator) generator, exact on
// average for any integer baud rate.
// =============================================================================
`default_nettype none

module top #(
    parameter integer CLK_HZ         = 27_000_000,
    parameter integer BOOT_BAUD      = 115_200,
    parameter integer MIN_BAUD       = 9_600,
    parameter integer MAX_BAUD       = 3_000_000,  // 9 clocks per bit at 27 MHz
    parameter integer REVERT_MS      = 2000,       // keep <= 2400 (26-bit counter)
    parameter integer PKT_TIMEOUT_MS = 50,         // max gap between bytes of a packet
    parameter integer K_THRESHOLD    = 15_000,     // fire needs K > this
    parameter integer F_MAX          = 120_000,    // fire needs F < this
    parameter integer RISE_FRAMES    = 3           // fire needs K rising this many frames
)(
    input  wire       clk,       // 27 MHz crystal          pin 4
    input  wire       uart_rx,   // BL616 -> FPGA           pin 70
    output wire       uart_tx,   // FPGA -> BL616           pin 69
    output wire [5:0] led        // onboard LEDs, active low pins 15..20
);
    localparam integer REVERT_CYC = CLK_HZ / 1000 * REVERT_MS;

    // ------------------------------------------------------------------ reset
    reg [7:0] por_cnt = 8'd0;
    reg       rst     = 1'b1;
    always @(posedge clk) begin
        if (por_cnt != 8'hFF) por_cnt <= por_cnt + 8'd1;
        rst <= (por_cnt != 8'hFF);
    end

    // ------------------------------------------------------------------ run-time settings
    reg [21:0] baud       = BOOT_BAUD;
    reg [23:0] k_thr      = K_THRESHOLD;
    reg [23:0] f_max      = F_MAX;
    reg [3:0]  rise_n     = RISE_FRAMES;
    reg [15:0] rise_delta = 16'd0;
    reg [6:0]  roi_x0     = 7'd0;
    reg [6:0]  roi_x1     = 7'd79;
    reg [5:0]  roi_y0     = 6'd0;
    reg [5:0]  roi_y1     = 6'd59;

    // ------------------------------------------------------------------ UART receive
    wire [7:0] rx_byte;
    wire       rx_valid;
    wire       rx_ferr;

    uart_rx #(.CLK_HZ(CLK_HZ)) u_uart_rx (
        .clk(clk), .rst(rst), .baud(baud), .rx(uart_rx),
        .data(rx_byte), .valid(rx_valid), .frame_err(rx_ferr)
    );

    // ------------------------------------------------------------------ packet parser
    wire        pk_we;
    wire        pk_wbuf;
    wire [12:0] pk_wa;
    wire [7:0]  pk_wd;
    wire        frame_ok;
    wire        frame_ok_buf;
    wire [15:0] frame_ok_seq;
    wire        frame_bad;
    wire [7:0]  bad_reason;
    wire [15:0] bad_seq;
    wire        cmd_ok;
    wire [15:0] cmd_seq;
    wire [7:0]  cmd_code;
    wire [7:0]  cmd_sub;
    wire [31:0] cmd_arg;
    reg  [1:0]  buf_release = 2'b00;

    frame_packet_rx #(
        .NPIX(4800),
        .TIMEOUT_CYC(CLK_HZ / 1000 * PKT_TIMEOUT_MS)
    ) u_pkt (
        .clk(clk), .rst(rst),
        .rx_data(rx_byte), .rx_valid(rx_valid),
        .buf_release(buf_release),
        .wr_en(pk_we), .wr_buf(pk_wbuf), .wr_addr(pk_wa), .wr_data(pk_wd),
        .frame_ok(frame_ok), .frame_buf(frame_ok_buf), .frame_seq(frame_ok_seq),
        .frame_bad(frame_bad), .bad_reason(bad_reason), .bad_seq(bad_seq),
        .cmd_ok(cmd_ok), .cmd_seq(cmd_seq), .cmd_code(cmd_code), .cmd_sub(cmd_sub), .cmd_arg(cmd_arg)
    );

    // ------------------------------------------------------------------ LGMD engine + memories
    reg         eng_start = 1'b0;
    reg         eng_clear = 1'b0;
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
    wire        pset;
    wire        eng_busy, eng_done;
    wire [23:0] k_sum, f_sum;
    wire [3:0]  frame_count;

    frame_buffers u_mem (
        .clk(clk),
        .pk_we(pk_we), .pk_wbuf(pk_wbuf), .pk_wa(pk_wa), .pk_wd(pk_wd),
        .cur_sel(cur_sel), .g_ra(g_ra), .cur_rd(cur_rd), .prev_rd(prev_rd),
        .prev_we(prev_we), .prev_wa(prev_wa), .prev_wd(prev_wd),
        .pset(pset), .p_ra0(p_ra0), .p_ra1(p_ra1), .p_ra2(p_ra2),
        .p_rd0(p_rd0), .p_rd1(p_rd1), .p_rd2(p_rd2),
        .p_we(p_we), .p_wbank(p_wbank), .p_wa(p_wa), .p_wd(p_wd)
    );

    lgmd_engine u_lgmd (
        .clk(clk), .rst(rst), .start(eng_start), .clear(eng_clear),
        .roi_x0(roi_x0), .roi_x1(roi_x1), .roi_y0(roi_y0), .roi_y1(roi_y1),
        .g_ra(g_ra), .cur_rd(cur_rd), .prev_rd(prev_rd),
        .prev_we(prev_we), .prev_wa(prev_wa), .prev_wd(prev_wd),
        .p_ra0(p_ra0), .p_ra1(p_ra1), .p_ra2(p_ra2),
        .p_rd0(p_rd0), .p_rd1(p_rd1), .p_rd2(p_rd2),
        .p_we(p_we), .p_wbank(p_wbank), .p_wa(p_wa), .p_wd(p_wd),
        .pset(pset), .busy(eng_busy), .done(eng_done),
        .k_sum(k_sum), .f_sum(f_sum), .frame_count(frame_count)
    );

    wire       det_valid, det_fire, det_kvalid, det_fsupp, det_above;
    wire [3:0] det_rise;

    collision_detector u_det (
        .clk(clk), .rst(rst), .clear(eng_clear),
        .frame_done(eng_done), .k(k_sum), .f(f_sum), .frame_count(frame_count),
        .k_thr(k_thr), .f_max(f_max), .rise_n(rise_n), .rise_delta(rise_delta),
        .valid(det_valid), .fire(det_fire), .k_valid(det_kvalid),
        .f_supp(det_fsupp), .k_above(det_above), .rise_cnt(det_rise)
    );

    // ------------------------------------------------------------------ frame queue / engine control
    // Good frames wait here (in arrival order) until the engine is free.
    // Two entries are enough: there are only two receive buffers.
    reg        q0_v = 1'b0, q1_v = 1'b0;
    reg        q0_b = 1'b0, q1_b = 1'b0;
    reg [15:0] q0_s = 16'd0, q1_s = 16'd0;
    reg        proc_active = 1'b0;
    reg        proc_buf    = 1'b0;
    reg [15:0] proc_seq    = 16'd0;
    reg        clear_cmd   = 1'b0;
    reg        clear_pend  = 1'b0;
    reg [15:0] good_cnt    = 16'd0;
    reg [15:0] bad_cnt     = 16'd0;

    reg        ack_req = 1'b0;
    reg [15:0] ack_seq = 16'd0;
    reg [7:0]  ack_flags = 8'd0, ack_aux = 8'd0;
    reg [31:0] ack_w0 = 32'd0, ack_w1 = 32'd0;

    wire pop = q0_v && !proc_active && !clear_pend;

    always @(posedge clk) begin
        eng_start   <= 1'b0;
        eng_clear   <= 1'b0;
        buf_release <= 2'b00;
        ack_req     <= 1'b0;
        if (rst) begin
            q0_v <= 1'b0; q1_v <= 1'b0;
            proc_active <= 1'b0; clear_pend <= 1'b0;
            good_cnt <= 16'd0; bad_cnt <= 16'd0;
        end else begin
            if (pop) begin
                eng_start   <= 1'b1;
                proc_active <= 1'b1;
                proc_buf    <= q0_b;
                proc_seq    <= q0_s;
                cur_sel     <= q0_b;
                if (q1_v) begin
                    q0_b <= q1_b; q0_s <= q1_s;
                    q1_v <= frame_ok; q1_b <= frame_ok_buf; q1_s <= frame_ok_seq;
                end else begin
                    q0_v <= frame_ok; q0_b <= frame_ok_buf; q0_s <= frame_ok_seq;
                end
            end else if (frame_ok) begin
                if (!q0_v) begin
                    q0_v <= 1'b1; q0_b <= frame_ok_buf; q0_s <= frame_ok_seq;
                end else begin
                    q1_v <= 1'b1; q1_b <= frame_ok_buf; q1_s <= frame_ok_seq;
                end
            end

            // Frame finished: free its buffer, then ACK (so an ACK always means "buffer free").
            if (det_valid) begin
                proc_active           <= 1'b0;
                buf_release[proc_buf] <= 1'b1;
                ack_req   <= 1'b1;
                ack_seq   <= proc_seq;
                ack_flags <= {4'd0, det_above, det_fsupp, det_kvalid, det_fire};
                ack_aux   <= {4'd0, det_rise};
                ack_w0    <= {8'd0, k_sum};
                ack_w1    <= {8'd0, f_sum};
                good_cnt  <= good_cnt + 16'd1;
            end
            if (frame_bad) bad_cnt <= bad_cnt + 16'd1;

            // RESET_LGMD waits until the engine is idle.
            if (clear_cmd) clear_pend <= 1'b1;
            else if (clear_pend && !proc_active) begin
                eng_clear  <= 1'b1;
                clear_pend <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------ commands, baud switching, watchdog
    localparam [7:0] CMD_PING = 8'd1, CMD_SET_BAUD = 8'd2, CMD_SET_PARAM = 8'd3, CMD_RESET = 8'd4;

    wire       resp_idle;
    reg [25:0] wd_cnt  = 26'd0;
    reg        sw_pend = 1'b0;
    reg [21:0] sw_baud = 22'd0;

    reg        rep_req = 1'b0;
    reg [15:0] rep_seq = 16'd0;
    reg [7:0]  rep_flags = 8'd0, rep_aux = 8'd0;
    reg [31:0] rep_w0 = 32'd0, rep_w1 = 32'd0;

    always @(posedge clk) begin
        rep_req   <= 1'b0;
        clear_cmd <= 1'b0;
        if (rst) begin
            baud <= BOOT_BAUD; sw_pend <= 1'b0; wd_cnt <= 26'd0;
            k_thr <= K_THRESHOLD; f_max <= F_MAX; rise_n <= RISE_FRAMES; rise_delta <= 16'd0;
            roi_x0 <= 7'd0; roi_x1 <= 7'd79; roi_y0 <= 6'd0; roi_y1 <= 6'd59;
        end else begin
            // watchdog: time since the last valid packet
            if (frame_ok || cmd_ok)       wd_cnt <= 26'd0;
            else if (wd_cnt != {26{1'b1}}) wd_cnt <= wd_cnt + 26'd1;

            if (sw_pend && resp_idle) begin
                baud    <= sw_baud;            // the SET_BAUD reply has fully left the UART
                sw_pend <= 1'b0;
                wd_cnt  <= 26'd0;
            end else if (!sw_pend && baud != BOOT_BAUD && wd_cnt >= REVERT_CYC && resp_idle) begin
                baud <= BOOT_BAUD;             // nobody is talking to us at this rate: fall back
            end

            if (cmd_ok) begin
                rep_req   <= 1'b1;
                rep_seq   <= cmd_seq;
                rep_flags <= cmd_code;
                rep_aux   <= 8'd0;
                rep_w0    <= 32'd0;
                rep_w1    <= 32'd0;
                case (cmd_code)
                    CMD_PING: begin
                        rep_w0 <= {10'd0, baud};
                        rep_w1 <= {bad_cnt, good_cnt};
                    end
                    CMD_SET_BAUD: begin
                        if (cmd_arg >= MIN_BAUD && cmd_arg <= MAX_BAUD) begin
                            sw_pend <= 1'b1;
                            sw_baud <= cmd_arg[21:0];
                            rep_w0  <= cmd_arg;
                        end else begin
                            rep_aux <= 8'd1;
                            rep_w0  <= {10'd0, baud};
                        end
                    end
                    CMD_SET_PARAM: begin
                        rep_w0 <= cmd_arg;
                        case (cmd_sub)
                            8'd0: k_thr <= (cmd_arg[31:24] != 8'd0) ? 24'hFFFFFF : cmd_arg[23:0];
                            8'd1: f_max <= (cmd_arg[31:24] != 8'd0) ? 24'hFFFFFF : cmd_arg[23:0];
                            8'd2: begin
                                if (cmd_arg >= 1 && cmd_arg <= 15) rise_n <= cmd_arg[3:0];
                                else rep_aux <= 8'd1;
                            end
                            8'd3: begin
                                if (cmd_arg[7:0] <= cmd_arg[15:8] && cmd_arg[15:8] <= 8'd79 &&
                                    cmd_arg[23:16] <= cmd_arg[31:24] && cmd_arg[31:24] <= 8'd59) begin
                                    roi_x0 <= cmd_arg[6:0];   roi_x1 <= cmd_arg[14:8];
                                    roi_y0 <= cmd_arg[21:16]; roi_y1 <= cmd_arg[29:24];
                                end else rep_aux <= 8'd1;
                            end
                            8'd4: rise_delta <= (cmd_arg[31:16] != 16'd0) ? 16'hFFFF : cmd_arg[15:0];
                            default: rep_aux <= 8'd1;
                        endcase
                    end
                    CMD_RESET: clear_cmd <= 1'b1;
                    default:   rep_aux <= 8'd2;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------ UART transmit (ACK / NAK / replies)
    resp_tx #(.CLK_HZ(CLK_HZ)) u_resp (
        .clk(clk), .rst(rst), .baud(baud),
        .ack_req(ack_req), .ack_seq(ack_seq), .ack_flags(ack_flags), .ack_aux(ack_aux),
        .ack_w0(ack_w0), .ack_w1(ack_w1),
        .nak_req(frame_bad), .nak_seq(bad_seq), .nak_flags(bad_reason), .nak_aux(8'd0),
        .nak_w0({16'd0, bad_cnt}), .nak_w1({16'd0, good_cnt}),
        .rep_req(rep_req), .rep_seq(rep_seq), .rep_flags(rep_flags), .rep_aux(rep_aux),
        .rep_w0(rep_w0), .rep_w1(rep_w1),
        .tx(uart_tx), .idle(resp_idle)
    );

    // ------------------------------------------------------------------ LEDs
    led_driver #(.CLK_HZ(CLK_HZ)) u_led (
        .clk(clk), .rst(rst),
        .frame_pulse(frame_ok),
        .fire_pulse(det_valid & det_fire),
        .err_pulse(frame_bad | rx_ferr),
        .led(led)
    );
endmodule


// =============================================================================
// Fractional baud tick generator (phase accumulator).
// Adds `baud` every clock; each time the sum passes CLK_HZ it ticks and wraps.
// Ticks therefore come every CLK_HZ/baud clocks on average with no drift,
// e.g. 13 or 14 clocks (13.5 average) at 2 Mbaud. `load` restarts the phase.
// =============================================================================
module baud_gen #(
    parameter integer CLK_HZ = 27_000_000
)(
    input  wire        clk,
    input  wire        load,
    input  wire [24:0] load_val,
    input  wire        run,
    input  wire [21:0] baud,
    output wire        tick
);
    reg  [24:0] acc = 25'd0;
    wire [25:0] sum = {1'b0, acc} + {4'd0, baud};

    assign tick = run && !load && (sum >= CLK_HZ);

    always @(posedge clk) begin
        if (load)     acc <= load_val;
        else if (run) acc <= tick ? (sum - CLK_HZ) : sum[24:0];
    end
endmodule


// =============================================================================
// UART receiver, 8N1, runtime baud rate.
// 2-FF synchroniser; start detected on the falling edge; the first tick lands
// half a bit later (centre of the start bit) and then every bit period, so
// data and stop bits are sampled at their centres. Sampling error is within
// +-1 clock (+-11% of a bit at 3 Mbaud, +-7% at 2 Mbaud). Returns to IDLE at
// the middle of the stop bit, so back-to-back bytes are never missed.
// =============================================================================
module uart_rx #(
    parameter integer CLK_HZ = 27_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [21:0] baud,
    input  wire        rx,
    output reg  [7:0]  data,
    output reg         valid,
    output reg         frame_err
);
    localparam [24:0] HALF = CLK_HZ / 2;
    localparam [1:0]  IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;

    reg rx_m = 1'b1, rx_s = 1'b1, rx_d = 1'b1;   // synchroniser + edge history
    always @(posedge clk) begin
        rx_m <= rx;
        rx_s <= rx_m;
        rx_d <= rx_s;
    end

    reg  [1:0] st   = IDLE;
    reg  [2:0] nbit = 3'd0;
    reg  [7:0] sh   = 8'd0;
    wire       start_edge = (st == IDLE) && rx_d && !rx_s;
    wire       tick;
    // preload HALF + baud puts the first tick one clock before the half-bit
    // point, centring the +-1 clock edge-detection uncertainty
    wire [24:0] preload = HALF + {3'd0, baud};

    baud_gen #(.CLK_HZ(CLK_HZ)) u_bg (
        .clk(clk), .load(start_edge), .load_val(preload),
        .run(st != IDLE), .baud(baud), .tick(tick)
    );

    always @(posedge clk) begin
        valid     <= 1'b0;
        frame_err <= 1'b0;
        if (rst) begin
            st <= IDLE;
        end else begin
            case (st)
                IDLE:  if (start_edge) st <= START;
                START: if (tick) begin
                           nbit <= 3'd0;
                           st   <= rx_s ? IDLE : DATA;   // high again = glitch, ignore
                       end
                DATA:  if (tick) begin
                           sh   <= {rx_s, sh[7:1]};      // LSB first
                           nbit <= nbit + 3'd1;
                           if (nbit == 3'd7) st <= STOP;
                       end
                STOP:  if (tick) begin
                           if (rx_s) begin
                               data  <= sh;
                               valid <= 1'b1;
                           end else begin
                               frame_err <= 1'b1;        // stop bit low: wrong baud or noise
                           end
                           st <= IDLE;
                       end
            endcase
        end
    end
endmodule


// =============================================================================
// UART transmitter, 8N1, runtime baud rate. `start` is accepted when !busy.
// =============================================================================
module uart_tx #(
    parameter integer CLK_HZ = 27_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [21:0] baud,
    input  wire        start,
    input  wire [7:0]  data,
    output wire        tx,
    output reg         busy
);
    reg  [9:0] sh = 10'h3FF;
    reg  [3:0] n  = 4'd0;
    wire       go = start && !busy;
    wire       tick;

    initial busy = 1'b0;

    baud_gen #(.CLK_HZ(CLK_HZ)) u_bg (
        .clk(clk), .load(go), .load_val(25'd0),
        .run(busy), .baud(baud), .tick(tick)
    );

    assign tx = sh[0];

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            sh   <= 10'h3FF;
            n    <= 4'd0;
        end else if (go) begin
            sh   <= {1'b1, data, 1'b0};     // stop, data LSB first, start
            n    <= 4'd0;
            busy <= 1'b1;
        end else if (busy && tick) begin
            sh <= {1'b1, sh[9:1]};
            n  <= n + 4'd1;
            if (n == 4'd9) busy <= 1'b0;    // stop bit has been on the line for a full bit
        end
    end
endmodule


// =============================================================================
// CRC-16/CCITT-FALSE, one byte per clock (combinational).
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
// Packet receiver.
// Hunts for "OMN" + type byte, so it resynchronises after any garbage.
// Frames ('I'): the 4800 pixels are written straight into a free receive
// buffer while the CRC is computed on the fly. A buffer is marked busy from the
// type byte until the engine releases it, so a buffer that is queued or being
// processed is never written. No free buffer -> payload is skipped and the frame
// is NAKed BUSY. Bad CRC -> buffer freed, NAK CRC. A stall longer than
// TIMEOUT_CYC mid-packet -> buffer freed, NAK TIMEOUT, back to hunting.
// Commands ('C'): delivered on cmd_ok only when their CRC matches.
// =============================================================================
module frame_packet_rx #(
    parameter integer NPIX        = 4800,
    parameter integer TIMEOUT_CYC = 1_350_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire [1:0]  buf_release,   // pulse per buffer: engine finished with it
    output reg         wr_en,
    output reg         wr_buf,
    output reg  [12:0] wr_addr,
    output reg  [7:0]  wr_data,
    output reg         frame_ok,
    output reg         frame_buf,
    output reg  [15:0] frame_seq,
    output reg         frame_bad,
    output reg  [7:0]  bad_reason,
    output reg  [15:0] bad_seq,
    output reg         cmd_ok,
    output reg  [15:0] cmd_seq,
    output reg  [7:0]  cmd_code,
    output reg  [7:0]  cmd_sub,
    output reg  [31:0] cmd_arg
);
    localparam [7:0] CH_O = 8'h4F, CH_M = 8'h4D, CH_N = 8'h4E, CH_I = 8'h49, CH_C = 8'h43;
    localparam [7:0] NAK_CRC = 8'd1, NAK_BUSY = 8'd2, NAK_TIMEOUT = 8'd3;
    localparam [3:0] S_M0 = 4'd0, S_M1 = 4'd1, S_M2 = 4'd2, S_TYPE = 4'd3,
                     S_SEQ0 = 4'd4, S_SEQ1 = 4'd5, S_PAY = 4'd6, S_CRC0 = 4'd7, S_CRC1 = 4'd8,
                     S_CMD = 4'd9, S_SUB = 4'd10, S_ARG = 4'd11, S_CCRC0 = 4'd12, S_CCRC1 = 4'd13;

    reg  [3:0]  st       = S_M0;
    reg  [1:0]  busy     = 2'b00;   // buffer allocated: filling, queued or being processed
    reg         is_frame = 1'b0;
    reg         have_buf = 1'b0;
    reg         cur_buf  = 1'b0;
    reg  [12:0] cnt      = 13'd0;
    reg  [1:0]  argn     = 2'd0;
    reg  [15:0] seq      = 16'd0;
    reg  [15:0] crc      = 16'hFFFF;
    reg  [7:0]  crc_lo   = 8'd0;
    reg  [7:0]  code     = 8'd0;
    reg  [7:0]  sub      = 8'd0;
    reg  [31:0] arg      = 32'd0;
    reg  [21:0] idle_cnt = 22'd0;
    reg  [1:0]  busy_n;              // scratch (blocking) for this clock's busy update
    wire [15:0] crc_nx;

    initial begin
        wr_en = 1'b0; frame_ok = 1'b0; frame_bad = 1'b0; cmd_ok = 1'b0;
    end

    crc16_ccitt_byte u_crc (.crc_in(crc), .d(rx_data), .crc_out(crc_nx));

    always @(posedge clk) begin
        wr_en     <= 1'b0;
        frame_ok  <= 1'b0;
        frame_bad <= 1'b0;
        cmd_ok    <= 1'b0;
        busy_n = busy & ~buf_release;

        if (rst) begin
            st       <= S_M0;
            have_buf <= 1'b0;
            idle_cnt <= 22'd0;
            busy_n   = 2'b00;
        end else begin
            if (rx_valid)                                    idle_cnt <= 22'd0;
            else if (st != S_M0 && idle_cnt != {22{1'b1}})   idle_cnt <= idle_cnt + 22'd1;

            if (!rx_valid && st != S_M0 && idle_cnt >= TIMEOUT_CYC) begin
                // sender stalled mid-packet: drop it and hunt for the next header
                if (is_frame && st >= S_SEQ0 && st <= S_CRC1) begin
                    frame_bad  <= 1'b1;
                    bad_reason <= NAK_TIMEOUT;
                    bad_seq    <= seq;
                    if (have_buf) busy_n[cur_buf] = 1'b0;
                end
                have_buf <= 1'b0;
                st       <= S_M0;
            end else if (rx_valid) begin
                case (st)
                    S_M0: if (rx_data == CH_O) st <= S_M1;
                    S_M1: st <= (rx_data == CH_M) ? S_M2 : (rx_data == CH_O) ? S_M1 : S_M0;
                    S_M2: st <= (rx_data == CH_N) ? S_TYPE : (rx_data == CH_O) ? S_M1 : S_M0;
                    S_TYPE: begin
                        crc <= 16'hFFFF;
                        if (rx_data == CH_I) begin
                            is_frame <= 1'b1;
                            st       <= S_SEQ0;
                            if (!busy_n[0]) begin
                                cur_buf <= 1'b0; have_buf <= 1'b1; busy_n[0] = 1'b1;
                            end else if (!busy_n[1]) begin
                                cur_buf <= 1'b1; have_buf <= 1'b1; busy_n[1] = 1'b1;
                            end else begin
                                have_buf <= 1'b0;     // both buffers in use: skip, NAK BUSY
                            end
                        end else if (rx_data == CH_C) begin
                            is_frame <= 1'b0;
                            have_buf <= 1'b0;
                            st       <= S_SEQ0;
                        end else begin
                            st <= (rx_data == CH_O) ? S_M1 : S_M0;
                        end
                    end
                    S_SEQ0: begin
                        seq[7:0] <= rx_data;
                        crc      <= crc_nx;
                        st       <= S_SEQ1;
                    end
                    S_SEQ1: begin
                        seq[15:8] <= rx_data;
                        crc       <= crc_nx;
                        cnt       <= 13'd0;
                        argn      <= 2'd0;
                        st        <= is_frame ? S_PAY : S_CMD;
                    end
                    S_PAY: begin
                        crc     <= crc_nx;
                        wr_en   <= have_buf;
                        wr_buf  <= cur_buf;
                        wr_addr <= cnt;
                        wr_data <= rx_data;
                        cnt     <= cnt + 13'd1;
                        if (cnt == NPIX - 1) st <= S_CRC0;
                    end
                    S_CRC0: begin
                        crc_lo <= rx_data;
                        st     <= S_CRC1;
                    end
                    S_CRC1: begin
                        st       <= S_M0;
                        have_buf <= 1'b0;
                        if ({rx_data, crc_lo} != crc) begin
                            frame_bad  <= 1'b1;
                            bad_reason <= NAK_CRC;
                            bad_seq    <= seq;
                            if (have_buf) busy_n[cur_buf] = 1'b0;
                        end else if (!have_buf) begin
                            frame_bad  <= 1'b1;
                            bad_reason <= NAK_BUSY;
                            bad_seq    <= seq;
                        end else begin
                            frame_ok  <= 1'b1;
                            frame_buf <= cur_buf;
                            frame_seq <= seq;
                        end
                    end
                    S_CMD: begin
                        code <= rx_data;
                        crc  <= crc_nx;
                        st   <= S_SUB;
                    end
                    S_SUB: begin
                        sub <= rx_data;
                        crc <= crc_nx;
                        st  <= S_ARG;
                    end
                    S_ARG: begin
                        arg  <= {rx_data, arg[31:8]};
                        crc  <= crc_nx;
                        argn <= argn + 2'd1;
                        if (argn == 2'd3) st <= S_CCRC0;
                    end
                    S_CCRC0: begin
                        crc_lo <= rx_data;
                        st     <= S_CCRC1;
                    end
                    S_CCRC1: begin
                        st <= S_M0;
                        if ({rx_data, crc_lo} == crc) begin
                            cmd_ok   <= 1'b1;
                            cmd_seq  <= seq;
                            cmd_code <= code;
                            cmd_sub  <= sub;
                            cmd_arg  <= arg;
                        end
                    end
                    default: st <= S_M0;
                endcase
            end
        end
        busy <= busy_n;
    end
endmodule


// =============================================================================
// Simple dual-port block RAM (1 write port, 1 registered read port, 1 clock
// read latency). Written in the pattern Gowin Synthesis maps to BSRAM (SDPB).
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
// Frame memories (all BSRAM):
//   g0, g1   two receive buffers (written by the packet parser, read by engine)
//   gp       previous gray frame (read and rewritten by the engine)
//   P sets   previous-frame P and current-frame P, ping-ponged by `pset`.
//            Each set is split into three banks by row (bank = y % 3, address
//            = (y/3)*80 + x), so rows y-1, y, y+1 always sit in different banks
//            and one clock fetches a whole 3-pixel column of the 3x3 window.
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
    input  wire        pset,          // 0: set A holds previous P (read), B is written
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

    sdp_ram #(.AW(13), .DEPTH(4800)) u_g0 (
        .clk(clk), .we(pk_we & ~pk_wbuf), .wa(pk_wa), .wd(pk_wd), .ra(g_ra), .rd(g0_rd));
    sdp_ram #(.AW(13), .DEPTH(4800)) u_g1 (
        .clk(clk), .we(pk_we &  pk_wbuf), .wa(pk_wa), .wd(pk_wd), .ra(g_ra), .rd(g1_rd));
    sdp_ram #(.AW(13), .DEPTH(4800)) u_gp (
        .clk(clk), .we(prev_we), .wa(prev_wa), .wd(prev_wd), .ra(g_ra), .rd(prev_rd));

    assign cur_rd = cur_sel ? g1_rd : g0_rd;

    wire [7:0] a_rd0, a_rd1, a_rd2, b_rd0, b_rd1, b_rd2;
    wire       we_a = p_we &  pset;   // writes go to the set that is not being read
    wire       we_b = p_we & ~pset;

    sdp_ram #(.AW(11), .DEPTH(1600)) u_pa0 (
        .clk(clk), .we(we_a & (p_wbank == 2'd0)), .wa(p_wa), .wd(p_wd), .ra(p_ra0), .rd(a_rd0));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pa1 (
        .clk(clk), .we(we_a & (p_wbank == 2'd1)), .wa(p_wa), .wd(p_wd), .ra(p_ra1), .rd(a_rd1));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pa2 (
        .clk(clk), .we(we_a & (p_wbank == 2'd2)), .wa(p_wa), .wd(p_wd), .ra(p_ra2), .rd(a_rd2));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pb0 (
        .clk(clk), .we(we_b & (p_wbank == 2'd0)), .wa(p_wa), .wd(p_wd), .ra(p_ra0), .rd(b_rd0));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pb1 (
        .clk(clk), .we(we_b & (p_wbank == 2'd1)), .wa(p_wa), .wd(p_wd), .ra(p_ra1), .rd(b_rd1));
    sdp_ram #(.AW(11), .DEPTH(1600)) u_pb2 (
        .clk(clk), .we(we_b & (p_wbank == 2'd2)), .wa(p_wa), .wd(p_wd), .ra(p_ra2), .rd(b_rd2));

    assign p_rd0 = pset ? b_rd0 : a_rd0;
    assign p_rd1 = pset ? b_rd1 : a_rd1;
    assign p_rd2 = pset ? b_rd2 : a_rd2;
endmodule


// =============================================================================
// LGMD engine: one pixel per clock, 4-stage pipeline.
//
//   P(x,y) = |cur(x,y) - prev(x,y)|
//   I(x,y) = (sum of the 8 neighbours of previous-frame P) >> 3   (outside = 0)
//   S(x,y) = max(P - (I >> 1), 0)
//   K = sum S (inside ROI),  F = sum P (whole frame)
//
// Stage 0  fetch column x+1 of previous P (rows y-1, y, y+1, one bank each)
//          and the cur/prev gray pixels at (x, y)
// Stage 1  BRAM data back: shift the 3x3 window (masked at the image edges)
// Stage 2  P, I, S for (x, y)
// Stage 3  write P (current P set) and cur (previous-gray buffer); add to K, F
//
// Each row issues W+1 fetches (one extra to bring in the right edge), so a
// frame takes 60 * 81 + 5 = 4865 clocks = 0.18 ms at 27 MHz.
//
// Warm-up: on the first frame after reset/clear prev is replaced by cur (P = 0);
// on the second frame previous P is treated as 0 (no inhibition yet). The
// detector ignores K until the third frame.
// =============================================================================
module lgmd_engine #(
    parameter integer W = 80,
    parameter integer H = 60
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        clear,
    input  wire [6:0]  roi_x0,
    input  wire [6:0]  roi_x1,
    input  wire [5:0]  roi_y0,
    input  wire [5:0]  roi_y1,
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
    output reg         pset,
    output reg         busy,
    output reg         done,
    output reg  [23:0] k_sum,
    output reg  [23:0] f_sum,
    output reg  [3:0]  frame_count   // frames processed since reset/clear (saturates at 15)
);
    // ---------------------------------------------------------------- stage 0: fetch
    reg        issuing = 1'b0;
    reg [5:0]  y    = 6'd0;
    reg [6:0]  j    = 7'd0;    // column being fetched, 0..W (W = one past the right edge)
    reg [1:0]  ym3  = 2'd0;    // y % 3   : bank holding row y
    reg [10:0] yb   = 11'd0;   // (y/3)*W : row y's base address inside its bank
    reg [12:0] grow = 13'd0;   // y*W     : row y's base address in the gray buffers
    reg        use_pg = 1'b0;  // previous gray frame is valid
    reg        use_pp = 1'b0;  // previous P frame is valid

    wire [1:0]  bank_bot = (ym3 == 2'd2) ? 2'd0 : ym3 + 2'd1;
    wire [10:0] base_top = (y == 6'd0)          ? 11'd0 : ((ym3 == 2'd0) ? yb - W : yb);
    wire [10:0] base_bot = (y == H - 1)         ? yb    : ((ym3 == 2'd2) ? yb + W : yb);
    wire [6:0]  jc       = (j == W) ? (W - 1) : j;
    wire [10:0] a_mid    = yb + jc;
    wire [10:0] a_top    = base_top + jc;
    wire [10:0] a_bot    = base_bot + jc;

    assign p_ra0 = (ym3 == 2'd0) ? a_mid : (bank_bot == 2'd0) ? a_bot : a_top;
    assign p_ra1 = (ym3 == 2'd1) ? a_mid : (bank_bot == 2'd1) ? a_bot : a_top;
    assign p_ra2 = (ym3 == 2'd2) ? a_mid : (bank_bot == 2'd2) ? a_bot : a_top;
    assign g_ra  = (j == 7'd0) ? grow : grow + j - 13'd1;     // centre pixel x = j - 1

    // ---------------------------------------------------------------- stage 1: window
    reg        s1_v = 1'b0;
    reg [6:0]  s1_j;
    reg [5:0]  s1_y;
    reg [1:0]  s1_ym3;
    reg [10:0] s1_yb;
    reg [12:0] s1_ga;
    reg        s1_tv, s1_mv, s1_bv;   // rows y-1 / y / y+1 exist (and previous P valid)

    function [7:0] pick;
        input [1:0] b;
        input [7:0] d0, d1, d2;
        pick = (b == 2'd0) ? d0 : (b == 2'd1) ? d1 : d2;
    endfunction

    wire [1:0] s1_bb = (s1_ym3 == 2'd2) ? 2'd0 : s1_ym3 + 2'd1;
    wire [1:0] s1_tb = (s1_ym3 == 2'd0) ? 2'd2 : s1_ym3 - 2'd1;
    wire       s1_cv = (s1_j != W);   // column inside the image
    wire [7:0] col_t = (s1_tv && s1_cv) ? pick(s1_tb,  p_rd0, p_rd1, p_rd2) : 8'd0;
    wire [7:0] col_m = (s1_mv && s1_cv) ? pick(s1_ym3, p_rd0, p_rd1, p_rd2) : 8'd0;
    wire [7:0] col_b = (s1_bv && s1_cv) ? pick(s1_bb,  p_rd0, p_rd1, p_rd2) : 8'd0;

    // 3x3 window of previous-frame P. l/c/r = columns x-1, x, x+1; t/m/b = rows y-1, y, y+1
    reg [7:0] wl_t, wl_m, wl_b, wc_t, wc_m, wc_b, wr_t, wr_m, wr_b;

    // ---------------------------------------------------------------- stage 2: pixel math
    reg        s2_v = 1'b0;
    reg [6:0]  s2_x;
    reg [5:0]  s2_y;
    reg [1:0]  s2_ym3;
    reg [10:0] s2_yb;
    reg [12:0] s2_ga;
    reg [7:0]  s2_cur, s2_prv;

    wire [10:0] i_sum  = wl_t + wl_m + wl_b + wc_t + wc_b + wr_t + wr_m + wr_b;
    wire [7:0]  i_val  = i_sum[10:3];
    wire [7:0]  i_half = {1'b0, i_val[7:1]};
    wire [7:0]  p_val  = (s2_cur >= s2_prv) ? (s2_cur - s2_prv) : (s2_prv - s2_cur);
    wire [7:0]  s_val  = (p_val > i_half) ? (p_val - i_half) : 8'd0;

    // ---------------------------------------------------------------- stage 3: write + accumulate
    reg        s3_v = 1'b0;
    reg        s3_last;
    reg [6:0]  s3_x;
    reg [5:0]  s3_y;
    reg [1:0]  s3_ym3;
    reg [10:0] s3_yb;
    reg [12:0] s3_ga;
    reg [7:0]  s3_cur, s3_p, s3_s;
    reg [23:0] k_acc = 24'd0;
    reg [23:0] f_acc = 24'd0;
    reg        fin   = 1'b0;

    wire s3_roi = (s3_x >= roi_x0) && (s3_x <= roi_x1) && (s3_y >= roi_y0) && (s3_y <= roi_y1);

    assign p_we    = s3_v;
    assign p_wbank = s3_ym3;
    assign p_wa    = s3_yb + s3_x;
    assign p_wd    = s3_p;
    assign prev_we = s3_v;
    assign prev_wa = s3_ga;
    assign prev_wd = s3_cur;

    initial begin
        pset = 1'b0; busy = 1'b0; done = 1'b0;
        k_sum = 24'd0; f_sum = 24'd0; frame_count = 4'd0;
    end

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            issuing <= 1'b0; busy <= 1'b0; pset <= 1'b0; frame_count <= 4'd0;
            s1_v <= 1'b0; s2_v <= 1'b0; s3_v <= 1'b0; fin <= 1'b0;
            k_acc <= 24'd0; f_acc <= 24'd0; k_sum <= 24'd0; f_sum <= 24'd0;
        end else begin
            if (clear && !busy) frame_count <= 4'd0;

            // stage 0
            if (start && !busy) begin
                busy    <= 1'b1;
                issuing <= 1'b1;
                y <= 6'd0; j <= 7'd0; ym3 <= 2'd0; yb <= 11'd0; grow <= 13'd0;
                use_pg  <= (frame_count != 4'd0);
                use_pp  <= (frame_count >= 4'd2);
                k_acc   <= 24'd0;
                f_acc   <= 24'd0;
            end else if (issuing) begin
                if (j == W) begin
                    j <= 7'd0;
                    if (y == H - 1) begin
                        issuing <= 1'b0;
                    end else begin
                        y    <= y + 6'd1;
                        grow <= grow + W;
                        if (ym3 == 2'd2) begin
                            ym3 <= 2'd0;
                            yb  <= yb + W;
                        end else begin
                            ym3 <= ym3 + 2'd1;
                        end
                    end
                end else begin
                    j <= j + 7'd1;
                end
            end

            s1_v   <= issuing;
            s1_j   <= j;
            s1_y   <= y;
            s1_ym3 <= ym3;
            s1_yb  <= yb;
            s1_ga  <= g_ra;
            s1_tv  <= use_pp && (y != 6'd0);
            s1_mv  <= use_pp;
            s1_bv  <= use_pp && (y != H - 1);

            // stage 1 -> 2
            if (s1_v) begin
                if (s1_j == 7'd0) begin         // new row: nothing left of column 0
                    wl_t <= 8'd0; wl_m <= 8'd0; wl_b <= 8'd0;
                    wc_t <= 8'd0; wc_m <= 8'd0; wc_b <= 8'd0;
                end else begin
                    wl_t <= wc_t; wl_m <= wc_m; wl_b <= wc_b;
                    wc_t <= wr_t; wc_m <= wr_m; wc_b <= wr_b;
                end
                wr_t <= col_t; wr_m <= col_m; wr_b <= col_b;
            end
            s2_v   <= s1_v && (s1_j != 7'd0);
            s2_x   <= s1_j - 7'd1;
            s2_y   <= s1_y;
            s2_ym3 <= s1_ym3;
            s2_yb  <= s1_yb;
            s2_ga  <= s1_ga;
            s2_cur <= cur_rd;
            s2_prv <= use_pg ? prev_rd : cur_rd;

            // stage 2 -> 3
            s3_v    <= s2_v;
            s3_last <= (s2_x == W - 1) && (s2_y == H - 1);
            s3_x    <= s2_x;
            s3_y    <= s2_y;
            s3_ym3  <= s2_ym3;
            s3_yb   <= s2_yb;
            s3_ga   <= s2_ga;
            s3_cur  <= s2_cur;
            s3_p    <= p_val;
            s3_s    <= s_val;

            // stage 3 (the BRAM writes are the assigns above)
            if (s3_v) begin
                f_acc <= f_acc + s3_p;
                if (s3_roi) k_acc <= k_acc + s3_s;
            end
            fin <= s3_v && s3_last;

            if (fin) begin
                done  <= 1'b1;
                busy  <= 1'b0;
                k_sum <= k_acc;
                f_sum <= f_acc;
                pset  <= ~pset;                 // this frame's P becomes "previous P"
                if (frame_count != 4'hF) frame_count <= frame_count + 4'd1;
            end
        end
    end
endmodule


// =============================================================================
// Collision decision, once per processed frame:
//   fire = K > T  &&  F < F_MAX  &&  K rose for RISE_FRAMES consecutive frames
// K only counts from the third frame after reset (earlier frames have no valid
// P / inhibition history). "Rose" means K > K_previous + rise_delta.
// =============================================================================
module collision_detector (
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,
    input  wire        frame_done,
    input  wire [23:0] k,
    input  wire [23:0] f,
    input  wire [3:0]  frame_count,   // including this frame
    input  wire [23:0] k_thr,
    input  wire [23:0] f_max,
    input  wire [3:0]  rise_n,
    input  wire [15:0] rise_delta,
    output reg         valid,
    output reg         fire,
    output reg         k_valid,
    output reg         f_supp,
    output reg         k_above,
    output reg  [3:0]  rise_cnt
);
    reg  [23:0] k_last = 24'd0;
    reg         hist_v = 1'b0;
    wire        rising  = hist_v && ({1'b0, k} > ({1'b0, k_last} + {9'd0, rise_delta}));
    wire [3:0]  rise_nx = rising ? ((rise_cnt == 4'hF) ? 4'hF : rise_cnt + 4'd1) : 4'd0;

    initial begin
        valid = 1'b0; fire = 1'b0; k_valid = 1'b0; f_supp = 1'b0; k_above = 1'b0; rise_cnt = 4'd0;
    end

    always @(posedge clk) begin
        valid <= 1'b0;
        if (rst || clear) begin
            hist_v <= 1'b0; k_last <= 24'd0; rise_cnt <= 4'd0;
            fire <= 1'b0; k_valid <= 1'b0; f_supp <= 1'b0; k_above <= 1'b0;
        end else if (frame_done) begin
            valid   <= 1'b1;
            f_supp  <= (f >= f_max);
            k_above <= (k > k_thr);
            if (frame_count < 4'd3) begin
                k_valid  <= 1'b0;
                hist_v   <= 1'b0;
                rise_cnt <= 4'd0;
                fire     <= 1'b0;
            end else begin
                k_valid  <= 1'b1;
                hist_v   <= 1'b1;
                k_last   <= k;
                rise_cnt <= rise_nx;
                fire     <= (k > k_thr) && (f < f_max) && (rise_nx >= rise_n);
            end
        end
    end
endmodule


// =============================================================================
// Response transmitter: ACK / NAK / command replies as 18-byte packets.
// One holding slot per type; replies first, then NAKs, then ACKs.
// `idle` = nothing queued and the last stop bit has left the pin.
// =============================================================================
module resp_tx #(
    parameter integer CLK_HZ = 27_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [21:0] baud,
    input  wire        ack_req,
    input  wire [15:0] ack_seq,
    input  wire [7:0]  ack_flags,
    input  wire [7:0]  ack_aux,
    input  wire [31:0] ack_w0,
    input  wire [31:0] ack_w1,
    input  wire        nak_req,
    input  wire [15:0] nak_seq,
    input  wire [7:0]  nak_flags,
    input  wire [7:0]  nak_aux,
    input  wire [31:0] nak_w0,
    input  wire [31:0] nak_w1,
    input  wire        rep_req,
    input  wire [15:0] rep_seq,
    input  wire [7:0]  rep_flags,
    input  wire [7:0]  rep_aux,
    input  wire [31:0] rep_w0,
    input  wire [31:0] rep_w1,
    output wire        tx,
    output wire        idle
);
    reg        a_p = 1'b0, n_p = 1'b0, r_p = 1'b0;
    reg [15:0] a_seq, n_seq, r_seq;
    reg [7:0]  a_fl, a_ax, n_fl, n_ax, r_fl, r_ax;
    reg [31:0] a_w0, a_w1, n_w0, n_w1, r_w0, r_w1;

    reg        sending = 1'b0;
    reg [4:0]  idx = 5'd0;
    reg [7:0]  p_type;
    reg [15:0] p_seq;
    reg [7:0]  p_fl, p_ax;
    reg [31:0] p_w0, p_w1;
    reg [15:0] crc = 16'hFFFF;

    reg        tx_start = 1'b0;
    reg [7:0]  tx_byte  = 8'hFF;
    wire       tx_busy;

    uart_tx #(.CLK_HZ(CLK_HZ)) u_uart_tx (
        .clk(clk), .rst(rst), .baud(baud),
        .start(tx_start), .data(tx_byte), .tx(tx), .busy(tx_busy)
    );

    reg [7:0] cur_byte;
    always @(*) begin
        case (idx)
            5'd0:  cur_byte = 8'h4F;          // 'O'
            5'd1:  cur_byte = 8'h4D;          // 'M'
            5'd2:  cur_byte = 8'h4E;          // 'N'
            5'd3:  cur_byte = p_type;
            5'd4:  cur_byte = p_seq[7:0];
            5'd5:  cur_byte = p_seq[15:8];
            5'd6:  cur_byte = p_fl;
            5'd7:  cur_byte = p_ax;
            5'd8:  cur_byte = p_w0[7:0];
            5'd9:  cur_byte = p_w0[15:8];
            5'd10: cur_byte = p_w0[23:16];
            5'd11: cur_byte = p_w0[31:24];
            5'd12: cur_byte = p_w1[7:0];
            5'd13: cur_byte = p_w1[15:8];
            5'd14: cur_byte = p_w1[23:16];
            5'd15: cur_byte = p_w1[31:24];
            5'd16: cur_byte = crc[7:0];
            5'd17: cur_byte = crc[15:8];
            default: cur_byte = 8'h00;
        endcase
    end

    wire [15:0] crc_nx;
    crc16_ccitt_byte u_crc (.crc_in(crc), .d(cur_byte), .crc_out(crc_nx));

    assign idle = !sending && !tx_busy && !tx_start && !a_p && !n_p && !r_p &&
                  !ack_req && !nak_req && !rep_req;

    always @(posedge clk) begin
        tx_start <= 1'b0;
        if (rst) begin
            a_p <= 1'b0; n_p <= 1'b0; r_p <= 1'b0; sending <= 1'b0; idx <= 5'd0;
        end else begin
            if (!sending) begin
                if (r_p) begin
                    r_p <= 1'b0; sending <= 1'b1; idx <= 5'd0; crc <= 16'hFFFF;
                    p_type <= 8'h52;   // 'R'
                    p_seq <= r_seq; p_fl <= r_fl; p_ax <= r_ax; p_w0 <= r_w0; p_w1 <= r_w1;
                end else if (n_p) begin
                    n_p <= 1'b0; sending <= 1'b1; idx <= 5'd0; crc <= 16'hFFFF;
                    p_type <= 8'h4E;   // 'N'
                    p_seq <= n_seq; p_fl <= n_fl; p_ax <= n_ax; p_w0 <= n_w0; p_w1 <= n_w1;
                end else if (a_p) begin
                    a_p <= 1'b0; sending <= 1'b1; idx <= 5'd0; crc <= 16'hFFFF;
                    p_type <= 8'h41;   // 'A'
                    p_seq <= a_seq; p_fl <= a_fl; p_ax <= a_ax; p_w0 <= a_w0; p_w1 <= a_w1;
                end
            end else if (!tx_busy && !tx_start) begin
                tx_byte  <= cur_byte;
                tx_start <= 1'b1;
                if (idx >= 5'd4 && idx <= 5'd15) crc <= crc_nx;
                if (idx == 5'd17) sending <= 1'b0;
                idx <= idx + 5'd1;
            end

            // capture new requests last, so one arriving while its slot is being
            // emptied is kept
            if (ack_req) begin
                a_p <= 1'b1; a_seq <= ack_seq; a_fl <= ack_flags; a_ax <= ack_aux; a_w0 <= ack_w0; a_w1 <= ack_w1;
            end
            if (nak_req) begin
                n_p <= 1'b1; n_seq <= nak_seq; n_fl <= nak_flags; n_ax <= nak_aux; n_w0 <= nak_w0; n_w1 <= nak_w1;
            end
            if (rep_req) begin
                r_p <= 1'b1; r_seq <= rep_seq; r_fl <= rep_flags; r_ax <= rep_aux; r_w0 <= rep_w0; r_w1 <= rep_w1;
            end
        end
    end
endmodule


// =============================================================================
// LEDs (active low). All timing from the 27 MHz clock.
// =============================================================================
module led_driver #(
    parameter integer CLK_HZ = 27_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       frame_pulse,
    input  wire       fire_pulse,
    input  wire       err_pulse,
    output wire [5:0] led
);
    localparam integer HB_HALF    = CLK_HZ / 2;    // 1 Hz heartbeat
    localparam integer FRAME_ON   = CLK_HZ / 40;   // 25 ms per good frame
    localparam integer FIRE_ON    = CLK_HZ;        // blink for 1 s after the last fire
    localparam integer BLINK_HALF = CLK_HZ / 16;   // 8 Hz blink
    localparam integer ERR_ON     = CLK_HZ / 4;    // 250 ms per error

    reg [24:0] hb_cnt    = 25'd0;
    reg        hb        = 1'b0;
    reg [24:0] fr_cnt    = 25'd0;
    reg [24:0] fire_cnt  = 25'd0;
    reg [24:0] blink_cnt = 25'd0;
    reg        blink     = 1'b0;
    reg [24:0] err_cnt   = 25'd0;

    always @(posedge clk) begin
        if (rst) begin
            hb_cnt <= 25'd0; hb <= 1'b0; fr_cnt <= 25'd0; fire_cnt <= 25'd0;
            blink_cnt <= 25'd0; blink <= 1'b0; err_cnt <= 25'd0;
        end else begin
            if (hb_cnt == HB_HALF - 1) begin
                hb_cnt <= 25'd0;
                hb     <= ~hb;
            end else begin
                hb_cnt <= hb_cnt + 25'd1;
            end

            if (frame_pulse)          fr_cnt <= FRAME_ON;
            else if (fr_cnt != 25'd0) fr_cnt <= fr_cnt - 25'd1;

            if (err_pulse)             err_cnt <= ERR_ON;
            else if (err_cnt != 25'd0) err_cnt <= err_cnt - 25'd1;

            if (fire_pulse) begin
                fire_cnt <= FIRE_ON;
                if (fire_cnt == 25'd0) begin    // start a fresh blink pattern only if idle
                    blink     <= 1'b1;
                    blink_cnt <= 25'd0;
                end
            end else if (fire_cnt != 25'd0) begin
                fire_cnt <= fire_cnt - 25'd1;
            end

            if (fire_cnt != 25'd0) begin
                if (blink_cnt == BLINK_HALF - 1) begin
                    blink_cnt <= 25'd0;
                    blink     <= ~blink;
                end else begin
                    blink_cnt <= blink_cnt + 25'd1;
                end
            end
        end
    end

    //            LED5  LED4  LED3            LED2                         LED1              LED0
    assign led = ~{1'b0, 1'b0, err_cnt != 25'd0, (fire_cnt != 25'd0) & blink, fr_cnt != 25'd0, hb};
endmodule

`default_nettype wire
