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
        std.log.err("ERROR: missing directory name\n", .{});
        std.process.exit(1);
    };

    const cwd = std.fs.cwd();
    var directory = cwd.openDir(directory_name, .{}) catch |err| {
        std.log.err("ERROR: unable to open directory {s}: {}", .{ directory_name, err });
        std.process.exit(1);
    };
    defer directory.close();

    const port = 8000;
    var gateway = Gateway.init(allocator, directory);
    var server = try httpz.Server(*Gateway).init(allocator, .{ .port = port }, &gateway);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("*", serve, .{});
    std.debug.print("Listening on http://localhost:{}\n", .{port});
    try server.listen();
}

const Gateway = struct {
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,

    fn init(allocator: std.mem.Allocator, directory: fs.Dir) Gateway {
        return .{
            .allocator = allocator,
            .directory = directory,
        };
    }
};

fn serve(gateway: *Gateway, req: *httpz.Request, res: *httpz.Response) !void {
    const binary_name = req.url.path[1..];
    if (binary_name.len == 0) {
        res.status = 404;
        res.body = "not found";
        return;
    }

    const binary_stat = gateway.directory.statFile(binary_name) catch {
        std.log.err("No file {s} in directory", .{binary_name});
        res.status = 404;
        res.body = "not found";
        return;
    };
    const permissions = std.fs.File.PermissionsUnix.unixNew(binary_stat.mode);
    if (!permissions.unixHas(.user, .execute)) {
        std.log.err("Binary {s} is not executable", .{binary_name});
        res.body = "methd not allowed";
        return;
    }

    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    const res_writer = res.writer();

    const binary_path = try gateway.directory.realpathAlloc(gateway.allocator, binary_name);
    var proc = std.process.Child.init(&.{binary_path}, gateway.allocator);
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;

    try proc.spawn();
    if (proc.stdout) |out| {
        var file_reader = out.reader(&out_buffer);
        const reader = &file_reader.interface;

        while (try reader.peekByte() != '\n') {
            if (try reader.takeDelimiter('\n')) |header| {
                if (split(header)) |parts| {
                    res.headers.add(parts[0], parts[1]);
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
            std.log.info("{s}: {s}", .{ binary_name, line });
        }
    }
    const term = try proc.wait();
    std.debug.assert(term == .Exited);
    try res_writer.flush();
}

fn split(raw: []u8) ?(struct { []u8, []u8 }) {
    for (raw, 1..) |char, index| {
        if (char == ':') {
            return .{ raw[0 .. index - 1], raw[index..] };
        }
    }
    return null;
}
