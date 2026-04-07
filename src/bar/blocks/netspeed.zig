const std = @import("std");

pub const Netspeed = struct {
    format: []const u8,
    interval_secs: u64,
    color: c_ulong,
    interface: []const u8,
    prev_rx: u64,
    prev_tx: u64,
    initialized: bool,

    pub fn init(format: []const u8, interface: []const u8, interval_secs: u64, color: c_ulong) Netspeed {
        return .{
            .format = format,
            .interface = interface,
            .interval_secs = interval_secs,
            .color = color,
            .prev_rx = 0,
            .prev_tx = 0,
            .initialized = false,
        };
    }

    pub fn content(self: *Netspeed, buffer: []u8) []const u8 {
        const iface = if (self.interface.len > 0)
            self.interface
        else
            getDefaultInterface() orelse return buffer[0..0];

        const rx_bytes = readSysCounter(iface, "rx_bytes") orelse return buffer[0..0];
        const tx_bytes = readSysCounter(iface, "tx_bytes") orelse return buffer[0..0];

        if (!self.initialized) {
            self.prev_rx = rx_bytes;
            self.prev_tx = tx_bytes;
            self.initialized = true;
            return substituteFallback(self.format, buffer);
        }

        const rx_delta = rx_bytes - self.prev_rx;
        const tx_delta = tx_bytes - self.prev_tx;

        self.prev_rx = rx_bytes;
        self.prev_tx = tx_bytes;

        const rx_speed = @as(f64, @floatFromInt(rx_delta)) / @as(f64, @floatFromInt(self.interval_secs));
        const tx_speed = @as(f64, @floatFromInt(tx_delta)) / @as(f64, @floatFromInt(self.interval_secs));

        var rx_buf: [32]u8 = undefined;
        var tx_buf: [32]u8 = undefined;

        const rx_str = humanBytes(rx_speed, &rx_buf);
        const tx_str = humanBytes(tx_speed, &tx_buf);

        return substitute(self.format, rx_str, tx_str, buffer);
    }

    pub fn interval(self: *Netspeed) u64 {
        return self.interval_secs;
    }

    pub fn getColor(self: *Netspeed) c_ulong {
        return self.color;
    }
};

fn getDefaultInterface() ?[]const u8 {
    const file = std.fs.openFileAbsolute("/proc/net/route", .{}) catch return null;
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&read_buf) catch return null;
    const data = read_buf[0..bytes_read];

    var lines = std.mem.splitScalar(u8, data, '\n');

    // Skip header line
    _ = lines.next() orelse return null;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        const dest_hex = it.next() orelse continue;
        _ = it.next() orelse continue; // gateway
        const flags_hex = it.next() orelse continue;

        const dest = std.fmt.parseInt(u32, dest_hex, 16) catch continue;
        const flags = std.fmt.parseInt(u32, flags_hex, 16) catch continue;

        // Default route: destination == 0 and UP flag (0x01)
        if (dest == 0 and (flags & 0x01) != 0) {
            return name;
        }
    }

    return null;
}

fn readSysCounter(iface: []const u8, counter: []const u8) ?u64 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/class/net/{s}/statistics/{s}", .{ iface, counter }) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var read_buf: [32]u8 = undefined;
    const bytes_read = file.readAll(&read_buf) catch return null;
    const trimmed = std.mem.trim(u8, read_buf[0..bytes_read], " \t\n\r");

    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

fn humanBytes(bytes_per_sec: f64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B/s", "KB/s", "MB/s", "GB/s", "TB/s" };
    var adjusted = bytes_per_sec;
    var unit_idx: usize = 0;

    while (adjusted >= 1024.0 and unit_idx < units.len - 1) {
        adjusted /= 1024.0;
        unit_idx += 1;
    }

    const unit_str = units[unit_idx];
    return std.fmt.bufPrint(buf, "{d:.2}{s}", .{ adjusted, unit_str }) catch "?";
}

fn substitute(
    format: []const u8,
    rx: []const u8,
    tx: []const u8,
    buffer: []u8,
) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;

    while (i < format.len) {
        if (format[i] == '{' and i + 1 < format.len) {
            const rest = format[i..];
            const repl = if (std.mem.startsWith(u8, rest, "{rx}")) blk: {
                i += 4;
                break :blk rx;
            } else if (std.mem.startsWith(u8, rest, "{tx}")) blk: {
                i += 4;
                break :blk tx;
            } else if (std.mem.startsWith(u8, rest, "{}")) blk: {
                i += 2;
                break :blk rx;
            } else null;

            if (repl) |r| {
                if (pos + r.len > buffer.len) break;
                @memcpy(buffer[pos..][0..r.len], r);
                pos += r.len;
                continue;
            }
        }
        if (pos >= buffer.len) break;
        buffer[pos] = format[i];
        pos += 1;
        i += 1;
    }
    return buffer[0..pos];
}

fn substituteFallback(format: []const u8, buffer: []u8) []const u8 {
    const na = "N/A";
    var pos: usize = 0;
    var i: usize = 0;

    while (i < format.len) {
        if (format[i] == '{' and i + 1 < format.len) {
            const rest = format[i..];
            const repl = if (std.mem.startsWith(u8, rest, "{rx}")) blk: {
                i += 4;
                break :blk na;
            } else if (std.mem.startsWith(u8, rest, "{tx}")) blk: {
                i += 4;
                break :blk na;
            } else if (std.mem.startsWith(u8, rest, "{}")) blk: {
                i += 2;
                break :blk na;
            } else null;

            if (repl) |r| {
                if (pos + r.len > buffer.len) break;
                @memcpy(buffer[pos..][0..r.len], r);
                pos += r.len;
                continue;
            }
        }
        if (pos >= buffer.len) break;
        buffer[pos] = format[i];
        pos += 1;
        i += 1;
    }
    return buffer[0..pos];
}
