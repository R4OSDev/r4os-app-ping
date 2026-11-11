const std = @import("std");
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
    target: r4os.abi.NetworkAddress,
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
    clock_error,
    input_error,
};

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,
    dev: r4os.r4dev.Context,
    app: *r4os.App2,
    clock: r4os.rpc_budget.Clock,
    sample: ?r4os.time_contract.checked.ClockSample = null,

    fn init(r4_app: *r4os.App2) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
            .dev = r4_app.devicesLowLevel() orelse return null,
            .app = r4_app,
            .clock = (r4_app.clock() catch return null).read,
        };
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

    fn sleepTicks(self: *const App, duration: u64) void {
        self.sys.sleepTicks(duration);
    }

    fn taskYield(self: *const App) void {
        self.sys.taskYield();
    }

    fn programShouldClose(self: *const App) bool {
        return self.sys.programShouldClose();
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

pub fn r4_app_main(r4_app: *r4os.App2) i32 {
    var ctx = App.init(r4_app) orelse return r4os.abi.err_no_group;
    const options = parseOptions(&ctx, r4_app.args()) orelse {
        ctx.println("Usage: PING [-t] [-4|-6] address|hostname");
        ctx.println("Link-local IPv6 requires address%numeric-interface.");
        return 1;
    };
    if (options.resolved_name) {
        ctx.write("Resolved ");
        ctx.write(options.target_name);
        ctx.write(" to ");
        writeAddress(&ctx, options.target);
        ctx.write("\r\n");
    }
    ctx.write("Pinging ");
    writeAddress(&ctx, options.target);
    ctx.write(" with 16 bytes of data:\r\n");
    var stats: PingStats = .{};
    var request_buf: [32]u8 = .{0} ** 32;
    const start = checkedNow(&ctx) catch {
        ctx.println("PING clock unavailable");
        return 1;
    };
    const ident = makeIdent(options.target.bytes[0..4].*, start.instant_ns);
    var ipv6: r4os.network_family.Ipv6 = undefined;
    var prepared: r4os.abi.Ipv6Packet = .{};
    if (options.target.family == 6) {
        var budget = operationBudget(&ctx, PING_TIMEOUT_MS) catch return 1;
        const rc = selectIpv6(&ctx, options.target, &budget, &ipv6, &prepared);
        if (rc != 0) {
            ctx.write("IPv6 route/provider unavailable, code=");
            ctx.sys.printI32(rc);
            ctx.write("\r\n");
            return 1;
        }
    } else stats.drained = drainIcmpQueue(&ctx);
    var sequence_counter: u32 = 0;
    var aborted = false;
    while (options.continuous or sequence_counter < DEFAULT_COUNT) {
        sequence_counter +%= 1;
        const seq = makeSeq(sequence_counter);
        const attempt = if (options.target.family == 6)
            pingIpv6(&ctx, &ipv6, prepared, ident, seq, &stats)
        else
            pingOnce(&ctx, options.target.bytes[0..4].*, ident, seq, &request_buf, &stats);
        if (attempt == .input_error) {
            ctx.println("PING console input unavailable");
            return 1;
        }
        if (attempt == .clock_error) {
            ctx.println("PING clock/budget failure");
            return 1;
        }
        if (attempt == .aborted) {
            aborted = true;
            break;
        }
        if (!options.continuous and sequence_counter >= DEFAULT_COUNT) break;
        if (waitOrAbort(&ctx, PING_DELAY_MS, options.target, ident, &stats) catch |err| {
            ctx.println(if (err == error.Input) "PING console input unavailable" else "PING clock/budget failure");
            return 1;
        }) {
            aborted = true;
            break;
        }
    }
    if (aborted) ctx.write("^C\r\n");
    printStats(&ctx, options.target, stats);
    if (aborted) return 0;
    return if (stats.sent != 0 and stats.received == stats.sent) 0 else 1;
}

fn parseOptions(ctx: *const App, raw: []const u8) ?PingOptions {
    var detail: r4os.arguments.Failure = .{};
    var cursor = r4os.arguments.ArgCursor.init(raw, .{ .switches = r4os.arguments.dash }, &detail) catch return null;
    var options: PingOptions = .{ .target = .{}, .target_name = "", .resolved_name = false, .continuous = false };
    var family: u32 = 0;
    while (cursor.next() catch return null) |token| {
        const value = token.bytes(raw) catch return null;
        if (token.switch_prefix != 0) {
            if (std.ascii.eqlIgnoreCase(value, "-t")) {
                if (options.continuous) return null;
                options.continuous = true;
            } else if (std.ascii.eqlIgnoreCase(value, "-4") or std.ascii.eqlIgnoreCase(value, "-6")) {
                if (family != 0) return null;
                family = if (value[1] == '4') 4 else 6;
            } else return null;
        } else {
            if (options.target_name.len != 0 or value.len == 0) return null;
            options.target_name = value;
        }
    }
    if (options.target_name.len == 0) return null;
    if (r4os.network_family.parseAddress(options.target_name)) |address| {
        if (family != 0 and family != address.family) return null;
        options.target = address;
        return options;
    }
    if (std.mem.indexOfScalar(u8, options.target_name, ':') != null or std.mem.indexOfScalar(u8, options.target_name, '%') != null) return null;
    const clock = ctx.app.clock() catch return null;
    var budget = r4os.rpc_budget.Budget.fromTimeout(clock.read, .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = 5_000_000_000 }) catch return null;
    var client: r4os.network_family.Client = undefined;
    const opened = ctx.app.networkFamily(.dns, &client);
    if (opened != 0) {
        ctx.println("DNS service unavailable");
        return null;
    }
    var answers: [32]r4os.abi.NetworkResolveAnswer = undefined;
    var count: u32 = 0;
    const rc = r4os.network_family.resolveAll(&client, options.target_name, if (family == 0) 4 else family, .{}, &budget, &answers, &count);
    const closed = client.close();
    if (rc != 0 or closed < 0) {
        ctx.write("DNS resolve failed for ");
        ctx.write(options.target_name);
        ctx.write(" code=");
        ctx.sys.printI32(if (rc != 0) rc else closed);
        ctx.write("\r\n");
        return null;
    }
    options.target = answers[0].address;
    if (options.target.family == 6 and r4os.network_family.linkLocal(options.target.bytes) and options.target.scope_id == 0) {
        ctx.println("DNS link-local address has no interface scope");
        return null;
    }
    options.resolved_name = true;
    return options;
}

fn checkedNow(ctx: *App) r4os.network_family.common.Error!r4os.time_contract.checked.ClockSample {
    const now = try r4os.network_family.common.sample(ctx.sys);
    if (ctx.sample) |before| {
        if (!std.meta.eql(now.identity, before.identity) or now.instant_ns < before.instant_ns) return error.ClockChanged;
    }
    ctx.sample = now;
    return now;
}

fn operationBudget(ctx: *App, milliseconds: u64) r4os.rpc_budget.Error!r4os.rpc_budget.Budget {
    _ = checkedNow(ctx) catch return error.ClockChanged;
    return r4os.rpc_budget.Budget.fromTimeout(ctx.clock, .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = milliseconds * 1_000_000 });
}

fn pingOnce(
    ctx: *App,
    target: [4]u8,
    ident: u16,
    seq: u16,
    request_buf: []u8,
    stats: *PingStats,
) PingAttemptResult {
    var budget = operationBudget(ctx, PING_TIMEOUT_MS) catch return .clock_error;
    const wait_start = (checkedNow(ctx) catch return .clock_error).instant_ns;
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

    var reply_buf: [128]u8 = .{0} ** 128;
    var empty_spins: u32 = 0;
    while (true) {
        _ = budget.remainingTicks() catch |err| {
            if (err != error.TimedOut) return .clock_error;
            break;
        };
        if (checkAbort(ctx) catch return .input_error) return .aborted;

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
    ctx: *App,
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
        if (got < 0 or got > reply_buf.len) return .tx_error;
        if (got == 0) return null;

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
            const now = checkedNow(ctx) catch return .clock_error;
            const elapsed_ms = (now.instant_ns - wait_start) / 1_000_000;
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

fn printStats(ctx: *const App, target: r4os.abi.NetworkAddress, stats: PingStats) void {
    const lost = if (stats.sent > stats.received) stats.sent - stats.received else 0;
    const loss_pct: u64 = if (stats.sent == 0) 0 else (@as(u64, lost) * 100) / stats.sent;

    ctx.write("\r\nPing statistics for ");
    writeAddress(ctx, target);
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

fn waitOrAbort(ctx: *App, milliseconds: u64, target: r4os.abi.NetworkAddress, ident: u16, stats: *PingStats) (r4os.rpc_budget.Error || error{Input})!bool {
    var budget = try operationBudget(ctx, milliseconds);
    const started = (checkedNow(ctx) catch return error.ClockChanged).instant_ns;
    var reply_buf: [128]u8 = undefined;
    while (true) {
        _ = budget.remainingTicks() catch |err| {
            if (err == error.TimedOut) return false;
            return err;
        };
        if (try checkAbort(ctx)) return true;
        if (target.family == 4) {
            if (pollForReply(ctx, target.bytes[0..4].*, ident, 0, started, &reply_buf, stats) == .clock_error) return error.ClockChanged;
        }
        ctx.sleepTicks(1);
    }
}

fn checkAbort(ctx: *const App) error{Input}!bool {
    if (ctx.programShouldClose()) return true;
    var events: [16]r4os.abi.ConsoleInputEvent = undefined;
    const got = ctx.sys.consoleReadEvents(&events);
    if (got < 0 or got > events.len) return error.Input;
    for (events[0..@intCast(got)]) |event| {
        if (event.version != 1 or event.flags != 0) return error.Input;
        if ((event.kind == r4os.abi.console_input_event_text or event.kind == r4os.abi.console_input_event_utf8_byte) and event.value == CTRL_C) return true;
    }
    return false;
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

fn echoReplySeq(data: []const u8, ident: u16) ?u16 {
    if (data.len != 16 or !std.mem.eql(u8, data[8..], "R4OSPING")) return null;
    if (data[0] != ICMP_ECHO_REPLY or data[1] != 0) return null;
    if (checksum(data) != 0) return null;
    if (readBe16(data, 4) != ident) return null;
    return readBe16(data, 6);
}

fn checksum(data: []const u8) u16 {
    var state: r4os.internet_checksum.Checksum16 = .{};
    state.add(data) catch unreachable;
    return state.finish() catch unreachable;
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

fn writeAddress(ctx: *const App, address: r4os.abi.NetworkAddress) void {
    var buffer: [80]u8 = undefined;
    ctx.write(r4os.network_family.addressText(&buffer, address) catch "unknown");
}

fn prefixMatches(address: [16]u8, prefix: [16]u8, bits: u32) bool {
    if (bits > 128) return false;
    const whole = bits / 8;
    if (!std.mem.eql(u8, address[0..whole], prefix[0..whole])) return false;
    const tail: u3 = @intCast(bits % 8);
    if (tail == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @as(u3, @intCast(8 - @as(u4, tail)));
    return address[whole] & mask == prefix[whole] & mask;
}

fn selectIpv6(ctx: *App, target: r4os.abi.NetworkAddress, budget: *r4os.rpc_budget.Budget, selected: *r4os.network_family.Ipv6, prepared: *r4os.abi.Ipv6Packet) i32 {
    const a = r4os.abi;
    var snapshot: a.NetConfigSnapshot = .{};
    if (ctx.net.netConfigGet(&snapshot) != a.net_config_ok) return a.network_error_backend;
    var found = false;
    var ambiguous = false;
    var best_bits: u32 = 0;
    var best_metric: u32 = std.math.maxInt(u32);
    var failure: i32 = a.network_error_not_found;
    for (0..snapshot.adapter_count) |index| {
        _ = budget.remainingTicks() catch |err| return r4os.rpc_budget.code(err);
        var client: r4os.network_family.Ipv6 = undefined;
        const opened = r4os.network_family.Ipv6.open(ctx.dev, @intCast(index), &client);
        if (opened != 0) {
            failure = opened;
            continue;
        }
        const info = client.info;
        if (info.capabilities & (a.ipv6_cap_packet | a.ipv6_cap_icmp) != (a.ipv6_cap_packet | a.ipv6_cap_icmp)) {
            failure = a.network_error_unsupported_policy;
            continue;
        }
        if (target.interface_id != 0 and target.interface_id != info.link.interface_id) continue;
        for (0..info.route_count) |cursor| {
            _ = budget.remainingTicks() catch |err| return r4os.rpc_budget.code(err);
            var route: a.Ipv6RouteInfo = .{};
            const rc = client.route(@intCast(cursor), &route);
            if (rc != 0) return rc;
            if (!prefixMatches(target.bytes, route.prefix.bytes, route.prefix_length)) continue;
            if (found and (route.prefix_length < best_bits or route.prefix_length == best_bits and route.metric > best_metric)) continue;
            var request: a.Ipv6Packet = .{
                .provider = info.link.provider,
                .generation = info.link.generation,
                .source = .{ .family = 6, .interface_id = info.link.interface_id },
                .destination = target,
                .deadline = r4os.network_family.fromBudget(budget.deadline) catch |err| return r4os.network_family.common.code(err),
                .next_header = 58,
            };
            request.destination.interface_id = info.link.interface_id;
            var value: a.Ipv6Packet = .{};
            const ready = client.packet(a.ipv6_op_prepare, &request, &value);
            if (ready != 0) {
                failure = ready;
                continue;
            }
            if (found and route.prefix_length == best_bits and route.metric == best_metric) {
                if (selected.info.link.interface_id != info.link.interface_id) ambiguous = true;
            } else {
                selected.* = client;
                prepared.* = value;
                found = true;
                ambiguous = false;
                best_bits = route.prefix_length;
                best_metric = route.metric;
            }
        }
    }
    if (ambiguous) return a.network_error_unsupported_scope;
    return if (found) 0 else failure;
}

fn pingIpv6(ctx: *App, client: *const r4os.network_family.Ipv6, prepared: r4os.abi.Ipv6Packet, ident: u16, seq: u16, stats: *PingStats) PingAttemptResult {
    const a = r4os.abi;
    var budget = operationBudget(ctx, PING_TIMEOUT_MS) catch return .clock_error;
    const started = (checkedNow(ctx) catch return .clock_error).instant_ns;
    var message: a.Icmpv6Message = .{ .source = prepared.source.bytes, .destination = prepared.destination.bytes, .bytes = 16 };
    message.payload[0] = 128;
    writeBe16(&message.payload, 4, ident);
    writeBe16(&message.payload, 6, seq);
    @memcpy(message.payload[8..16], "R4OSPING");
    var sealed: a.Icmpv6Message = .{};
    const code = r4os.network_family.protocolRecord(ctx.dev, a.Icmpv6Message, a.Icmpv6Message, "net.icmpv6", a.icmpv6_op_seal, &message, &sealed);
    if (code != 0 or sealed.bytes != 16 or sealed.flags != 0 or !std.mem.eql(u8, &sealed.source, &message.source) or !std.mem.eql(u8, &sealed.destination, &message.destination)) {
        ctx.println("ICMPv6 provider/seal failed");
        return .tx_error;
    }
    var request = prepared;
    request.bytes = sealed.bytes;
    @memcpy(request.payload[0..sealed.bytes], sealed.payload[0..sealed.bytes]);
    stats.sent += 1;
    var sent = false;
    while (true) {
        _ = budget.remainingTicks() catch |err| {
            if (err != error.TimedOut) return .clock_error;
            break;
        };
        if (checkAbort(ctx) catch return .input_error) return .aborted;
        request.deadline = r4os.network_family.fromBudget(budget.deadline) catch return .clock_error;
        var response: a.Ipv6Packet = .{};
        if (!sent) {
            const rc = client.packet(a.ipv6_op_send, &request, &response);
            if (rc == 0) sent = true else if (rc != a.network_error_would_block) {
                ctx.write("IPv6 transmit failed, code=");
                ctx.sys.printI32(rc);
                ctx.write("\r\n");
                return .tx_error;
            }
        }
        if (sent) {
            const receive: a.Ipv6Packet = .{
                .provider = request.provider,
                .generation = request.generation,
                .source = .{ .family = 6, .interface_id = client.info.link.interface_id },
                .destination = .{ .family = 6, .interface_id = client.info.link.interface_id },
                .deadline = request.deadline,
                .next_header = 58,
            };
            for (0..PING_RECV_BUDGET) |_| {
                _ = budget.remainingTicks() catch |err| return if (err == error.TimedOut) .timeout else .clock_error;
                const rc = client.packet(a.ipv6_op_receive, &receive, &response);
                if (rc == a.network_error_would_block) break;
                if (rc != 0) {
                    ctx.write("IPv6 receive failed, code=");
                    ctx.sys.printI32(rc);
                    ctx.write("\r\n");
                    return .tx_error;
                }
                const data = response.payload[0..response.bytes];
                if (!std.mem.eql(u8, &response.source.bytes, &request.destination.bytes) or !std.mem.eql(u8, &response.destination.bytes, &request.source.bytes) or data.len != 16 or data[0] != 129 or data[1] != 0 or readBe16(data, 4) != ident or !std.mem.eql(u8, data[8..], "R4OSPING")) {
                    stats.ignored += 1;
                    continue;
                }
                const actual_seq = readBe16(data, 6);
                if (actual_seq != seq) {
                    stats.late += 1;
                    continue;
                }
                const now = checkedNow(ctx) catch return .clock_error;
                stats.received += 1;
                ctx.write("Reply from ");
                writeAddress(ctx, response.source);
                ctx.write(": bytes=16 time=");
                ctx.printU64((now.instant_ns - started) / 1_000_000);
                ctx.write("ms seq=");
                ctx.printU64(seq);
                ctx.write("\r\n");
                return .reply;
            }
        }
        ctx.sleepTicks(1);
    }
    ctx.write("Request timed out. seq=");
    ctx.printU64(seq);
    ctx.write("\r\n");
    return .timeout;
}

test "migration ping route prefixes and whole echo identity" {
    try std.testing.expect(prefixMatches(.{ 0xfd, 0 } ++ [_]u8{0} ** 14, .{ 0xfd, 0 } ++ [_]u8{0} ** 14, 64));
    try std.testing.expect(!prefixMatches(.{ 0xfd, 0 } ++ [_]u8{0} ** 14, .{ 0xfe, 0 } ++ [_]u8{0} ** 14, 7));
    try std.testing.expect(prefixMatches([_]u8{0xff} ** 16, [_]u8{0} ** 16, 0));
    var bytes: [32]u8 = undefined;
    _ = buildEchoRequest(&bytes, 17, 23).?;
    bytes[0] = 0;
    bytes[2] = 0;
    bytes[3] = 0;
    writeBe16(&bytes, 2, checksum(bytes[0..16]));
    try std.testing.expectEqual(@as(?u16, 23), echoReplySeq(bytes[0..16], 17));
    bytes[15] ^= 1;
    bytes[2] = 0;
    bytes[3] = 0;
    writeBe16(&bytes, 2, checksum(bytes[0..16]));
    try std.testing.expectEqual(@as(?u16, null), echoReplySeq(bytes[0..16], 17));
}

test "migration ping clock regression and generation changes retain the prior observation" {
    const a = r4os.abi;
    const Peer = struct {
        var generation: u32 = 7;
        var instant: u64 = 1_000_000_000;
        fn clock(out: *a.MonotonicClockInfo) callconv(.c) i32 {
            out.* = .{ .flags = a.monotonic_clock_flag_valid, .source = 1, .generation = generation, .instant_ns = instant, .resolution_ns = 1, .event_requested_hz = 1000 };
            return 1;
        }
    };
    const platform = r4os.platform2;
    var table: platform.abi.R4XStartR4Sys2 = .{ .monotonic_clock = @intFromPtr(&Peer.clock) };
    const imports = [_]platform.abi.R4XStartImport{.{ .group_id = 1, .resolved_version = 2, .table = @intFromPtr(&table) }};
    const raw: platform.abi.R4XStartContext2 = .{ .import_count = imports.len, .imports = @intFromPtr(&imports) };
    const context = try platform.Context.init(&raw);
    var ctx: App = .{ .sys = r4os.r4sys.Context.fromProgram(.{ .generation2 = &context }), .net = undefined, .dev = undefined, .app = undefined, .clock = Peer.clock };
    _ = try checkedNow(&ctx);
    const before = ctx.sample;
    Peer.instant -= 1;
    try std.testing.expectError(error.ClockChanged, checkedNow(&ctx));
    try std.testing.expectEqualDeep(before, ctx.sample);
    Peer.instant += 1;
    Peer.generation += 1;
    try std.testing.expectError(error.ClockChanged, checkedNow(&ctx));
    try std.testing.expectEqualDeep(before, ctx.sample);
}

test "migration ping consumes typed Ctrl-C and explicit bytes from its own console" {
    const a = r4os.abi;
    const Peer = struct {
        var mode: u8 = 0;
        fn closing(_: *const r4os.platform2.abi.R4XStartContext2) callconv(.c) u32 {
            return 0;
        }
        fn read(out: [*]a.ConsoleInputEvent, capacity: u32) callconv(.c) i32 {
            if (mode == 3) return -1;
            if (capacity == 0) return -1;
            out[0] = .{ .kind = if (mode == 1) a.console_input_event_utf8_byte else a.console_input_event_text, .value = if (mode == 2) 'x' else CTRL_C };
            return 1;
        }
    };
    const platform = r4os.platform2;
    var table: platform.abi.R4XStartR4Sys2 = .{};
    var desk: platform.abi.R4XStartR4Desk2 = .{ .console_read_events = @intFromPtr(&Peer.read) };
    const imports = [_]platform.abi.R4XStartImport{
        .{ .group_id = 1, .resolved_version = 2, .table = @intFromPtr(&table) },
        .{ .group_id = 2, .resolved_version = 2, .table = @intFromPtr(&desk) },
    };
    const callback: platform.abi.R4XStartShouldCloseFn2 = Peer.closing;
    const raw: platform.abi.R4XStartContext2 = .{ .import_count = imports.len, .imports = @intFromPtr(&imports), .flags = a.r4xstart_flag_close_supported, .should_close = @intFromPtr(callback) };
    const context = try platform.Context.init(&raw);
    const ctx: App = .{ .sys = r4os.r4sys.Context.fromProgram(.{ .generation2 = &context }), .net = undefined, .dev = undefined, .app = undefined, .clock = null };
    Peer.mode = 0;
    try std.testing.expect(try checkAbort(&ctx));
    Peer.mode = 1;
    try std.testing.expect(try checkAbort(&ctx));
    Peer.mode = 2;
    try std.testing.expect(!try checkAbort(&ctx));
    Peer.mode = 3;
    try std.testing.expectError(error.Input, checkAbort(&ctx));
}
