const std = @import("std");

const ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub fn generate(allocator: std.mem.Allocator) ![]u8 {
    var buf: [26]u8 = undefined;
    const now = std.time.milliTimestamp();
    
    // 48-bit timestamp
    var time = @as(u64, @intCast(now));
    
    // Encode timestamp (10 chars)
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        buf[i] = ENCODING[time % 32];
        time /= 32;
    }

    // 80-bit randomness (16 chars)
    const r = std.crypto.random;
    i = 10;
    while (i < 26) : (i += 1) {
        const rand_val = r.int(u5);
        buf[i] = ENCODING[rand_val];
    }

    return allocator.dupe(u8, &buf);
}
