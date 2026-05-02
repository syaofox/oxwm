const std = @import("std");
const xlib = @import("../x11/xlib.zig");
const config = @import("../config/config.zig");

pub const max_chord_len: u8 = 4;

const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const digits = "0123456789";

fn keyName(keysym: u64) []const u8 {
    return switch (keysym) {
        0xff0d => "Return",
        0x0020 => "Space",
        0xff1b => "Escape",
        0xff08 => "BackSpace",
        0xff09 => "Tab",
        0xffbe => "F1",
        0xffbf => "F2",
        0xffc0 => "F3",
        0xffc1 => "F4",
        0xffc2 => "F5",
        0xffc3 => "F6",
        0xffc4 => "F7",
        0xffc5 => "F8",
        0xffc6 => "F9",
        0xffc7 => "F10",
        0xffc8 => "F11",
        0xffc9 => "F12",
        0xff51 => "Left",
        0xff52 => "Up",
        0xff53 => "Right",
        0xff54 => "Down",
        0x002c => ",",
        0x002e => ".",
        0x002f => "/",
        'a'...'z' => |c| upper[c - 'a' ..][0..1],
        'A'...'Z' => |c| upper[c - 'A' ..][0..1],
        '0'...'9' => |c| digits[c - '0' ..][0..1],
        else => "?",
    };
}

fn fmtKeyPress(key: *const config.KeyPress, buf: []u8) usize {
    var pos: usize = 0;

    if ((key.mod_mask & xlib.ShiftMask) != 0) {
        const s = "Shift";
        if (pos + s.len > buf.len) return pos;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if ((key.mod_mask & xlib.ControlMask) != 0) {
        const s = " + Ctrl";
        if (pos + s.len > buf.len) return pos;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if ((key.mod_mask & xlib.Mod1Mask) != 0) {
        const s = " + Alt";
        if (pos + s.len > buf.len) return pos;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if ((key.mod_mask & xlib.Mod4Mask) != 0) {
        const s = " + Mod";
        if (pos + s.len > buf.len) return pos;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }

    const name = keyName(key.keysym);
    if (pos > 0) {
        const sep = " + ";
        if (pos + sep.len + name.len > buf.len) return pos;
        @memcpy(buf[pos..][0..sep.len], sep);
        pos += sep.len;
    } else if (pos + name.len > buf.len) {
        return pos;
    }
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;

    return pos;
}
/// How long (in milliseconds) the user has between key presses within
/// a chord before the sequence is abandoned and state is reset.
pub const timeout_ms: i64 = 1000;

/// Tracks the in-progress key-chord sequence.
///
/// Owned by `WindowManager`. Call `update` on every key press; it returns
/// whether the sequence is still live. Call `reset` to abandon the
/// current sequence and release the keyboard grab if one is held.
pub const ChordState = struct {
    keys: [max_chord_len]config.KeyPress = .{config.KeyPress{}} ** max_chord_len,
    index: u8 = 0,
    last_timestamp: i64 = 0,
    keyboard_grabbed: bool = false,

    /// Push a new key press onto the sequence and update the timestamp.
    ///
    /// Returns `false` if the sequence is already at maximum length, in which
    /// case the caller should call `reset` before retrying.
    pub fn push(self: *ChordState, io: std.Io, key: config.KeyPress) bool {
        if (self.index >= max_chord_len) return false;
        self.keys[self.index] = key;
        self.index += 1;
        self.last_timestamp = std.Io.Timestamp.now(io, .awake).toMilliseconds();

        return true;
    }

    /// Format the partial chord as a display hint for the bar.
    /// Writes something like "Mod + K + ?" and returns the slice.
    /// Returns null if the chord is empty.
    pub fn formatHint(self: *const ChordState, buf: []u8) ?[]const u8 {
        if (self.index == 0) return null;

        var pos: usize = 0;

        for (0..self.index) |i| {
            if (i > 0) {
                if (pos + 3 > buf.len) return buf[0..pos];
                buf[pos] = ' ';
                buf[pos + 1] = '+';
                buf[pos + 2] = ' ';
                pos += 3;
            }
            const n = fmtKeyPress(&self.keys[i], buf[pos..]);
            if (n == 0) return buf[0..pos];
            pos += n;
        }

        const waiting = " + ?";
        if (pos + waiting.len > buf.len) return buf[0..pos];
        @memcpy(buf[pos..][0..waiting.len], waiting);
        pos += waiting.len;

        return buf[0..pos];
    }

    /// Returns true if the sequence has timed out and should be reset.
    pub fn isTimedOut(self: *const ChordState, io: std.Io) bool {
        if (self.index == 0) return false;
        return (std.Io.Timestamp.now(io, .awake).toMilliseconds() - self.last_timestamp) >= timeout_ms;
    }

    /// Clears the sequence and releases the keyboard grab if one is held.
    ///
    /// `display` may be null only during early startup before the connection
    /// is open, in normal operation it should always be provided.
    pub fn reset(self: *ChordState, display: ?*xlib.Display) void {
        self.keys = .{config.KeyPress{}} ** max_chord_len;
        self.index = 0;
        self.last_timestamp = 0;

        if (self.keyboard_grabbed) {
            if (display) |dpy| {
                _ = xlib.XUngrabKeyboard(dpy, xlib.CurrentTime);
            }
            self.keyboard_grabbed = false;
        }
    }

    /// Try to grab the keyboard for exclusive input during a partial match.
    ///
    /// Sets `keyboard_grabbed` on success.  Safe to call repeatedly,
    /// does nothing if already grabbed.
    pub fn grabKeyboard(self: *ChordState, display: *xlib.Display, root: xlib.Window) void {
        if (self.keyboard_grabbed) return;

        const result = xlib.XGrabKeyboard(display, root, xlib.True, xlib.GrabModeAsync, xlib.GrabModeAsync, xlib.CurrentTime);
        if (result == xlib.GrabSuccess) {
            self.keyboard_grabbed = true;
        }
    }
};
