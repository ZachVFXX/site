const std = @import("std");

pub const Self = @This();

gpa: std.mem.Allocator,
buf: std.ArrayList(u8) = .empty,

pub fn init(gpa: std.mem.Allocator) Self {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Self) void {
    self.buf.deinit(self.gpa);
}

pub fn bytes(self: *const Self) []const u8 {
    return self.buf.items;
}

pub fn raw(self: *Self, s: []const u8) !void {
    try self.buf.appendSlice(self.gpa, s);
}

pub fn escaped(self: *Self, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try self.raw("&amp;"),
        '<' => try self.raw("&lt;"),
        '>' => try self.raw("&gt;"),
        '"' => try self.raw("&quot;"),
        else => try self.buf.append(self.gpa, ch),
    };
}
