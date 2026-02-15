const std = @import("std");

/// Emit a JSON string with standard escapes. For bytes >= 0x80, always escape as \u00XX
/// so the output is valid UTF-8 JSON regardless of input encoding.
pub fn writeJsonStringEscaped(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 32) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else if (ch >= 0x80) {
                    try w.print("\\u00{x:0>2}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}
