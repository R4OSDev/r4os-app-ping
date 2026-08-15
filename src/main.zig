const r4os = @import("r4os");

const ICMP_PROTOCOL: u8 = 1;
const ICMP_ECHO_REPLY: u8 = 0;
const ICMP_ECHO_REQUEST: u8 = 8;
const DEFAULT_COUNT: u32 = 3;
const PING_TIMEOUT_MS: u64 = 4000;
const PING_DELAY_MS: u64 = 1000;
const PING_DRAIN_LIMIT: u32 = 16;
const PING_RECV_BUDGET: u32 = 16;
const PING_EMPTY_SPINS_BEFORE_SLEEP: u32 = 4;
const CTRL_C: u8 = 0x03;

const PingOptions = struct {
    target: [4]u8,
    target_name: []const u8,
    resolved_name: bool,
    continuous: bool,
};

const PingStats = struct {
    sent: u32 = 0,
    received: u32 = 0,
    drained: u32 = 0,
    ignored: u32 = 0,
    late: u32 = 0,
};

const PingAttemptResult = enum {
    reply,
    timeout,
    tx_error,
    aborted,
};

const App = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }

    fn argsRaw(self: *const App) [*:0]const u8 {
        return self.sys.argsRaw();
    }

    fn write(self: *const App, value: []const u8) void {
        self.sys.write(value);
    }

    fn println(self: *const App, value: []const u8) void {
        self.sys.println(value);
    }

    fn putc(self: *const App, ch: u8) void {
        self.sys.putc(ch);
    }

    fn printU64(self: *const App, value: u64) void {
        self.sys.printU64(value);
    }

    fn ticks(self: *const App) u64 {
        return self.sys.ticks();
    }

    fn sleepTicks(self: *const App, duration: u64) void {
        self.sys.sleepTicks(duration);
    }

    fn taskYield(self: *const App) void {
        self.sys.taskYield();
    }

    fn monotonicHz(self: *const App) u32 {
        return self.sys.monotonicHz();
    }

    fn programShouldClose(self: *const App) bool {
        return self.sys.programShouldClose();
    }

    fn readKey(self: *const App) u8 {
        return self.desk.readKey();
    }

    fn netResolveA(self: *const App, name_value: []const u8, options: r4os.r4net.ResolverOptions, out: *r4os.r4net.ResolverResult) i32 {
        return self.net.netResolveA(name_value, options, out);
    }

    fn netDnsResultName(self: *const App, result: i32) []const u8 {
        return self.net.netDnsResultName(result);
    }

    fn netIpv4Send(self: *const App, a: u8, b: u8, c: u8, d: u8, protocol_id: u8, payload: []const u8) i32 {
        return self.net.netIpv4Send(a, b, c, d, protocol_id, payload);
    }

    fn netIpv4Recv(self: *const App, protocol_id: u8, out: *r4os.abi.NetIpv4Packet, payload: []u8) i32 {
        return self.net.netIpv4Recv(protocol_id, out, payload);
    }

    fn netTxResultName(self: *const App, result: i32) []const u8 {
        return self.net.netTxResultName(result);
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    const ctx = App.init(r4_app) orelse return r4os.abi.err_no_group;
    const options = parseOptions(&ctx, trim(zSlice(ctx.argsRaw()))) orelse {
        usage(&ctx);
        return 1;
    };

    if (options.resolved_name) {
        ctx.write("Resolved ");
        ctx.write(options.target_name);
        ctx.write(" to ");
        writeIpv4(&ctx, options.target);
        ctx.write("\r\n");
    }

    ctx.write("Pinging ");
    writeIpv4(&ctx, options.target);
    ctx.write(" with 16 bytes of data:\r\n");

    var stats = PingStats{};
    stats.drained += drainIcmpQueue(&ctx);
    var request_buf: [32]u8 = .{0} ** 32;
    const ident = makeIdent(options.target, ctx.ticks());
    var sequence_counter: u32 = 0;
    var aborted = false;

    while (options.continuous or sequence_counter < DEFAULT_COUNT) {
        sequence_counter += 1;
        const seq = makeSeq(sequence_counter);

        const attempt = pingOnce(&ctx, options.target, ident, seq, request_buf[0..], &stats);
        if (attempt == .aborted) {
            aborted = true;
            break;
        }

        if (!options.continuous and sequence_counter >= DEFAULT_COUNT) break;
        if (waitOrAbort(&ctx, msToTicks(&ctx, PING_DELAY_MS), options.target, ident, &stats)) {
            aborted = true;
            break;
        }
    }

    if (aborted) {
        ctx.write("^C\r\n");
    }

    printStats(&ctx, options.target, stats);
    if (aborted) return 0;
    return if (stats.sent != 0 and stats.received == stats.sent) 0 else 1;
}

fn usage(ctx: *const App) void {
    ctx.println("Usage: PING [-t] a.b.c.d|hostname");
}

fn parseOptions(ctx: *const App, args: []const u8) ?PingOptions {
    var rest = trim(args);
    var options = PingOptions{ .target = .{ 0, 0, 0, 0 }, .target_name = "", .resolved_name = false, .continuous = false };
    var have_target = false;

    while (rest.len != 0) {
        const split = firstSpace(rest) orelse rest.len;
        const token = rest[0..split];

        if (equalsIgnoreCase(token, "-t")) {
            if (options.continuous) return null;
            options.continuous = true;
        } else {
            if (have_target) return null;
            if (parseIpv4(token)) |ip| {
                options.target = ip;
            } else {
                var resolved: r4os.r4net.ResolverResult = .{};
                const result = ctx.netResolveA(token, .{}, &resolved);
                if (result != r4os.abi.dns_result_ok) {
                    ctx.write("DNS resolve failed for ");
                    ctx.write(token);
                    ctx.write(": ");
                    ctx.write(ctx.netDnsResultName(result));
                    ctx.write("\r\n");
                    return null;
                }
                options.target = resolved.answer;
                options.target_name = token;
                options.resolved_name = true;
            }
            have_target = true;
        }

        rest = if (split >= rest.len) "" else trim(rest[split..]);
    }

    if (!have_target) return null;
    return options;
}

fn pingOnce(
    ctx: *const App,
    target: [4]u8,
    ident: u16,
    seq: u16,
    request_buf: []u8,
    stats: *PingStats,
) PingAttemptResult {
    const request = buildEchoRequest(request_buf, ident, seq) orelse {
        ctx.println("build-failed");
        return .tx_error;
    };

    stats.sent += 1;
    const result = ctx.netIpv4Send(target[0], target[1], target[2], target[3], ICMP_PROTOCOL, request);
    if (result != r4os.abi.net_tx_ok) {
        ctx.write("Transmit failed: ");
        ctx.write(ctx.netTxResultName(result));
        ctx.write(" seq=");
        ctx.printU64(seq);
        ctx.write("\r\n");
        return .tx_error;
    }

    const wait_ticks = msToTicks(ctx, PING_TIMEOUT_MS);
    const wait_start = ctx.ticks();
    var reply_buf: [128]u8 = .{0} ** 128;
    var empty_spins: u32 = 0;
    while (ctx.ticks() - wait_start < wait_ticks) {
        if (checkAbort(ctx)) return .aborted;

        const poll_result = pollForReply(ctx, target, ident, seq, wait_start, reply_buf[0..], stats);
        if (poll_result != null) return poll_result.?;

        empty_spins += 1;
        if (empty_spins >= PING_EMPTY_SPINS_BEFORE_SLEEP) {
            empty_spins = 0;
            ctx.sleepTicks(1);
        } else {
            ctx.taskYield();
        }
    }

    ctx.write("Request timed out. seq=");
    ctx.printU64(seq);
    ctx.write("\r\n");
    return .timeout;
}

fn pollForReply(
    ctx: *const App,
    target: [4]u8,
    ident: u16,
    current_seq: u16,
    wait_start: u64,
    reply_buf: []u8,
    stats: *PingStats,
) ?PingAttemptResult {
    var polled: u32 = 0;
    while (polled < PING_RECV_BUDGET) : (polled += 1) {
        var packet: r4os.abi.NetIpv4Packet = .{};
        const got = ctx.netIpv4Recv(ICMP_PROTOCOL, &packet, reply_buf);
        if (got <= 0) return null;

        const reply_len: usize = @intCast(got);
        if (!sameIpv4(packet.source_ip, target)) {
            stats.ignored += 1;
            continue;
        }

        const reply_seq = echoReplySeq(reply_buf[0..reply_len], ident) orelse {
            stats.ignored += 1;
            continue;
        };

        if (reply_seq == current_seq) {
            const elapsed_ms = ticksToMs(ctx, ctx.ticks() - wait_start);
            stats.received += 1;
            ctx.write("Reply from ");
            writeIpv4(ctx, packet.source_ip);
            ctx.write(": bytes=");
            ctx.printU64(@intCast(reply_len));
            ctx.write(" time=");
            ctx.printU64(elapsed_ms);
            ctx.write("ms seq=");
            ctx.printU64(reply_seq);
            ctx.write("\r\n");
            return .reply;
        }

        stats.late += 1;
        ctx.write("Late reply from ");
        writeIpv4(ctx, packet.source_ip);
        ctx.write(": bytes=");
        ctx.printU64(@intCast(reply_len));
        ctx.write(" seq=");
        ctx.printU64(reply_seq);
        ctx.write("\r\n");
    }
    return null;
}

fn printStats(ctx: *const App, target: [4]u8, stats: PingStats) void {
    const lost = if (stats.sent > stats.received) stats.sent - stats.received else 0;
    const loss_pct: u32 = if (stats.sent == 0) 0 else (lost * 100) / stats.sent;

    ctx.write("\r\nPing statistics for ");
    writeIpv4(ctx, target);
    ctx.write(":\r\n");
    ctx.write("    Packets: Sent = ");
    ctx.printU64(stats.sent);
    ctx.write(", Received = ");
    ctx.printU64(stats.received);
    ctx.write(", Lost = ");
    ctx.printU64(lost);
    ctx.write(" (");
    ctx.printU64(loss_pct);
    ctx.write("% loss)\r\n");
    if (stats.ignored != 0 or stats.drained != 0 or stats.late != 0) {
        ctx.write("    Debug: ignored=");
        ctx.printU64(stats.ignored);
        ctx.write(" drained=");
        ctx.printU64(stats.drained);
        ctx.write(" late=");
        ctx.printU64(stats.late);
        ctx.write("\r\n");
    }
}

fn waitOrAbort(
    ctx: *const App,
    ticks: u64,
    target: [4]u8,
    ident: u16,
    stats: *PingStats,
) bool {
    const started = ctx.ticks();
    var reply_buf: [128]u8 = .{0} ** 128;
    while (ctx.ticks() - started < ticks) {
        if (checkAbort(ctx)) return true;
        _ = pollForReply(ctx, target, ident, 0, started, reply_buf[0..], stats);
        ctx.sleepTicks(1);
    }
    return false;
}

fn checkAbort(ctx: *const App) bool {
    if (ctx.programShouldClose()) return true;
    return ctx.readKey() == CTRL_C;
}

fn parseIpv4(value: []const u8) ?[4]u8 {
    var out: [4]u8 = .{0} ** 4;
    var part: usize = 0;
    var accum: u16 = 0;
    var digits: usize = 0;

    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const ch = value[index];
        if (ch >= '0' and ch <= '9') {
            accum = accum * 10 + @as(u16, ch - '0');
            if (accum > 255) return null;
            digits += 1;
            if (digits > 3) return null;
        } else if (ch == '.') {
            if (digits == 0 or part >= 3) return null;
            out[part] = @intCast(accum);
            part += 1;
            accum = 0;
            digits = 0;
        } else {
            return null;
        }
    }

    if (digits == 0 or part != 3) return null;
    out[part] = @intCast(accum);
    return out;
}

fn writeIpv4(ctx: *const App, ip: [4]u8) void {
    ctx.printU64(ip[0]);
    ctx.putc('.');
    ctx.printU64(ip[1]);
    ctx.putc('.');
    ctx.printU64(ip[2]);
    ctx.putc('.');
    ctx.printU64(ip[3]);
}

fn drainIcmpQueue(ctx: *const App) u32 {
    var drained: u32 = 0;
    while (drained < PING_DRAIN_LIMIT) : (drained += 1) {
        var packet: r4os.abi.NetIpv4Packet = .{};
        var buf: [128]u8 = .{0} ** 128;
        const got = ctx.netIpv4Recv(ICMP_PROTOCOL, &packet, buf[0..]);
        if (got <= 0) return drained;
    }
    return drained;
}

fn buildEchoRequest(out: []u8, ident: u16, seq: u16) ?[]const u8 {
    const data = "R4OSPING";
    const len = 8 + data.len;
    if (out.len < len) return null;
    var index: usize = 0;
    while (index < len) : (index += 1) out[index] = 0;
    out[0] = ICMP_ECHO_REQUEST;
    out[1] = 0;
    writeBe16(out, 4, ident);
    writeBe16(out, 6, seq);
    index = 0;
    while (index < data.len) : (index += 1) out[8 + index] = data[index];
    writeBe16(out, 2, checksum(out[0..len]));
    return out[0..len];
}

fn isEchoReply(data: []const u8, ident: u16, seq: u16) bool {
    const reply_seq = echoReplySeq(data, ident) orelse return false;
    return reply_seq == seq;
}

fn echoReplySeq(data: []const u8, ident: u16) ?u16 {
    if (data.len < 8) return null;
    if (data[0] != ICMP_ECHO_REPLY or data[1] != 0) return null;
    if (checksum(data) != 0) return null;
    if (readBe16(data, 4) != ident) return null;
    return readBe16(data, 6);
}

fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var index: usize = 0;
    while (index + 1 < data.len) : (index += 2) {
        sum += (@as(u32, data[index]) << 8) | data[index + 1];
    }
    if (index < data.len) sum += @as(u32, data[index]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @intCast(~sum & 0xFFFF);
}

fn readBe16(buf: []const u8, offset: usize) u16 {
    return (@as(u16, buf[offset]) << 8) | buf[offset + 1];
}

fn writeBe16(buf: []u8, offset: usize, value: u16) void {
    buf[offset] = @intCast(value >> 8);
    buf[offset + 1] = @intCast(value & 0xFF);
}

fn sameIpv4(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn makeIdent(target: [4]u8, ticks: u64) u16 {
    var value: u32 = 0x5234;
    value ^= @as(u32, target[0]) << 24;
    value ^= @as(u32, target[1]) << 16;
    value ^= @as(u32, target[2]) << 8;
    value ^= @as(u32, target[3]);
    value ^= @as(u32, @truncate(ticks));
    value ^= @as(u32, @truncate(ticks >> 32));
    value ^= value >> 16;
    const ident: u16 = @truncate(value);
    return if (ident == 0) 0x5234 else ident;
}

fn makeSeq(counter: u32) u16 {
    const seq: u16 = @truncate(counter);
    return if (seq == 0) 1 else seq;
}

fn msToTicks(ctx: *const App, ms: u64) u64 {
    const hz_raw = ctx.monotonicHz();
    const hz: u64 = if (hz_raw == 0) 100 else hz_raw;
    const ticks = (ms * hz + 999) / 1000;
    return if (ticks == 0) 1 else ticks;
}

fn ticksToMs(ctx: *const App, ticks: u64) u64 {
    const hz_raw = ctx.monotonicHz();
    const hz: u64 = if (hz_raw == 0) 100 else hz_raw;
    return (ticks * 1000 + hz / 2) / hz;
}

fn zSlice(value: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn firstSpace(value: []const u8) ?usize {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (isSpace(value[index])) return index;
    }
    return null;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (upperAscii(a[index]) != upperAscii(b[index])) return false;
    }
    return true;
}

fn upperAscii(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}
