const std = @import("std");
const fs = std.fs;

pub inline fn eqlContentReader(from_reader: anytype, to_reader: anytype) !void {
    var from_buffer: [1024]u8 = undefined;
    const from_bytes_read = try from_reader.read(&from_buffer);

    var to_buffer: [1024]u8 = undefined;
    const to_bytes_read = try to_reader.read(&to_buffer);

    try std.testing.expectEqual(to_bytes_read, from_bytes_read);

    try std.testing.expectEqualStrings(to_buffer[0..to_bytes_read], from_buffer[0..from_bytes_read]);
}
