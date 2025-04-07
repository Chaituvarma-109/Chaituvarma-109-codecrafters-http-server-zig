const std = @import("std");
const net = std.net;
const http = std.http;
const Pool = std.Thread.Pool;

// const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    const page_alloc = std.heap.page_allocator;
    var pool: std.Thread.Pool = undefined;
    try pool.init(Pool.Options{ .n_jobs = 4, .allocator = page_alloc });
    defer pool.deinit();

    // Uncomment this block to pass the first stage
    const address = try net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    while (true) {
        const conn = try listener.accept();

        try pool.spawn(connServer, .{ conn, page_alloc });
    }
}

fn connServer(conn: net.Server.Connection, alloc: std.mem.Allocator) void {
    defer conn.stream.close();

    var buff: [1024]u8 = undefined;
    var server = http.Server.init(conn, &buff);

    while (server.state == .ready) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => continue,
            else => |e| {
                std.log.err("Error responding to request: {}", .{e});
                continue;
            },
        };

        handleRequest(&req, alloc) catch |err| {
            std.log.err("Error handling request: {}", .{err});
        };
    }
}

fn handleRequest(request: *http.Server.Request, _: std.mem.Allocator) !void {
    // const body = try (try request.reader()).readAllAlloc(allocator, 1024);
    // defer allocator.free(body);

    if (std.mem.startsWith(u8, request.head.target, "/index.html")) {
        request.respond("", .{}) catch |err| {
            std.log.err("Error responding to request: {}", .{err});
        };
    } else if (std.mem.eql(u8, request.head.target, "/")) {
        request.respond("", .{}) catch |err| {
            std.log.err("Error responding to request: {}", .{err});
        };
    } else if (std.mem.startsWith(u8, request.head.target, "/echo")) {
        var echo = std.mem.splitAny(u8, request.head.target, "/");
        _ = echo.next();
        _ = echo.next();
        const respEcho = echo.next().?;

        request.respond(respEcho, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }} }) catch |err| {
            std.log.err("Error responding to request: {}", .{err});
        };
    } else if (std.mem.startsWith(u8, request.head.target, "/user-agent")) {
        var it = request.iterateHeaders();
        var respBody: []const u8 = undefined;

        while (it.next()) |header| {
            if (std.mem.eql(u8, header.name, "User-Agent")) {
                respBody = header.value;
            }
        }

        request.respond(respBody, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }} }) catch |err| {
            std.log.err("Error responding to request: {}", .{err});
        };
    } else {
        request.respond("", .{ .status = .not_found }) catch |err| {
            std.log.err("Error responding to request: {}", .{err});
        };
    }
}
