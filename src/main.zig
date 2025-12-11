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

    var context = Context{ .directory = directory };
    var server = try httpz.Server(*Context).init(allocator, .{ .address = hostname, .port = port }, &context);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.all("*", serve, .{});

    std.debug.print("Listening on http://{s}:{}\n", .{ hostname orelse "localhost", port });
    try server.listen();
}

const Context = struct {
    directory: std.fs.Dir,
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

    const permissions = std.fs.File.PermissionsUnix.unixNew(try file.mode());
    if (!permissions.unixHas(.user, .execute)) {
        std.log.err("File {s} is not executable", .{file_name});
        return not_found(response);
    }

    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    const res_writer = response.writer();

    const file_path = try context.directory.realpathAlloc(allocator, file_name);
    var proc = std.process.Child.init(&.{file_path}, allocator);
    proc.env_map = &std.process.EnvMap.init(allocator);
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;

    try proc.spawn();
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
        _ = try reader.streamRemaining(res_writer);
    }
    if (proc.stderr) |err| {
        var file_reader = err.reader(&err_buffer);
        const reader = &file_reader.interface;
        while (try reader.takeDelimiter('\n')) |line| {
            std.log.info("{s}: {s}", .{ file_name, line });
        }
    }
    const term = try proc.wait();
    std.debug.assert(term == .Exited);
    try res_writer.flush();
}

fn split(raw: []u8, comptime separator: u8) ?(struct { []u8, []u8 }) {
    for (raw, 1..) |char, index| {
        if (char == separator) {
            return .{ raw[0 .. index - 1], raw[index..] };
        }
    }
    return null;
}

fn not_found(response: *httpz.Response) void {
    response.status = 404;
    response.body = "not found";
}
