const std = @import("std");
const xml = @import("xml");
const Out = @import("html.zig");

pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,

    pub fn isPlain(self: Style) bool {
        return !(self.bold or self.italic or self.underline);
    }

    pub fn open(self: Style, out: *Out) !void {
        if (self.bold) try out.raw("<strong>");
        if (self.italic) try out.raw("<em>");
        if (self.underline) try out.raw("<u>");
    }

    pub fn close(self: Style, out: *Out) !void {
        if (self.underline) try out.raw("</u>");
        if (self.italic) try out.raw("</em>");
        if (self.bold) try out.raw("</strong>");
    }
};

/// Maps ODT style names ("T11") to the few properties we care about.
pub const StyleTable = struct {
    map: std.StringHashMap(Style),

    /// Pass 1: reads the automatic styles. Everything is allocated in `arena`,
    /// so there is nothing to free individually.
    pub fn collect(arena: std.mem.Allocator, content: []const u8) !StyleTable {
        var map = std.StringHashMap(Style).init(arena);
        var reader = xml.Reader.init(arena, content);
        defer reader.deinit();

        var current: ?[]const u8 = null;

        while (try reader.next()) |event| {
            switch (event) {
                .open => |el| {
                    if (std.mem.eql(u8, el.name, "office:body")) break; // styles are all before
                    if (std.mem.eql(u8, el.name, "style:style")) {
                        current = if (el.attribute("style:name")) |n| try arena.dupe(u8, n) else null;
                    }
                    try readProperties(&map, current, el);
                },
                .self_closing => |el| try readProperties(&map, current, el),
                .close => |name| {
                    if (std.mem.eql(u8, name, "style:style")) current = null;
                },
                else => {},
            }
        }
        return .{ .map = map };
    }

    pub fn get(self: *const StyleTable, name: ?[]const u8) Style {
        const n = name orelse return .{};
        return self.map.get(n) orelse .{};
    }
};

fn readProperties(map: *std.StringHashMap(Style), current: ?[]const u8, el: xml.Element) !void {
    if (!std.mem.eql(u8, el.name, "style:text-properties")) return;
    const style_name = current orelse return;

    var s = Style{};
    if (el.attribute("fo:font-weight")) |v| s.bold = std.mem.eql(u8, v, "bold");
    if (el.attribute("fo:font-style")) |v| s.italic = std.mem.eql(u8, v, "italic");
    if (el.attribute("style:text-underline-style")) |v| s.underline = !std.mem.eql(u8, v, "none");

    if (!s.isPlain()) try map.put(style_name, s);
}
