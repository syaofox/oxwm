const std = @import("std");

pub const Cpu = struct {
    format: []const u8,
    interval_secs: u64,
    color: c_ulong,
    prev_idle: u64,
    prev_total: u64,
    initialized: bool,

    pub fn init(format: []const u8, interval_secs: u64, color: c_ulong) Cpu {
        return .{
            .format = format,
            .interval_secs = interval_secs,
            .color = color,
            .prev_idle = 0,
            .prev_total = 0,
            .initialized = false,
        };
    }

    pub fn content(self: *Cpu, buffer: []u8) []const u8 {
        const file = std.fs.openFileAbsolute("/proc/stat", .{}) catch return buffer[0..0];
        defer file.close();

        var read_buffer: [1024]u8 = undefined;
        const bytes_read = file.readAll(&read_buffer) catch return buffer[0..0];
        const data = read_buffer[0..bytes_read];

        var lines = std.mem.splitScalar(u8, data, '\n');
        const first_line = lines.next() orelse return buffer[0..0];

        if (!std.mem.startsWith(u8, first_line, "cpu ")) return buffer[0..0];

        var total: u64 = 0;
        var idle: u64 = 0;
        var iowait: u64 = 0;

        var it = std.mem.tokenizeAny(u8, first_line, " \t");
        _ = it.next(); // "cpu"

        var field_idx: usize = 0;
        while (it.next()) |token| : (field_idx += 1) {
            const val = std.fmt.parseInt(u64, token, 10) catch continue;
            total += val;
            if (field_idx == 3) {
                idle = val;
            } else if (field_idx == 4) {
                iowait = val;
            }
        }

        if (!self.initialized) {
            self.prev_idle = idle;
            self.prev_total = total;
            self.initialized = true;
            return buffer[0..0];
        }

        const total_delta = total - self.prev_total;
        const idle_delta = idle - self.prev_idle;

        self.prev_idle = idle;
        self.prev_total = total;

        if (total_delta == 0) return buffer[0..0];

        const usage = (@as(f32, @floatFromInt(total_delta - idle_delta)) / @as(f32, @floatFromInt(total_delta))) * 100.0;

        var pct_buf: [16]u8 = undefined;
        const percent_str = std.fmt.bufPrint(&pct_buf, "{d:.1}", .{usage}) catch return buffer[0..0];

        return substitute(self.format, percent_str, buffer);
    }

    pub fn interval(self: *Cpu) u64 {
        return self.interval_secs;
    }

    pub fn getColor(self: *Cpu) c_ulong {
        return self.color;
    }
};

fn substitute(format: []const u8, percent: []const u8, buffer: []u8) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;

    while (i < format.len) {
        if (format[i] == '{' and i + 1 < format.len) {
            const rest = format[i..];
            const repl = if (std.mem.startsWith(u8, rest, "{percent}")) blk: {
                i += 9;
                break :blk percent;
            } else if (std.mem.startsWith(u8, rest, "{}")) blk: {
                i += 2;
                break :blk percent;
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
