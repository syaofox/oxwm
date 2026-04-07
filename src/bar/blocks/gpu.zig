const std = @import("std");

pub const Gpu = struct {
    format: []const u8,
    interval_secs: u64,
    color: c_ulong,
    nvml: std.DynLib = undefined,
    device: ?*anyopaque = null,
    nvml_loaded: bool = false,
    nvml_available: bool = true,

    const NvmlReturn = c_int;
    const NvmlSuccess: NvmlReturn = 0;

    const NvmlUtilization = extern struct {
        gpu: c_uint,
        memory: c_uint,
    };

    const NvmlMemory = extern struct {
        total: u64,
        reserved: u64,
        used: u64,
        free: u64,
    };

    const NvmlInitFn = *const fn () callconv(.c) NvmlReturn;
    const NvmlShutdownFn = *const fn () callconv(.c) NvmlReturn;
    const NvmlDeviceGetHandleByIndexFn = *const fn (c_uint, *?*anyopaque) callconv(.c) NvmlReturn;
    const NvmlDeviceGetUtilizationRatesFn = *const fn (?*anyopaque, *NvmlUtilization) callconv(.c) NvmlReturn;
    const NvmlDeviceGetMemoryInfoFn = *const fn (?*anyopaque, *NvmlMemory) callconv(.c) NvmlReturn;

    pub fn init(format: []const u8, interval_secs: u64, color: c_ulong) Gpu {
        return .{
            .format = format,
            .interval_secs = interval_secs,
            .color = color,
        };
    }

    pub fn content(self: *Gpu, buffer: []u8) []const u8 {
        if (!self.ensureNvml()) {
            const na = "N/A";
            if (buffer.len >= na.len) {
                @memcpy(buffer[0..na.len], na);
                return buffer[0..na.len];
            }
            return buffer[0..0];
        }

        const getUtilFn = self.nvml.lookup(NvmlDeviceGetUtilizationRatesFn, "nvmlDeviceGetUtilizationRates") orelse return buffer[0..0];
        const getMemFn = self.nvml.lookup(NvmlDeviceGetMemoryInfoFn, "nvmlDeviceGetMemoryInfo") orelse return buffer[0..0];

        var utilization: NvmlUtilization = undefined;
        if (getUtilFn(self.device.?, &utilization) != NvmlSuccess) return buffer[0..0];

        var memory: NvmlMemory = undefined;
        if (getMemFn(self.device.?, &memory) != NvmlSuccess) return buffer[0..0];

        const gpu_util = utilization.gpu;
        const vram_used_gb = @as(f32, @floatFromInt(memory.used)) / 1024.0 / 1024.0 / 1024.0;
        const vram_total_gb = @as(f32, @floatFromInt(memory.total)) / 1024.0 / 1024.0 / 1024.0;
        const vram_percent = if (memory.total > 0)
            (@as(f32, @floatFromInt(memory.used)) / @as(f32, @floatFromInt(memory.total))) * 100.0
        else
            0.0;

        var val_bufs: [4][16]u8 = undefined;
        const gpu_util_str = std.fmt.bufPrint(&val_bufs[0], "{d}", .{gpu_util}) catch return buffer[0..0];
        const vram_used_str = std.fmt.bufPrint(&val_bufs[1], "{d:.2}", .{vram_used_gb}) catch return buffer[0..0];
        const vram_total_str = std.fmt.bufPrint(&val_bufs[2], "{d:.2}", .{vram_total_gb}) catch return buffer[0..0];
        const vram_percent_str = std.fmt.bufPrint(&val_bufs[3], "{d:.1}", .{vram_percent}) catch return buffer[0..0];

        return substitute(self.format, buffer, .{
            .gpu_util = gpu_util_str,
            .vram_used = vram_used_str,
            .vram_total = vram_total_str,
            .vram_percent = vram_percent_str,
        });
    }

    fn ensureNvml(self: *Gpu) bool {
        if (!self.nvml_available) return false;
        if (self.nvml_loaded) return self.device != null;

        self.nvml = std.DynLib.open("libnvidia-ml.so.1") catch {
            self.nvml_available = false;
            return false;
        };

        const nvmlInitFn = self.nvml.lookup(NvmlInitFn, "nvmlInit") orelse {
            self.cleanup();
            return false;
        };
        const getHandleFn = self.nvml.lookup(NvmlDeviceGetHandleByIndexFn, "nvmlDeviceGetHandleByIndex") orelse {
            self.cleanup();
            return false;
        };

        if (nvmlInitFn() != NvmlSuccess) {
            self.cleanup();
            return false;
        }

        var device: ?*anyopaque = null;
        if (getHandleFn(0, &device) != NvmlSuccess) {
            const shutdownFn = self.nvml.lookup(NvmlShutdownFn, "nvmlShutdown") orelse return false;
            _ = shutdownFn();
            self.cleanup();
            return false;
        }

        self.device = device;
        self.nvml_loaded = true;
        return true;
    }

    fn cleanup(self: *Gpu) void {
        if (self.nvml_loaded) {
            self.nvml.close();
            self.nvml_loaded = false;
        }
        self.device = null;
    }

    pub fn interval(self: *Gpu) u64 {
        return self.interval_secs;
    }

    pub fn getColor(self: *Gpu) c_ulong {
        return self.color;
    }
};

fn substitute(format: []const u8, buffer: []u8, values: struct {
    gpu_util: []const u8,
    vram_used: []const u8,
    vram_total: []const u8,
    vram_percent: []const u8,
}) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;

    while (i < format.len) {
        if (format[i] == '{' and i + 1 < format.len) {
            const rest = format[i..];
            const repl = if (std.mem.startsWith(u8, rest, "{gpu_util}")) blk: {
                i += 10;
                break :blk values.gpu_util;
            } else if (std.mem.startsWith(u8, rest, "{vram_used}")) blk: {
                i += 11;
                break :blk values.vram_used;
            } else if (std.mem.startsWith(u8, rest, "{vram_total}")) blk: {
                i += 12;
                break :blk values.vram_total;
            } else if (std.mem.startsWith(u8, rest, "{vram_percent}")) blk: {
                i += 14;
                break :blk values.vram_percent;
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
