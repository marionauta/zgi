const std = @import("std");
const fs = std.fs;
const httpz = @import("httpz");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip program name
    const directory_name = args.next() orelse {
        std.log.err("Missing directory name", .{});
        std.process.exit(1);
    };

    const cwd = std.fs.cwd();
    var directory = cwd.openDir(directory_name, .{}) catch |err| {
        std.log.err("Unable to open directory {s}: {}", .{ directory_name, err });
        std.process.exit(1);
    };
    defer directory.close();

    var environment = try std.process.getEnvMap(allocator);
    defer environment.deinit();
    const hostname = environment.get("HOSTNAME") orelse environment.get("HOST");
    const port: u16 = if (environment.get("PORT")) |ps| try std.fmt.parseInt(u16, ps, 10) else 8000;

    var context = Context{ .directory = directory, .hostname = hostname orelse "localhost", .port = port };
    var server = try httpz.Server(*Context).init(allocator, .{ .address = hostname, .port = port }, &context);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.all("*", serve, .{});

    std.debug.print("Listening on http://{s}:{}\n", .{ context.hostname, context.port });
    try server.listen();
}

const Context = struct {
    directory: std.fs.Dir,
    hostname: []const u8,
    port: u16,
};

fn serve(context: *Context, request: *httpz.Request, response: *httpz.Response) !void {
    const allocator = request.arena;

    const file_name = request.url.path[1..];
    if (file_name.len == 0) {
        return not_found(response);
    }

    const file = context.directory.openFile(file_name, .{}) catch {
        std.log.err("No file {s} in directory", .{file_name});
        return not_found(response);
    };
    defer file.close();

    const permissions = std.fs.File.PermissionsUnix.unixNew(try file.mode());
    if (!permissions.unixHas(.user, .execute)) {
        std.log.err("File {s} is not executable", .{file_name});
        return not_found(response);
    }

    var body_buffer: std.ArrayList(u8) = .empty;
    if (request.body()) |body| {
        try body_buffer.appendSlice(allocator, body);
    }

    var environment = std.process.EnvMap.init(allocator);
    if (body_buffer.items.len > 0) {
        try environment.put("CONTENT_LENGTH", try std.fmt.allocPrint(allocator, "{}", .{body_buffer.items.len}));
        if (request.header("content-type")) |content_type| {
            try environment.put("CONTENT_TYPE", content_type);
        }
    }
    try environment.put("GATEWAY_INTERFACE", "CGI/1.1");
    try environment.put("QUERY_STRING", ""); // TODO: pass query string

    {
        var address_buffer: std.ArrayList(u8) = .empty;
        try address_buffer.print(allocator, "{f}", .{request.address});
        const colon_index = std.mem.indexOfScalar(u8, address_buffer.items, ':');
        const addr = if (colon_index) |index| address_buffer.items[0..index] else address_buffer.items;
        try environment.put("REMOTE_ADDR", addr);
        try environment.put("REMOTE_HOST", addr);
    }
    const method = if (request.method != .OTHER) blk: {
        const method = try std.fmt.allocPrint(allocator, "{}", .{request.method});
        break :blk method[1..];
    } else request.method_string;
    try environment.put("REQUEST_METHOD", method);
    {
        var host = request.header("x-forwarded-host") orelse request.header("host") orelse context.hostname;
        var port: ?[]const u8 = null;
        if (split(host, ':')) |parts| {
            host = parts[0];
            port = parts[1];
        }
        try environment.put("SERVER_NAME", host);
        const pport = request.header("x-forwarded-port") orelse port orelse try std.fmt.allocPrint(allocator, "{}", .{context.port});
        try environment.put("SERVER_PORT", pport);
    }
    try environment.put("SERVER_PROTOCOL", "HTTP/1.1");

    var header_iterator = request.headers.iterator();
    while (header_iterator.next()) |header| {
        var key = try header_into_meta_variable(allocator, header.key);
        defer key.deinit(allocator);
        try environment.put(key.items, header.value);
    }

    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    const res_writer = response.writer();

    const file_path = try context.directory.realpathAlloc(allocator, file_name);
    var proc = std.process.Child.init(&.{file_path}, allocator);
    proc.env_map = &environment;
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;

    try proc.spawn();

    if (proc.stdin) |in| {
        _ = try in.write(body_buffer.items);
    }

    if (proc.stderr) |err| {
        var file_reader = err.reader(&err_buffer);
        const reader = &file_reader.interface;
        while (try reader.takeDelimiter('\n')) |line| {
            std.log.info("{s}: {s}", .{ file_name, line });
        }
    }

    if (proc.stdout) |out| {
        var file_reader = out.reader(&out_buffer);
        const reader = &file_reader.interface;

        while (try reader.peekByte() != '\n') {
            if (try reader.takeDelimiter('\n')) |header| {
                if (split(header, ':')) |parts| {
                    if (std.mem.eql(u8, parts[0], "Status")) {
                        // TODO: clean up this mess
                        var status = parts[1];
                        status: for (status, 0..) |value, index| {
                            if (value != ' ') {
                                status = status[index..];
                                break :status;
                            }
                        }
                        if (split(status, ' ')) |status_parts| status = status_parts[0];
                        response.status = std.fmt.parseInt(u16, status, 10) catch 200;
                    } else {
                        response.header(parts[0], parts[1]);
                    }
                }
            }
        }
        _ = try reader.takeByte();
        if (request.method != .HEAD) {
            _ = try reader.streamRemaining(res_writer);
        }
    }

    switch (try proc.wait()) {
        .Exited => |status| {
            if (status != 0) {
                std.log.err("{s}: exited with status {}", .{ file_name, status });
            }
        },
        else => |term| {
            std.log.err("{s}: abnormal termination {}", .{ file_name, term });
        },
    }

    try res_writer.flush();
}

fn split(raw: []const u8, comptime separator: u8) ?(struct { []const u8, []const u8 }) {
    const index = std.mem.indexOfScalar(u8, raw, separator) orelse return null;
    return .{ raw[0..index], raw[(index + 1)..] };
}

fn not_found(response: *httpz.Response) void {
    response.status = 404;
    response.body = "not found";
}

fn header_into_meta_variable(allocator: std.mem.Allocator, header: []const u8) !std.ArrayList(u8) {
    const prefix = "HTTP_";
    var header_buffer: std.ArrayList(u8) = .empty;
    // defer header_buffer.deinit(allocator);
    try header_buffer.appendSlice(allocator, prefix);
    for (header) |letter| {
        if (letter == '-') {
            try header_buffer.append(allocator, '_');
        } else {
            try header_buffer.append(allocator, std.ascii.toUpper(letter));
        }
    }
    return header_buffer;
}
