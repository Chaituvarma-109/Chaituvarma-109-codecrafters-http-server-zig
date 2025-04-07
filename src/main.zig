const std = @import("std");
const net = std.net;
const http = std.http;
const Pool = std.Thread.Pool;

const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    const page_alloc = std.heap.page_allocator;

    var args = std.process.argsWithAllocator(page_alloc) catch |err| {
        std.log.err("Error in args", .{err});
    };
    defer args.deinit();
    _ = args.skip();

    var dirname: []u8 = undefined;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--directory")) {
            dirname = @constCast(args.next().?);
        }
    }

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

        try pool.spawn(connServer, .{ conn, page_alloc, dirname });
    }
}

fn connServer(conn: net.Server.Connection, alloc: std.mem.Allocator, dirname: []const u8) void {
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

        handleRequest(&req, alloc, dirname) catch |err| {
            std.log.err("Error handling request: {}", .{err});
        };
    }
}

fn handleRequest(request: *http.Server.Request, alloc: std.mem.Allocator, dirname: []const u8) !void {
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
    } else if (std.mem.startsWith(u8, request.head.target, "/files")) {
        var fi = std.mem.splitAny(u8, request.head.target, "/");
        _ = fi.next();
        _ = fi.next();
        const filename = fi.next().?;
        const filepath = try std.fmt.allocPrint(alloc, "{s}{s}", .{ dirname, filename });

        const file = std.fs.cwd().openFile(filepath, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    try request.respond("", .{ .status = .not_found });
                    return;
                },
                else => {
                    std.log.err("Error opening file: {}", .{err});
                    try request.respond("", .{ .status = .internal_server_error });
                    return;
                },
            }
        };
        defer file.close();
        const buff = try std.fs.cwd().readFileAlloc(alloc, filepath, std.math.maxInt(usize));
        defer alloc.free(buff);

        try request.respond(buff, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/octet-stream" }} });
    } else {
        request.respond("", .{ .status = .not_found }) catch |err| {
            std.log.err("Error responding to request: {}", .{err});
        };
    }
}
