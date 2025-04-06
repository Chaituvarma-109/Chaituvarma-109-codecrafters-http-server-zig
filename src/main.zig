const std = @import("std");
const net = std.net;

pub fn main() !void {
    const page_alloc = std.heap.page_allocator;
    // const stdout = std.io.getStdOut().writer();

    // Uncomment this block to pass the first stage
    const address = try net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    const conn = try listener.accept();
    defer conn.stream.close();
    const buff = try page_alloc.alloc(u8, 1024);
    defer page_alloc.free(buff);

    _ = try conn.stream.read(buff);
    var token = std.mem.splitSequence(u8, buff, " ");
    _ = token.next();
    const path = token.next().?;
    var path_token = std.mem.splitSequence(u8, path, "/");
    _ = path_token.next();
    const root = path_token.next().?;

    if (std.mem.eql(u8, path, "/")) {
        try conn.stream.writeAll("HTTP/1.1 200 OK\r\n\r\n");
    } else if (std.mem.eql(u8, root, "echo")) {
        const echo_arg = path[6..];
        const res = try std.fmt.allocPrint(page_alloc, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{ echo_arg.len, echo_arg });
        try conn.stream.writeAll(res);
    } else {
        try conn.stream.writeAll("HTTP/1.1 404 Not Found\r\n\r\n");
    }
}
