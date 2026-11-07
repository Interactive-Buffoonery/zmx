const std = @import("std");
const vt = @import("ghostty-vt");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const input = args.next().?;
    const rows = try std.fmt.parseInt(u16, args.next().?, 10);
    const cols = try std.fmt.parseInt(u16, args.next().?, 10);
    const output = args.next().?;
    const file = try std.Io.Dir.cwd().openFile(init.io, input, .{});
    defer file.close(init.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(init.io, &buf);
    const bytes = try reader.interface.allocRemaining(alloc, .unlimited);
    var term = try vt.Terminal.init(init.io, alloc, .{
        .rows = rows,
        .cols = cols,
        .max_scrollback_lines = 10000,
    });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    if (args.next()) |width| try term.resize(alloc, .{ .cols = try std.fmt.parseInt(u16, width, 10), .rows = rows });
    var text: std.Io.Writer.Allocating = .init(alloc);
    var it = term.screens.active.pages.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |pin| {
        const rc = pin.rowAndCell();
        const page = pin.node.page();
        for (page.getCells(rc.row)) |cell| {
            const cp = if (cell.hasText()) cell.codepoint() else ' ';
            var utf8: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &utf8);
            try text.writer.writeAll(utf8[0..n]);
        }
        try text.writer.writeByte('\n');
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = text.written() });
}
