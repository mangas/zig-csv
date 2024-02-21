const std = @import("std");
const fs = std.fs;
const Type = std.builtin.Type;
const ascii = std.ascii;

const cnf = @import("config.zig");
const utils = @import("utils.zig");

// Utils

const WriterError = error{
    AccessDenied,
    BrokenPipe,
    ConnectionResetByPeer,
    DiskQuota,
    FileTooBig,
    InputOutput,
    LockViolation,
    NoSpaceLeft,
    NotOpenForWriting,
    OperationAborted,
    SystemResources,
    Unexpected,
    WouldBlock,
    DeviceBusy,
    InvalidArgument,
};

// TODO: generalize to all atomic types
fn serializeAtomic(
    comptime T: type,
    comptime Writer: type,
    writer: Writer,
    value: T,
) WriterError!void {
    switch (@typeInfo(T)) {
        .Int => {
            var buffer: [20]u8 = undefined;
            const buffer_slice = buffer[0..];
            const bytes_written = try std.fmt.bufPrint(buffer_slice, "{}", .{value});
            _ = try writer.write(bytes_written);
        },
        .Float => {
            var buffer: [20]u8 = undefined;
            const buffer_slice = buffer[0..];
            // TODO: how floating point is printed should be configurable
            const bytes_written = try std.fmt.bufPrint(buffer_slice, "{e}", .{value});
            _ = try writer.write(bytes_written);
        },
        .Bool => {
            if (value) {
                _ = try writer.writeAll("true");
            } else {
                _ = try writer.writeAll("false");
            }
        },
        .Enum => |Enum| {
            if (!Enum.is_exhaustive) {
                @compileError("Non exhaustive enums are not supported: " ++ @typeName(T));
            }

            inline for (Enum.fields) |EnumField| {
                if (value == @field(T, EnumField.name)) {
                    _ = try writer.writeAll(EnumField.name);
                }
            }
        },
        else => @compileError("Unsupported atomic type: " ++ @typeName(T)),
    }
}

pub fn CsvSerializer(
    comptime T: type,
    comptime Writer: type,
    comptime config: cnf.CsvConfig,
) type {
    return struct {
        const Self = @This();

        const Fields: []const Type.StructField = switch (@typeInfo(T)) {
            .Struct => |S| S.fields,
            else => @compileError("T needs to be a struct"),
        };

        const NumberOfFields: usize = Fields.len;

        writer: Writer,

        pub fn init(writer: Writer) Self {
            return Self{ .writer = writer };
        }

        pub fn writeHeader(self: *Self) WriterError!void {
            inline for (Fields) |Field| {
                _ = try self.writer.write(Field.name);
                _ = try self.writer.writeByte(config.field_end_delimiter);
            }
            _ = try self.writer.writeByte(config.row_end_delimiter);
        }

        pub fn appendRow(self: *Self, data: T) WriterError!void {
            inline for (Fields) |F| {
                const field_val: F.type = @field(data, F.name);
                switch (@typeInfo(F.type)) {
                    .Array => |info| {
                        if (comptime info.child != u8) {
                            @compileError("Arrays can only be u8 and '" ++ F.name ++ "'' is " ++ @typeName(info.child));
                        }

                        if (field_val.len != 0) {
                            try self.writer.writeAll(field_val);
                        }
                    },
                    .Pointer => |info| {
                        switch (info.size) {
                            .Slice => {
                                if (info.child != u8) {
                                    @compileError("Slices can only be u8 and '" ++ F.name ++ "' is " ++ @typeName(info.child));
                                }
                                if (field_val.len != 0) {
                                    _ = try self.writer.write(field_val);
                                }
                            },
                            else => @compileError("Pointer not implemented yet and '" ++ F.name ++ "'' is a pointer."),
                        }
                    },
                    .Optional => |Optional| {
                        if (field_val) |v| {
                            try serializeAtomic(Optional.child, Writer, self.writer, v);
                        }
                    },
                    .Union => |U| {
                        inline for (U.fields) |UF| {
                            if (field_val == @field(U.tag_type.?, UF.name)) {
                                try serializeAtomic(UF.type, Writer, self.writer, @field(field_val, UF.name));
                            }
                        }
                    },
                    else => {
                        try serializeAtomic(F.type, Writer, self.writer, field_val);
                    },
                }
                try self.writer.writeByte(config.field_end_delimiter);
            }
            try self.writer.writeByte(config.row_end_delimiter);
        }
    };
}

test "serialize to buffer" {
    const User = struct { id: u32, name: []const u8 };

    const expected = "id,name,\n1,none,";
    const n = expected.len;
    var buffer: [n + 1]u8 = undefined;

    var fixed_buffer_stream = std.io.fixedBufferStream(buffer[0..]);
    const writer = fixed_buffer_stream.writer();

    var serializer = CsvSerializer(User, @TypeOf(writer), .{}).init(writer);

    try serializer.writeHeader();
    try serializer.appendRow(User{ .id = 1, .name = "none" });

    try std.testing.expect(std.mem.eql(u8, expected, buffer[0..n]));
}

test "serialize unions" {
    var allocator = std.testing.allocator;

    var buf: [48]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = stream.writer();

    const Color = enum { red, green, blue };

    const Tag = enum { int, uint, boolean };

    const SampleUnion = union(Tag) {
        int: i32,
        uint: u64,
        boolean: bool,
    };

    const UnionStruct = struct { color: Color, union_field: SampleUnion };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var serializer = CsvSerializer(UnionStruct, @TypeOf(writer), .{}).init(writer);

    try serializer.writeHeader();
    try serializer.appendRow(UnionStruct{
        .color = Color.red,
        .union_field = SampleUnion{ .int = -1 },
    });
    try serializer.appendRow(UnionStruct{
        .color = Color.green,
        .union_field = SampleUnion{ .uint = 32 },
    });
    try serializer.appendRow(UnionStruct{
        .color = Color.blue,
        .union_field = SampleUnion{ .boolean = true },
    });

    const from_path = "test/data/serialize_union.csv";
    const from_file = try std.fs.cwd().openFile(from_path, .{});
    defer from_file.close();

    var reader = std.io.fixedBufferStream(&buf);

    try utils.eqlContentReader(reader.reader(), from_file.reader());
}
