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
    if (std.mem.startsWith(u8, request.head.target, "/index.html")) {
        request.respond("", .{}) catch |err| {
            std.log.err("Error responding to request: {}", .{err});
        };
    } else if (std.mem.eql(u8, request.head.target, "/")) {
        request.respond("", .{}) catch |err| {
            std.log.err("Error responding to request: {}", .{err});
        };
    } else if (std.mem.startsWith(u8, request.head.target, "/echo")) {
        const respEcho = request.head.target[6..];
        var iter = request.iterateHeaders();
        var supports_gzip = false;

        while (iter.next()) |header| {
            if (std.mem.eql(u8, header.name, "Accept-Encoding")) {
                var it = std.mem.splitAny(u8, header.value, ", ");
                while (it.next()) |val| {
                    if (std.mem.eql(u8, val, "gzip")) {
                        supports_gzip = true;
                    }
                }
            }
        }

        if (supports_gzip) {
            var arr = std.ArrayList(u8).init(alloc);
            defer arr.deinit();

            var buff = std.io.fixedBufferStream(respEcho);
            try std.compress.gzip.compress(buff.reader(), arr.writer(), .{});

            request.respond(arr.items, .{ .extra_headers = &.{ .{ .name = "Content-Type", .value = "text/plain" }, .{ .name = "Content-Encoding", .value = "gzip" } } }) catch |err| {
                std.log.err("Error responding to request: {}", .{err});
            };
        } else {
            request.respond(respEcho, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }} }) catch |err| {
                std.log.err("Error responding to request: {}", .{err});
            };
        }
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
        const filename = request.head.target[7..];
        try stdout.print("{s}\n", .{filename});
        const filepath = try std.fmt.allocPrint(alloc, "{s}{s}", .{ dirname, filename });

        switch (request.head.method) {
            .GET => {
                const buff = std.fs.cwd().readFileAlloc(alloc, filepath, std.math.maxInt(usize)) catch |err| {
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
                defer alloc.free(buff);

                try request.respond(buff, .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/octet-stream" }} });
            },
            .POST => {
                const body = try (try request.reader()).readAllAlloc(alloc, 1024 * 1024);
                defer alloc.free(body);

                const file = std.fs.cwd().createFile(filepath, .{}) catch |err| {
                    std.log.err("Error creating file: {}", .{err});
                    try request.respond("", .{ .status = .internal_server_error });
                    return;
                };
                defer file.close();

                file.writeAll(body) catch |err| {
                    std.log.err("Error writing to file: {}", .{err});
                    try request.respond("", .{ .status = .internal_server_error });
                    return;
                };

                try request.respond("", .{ .status = .created });
            },
            else => {
                try request.respond("", .{ .status = .internal_server_error });
                return;
            },
        }
    } else {
        request.respond("", .{ .status = .not_found }) catch |err| {
            std.log.err("Error responding to request: {}", .{err});
        };
    }
}
