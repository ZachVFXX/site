const std = @import("std");
const xml = @import("xml");
const Out = @import("html.zig");
const Style = @import("style.zig").Style;
const StyleTable = @import("style.zig").StyleTable;
const Annotations = @import("annotations.zig");
const Images = @import("images.zig");

// ---------------------------------------------------------------------------
// Tables: this is where you extend the converter
// ---------------------------------------------------------------------------

const Simple = struct { open: []const u8, close: []const u8 };

/// Elements that map 1:1 to an HTML tag pair. To support a new one, add a line.
const simple = std.StaticStringMap(Simple).initComptime(.{
    .{ "text:list", Simple{ .open = "<ul>", .close = "</ul>" } },
    .{ "text:list-item", Simple{ .open = "<li>", .close = "</li>" } },
    .{ "table:table", Simple{ .open = "<table>", .close = "</table>" } },
    .{ "table:table-row", Simple{ .open = "<tr>", .close = "</tr>" } },
    .{ "table:table-cell", Simple{ .open = "<td>", .close = "</td>" } },
});

/// Elements that need real logic (attributes, state). Handled in `switch`es below.
const Tag = enum {
    heading,
    paragraph,
    span,
    annotation,
    annotation_end,
    meta, // dc:creator, dc:date
    space,
    line_break,
    tab,
    link,
    frame, // draw:frame
    image, // draw:image
    alt, // svg:title, svg:desc
};

const tags = std.StaticStringMap(Tag).initComptime(.{
    .{ "text:h", .heading },
    .{ "text:p", .paragraph },
    .{ "text:span", .span },
    .{ "office:annotation", .annotation },
    .{ "office:annotation-end", .annotation_end },
    .{ "dc:creator", .meta },
    .{ "dc:date", .meta },
    .{ "text:s", .space },
    .{ "text:line-break", .line_break },
    .{ "text:tab", .tab },
    .{ "text:a", .link },
    .{ "draw:frame", .frame },
    .{ "draw:image", .image },
    .{ "svg:title", .alt },
    .{ "svg:desc", .alt },
});

const h_open = [_][]const u8{ "<h1>", "<h2>", "<h3>", "<h4>", "<h5>", "<h6>" };
const h_close = [_][]const u8{ "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>" };

// ---------------------------------------------------------------------------
// What to do when an element closes
// ---------------------------------------------------------------------------

const Frame = union(enum) {
    block: []const u8, // paragraph or heading: closing tag
    html: []const u8, // simple element: closing tag
    span: Style, // styled span: which tags to close
    annotation, // finish the note, open the tooltip span
    frame, // write the <img>
    alt, // stop reading alt text
    meta, // its text must be skipped
    ignored, // unknown element: write nothing, keep its text
};

// ---------------------------------------------------------------------------
// Converter
// ---------------------------------------------------------------------------

const Converter = struct {
    gpa: std.mem.Allocator,
    out: *Out,
    styles: *const StyleTable,
    notes: Annotations,
    images: Images,
    stack: std.ArrayList(Frame) = .empty,
    block_depth: usize = 0, // open <p>/<h>; text outside one is just indentation

    fn deinit(self: *Converter) void {
        self.stack.deinit(self.gpa);
        self.notes.deinit();
        self.images.deinit();
    }

    // ----- events -----

    fn open(self: *Converter, el: xml.Element) !void {
        const frame = if (self.notes.capturing)
            try self.openInNote(el)
        else
            try self.openInBody(el);
        try self.stack.append(self.gpa, frame);
    }

    fn empty(self: *Converter, el: xml.Element) !void {
        if (self.notes.capturing) return;
        const tag = tags.get(el.name) orelse return;

        switch (tag) {
            .space => {
                const raw = el.attribute("text:c") orelse "1";
                const count = std.fmt.parseInt(usize, raw, 10) catch 1;
                for (0..count) |_| try self.out.raw("&nbsp;");
            },
            .line_break => try self.out.raw("<br>"),
            .tab => try self.out.raw("&nbsp;&nbsp;&nbsp;&nbsp;"),
            .annotation_end => try self.notes.end(self.out, el.attribute("office:name")),
            .image => try self.images.setSrc(el.attribute("xlink:href")),
            else => {},
        }
    }

    fn text(self: *Converter, raw: []const u8) !void {
        if (self.topIsMeta()) return;
        const in_alt = self.images.reading_alt;
        if (!in_alt and !self.notes.capturing and self.block_depth == 0) return;

        const decoded = try xml.decode(self.gpa, raw);
        defer self.gpa.free(decoded);

        if (self.notes.capturing) {
            try self.notes.addText(decoded);
        } else if (in_alt) {
            try self.images.addAlt(decoded);
        } else {
            try self.out.escaped(decoded);
        }
    }

    fn close(self: *Converter) !void {
        const frame = self.stack.pop() orelse return error.UnbalancedXml;
        switch (frame) {
            .block => |tag| {
                try self.notes.closeBeforeBlockEnd(self.out);
                try self.out.raw(tag);
                self.block_depth -= 1;
            },
            .html => |tag| try self.out.raw(tag),
            .span => |style| try style.close(self.out),
            .annotation => try self.notes.finish(self.out),
            .frame => try self.images.endFrame(self.out),
            .alt => self.images.endAlt(),
            .meta, .ignored => {},
        }
    }

    // ----- opening, split by context -----

    fn openInNote(self: *Converter, el: xml.Element) !Frame {
        const tag = tags.get(el.name) orelse return .ignored;
        switch (tag) {
            .paragraph, .heading => {
                try self.notes.newLine();
                return .ignored;
            },
            .meta => return .meta,
            else => return .ignored,
        }
    }

    fn openInBody(self: *Converter, el: xml.Element) !Frame {
        if (simple.get(el.name)) |s| {
            try self.out.raw(s.open);
            return .{ .html = s.close };
        }

        const tag = tags.get(el.name) orelse return .ignored;
        switch (tag) {
            .heading, .paragraph => return self.openBlock(el),
            .span => return self.openSpan(el),
            .annotation => {
                try self.notes.begin(el.attribute("office:name"));
                return .annotation;
            },
            .meta => return .meta,
            .link => {
                const href = el.attribute("xlink:href") orelse "#";
                try self.out.raw("<a href=\"");
                try self.out.escaped(href);
                try self.out.raw("\">");
                return .{ .html = "</a>" };
            },
            .frame => {
                try self.images.beginFrame(el.attribute("svg:width"));
                return .frame;
            },
            .image => {
                // Normally self-closing, but LibreOffice sometimes writes it open.
                try self.images.setSrc(el.attribute("xlink:href"));
                return .ignored;
            },
            .alt => {
                self.images.beginAlt();
                return .alt;
            },
            else => return .ignored,
        }
    }

    fn openBlock(self: *Converter, el: xml.Element) !Frame {
        var open_tag: []const u8 = "<p>";
        var close_tag: []const u8 = "</p>";

        if (std.mem.eql(u8, el.name, "text:h")) {
            const raw = el.attribute("text:outline-level") orelse "1";
            const level = std.fmt.parseInt(usize, raw, 10) catch 1;
            const i = std.math.clamp(level, 1, 6) - 1;
            open_tag = h_open[i];
            close_tag = h_close[i];
        }

        try self.out.raw(open_tag);
        try self.notes.reopen(self.out);
        self.block_depth += 1;
        return .{ .block = close_tag };
    }

    fn openSpan(self: *Converter, el: xml.Element) !Frame {
        const style = self.styles.get(el.attribute("text:style-name"));
        try style.open(self.out);
        return .{ .span = style };
    }

    fn topIsMeta(self: *const Converter) bool {
        const items = self.stack.items;
        return items.len > 0 and items[items.len - 1] == .meta;
    }
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Converts the bytes of content.xml into HTML, appended to `out`.
pub fn convert(gpa: std.mem.Allocator, content: []const u8, out: *Out) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Pass 1: styles.
    const styles = try StyleTable.collect(arena, content);

    // Pass 2: document body.
    var conv = Converter{
        .gpa = gpa,
        .out = out,
        .styles = &styles,
        .notes = Annotations.init(gpa, arena),
        .images = Images.init(gpa, arena),
    };
    defer conv.deinit();

    var reader = xml.Reader.init(gpa, content);
    defer reader.deinit();

    while (try reader.next()) |event| {
        switch (event) {
            .open => |el| try conv.open(el),
            .self_closing => |el| try conv.empty(el),
            .text => |raw| try conv.text(raw),
            .close => try conv.close(),
            else => {},
        }
    }
}
