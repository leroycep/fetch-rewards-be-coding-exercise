const std = @import("std");
const http = @import("apple_pie");
const router = http.router;
pub const transaction_tree = @import("./transaction_tree.zig");
const Context = @import("./context.zig").Context;

//pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var my_context = Context.init(&gpa.allocator);

    const address = try std.net.Address.parseIp("127.0.0.1", 35866);

    std.log.info("listening on address {}", .{address});

    try http.listenAndServe(
        &gpa.allocator,
        address,
        &my_context,
        comptime router.Router(*Context, &.{
            router.get("/balance", getBalance),
            router.get("/", getIndex),
        }),
    );
}

fn getIndex(ctx: *Context, response: *http.Response, request: http.Request) !void {
    _ = ctx;
    _ = request;

    try response.writer().print("Hello, world!\n", .{});
}

fn getBalance(ctx: *Context, response: *http.Response, request: http.Request) !void {
    _ = request;

    var balance = try ctx.getBalance(ctx.allocator);
    defer balance.deinit();

    var iter = balance.iterator();
    while (iter.next()) |entry| {
        try response.writer().print("{s}: {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

test {
    std.testing.refAllDecls(@This());
}
