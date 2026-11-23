const std = @import("std");
const Out = @import("html.zig");

/// Turns <draw:frame><draw:image/><svg:title/>...</draw:frame> into one <img>.
pub const Self = @This();
gpa: std.mem.Allocator, // for the alt buffer
arena: std.mem.Allocator, // for src/width, which must outlive one event

src: ?[]const u8 = null,
width: ?[]const u8 = null, // e.g. "8cm", valid CSS as-is
alt: std.ArrayList(u8) = .empty,
reading_alt: bool = false, // true inside <svg:title> / <svg:desc>

pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) Self {
    return .{ .gpa = gpa, .arena = arena };
}

pub fn deinit(self: *Self) void {
    self.alt.deinit(self.gpa);
}

/// <draw:frame> opened: reset the state.
pub fn beginFrame(self: *Self, width: ?[]const u8) !void {
    self.src = null;
    self.alt.clearRetainingCapacity();
    self.width = if (width) |w| try self.arena.dupe(u8, w) else null;
}

/// <draw:image xlink:href="Pictures/x.png">
pub fn setSrc(self: *Self, href: ?[]const u8) !void {
    const h = href orelse return;
    self.src = try self.arena.dupe(u8, h);
}

/// <svg:title> or <svg:desc> opened. The last one wins (desc over title).
pub fn beginAlt(self: *Self) void {
    self.alt.clearRetainingCapacity();
    self.reading_alt = true;
}

pub fn addAlt(self: *Self, text: []const u8) !void {
    try self.alt.appendSlice(self.gpa, text);
}

pub fn endAlt(self: *Self) void {
    self.reading_alt = false;
}

/// </draw:frame>: everything is known, write the <img>.
pub fn endFrame(self: *Self, out: *Out) !void {
    defer {
        self.src = null;
        self.width = null;
    }
    const src = self.src orelse return; // a frame without image (text box...)

    try out.raw("<img src=\"");
    try out.escaped(src);
    try out.raw("\" alt=\"");
    try out.escaped(std.mem.trim(u8, self.alt.items, " \t\r\n"));
    try out.raw("\"");
    if (self.width) |w| {
        try out.raw(" style=\"width:");
        try out.escaped(w);
        try out.raw("\"");
    }
    try out.raw(">");
}
