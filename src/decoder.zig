const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");

const TypeTag = types.TypeTag;
const Binary = types.Binary;
const ObjectId = types.ObjectId;
const Timestamp = types.Timestamp;
const Regex = types.Regex;
const Decimal128 = types.Decimal128;

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize,
    skip_utf8_validation: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Self {
        return .{
            .allocator = allocator,
            .data = data,
            .pos = 0,
            .skip_utf8_validation = false,
        };
    }

    /// Enable/disable UTF-8 validation (disable for ASCII-only data)
    pub fn setSkipUtf8Validation(self: *Self, skip: bool) void {
        self.skip_utf8_validation = skip;
    }

    /// Decode BSON data to a Zig type
    /// Caller owns returned data and must free it
    pub fn decode(self: *Self, comptime T: type) errors.Error!T {
        const type_info = @typeInfo(T);

        // Top-level BSON must be a document (struct)
        if (type_info != .@"struct") {
            @compileError("Top-level BSON value must be a struct");
        }

        // Read and validate document size
        if (self.data.len < 5) return error.UnexpectedEof;
        const doc_size = self.readI32();
        if (doc_size < 5 or doc_size > self.data.len) {
            return error.MalformedDocument;
        }

        const doc_end = @as(usize, @intCast(doc_size));
        var result: T = undefined;

        // Decode fields directly (no type tag or field name for top-level)
        while (self.pos < doc_end - 1) {
            const tag_byte = self.data[self.pos];
            if (tag_byte == 0) break;

            self.pos += 1;
            const field_name = try self.readCString();

            // Find matching struct field
            var found = false;
            inline for (type_info.@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    try self.decodeFieldValue(@TypeOf(@field(result, field.name)), tag_byte, &@field(result, field.name));
                    found = true;
                    break;
                }
            }

            // Skip unknown fields
            if (!found) {
                try self.skipValue(tag_byte);
            }
        }

        // Validate null terminator
        if (self.pos >= self.data.len or self.data[self.pos] != 0) {
            return error.MalformedDocument;
        }

        return result;
    }

    fn decodeValue(self: *Self, comptime T: type, output: *T) errors.Error!void {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => output.* = try self.decodeInt(T),
            .float => output.* = try self.decodeFloat(T),
            .bool => output.* = try self.decodeBool(),
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        if (ptr_info.child == u8) {
                            output.* = try self.decodeString();
                        } else {
                            output.* = try self.decodeArray(ptr_info.child);
                        }
                    },
                    else => @compileError("Unsupported pointer type"),
                }
            },
            .@"struct" => {
                if (T == ObjectId) {
                    output.* = try self.decodeObjectId();
                } else if (T == Binary) {
                    output.* = try self.decodeBinary();
                } else if (T == Timestamp) {
                    output.* = try self.decodeTimestamp();
                } else if (T == Regex) {
                    output.* = try self.decodeRegex();
                } else if (T == Decimal128) {
                    output.* = try self.decodeDecimal128();
                } else {
                    try self.decodeDocument(T, output);
                }
            },
            .optional => |opt_info| {
                // Check next type tag
                if (self.pos < self.data.len) {
                    const tag_byte = self.data[self.pos];
                    if (tag_byte == @intFromEnum(TypeTag.null)) {
                        self.pos += 1;
                        // Skip field name
                        _ = try self.readCString();
                        output.* = null;
                    } else {
                        var value: opt_info.child = undefined;
                        try self.decodeValue(opt_info.child, &value);
                        output.* = value;
                    }
                } else {
                    output.* = null;
                }
            },
            .@"enum" => {
                const str = try self.decodeString();
                defer self.allocator.free(str);
                output.* = std.meta.stringToEnum(T, str) orelse return error.TypeMismatch;
            },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        }
    }

    fn decodeDocument(self: *Self, comptime T: type, output: *T) errors.Error!void {
        const type_info = @typeInfo(T).@"struct";

        // Read document size
        const doc_start = self.pos;
        const doc_size = self.readI32();
        const doc_end = doc_start + @as(usize, @intCast(doc_size));

        // Decode fields
        while (self.pos < doc_end - 1) {
            const tag_byte = self.data[self.pos];
            if (tag_byte == 0) break;

            self.pos += 1;
            const field_name = try self.readCString();

            // Find matching struct field
            var found = false;
            inline for (type_info.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    try self.decodeFieldValue(@TypeOf(@field(output.*, field.name)), tag_byte, &@field(output.*, field.name));
                    found = true;
                    break;
                }
            }

            // Skip unknown fields
            if (!found) {
                try self.skipValue(tag_byte);
            }
        }

        // Skip null terminator
        if (self.pos < self.data.len and self.data[self.pos] == 0) {
            self.pos += 1;
        }
    }

    fn decodeFieldValue(self: *Self, comptime T: type, tag: u8, output: *T) errors.Error!void {
        const type_info = @typeInfo(T);

        // Handle optional types specially
        if (type_info == .optional) {
            if (tag == @intFromEnum(TypeTag.null)) {
                output.* = null;
                return;
            }
            // For non-null values, validate against child type
            const child_tag = try self.expectedTag(type_info.optional.child);
            if (tag != child_tag) {
                // Allow int32 <-> int64 conversion
                const is_int_conversion = (tag == @intFromEnum(TypeTag.int32) or tag == @intFromEnum(TypeTag.int64)) and
                    (child_tag == @intFromEnum(TypeTag.int32) or child_tag == @intFromEnum(TypeTag.int64));

                if (!is_int_conversion) {
                    return error.TypeMismatch;
                }
            }
        } else {
            // Non-optional: validate type match
            const expected_tag = try self.expectedTag(T);
            if (tag != expected_tag) {
                // Allow int32 <-> int64 conversion
                const is_int_conversion = (tag == @intFromEnum(TypeTag.int32) or tag == @intFromEnum(TypeTag.int64)) and
                    (expected_tag == @intFromEnum(TypeTag.int32) or expected_tag == @intFromEnum(TypeTag.int64));

                if (!is_int_conversion) {
                    return error.TypeMismatch;
                }
            }
        }

        try self.decodeValue(T, output);
    }

    fn expectedTag(self: *Self, comptime T: type) !u8 {
        const type_info = @typeInfo(T);
        _ = self;

        return switch (type_info) {
            .int => |int_info| if (int_info.bits <= 32) @intFromEnum(TypeTag.int32) else @intFromEnum(TypeTag.int64),
            .float => @intFromEnum(TypeTag.double),
            .bool => @intFromEnum(TypeTag.boolean),
            .pointer => |ptr_info| if (ptr_info.child == u8) @intFromEnum(TypeTag.string) else @intFromEnum(TypeTag.array),
            .@"struct" => |_| {
                if (T == ObjectId) return @intFromEnum(TypeTag.object_id);
                if (T == Binary) return @intFromEnum(TypeTag.binary);
                if (T == Timestamp) return @intFromEnum(TypeTag.timestamp);
                if (T == Regex) return @intFromEnum(TypeTag.regex);
                if (T == Decimal128) return @intFromEnum(TypeTag.decimal128);
                return @intFromEnum(TypeTag.document);
            },
            .optional => @intFromEnum(TypeTag.null),
            .@"enum" => @intFromEnum(TypeTag.string),
            else => error.TypeMismatch,
        };
    }

    fn decodeInt(self: *Self, comptime T: type) !T {
        const type_info = @typeInfo(T).int;

        if (type_info.bits <= 32) {
            return @as(T, @intCast(self.readI32()));
        } else {
            return @as(T, @intCast(self.readI64()));
        }
    }

    fn decodeFloat(self: *Self, comptime T: type) !T {
        const value = @as(f64, @bitCast(self.readU64()));
        return @as(T, @floatCast(value));
    }

    fn decodeBool(self: *Self) !bool {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const value = self.data[self.pos];
        self.pos += 1;
        return value != 0;
    }

    fn decodeString(self: *Self) ![]const u8 {
        const len = self.readI32();
        if (len < 1) return error.MalformedDocument;

        const str_len = @as(usize, @intCast(len - 1)); // Exclude null terminator
        if (self.pos + str_len + 1 > self.data.len) return error.UnexpectedEof;

        const str = self.data[self.pos .. self.pos + str_len];

        // Validate UTF-8 (skip if disabled for performance)
        if (!self.skip_utf8_validation and !std.unicode.utf8ValidateSlice(str)) {
            return error.InvalidUtf8;
        }

        // Validate null terminator
        if (self.data[self.pos + str_len] != 0) {
            return error.MalformedDocument;
        }

        self.pos += str_len + 1;

        // Duplicate string (caller owns)
        return try self.allocator.dupe(u8, str);
    }

    fn decodeObjectId(self: *Self) !ObjectId {
        if (self.pos + 12 > self.data.len) return error.UnexpectedEof;

        var bytes: [12]u8 = undefined;
        @memcpy(&bytes, self.data[self.pos .. self.pos + 12]);
        self.pos += 12;

        return ObjectId.fromBytes(bytes);
    }

    fn decodeBinary(self: *Self) !Binary {
        const len = self.readI32();
        if (len < 0) return error.MalformedDocument;

        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const subtype_byte = self.data[self.pos];
        self.pos += 1;

        const data_len = @as(usize, @intCast(len));
        if (self.pos + data_len > self.data.len) return error.UnexpectedEof;

        const data = try self.allocator.dupe(u8, self.data[self.pos .. self.pos + data_len]);
        self.pos += data_len;

        return Binary{
            .subtype = @enumFromInt(subtype_byte),
            .data = data,
        };
    }

    fn decodeTimestamp(self: *Self) !Timestamp {
        const value = @as(u64, @bitCast(self.readI64()));
        return Timestamp.fromU64(value);
    }

    fn decodeRegex(self: *Self) !Regex {
        const pattern = try self.readCStringAlloc();
        const options = try self.readCStringAlloc();

        return Regex{
            .pattern = pattern,
            .options = options,
        };
    }

    fn decodeDecimal128(self: *Self) !Decimal128 {
        if (self.pos + 16 > self.data.len) return error.UnexpectedEof;

        var bytes: [16]u8 = undefined;
        @memcpy(&bytes, self.data[self.pos .. self.pos + 16]);
        self.pos += 16;

        return Decimal128.fromBytes(bytes);
    }

    fn decodeArray(self: *Self, comptime Child: type) ![]Child {
        // Read array size
        const array_start = self.pos;
        const array_size = self.readI32();
        const array_end = array_start + @as(usize, @intCast(array_size));

        var items: std.ArrayList(Child) = .empty;
        errdefer items.deinit(self.allocator);

        // Decode elements
        while (self.pos < array_end - 1) {
            const tag_byte = self.data[self.pos];
            if (tag_byte == 0) break;

            self.pos += 1;

            // Read and ignore index (numeric key)
            _ = try self.readCString();

            var item: Child = undefined;
            try self.decodeFieldValue(Child, tag_byte, &item);
            try items.append(self.allocator, item);
        }

        // Skip null terminator
        if (self.pos < self.data.len and self.data[self.pos] == 0) {
            self.pos += 1;
        }

        return try items.toOwnedSlice(self.allocator);
    }

    fn skipValue(self: *Self, tag: u8) !void {
        switch (@as(TypeTag, @enumFromInt(tag))) {
            .double => self.pos += 8,
            .string => {
                const len = self.readI32();
                self.pos += @as(usize, @intCast(len));
            },
            .document, .array => {
                const size = self.readI32();
                self.pos += @as(usize, @intCast(size)) - 4;
            },
            .binary => {
                const len = self.readI32();
                self.pos += 1 + @as(usize, @intCast(len)); // subtype + data
            },
            .object_id => self.pos += 12,
            .boolean => self.pos += 1,
            .datetime => self.pos += 8,
            .null => {},
            .regex => {
                _ = try self.readCString(); // pattern
                _ = try self.readCString(); // options
            },
            .int32 => self.pos += 4,
            .timestamp, .int64 => self.pos += 8,
            .decimal128 => self.pos += 16,
            else => return error.InvalidType,
        }
    }

    // Helper functions
    fn readI32(self: *Self) i32 {
        const value = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return value;
    }

    fn readI64(self: *Self) i64 {
        const value = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return value;
    }

    fn readU64(self: *Self) u64 {
        const value = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return value;
    }

    fn readCString(self: *Self) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != 0) {
            self.pos += 1;
        }

        if (self.pos >= self.data.len) return error.UnexpectedEof;

        const str = self.data[start..self.pos];
        self.pos += 1; // Skip null terminator

        return str;
    }

    fn readCStringAlloc(self: *Self) ![]const u8 {
        const str = try self.readCString();
        return try self.allocator.dupe(u8, str);
    }
};
