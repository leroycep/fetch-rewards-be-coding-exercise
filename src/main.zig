const std = @import("std");
const http = @import("apple_pie");

pub const io_mode = .evented;

const Context = struct {
    data: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const my_context: Context = .{ .data = "Hello, world!" };

    const address =try std.net.Address.parseIp("127.0.0.1", 8080);

    std.log.info("listening on address {}", .{address});

    try http.listenAndServe(
        &gpa.allocator,
        address,
        my_context,
        index,
    );
}

fn index(ctx: Context, response: *http.Response, request: http.Request) !void {
    _ = request;
    try response.writer().print("{s}", .{ctx.data});
}
