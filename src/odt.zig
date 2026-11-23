const std = @import("std");

pub const Self = @This();

io: std.Io,
src_file: std.Io.File,
temp_folder: std.Io.Dir,

pub fn init(io: std.Io, src_file: std.Io.File, temp_folder: std.Io.Dir) Self {
    return .{ .io = io, .src_file = src_file, .temp_folder = temp_folder };
}

pub fn deinit(_: Self) void {}

pub fn extractAll(self: Self) !void {
    var buffer: [8 * 1024]u8 = undefined;
    var reader = self.src_file.reader(self.io, &buffer);
    try std.zip.extract(self.temp_folder, &reader, .{});
}

pub fn readContentXml(self: Self, alloc: std.mem.Allocator) ![]u8 {
    return self.temp_folder.readFileAlloc(
        self.io,
        "content.xml",
        alloc,
        .limited(64 * 1024 * 1024), // 64 MiB max
    );
}

pub fn loadContentXml(self: Self, alloc: std.mem.Allocator) ![]u8 {
    try self.extractAll();
    return self.readContentXml(alloc);
}

pub fn copyPictures(self: Self, alloc: std.mem.Allocator, dest: std.Io.Dir) !void {
    var pictures = self.temp_folder.openDir(self.io, "Pictures", .{ .iterate = true }) catch |err| {
        std.log.info("no Pictures folder in the ODT ({t}), skipping images", .{err});
        return;
    };
    defer pictures.close(self.io);

    try dest.createDirPath(self.io, "Pictures");
    var target = try dest.openDir(self.io, "Pictures", .{});
    defer target.close(self.io);

    var it = pictures.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .file) continue;

        const data = try pictures.readFileAlloc(self.io, entry.name, alloc, .limited(64 * 1024 * 1024));
        defer alloc.free(data);

        try target.writeFile(self.io, .{ .sub_path = entry.name, .data = data });
    }
}
