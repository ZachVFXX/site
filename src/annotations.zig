const std = @import("std");
const Out = @import("html.zig");

pub const Self = @This();

gpa: std.mem.Allocator, // for the note buffer
arena: std.mem.Allocator, // for names and tags that outlive one event

capturing: bool = false, // true while inside <office:annotation>
note: std.ArrayList(u8) = .empty,
pending_name: ?[]const u8 = null, // annotation being read
active_name: ?[]const u8 = null, // annotation whose <span> is open
active_tag: []const u8 = "", // that span's opening tag, kept to reopen it

pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) Self {
    return .{ .gpa = gpa, .arena = arena };
}

pub fn deinit(self: *Self) void {
    self.note.deinit(self.gpa);
}

/// <office:annotation> opened: start collecting the note text.
pub fn begin(self: *Self, name: ?[]const u8) !void {
    self.capturing = true;
    self.note.clearRetainingCapacity();
    self.pending_name = if (name) |n| try self.arena.dupe(u8, n) else null;
}

pub fn addText(self: *Self, text: []const u8) !void {
    try self.note.appendSlice(self.gpa, text);
}

/// A new paragraph inside the note becomes a line break in the tooltip.
pub fn newLine(self: *Self) !void {
    if (self.note.items.len > 0) try self.note.append(self.gpa, '\n');
}

/// </office:annotation>: the note is complete, open the span.
pub fn finish(self: *Self, out: *Out) !void {
    self.capturing = false;
    const name = self.pending_name orelse return;

    var tag = Out.init(self.arena); // arena: never freed one by one
    try tag.raw("<span class=\"annotated\" tabindex=\"0\" data-tooltip=\"");
    try tag.escaped(std.mem.trim(u8, self.note.items, " \t\r\n"));
    try tag.raw("\">");

    self.active_name = name;
    self.active_tag = tag.bytes();
    try out.raw(self.active_tag);
}

/// Call right after opening a paragraph: continues a span from before.
pub fn reopen(self: *Self, out: *Out) !void {
    if (self.active_name != null) try out.raw(self.active_tag);
}

/// Call right before closing a paragraph: a span can't cross it.
pub fn closeBeforeBlockEnd(self: *Self, out: *Out) !void {
    if (self.active_name != null) try out.raw("</span>");
}

/// <office:annotation-end name="...">
pub fn end(self: *Self, out: *Out, name: ?[]const u8) !void {
    const active = self.active_name orelse return;
    const n = name orelse return;
    if (!std.mem.eql(u8, active, n)) return;
    try out.raw("</span>");
    self.active_name = null;
}
