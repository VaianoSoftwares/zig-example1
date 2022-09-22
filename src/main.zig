const std = @import("std");
const serial = @import("serial");

const array = @import("custom_utils").array;

const fs = std.fs;
const mem = std.mem;
const net = std.net;
const json = std.json;
const testing = std.testing;


const scan_driver = "cdc_acm";

const FindScanErr = error {
    NoScannerFound,
};

const ArgsParseErr = error {
    MissingToken,
};

const headers_format =  "POST /api/v1/badges/archivio HTTP/1.1\r\n"         ++
                        // "Host: {s}\r\n"                                     ++
                        "guest-token: {s}\r\n"                              ++                     
                        "Content-Type: application/json; charset=utf-8\r\n" ++
                        "Content-Length: {d}\r\n\r\n"                       ++
                        "{s}";

const default_host = "127.0.0.1";
const default_port = "443";

const default_cliente = "cliente1";
const default_post = "post1";
const default_tipo = "BARCODE";

const BodyArgs = struct {
    cliente: []const u8 = default_cliente,
    postazione: []const u8 = default_post,
    barcode: []const u8 = undefined,
    tipo: []const u8 = default_tipo,
};

pub fn main() !u8 {
    // cmd args parsing
    var token: []u8 = undefined;
    var serv_addr: net.Address = undefined;
    var body_args: BodyArgs = undefined;
    try parse_cmd_args(&token, &serv_addr, &body_args);

    // connect to server
    var opt_conn: ?net.Stream = null;
    while(opt_conn == null) {
        opt_conn = conn_to_server(serv_addr);
        if(opt_conn == null) {
            // std.log.err("Connection failed.\n", .{});
            std.time.sleep(std.time.ns_per_s);
        }
    }

    const conn_stream: net.Stream = opt_conn.?;
    defer conn_stream.close();

    // connect scanner
    var opt_scanner: ?fs.File = null;
    while(opt_scanner == null) {
        opt_scanner = try find_scanner();
        if(opt_scanner == null) {
            std.log.err("No scanner available.\n", .{});
            std.time.sleep(std.time.ns_per_s * 5);
        }
    }

    const scanner: fs.File = opt_scanner.?;
    defer scanner.close();

    // scanner setup
    try serial.configureSerialPort(scanner, serial.SerialConfig{
        .baud_rate = 115200,
        .word_size = 8,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    });

    var scan_buf: [64]u8 = undefined;
    var bytes_read: usize = undefined;

    while(true) {
        bytes_read = try scanner.reader().read(&scan_buf);
        const barcode = scan_buf[0..bytes_read];
        std.log.info("barcode={s} bytes_read={d}\n", .{ barcode, bytes_read });

        const req_body = BodyArgs{
            .barcode = barcode,
            .cliente = body_args.cliente,
            .postazione = body_args.postazione,
            .tipo = body_args.tipo,
        };

        const str_body = try get_body_str(req_body);

        // try conn_stream.writer().print(headers_format, .{serv_host, token, str_body.len, str_body});
        try conn_stream.writer().print(headers_format, .{token, str_body.len, str_body});
    }

    return 0;
}

fn parse_cmd_args(token: *[]u8, serv_addr: *net.Address, body_args: *BodyArgs) !void {
    var args_buf: [256]u8 = undefined;
    var cmd_alloc = std.heap.FixedBufferAllocator
        .init(&args_buf)
        .allocator();

    var args_iter = std.process.args();
    defer args_iter.deinit();

    _ = args_iter.skip();

    token.* = try args_iter.next(cmd_alloc) orelse {
        std.log.err("No token specified.\n", .{});
        return ArgsParseErr.MissingToken;
    };

    const serv_name = try args_iter.next(cmd_alloc) orelse default_host;
    const serv_port = port_blk: {
        const port_str = try args_iter.next(cmd_alloc) orelse default_port;
        const port_u16 = try std.fmt.parseUnsigned(u16, port_str, 0);
        break :port_blk port_u16;
    };
    serv_addr.* = try net.Address.resolveIp(serv_name, serv_port);

    
    body_args.* = BodyArgs{
        .cliente = try args_iter.next(cmd_alloc) orelse default_cliente,
        .postazione = try args_iter.next(cmd_alloc) orelse default_post,
        .tipo = try args_iter.next(cmd_alloc) orelse default_tipo,
    };
}

fn get_body_str(args: BodyArgs) ![]const u8 {    
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var str_args = std.ArrayList(u8).init(fba.allocator());
    defer str_args.deinit();

    try json.stringify(args, .{}, str_args.writer());

    std.log.info("str_args={s}\n", .{str_args});

    return str_args.items[0..str_args.items.len];
}

fn find_scanner() !?fs.File {
    var port_itir = try serial.list();
    defer port_itir.deinit();

    var scanner: ?fs.File = null;
    // errdefer if(scanner) |scanner| scanner.close();
    
    while(try port_itir.next()) |port| {
        // std.log.info("path={s}\tname={s}\tdriver={s}\n", .{ port.file_name, port.display_name, port.driver });

        if(!mem.eql(u8, port.driver.?, scan_driver)) continue;

        scanner = fs.cwd().openFile(port.file_name, .{ .read = true }) catch |err| {
            std.log.err("Can't open {s}. Error: {s}\n", .{ port.file_name, err });

            if(scanner) |value| value.close();
            scanner = null;

            continue;
        };

        std.log.info("Scanner {s} connected.\n", .{ port.file_name });

        break;
    }
    
    return scanner;
}

fn conn_to_server(addr: net.Address) ?net.Stream {
    const conn = net.tcpConnectToAddress(addr) catch |err| {
        std.log.err("Connection failed. Error: {s}\n", .{err});
        return null;
    };
    return conn;
}

test "json stringify struct" {
    const body_args = BodyArgs{
        .barcode = "CODICE1",
    };

    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var str_args = std.ArrayList(u8).init(fba.allocator());
    defer str_args.deinit();

    try json.stringify(body_args, .{}, str_args.writer());

    const expected_value =  "{\"cliente\":\"cliente1\","    ++
                            "\"postazione\":\"post1\","     ++
                            "\"barcode\":\"CODICE1\","       ++
                            "\"tipo\":\"BARCODE\"}";
    
    std.debug.print("{s}\n", .{str_args.items});
    std.debug.print("{s}\n", .{expected_value});

    try testing.expect(mem.eql(u8, str_args.items, expected_value));
}