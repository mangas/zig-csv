const std = @import("std");
const fs = std.fs;
const Type = std.builtin.Type;

const cnf = @import("config.zig");
const tokenize = @import("fast_tokenize.zig");
// const tokenize = @import("csv/tokenize.zig");

// ============================================================================
// Utils

pub inline fn parseAtomic(
    comptime T: type,
    comptime field_name: []const u8,
    input_val: []const u8,
) !T {
    switch (@typeInfo(T)) {
        .Bool => {
            if (std.mem.eql(u8, "true", input_val)) {
                return true;
            } else if (std.mem.eql(u8, "false", input_val)) {
                return false;
            } else {
                return error.BadInput;
            }
        },
        .Int => {
            return std.fmt.parseInt(T, input_val, 0) catch {
                return error.BadInput;
            };
        },
        .Float => {
            return std.fmt.parseFloat(T, input_val) catch {
                return error.BadInput;
            };
        },
        .Enum => |Enum| {
            comptime var i = 0;
            inline for (Enum.fields) |EnumField| {
                if (std.mem.eql(u8, input_val, EnumField.name)) {
                    return std.enums.nameCast(T, EnumField.name);
                }
                comptime i = i + 1;
            }
            if (Enum.is_exhaustive) {
                return error.BadInput;
            } else {
                // we generate the first enum outside of the possible enums
                return @as(T, @enumFromInt(i));
            }
        },
        .Struct => |_| {
            // std.debug.print("{any} - {s}", .{ T, input_val });
            if (!@hasDecl(T, "fromStr")) {
                return error.BadInput;
                // @compileError("Unsupported type " ++ @typeName(T) ++ " for field " ++ field_name);
            }
            const fromStr = T.fromStr;
            const info = @typeInfo(@TypeOf(fromStr));
            if (info == .Fn) {
                const func = info.Fn;
                if (func.params.len != 1) {
                    @compileError("Unsupported type " ++ @typeName(T) ++ ". Expected fromStr fn([]const u8) !T");
                }
                // if (func.return_type == null or func.return_type.? != T) {
                //     @compileError("Unsupported type " ++ @typeName(T) ++ ". Expected fromStr fn([]const u8) !T");
                // }

                return @call(.auto, fromStr, .{input_val});
            }
        },
        else => {
            @compileError("Unsupported type " ++ @typeName(T) ++ " for field " ++ field_name);
        },
    }
}

// ============================================================================
// Parser

// Want to do something that feels like a JIT

// 1. Read a schema from a file
// 2. Load a CSV file containing data that matches the schema
// 3. Print that

// I can start by doing that for a known schema and then seeing how to read the schema

// const csv_config = csv_mod.CsvConfig{
//     .col_sep = ',',
//     .row_sep = '\n',
//     .quote = '"',
// };

// Writing a CSV library that knew how to read directly into Structs would be cool

// something like

// readCSV(StructType, allocator, path) -> std.ArrayList(StructType)

// bonus points if it can be called during comptime to get a compile time array

// what is the ideal API?

// 1. Streaming so that the user can control how much memory to consume
// 2. Coerces to the types you already want
// 3. Efficient so that you can do it quickly if you want
// 4. Can read files partially

// var csv_reader = csv.Reader.init(T, allocator, file_reader);
// csv_reader.nextRow() -> ?T
// if ?T is null, we are done

const InternalParseError = error{
    // Should these be named CSV_ as to not pollute the overall error set?
    BadInput,
    MissingFields,
    ExtraFields,
    OutOfMemory,
};

// put this under CsvParser
pub const CsvParseError = tokenize.TokenizeError || InternalParseError;

// Errors from reading a File:

// 'error.MisplacedQuote' not a member of destination error set
// 'error.NoSeparatorAfterField' not a member of destination error set
// 'error.ShortBuffer' not a member of destination error set
// 'error.AccessDenied' not a member of destination error set
// 'error.BrokenPipe' not a member of destination error set
// 'error.ConnectionResetByPeer' not a member of destination error set
// 'error.ConnectionTimedOut' not a member of destination error set
// 'error.InputOutput' not a member of destination error set
// 'error.IsDir' not a member of destination error set
// 'error.NotOpenForReading' not a member of destination error set
// 'error.OperationAborted' not a member of destination error set
// 'error.SystemResources' not a member of destination error set
// 'error.Unexpected' not a member of destination error set
// 'error.WouldBlock' not a member of destination error set

pub fn CsvParser(
    comptime T: type,
    comptime Reader: type,
    comptime config: cnf.CsvConfig,
) type {
    return struct {
        const Self = @This();
        const Tokenizer = tokenize.CsvTokenizer(Reader, config);

        const Fields: []const Type.StructField = switch (@typeInfo(T)) {
            .Struct => |S| S.fields,
            else => @compileError("T needs to be a struct"),
        };

        const number_of_fields: usize = Fields.len;

        allocator: std.mem.Allocator,
        reader: Reader,
        tokenizer: Tokenizer,

        // The caller has to free the allocator when it is done with everything that
        // was parsed / allocated
        pub fn init(
            allocator: std.mem.Allocator,
            reader: Reader,
        ) CsvParseError!Self {
            var tokenizer = Tokenizer{ .reader = reader };

            var self = Self{
                .reader = reader,
                .tokenizer = tokenizer,
                .allocator = allocator,
            };

            if (config.skip_first_row) {
                try self.consume_row();
            }

            return self;
        }

        /// Try to read a row and return a parsed T out of it if possible
        /// Returns null if the iterator is done
        pub fn next(self: *Self) !?T {
            // TODO: Who should be managing draft_struct's memory?
            var draft_struct: T = undefined;
            const maybe = try self.nextInto(&draft_struct);
            if (maybe) |_| {
                return draft_struct;
            } else {
                return null;
            }
        }

        // Try to read a row into draft_struct and re-return it it if possible
        pub fn nextInto(self: *Self, draft_struct: *T) !?*T {
            var fields_added: u32 = 0;
            inline for (Fields) |F| {
                const token = try self.tokenizer.next();
                // tokenize.debugToken(token);
                switch (token) {
                    .row_end => return error.MissingFields,
                    .eof => return null,
                    .field => |field| {
                        // the user wants an immutable slice
                        // we need to grab what we read, copy it somewhere it will remain valid
                        // and then give them that slice

                        const FieldInfo = @typeInfo(F.type);
                        switch (FieldInfo) {
                            .Void => {
                                @field(draft_struct, F.name) = {};
                            },
                            .Pointer => |info| {
                                switch (info.size) {
                                    .Slice => {
                                        if (info.child != u8) {
                                            @compileError("Slices can only be u8 and '" ++ F.name ++ "' is " ++ @typeName(info.child));
                                        } else if (info.is_const) {
                                            const mutable_slice = self.allocator.alloc(u8, field.len) catch {
                                                return error.OutOfMemory;
                                            };
                                            std.mem.copy(u8, mutable_slice, field);
                                            @field(draft_struct, F.name) = mutable_slice[0..field.len];
                                        } else {
                                            @compileError("Mutable slices are not implemented and '" ++ F.name ++ "' is a mutable slice");
                                        }
                                    },
                                    else => @compileError("Pointer not implemented yet and '" ++ F.name ++ "'' is a pointer."),
                                }
                            },
                            .Optional => |Optional| {
                                // Unwrap the optional
                                // const NestedFieldType: type = Optional.child;
                                if (field.len == 0) {
                                    @field(draft_struct, F.name) = null;
                                } else {
                                    @field(draft_struct, F.name) = try parseAtomic(Optional.child, F.name, field);
                                }
                            },
                            .Union => |U| {
                                var maybe_out: ?F.type = null;
                                inline for (U.fields) |UF| {
                                    const maybe_atomic: ?UF.type = parseAtomic(UF.type, UF.name, field) catch null;
                                    if (maybe_atomic) |atomic| {
                                        maybe_out = @unionInit(F.type, UF.name, atomic);
                                        break; // stop when one succeeeds
                                    }
                                }
                                if (maybe_out) |out| {
                                    @field(draft_struct, F.name) = out;
                                } else {
                                    return error.BadInput;
                                }
                            },
                            else => {
                                @field(draft_struct, F.name) = try parseAtomic(F.type, F.name, field);
                            },
                        }
                        fields_added = fields_added + 1;
                    },
                }
            }

            // consume the row_end
            const token = try self.tokenizer.next();

            switch (token) {
                .field => {
                    if (token.field.len > 0) {
                        std.debug.print("Extra fields {s}\n", .{token.field});
                        return error.ExtraFields;
                    }
                },
                .row_end => {},
                .eof => {},
            }

            // were all the fields added?
            if (fields_added == number_of_fields) {
                return draft_struct;
            } else {
                return error.MissingFields;
            }
        }

        fn consume_row(self: *Self) !void {
            var token = try self.tokenizer.next();
            var continue_loop = true;
            while (continue_loop) {
                switch (token) {
                    .field => {
                        token = try self.tokenizer.next();
                        continue;
                    },
                    .row_end, .eof => {
                        continue_loop = false;
                        break;
                    },
                }
            }
        }
    };
}

fn testStructEql(comptime T: type, a: T, b: T) !void {
    const TypeInfo = @typeInfo(T);
    switch (TypeInfo) {
        .Void => {},
        .Optional => {
            const NestedFieldType: type = TypeInfo.Optional.child;
            if (a) |def_a| {
                if (b) |def_b| {
                    try testStructEql(NestedFieldType, def_a, def_b);
                } else {
                    try std.testing.expect(false);
                }
            } else {
                if (b) |_| {
                    try std.testing.expect(false);
                } else {
                    try std.testing.expect(true);
                }
            }
        },
        .Union => {
            try std.testing.expect(std.meta.eql(a, b));
            //     inline for (U.fields) |UF| {
            //         if (std.meta.isTag(a, UF.name)) {
            //             const def_a = @field(a, UF.name);
            //             if (std.meta.isTag(b, UF.name)) {
            //                 const def_b = @field(b, UF.name);
            //                 try testStructEql(UF.type, def_a, def_b);
            //             } else {
            //                 try std.testing.expect(false);
            //             }
            //         } else {
            //             if (std.meta.isTag(b, UF.name)) {
            //                 try std.testing.expect(false);
            //             } else {
            //                 try std.testing.expect(true);
            //             }
            //         }
            //     }
        },
        .Struct => {
            const Fields = TypeInfo.Struct.fields;
            inline for (Fields) |Field| {
                if (comptime Field.type == []const u8) {
                    // std.debug.print("Comparing {s} and {s}\n", .{ @field(a, Field.name), @field(b, Field.name) });
                    try std.testing.expect(std.mem.eql(u8, a.name, b.name));
                } else {
                    // try std.testing.expect(std.meta.eql(@field(a, Field.name), @field(b, Field.name)));
                    try testStructEql(Field.type, @field(a, Field.name), @field(b, Field.name));
                }
            }
        },
        .Int, .Float, .Bool, .Enum => {
            try std.testing.expectEqual(a, b);
        },
        else => @compileError("Invalid type: " ++ @typeName(T) ++ ". Should be void, struct, enum, union, optional, int, float, or bool"),
    }
}

// const builtin = @import("std").builtin;
//
// fn structEql(comptime T: type, a: T, b: T) bool {
//     const Fields = @typeInfo(T).Struct.fields;
//     inline for (Fields) |Field| {
//         if (comptime Field.type == []const u8) {
//             if (!std.mem.eql(u8, @field(a, Field.name), @field(b, Field.name))) {
//                 return false;
//             }
//         } else {
//             if (!builtin.eql(@field(a, Field.name), @field(b, Field.name))) {
//                 return false;
//             }
//         }
//     }
//     return true;
// }

test "parse" {
    var allocator = std.testing.allocator;

    const file_path = "test/data/simple_parse.csv";
    var file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    const SimpleParse = struct {
        id: u32,
        name: []const u8,
        unit: f32,
        nilable: ?u64,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = try CsvParser(SimpleParse, fs.File.Reader, .{}).init(arena.allocator(), file.reader());

    const maybe_first_row = try parser.next();

    // we the second struct before testing to see if the first row keeps its contents
    const maybe_second_row = try parser.next();

    if (maybe_first_row) |row| {
        const expected_row: SimpleParse = SimpleParse{
            .id = 1,
            .name = "abc",
            .unit = 1.1,
            .nilable = 111,
        };
        try testStructEql(SimpleParse, expected_row, row);
    } else {
        std.debug.print("Error parsing first row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    if (maybe_second_row) |row| {
        const expected_row: SimpleParse = SimpleParse{
            .id = 22,
            .name = "cdef",
            .unit = 22.2,
            .nilable = null,
        };
        try testStructEql(SimpleParse, expected_row, row);
    } else {
        std.debug.print("Error parsing second row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    const maybe_third_row = try parser.next();

    // we the fourth struct before testing to see if the third row keeps its contents
    const maybe_fourth_row = try parser.next();

    if (maybe_third_row) |row| {
        const expected_row: SimpleParse = SimpleParse{
            .id = 333,
            .name = "ghijk",
            .unit = 33.33,
            .nilable = 3333,
        };
        try testStructEql(SimpleParse, expected_row, row);
    } else {
        std.debug.print("Error parsing third row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    if (maybe_fourth_row) |_| {
        std.debug.print("Error parsing fourth row, expected null\n", .{});
        try std.testing.expectEqual(false, true);
    }
}

test "parse mutable slices" {
    const SliceParse = struct {
        id: u32,
        name: []const u8,
        unit: f32,
        nilable: ?u64,
    };
    var allocator = std.testing.allocator;

    const file_path = "test/data/simple_parse.csv";
    var file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = try CsvParser(SliceParse, fs.File.Reader, .{}).init(arena.allocator(), file.reader());

    const maybe_first_row = try parser.next();
    const maybe_second_row = try parser.next();
    if (maybe_first_row) |row| {
        const expected_row = SliceParse{
            .id = 1,
            .name = "abc",
            .unit = 1.1,
            .nilable = 111,
        };
        try testStructEql(SliceParse, expected_row, row);
    } else {
        std.debug.print("Error parsing first row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    if (maybe_second_row) |row| {
        const expected_row = SliceParse{
            .id = 22,
            .name = "cdef",
            .unit = 22.2,
            .nilable = null,
        };
        try testStructEql(SliceParse, expected_row, row);
    } else {
        std.debug.print("Error parsing second row\n", .{});
        try std.testing.expectEqual(false, true);
    }
}

test "parse into previously allocated structs" {
    const TightStruct = struct { id: i64, age: u32 };

    var allocator = std.testing.allocator;

    const file_path = "test/data/simple_end_to_end.csv";
    var file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const tight_array: []TightStruct = try arena_allocator.alloc(TightStruct, 17);

    var parser = try CsvParser(TightStruct, fs.File.Reader, .{}).init(arena_allocator, file.reader());

    const maybe_first_row = try parser.nextInto(&tight_array[0]);
    const maybe_second_row = try parser.nextInto(&tight_array[1]);

    if (maybe_first_row) |_| {
        const expected_row = TightStruct{ .id = 1, .age = 32 };
        try testStructEql(TightStruct, expected_row, tight_array[0]);
    } else {
        std.debug.print("Error parsing first row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    if (maybe_second_row) |_| {
        const expected_row = TightStruct{ .id = 1, .age = 28 };
        try testStructEql(TightStruct, expected_row, tight_array[1]);
    } else {
        std.debug.print("Error parsing second row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    var i: usize = 2; // we already advanced the parser twice
    while (i < 17) {
        const maybe_result = try parser.nextInto(&tight_array[i]);
        if (maybe_result == null) try std.testing.expect(false);
        i += 1;
    }

    const expected_last_row = TightStruct{ .id = 10, .age = 29 };
    try testStructEql(TightStruct, expected_last_row, tight_array[16]);
}

test "parse into arraylist" {
    const TightStruct = struct { id: i64, age: u32 };

    var allocator = std.testing.allocator;

    const file_path = "test/data/simple_end_to_end.csv";
    var file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    var list = std.ArrayList(TightStruct).init(allocator);
    defer list.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = try CsvParser(TightStruct, fs.File.Reader, .{}).init(arena.allocator(), file.reader());

    // We can use parser.nextInto with list.addOne
    {
        const elem = try list.addOne();
        const maybe_row = try parser.nextInto(elem);
        if (maybe_row) |_| {
            const expected_row = TightStruct{ .id = 1, .age = 32 };
            try testStructEql(TightStruct, expected_row, elem.*);
        } else {
            std.debug.print("Error parsing first row\n", .{});
            try std.testing.expectEqual(false, true);
        }
    }

    {
        const elem = try list.addOne();
        const maybe_row = try parser.nextInto(elem);
        if (maybe_row) |_| {
            const expected_row = TightStruct{ .id = 1, .age = 28 };
            try testStructEql(TightStruct, expected_row, elem.*);
        } else {
            std.debug.print("Error parsing second row\n", .{});
            try std.testing.expectEqual(false, true);
        }
    }

    // We can use parser.next with list.append
    while (try parser.next()) |row| {
        try list.append(row);
    }

    try std.testing.expectEqual(list.items.len, 17);

    const expected_last_row = TightStruct{ .id = 10, .age = 29 };
    try testStructEql(TightStruct, expected_last_row, list.pop());
}

test "parse enums" {
    var allocator = std.testing.allocator;

    const file_path = "test/data/parse_enum.csv";
    var file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    const OnOff = enum { ON, OFF };

    const Color = enum(u2) {
        red, // 00 -> 0
        blue, // 01 -> 1
        green, // 10 -> 2
        _, // 11 -> 3
    };

    const EnumParse = struct {
        id: u32,
        is_on: OnOff,
        color: Color,
        unit: void,
        nilable: ?u64,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = try CsvParser(EnumParse, fs.File.Reader, .{}).init(arena.allocator(), file.reader());

    const maybe_first_row = try parser.next();

    // we the second struct before testing to see if the first row keeps its contents
    const maybe_second_row = try parser.next();

    if (maybe_first_row) |row| {
        const expected_row = EnumParse{
            .id = 1,
            .is_on = OnOff.ON,
            .color = Color.red,
            .unit = {},
            .nilable = 111,
        };
        try testStructEql(EnumParse, expected_row, row);
    } else {
        std.debug.print("Error parsing first row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    if (maybe_second_row) |row| {
        const expected_row = EnumParse{
            .id = 22,
            .is_on = OnOff.OFF,
            .color = Color.blue,
            .unit = {},
            .nilable = null,
        };
        try testStructEql(EnumParse, expected_row, row);
    } else {
        std.debug.print("Error parsing second row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    const maybe_third_row = try parser.next();

    // we the fourth struct before testing to see if the third row keeps its contents
    const maybe_fourth_row = try parser.next();

    if (maybe_third_row) |row| {
        const expected_row = EnumParse{
            .id = 333,
            .is_on = OnOff.ON,
            .color = @as(Color, @enumFromInt(3)),
            .unit = {},
            .nilable = 3333,
        };
        try testStructEql(EnumParse, expected_row, row);
    } else {
        std.debug.print("Error parsing third row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    if (maybe_fourth_row) |_| {
        std.debug.print("Error parsing fourth row, expected null\n", .{});
        try std.testing.expectEqual(false, true);
    }
}

test "parse unions" {
    var allocator = std.testing.allocator;

    const file_path = "test/data/parse_union.csv";
    var file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    const Tag = enum { int, float, boolean };

    const SampleUnion = union(Tag) {
        int: i32,
        float: f64,
        boolean: bool,
    };

    const UnionStruct = struct { union_field: SampleUnion };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = try CsvParser(UnionStruct, fs.File.Reader, .{}).init(arena.allocator(), file.reader());

    const maybe_first_row = try parser.next();

    // we the second struct before testing to see if the first row keeps its contents
    const maybe_second_row = try parser.next();

    if (maybe_first_row) |row| {
        const expected_row = UnionStruct{ .union_field = SampleUnion{ .int = 1 } };
        try testStructEql(UnionStruct, expected_row, row);
    } else {
        std.debug.print("Error parsing first row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    if (maybe_second_row) |row| {
        const expected_row = UnionStruct{ .union_field = SampleUnion{ .float = 2.3 } };
        try testStructEql(UnionStruct, expected_row, row);
    } else {
        std.debug.print("Error parsing second row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    const maybe_third_row = try parser.next();

    // we the fourth struct before testing to see if the third row keeps its contents
    const maybe_fourth_row = try parser.next();

    if (maybe_third_row) |row| {
        const expected_row = UnionStruct{ .union_field = SampleUnion{ .boolean = true } };
        try testStructEql(UnionStruct, expected_row, row);
    } else {
        std.debug.print("Error parsing third row\n", .{});
        try std.testing.expectEqual(false, true);
    }

    if (maybe_fourth_row) |_| {
        std.debug.print("Error parsing fourth row, expected null\n", .{});
        try std.testing.expectEqual(false, true);
    }
}

test "nested struct" {
    var allocator = std.testing.allocator;

    const input =
        \\ union_field,
        \\1,
        \\2.3,
        \\true,
    ;

    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();
    const Tag = enum { int, float, boolean };

    const Bool = struct {
        is_bool: bool,

        pub fn fromStr(str: []const u8) !@This() {
            return .{ .is_bool = std.mem.eql(u8, "true", str) };
        }
    };
    const SampleUnion = union(Tag) {
        int: i32,
        float: f64,
        boolean: Bool,
    };

    const UnionStruct = struct { union_field: SampleUnion };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = try CsvParser(UnionStruct, @TypeOf(reader), .{}).init(arena.allocator(), reader);

    const expected = [_]UnionStruct{
        .{ .union_field = SampleUnion{ .int = 1 } },
        .{ .union_field = SampleUnion{ .float = 2.3 } },
        .{ .union_field = SampleUnion{ .boolean = .{ .is_bool = true } } },
    };

    for (expected) |e| {
        const row = try parser.next() orelse unreachable;
        try testStructEql(UnionStruct, e, row);
    }
}
