const std = @import("std");
const fs = std.fs;

const cnf = @import("config.zig");
const serialize = @import("serialize.zig");
const parse = @import("parse.zig");
const utils = @import("utils.zig");

const Simple = struct {
    id: []const u8,
    age: []const u8,
};

fn copyCsv(comptime T: type, from_path: []const u8, to_path: []const u8) !usize {
    var from_file = try fs.cwd().openFile(from_path, .{});
    defer from_file.close();
    const reader = from_file.reader();

    var to_file = try fs.cwd().createFile(to_path, .{});
    defer to_file.close();
    const writer = to_file.writer();

    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = try parse.CsvParser(T, fs.File.Reader, .{}).init(arena.allocator(), reader);

    var serializer = serialize.CsvSerializer(T, fs.File.Writer, .{}).init(writer);

    var rows: usize = 0;
    try serializer.writeHeader();
    while (try parser.next()) |row| {
        rows = rows + 1;
        try serializer.appendRow(row);
    }

    return rows;
}

// test "end to end" {
//     const from_path = "test/data/simple_end_to_end.csv";
//     const to_path = "tmp/simple_end_to_end.csv";

//     var from_file = try fs.cwd().openFile(from_path, .{});
//     defer from_file.close();

//     var to_file = try fs.cwd().openFile(to_path, .{});
//     defer to_file.close();

//     const rows = try copyCsv(Simple, from_path, to_path);

//     const expected_rows: usize = 17;
//     try std.testing.expectEqual(expected_rows, rows);

//     try std.testing.expect(try utils.eqlContentReader(from_file.reader(), to_file.reader()));
// }

const Color = enum { red, blue, green, yellow };

const Pokemon = struct {
    id: u32,
    name: []const u8,
    captured: bool,
    color: Color,
    health: ?f32,
};

test "parsing pokemon" {
    var file = try fs.cwd().openFile("test/data/pokemon_example.csv", .{});
    defer file.close();
    const reader = file.reader();

    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const config: cnf.CsvConfig = .{};
    const PokemonCsvParser = parse.CsvParser(Pokemon, fs.File.Reader, config);

    var parser = try PokemonCsvParser.init(arena.allocator(), reader);

    var number_captured: u32 = 0;
    while (try parser.next()) |pokemon| {
        if (pokemon.captured) {
            number_captured += 1;
        }
    }
    try std.testing.expectEqual(number_captured, 1);
}

test "serializing pokemon" {
    // var file = try fs.cwd().createFile("tmp/pokemon.csv", .{});
    // defer file.close();
    var buf: [1000]u8 = .{0} ** 1000;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const config: cnf.CsvConfig = .{};
    const PokemonCsvSerializer = serialize.CsvSerializer(Pokemon, @TypeOf(writer), config);
    var serializer = PokemonCsvSerializer.init(writer);

    const pokemons = [3]Pokemon{
        Pokemon{
            .id = 1,
            .name = "squirtle",
            .captured = false,
            .color = Color.blue,
            .health = null,
        },
        Pokemon{
            .id = 2,
            .name = "charmander",
            .captured = false,
            .color = Color.red,
            .health = null,
        },
        Pokemon{
            .id = 3,
            .name = "pikachu",
            .captured = true,
            .color = Color.yellow,
            .health = 10.0,
        },
    };

    try serializer.writeHeader();

    for (pokemons) |pokemon| {
        try serializer.appendRow(pokemon);
    }
}

test "buffer end to end" {
    const T = struct { id: u32, name: []const u8 };

    // parse
    const source = "id,name,\n1,none,";
    const n = source.len;

    var parsed_rows: [1]T = undefined;

    var buffer_stream = std.io.fixedBufferStream(source[0..n]);
    const reader = buffer_stream.reader();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var parser = try parse.CsvParser(T, @TypeOf(reader), .{}).init(arena_allocator, reader);

    var i: usize = 0;
    while (try parser.next()) |row| {
        parsed_rows[i] = row;
        i += 1;
    }

    // serialize
    var buffer: [n + 1]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(buffer[0..]);
    const writer = fixed_buffer_stream.writer();

    var serializer = serialize.CsvSerializer(T, @TypeOf(writer), .{}).init(writer);

    try serializer.writeHeader();
    for (parsed_rows) |row| {
        try serializer.appendRow(row);
    }

    try std.testing.expect(std.mem.eql(u8, source, buffer[0..n]));
}

test "fixed buffer allocator" {
    const NamelessPokemon = struct {
        id: void,
        name: []const u8,
        captured: bool,
        color: void,
        health: void,
    };

    var file = try fs.cwd().openFile("test/data/pokemon_example.csv", .{});
    defer file.close();
    const reader = file.reader();

    // 2. We will keep the strings of one row at a time in this buffer
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const PokemonCsvParser = parse.CsvParser(NamelessPokemon, fs.File.Reader, .{});

    var parser = try PokemonCsvParser.init(fba.allocator(), reader);

    var pikachus_captured: u32 = 0;
    while (try parser.next()) |pokemon| {

        // 1. We only use pokemon.captured and pokemon.name, everything else is void
        if (pokemon.captured and std.mem.eql(u8, "pikachu", pokemon.name)) {
            pikachus_captured += 1;
        }

        // 2. We already used the allocated strings (pokemon.name) so we can reset
        //    the memory. If we didn't, we would get an OutOfMemory error when the
        //    FixedBufferAllocator runs out of memory
        fba.reset();
    }
    try std.testing.expectEqual(pikachus_captured, 1);
}
