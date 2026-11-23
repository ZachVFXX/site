const std = @import("std");
const xml = @import("xml");
const Odt = @import("odt.zig");
const Out = @import("html.zig");
const convert = @import("convert.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    // Source ODT
    var src = try std.Io.Dir.cwd().openFile(io, "contents/index.odt", .{});
    defer src.close(io);

    var tmp = try std.Io.Dir.cwd().createDirPathOpen(io, ".odt-tmp", .{});
    defer tmp.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, ".odt-tmp") catch unreachable;

    var public = try std.Io.Dir.cwd().createDirPathOpen(io, "docs", .{});
    defer public.close(io);

    const odt = Odt.init(io, src, tmp);
    defer odt.deinit();

    const content = try odt.loadContentXml(alloc);
    defer alloc.free(content);
    try odt.copyPictures(alloc, public);

    var out = Out.init(alloc);
    defer out.deinit();

    try out.raw(
        \\<!doctype html>
        \\<html lang="fr"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<link rel="stylesheet" href="style.css">
        \\</head><body>
        \\
    );
    try convert.convert(alloc, content, &out);
    try out.raw("\n</body></html>\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "docs/index.html", .data = out.bytes() });
}
