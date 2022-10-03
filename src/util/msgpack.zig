//! This module defines funtionality to parse msgpack.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const StreamingParser = struct {
    pub const Token = union(enum) {
        invalid,
        end,
        nil,
        bool: bool,
        int: i64,
        uint: u64,
        float32: f32,
        float64: f64,
        str: []const u8,
        bin: []const u8,
        array: u32,
        map: u32,
        ext: struct {
            type: u8,
            data: []const u8,
        },
    };

    input: []const u8,
    offset: usize = 0,

    pub fn init(input: []const u8) StreamingParser {
        return .{ .input = input };
    }

    pub fn next(self: *StreamingParser) Token {
        const type_byte = self.read(u8) orelse return .end;
        switch (type_byte) {
            // nil format
            0xC0 => return .nil,
            // bool format
            0xC2 => return .{ .bool = false },
            0xC3 => return .{ .bool = true },
            // int format
            0x00...0x7F => return .{ .uint = type_byte & 0x7F },
            0xE0...0xFF => return .{ .int = -@as(i64, type_byte & 0x1F) },
            0xCC => return self.decodeNumber(u8),
            0xCD => return self.decodeNumber(u16),
            0xCE => return self.decodeNumber(u32),
            0xCF => return self.decodeNumber(u64),
            0xD0 => return self.decodeNumber(i8),
            0xD1 => return self.decodeNumber(i16),
            0xD2 => return self.decodeNumber(i32),
            0xD3 => return self.decodeNumber(i64),
            // float format
            0xCA => return self.decodeNumber(f32),
            0xCB => return self.decodeNumber(f64),
            // str format
            0xA0...0xBF => return self.decodeStr(.str, type_byte & 0x1F),
            0xD9 => return self.decodeSizedStr(.str, u8),
            0xDA => return self.decodeSizedStr(.str, u16),
            0xDB => return self.decodeSizedStr(.str, u32),
            // bin format
            0xC4 => return self.decodeSizedStr(.bin, u8),
            0xC5 => return self.decodeSizedStr(.bin, u16),
            0xC6 => return self.decodeSizedStr(.bin, u32),
            // array format
            0x90...0x9F => return .{ .array = type_byte & 0xF },
            0xDC => return self.decodeSizedContainer(.array, u16),
            0xDD => return self.decodeSizedContainer(.array, u32),
            // map format
            0x80...0x8F => return .{ .map = type_byte & 0xF },
            0xDE => return self.decodeSizedContainer(.map, u16),
            0xDF => return self.decodeSizedContainer(.map, u32),
            // ext format
            0xD4 => return self.decodeExt(.{ .fixed = 1 }),
            0xD5 => return self.decodeExt(.{ .fixed = 2 }),
            0xD6 => return self.decodeExt(.{ .fixed = 4 }),
            0xD7 => return self.decodeExt(.{ .fixed = 8 }),
            0xD8 => return self.decodeExt(.{ .fixed = 16 }),
            0xC7 => return self.decodeExt(.{ .dynamic = u8 }),
            0xC8 => return self.decodeExt(.{ .dynamic = u16 }),
            0xC9 => return self.decodeExt(.{ .dynamic = u32 }),
            else => return .invalid,
        }
    }

    fn decodeNumber(self: *StreamingParser, comptime T: type) Token {
        const value = self.read(T) orelse return .invalid;

        switch (@typeInfo(T)) {
            .Int => |info| switch (info.signedness) {
                .signed => return .{ .int = value },
                .unsigned => return .{ .uint = value },
            },
            .Float => |info| switch (info.bits) {
                32 => return .{ .float32 = value },
                64 => return .{ .float64 = value },
                else => unreachable,
            },
            else => unreachable,
        }
    }

    fn decodeStr(self: *StreamingParser, comptime kind: std.meta.Tag(Token), len: u32) Token {
        const str = self.readStr(len) orelse return .invalid;
        return @unionInit(Token, @tagName(kind), str);
    }

    fn decodeSizedStr(self: *StreamingParser, comptime kind: std.meta.Tag(Token), comptime LenType: type) Token {
        const len = self.read(LenType) orelse return .invalid;
        return self.decodeStr(kind, len);
    }

    fn decodeSizedContainer(self: *StreamingParser, comptime kind: std.meta.Tag(Token), comptime LenType: type) Token {
        const len = self.read(LenType) orelse return .invalid;
        return @unionInit(Token, @tagName(kind), len);
    }

    fn decodeExt(self: *StreamingParser, comptime size: union(enum) { fixed: u64, dynamic: type }) Token {
        const data_length = switch (size) {
            .fixed => |len| len,
            .dynamic => |LenType| self.read(LenType) orelse return .invalid,
        };

        const type_byte = self.read(u8) orelse return .invalid;
        if (self.readStr(data_length)) |data| {
            return .{ .ext = .{ .type = type_byte, .data = data } };
        }

        return .invalid;
    }

    fn readStr(self: *StreamingParser, len: u32) ?[]const u8 {
        const remaining = self.input[self.offset..];
        if (remaining.len < len) {
            return null;
        }

        self.offset += len;
        return remaining[0..len];
    }

    fn read(self: *StreamingParser, comptime T: type) ?T {
        const remaining = self.input[self.offset..];
        if (@sizeOf(T) > remaining.len) {
            return null;
        }

        const EquivalentIntType = std.meta.Int(.unsigned, @bitSizeOf(T));

        self.offset += @sizeOf(T);
        const value = std.mem.bytesAsValue(EquivalentIntType, remaining[0..@sizeOf(T)]).*;
        // msgpack integers- and floats are stored as big-endian.
        return @bitCast(T, @byteSwap(value));
    }
};

pub const Parser = struct {
    a: Allocator,
    tokenizer: StreamingParser,
    lookahead: ?StreamingParser.Token = null,

    pub const Error = error{
        InvalidType,
        InvalidFormat,
        UnexpectedEnd,
        DuplicateField,
        UnknownField,
        MissingField,
        MismatchedArrayLength,
        Overflow,
        InvalidEnumKey,
        OutOfMemory,
    };

    pub fn init(a: Allocator, input: []const u8) Parser {
        return .{
            .a = a,
            .tokenizer = StreamingParser.init(input),
        };
    }

    pub fn parse(self: *Parser, comptime T: type) Error!T {
        return switch (@typeInfo(T)) {
            .Optional => self.parseOptional(T),
            .Struct => self.parseStruct(T),
            .Array => self.parseArray(T),
            .Int => self.parseInt(T),
            .Float => self.parseFloat(T),
            .Bool => self.parseBool(),
            .Enum => self.parseEnum(T),
            .Pointer => self.parsePointer(T),
            else => @compileError("cannot parse " ++ @typeName(T)),
        };
    }

    fn parseOptional(self: *Parser, comptime T: type) !T {
        return switch (try self.peek()) {
            .nil => null,
            else => try self.parse(std.meta.Child(T)),
        };
    }

    fn parseStruct(self: *Parser, comptime T: type) !T {
        const len = try self.eat(.map);

        const info = @typeInfo(T).Struct;

        var result: T = undefined;
        var fields_seen = [_]bool{false} ** info.fields.len;

        var i: usize = 0;
        while (i < len) : (i += 1) {
            const key = try self.eat(.str);
            var found = false;
            inline for (info.fields) |field, field_index| {
                if (std.mem.eql(u8, field.name, key)) {
                    if (fields_seen[field_index]) {
                        return error.DuplicateField;
                    }
                    @field(result, field.name) = try self.parse(field.field_type);
                    fields_seen[field_index] = true;
                    found = true;
                }
            }

            if (!found) {
                return error.UnknownField;
            }
        }

        inline for (info.fields) |field, field_index| {
            if (!fields_seen[field_index]) {
                if (field.default_value) |default_ptr| {
                    if (!field.is_comptime) {
                        const default = @ptrCast(*const field.field_type, @alignCast(@alignOf(field.field_type), default_ptr)).*;
                        @field(result, field.name) = default;
                    }
                } else {
                    return error.MissingField;
                }
            }
        }

        return result;
    }

    fn parseArray(self: *Parser, comptime T: type) !T {
        const len = try self.eat(.array);
        const expected_len = @typeInfo(T).Array.len;

        if (len != expected_len) {
            return error.MismatchedArrayLength;
        }

        const Element = std.meta.Child(T);
        var array: [expected_len]Element = undefined;

        for (array) |*element| {
            element.* = try self.parse(Element);
        }

        return array;
    }

    fn parseInt(self: *Parser, comptime T: type) !T {
        const expected_tag = switch (@typeInfo(T).Int.signedness) {
            .unsigned => .uint,
            .signed => .int,
        };

        const value = try self.eat(expected_tag);
        return std.math.cast(T, value) orelse return error.Overflow;
    }

    fn parseFloat(self: *Parser, comptime T: type) !T {
        switch (@typeInfo(T).Float.bits) {
            32 => return self.eat(.float32),
            64 => return self.eat(.float64),
            else => @compileError("cannot parse " ++ @typeName(T)),
        }
    }

    fn parseBool(self: *Parser) !bool {
        return try self.eat(.bool);
    }

    fn parseEnum(self: *Parser, comptime T: type) !T {
        const key = try self.eat(.str);
        return std.meta.stringToEnum(T, key) orelse error.InvalidEnumKey;
    }

    fn parsePointer(self: *Parser, comptime T: type) !T {
        const Child = std.meta.Child(T);
        return switch (@typeInfo(T).Pointer.size) {
            .One => {
                const result = try self.a.create(Child);
                result.* = try self.parse(Child);
                return result;
            },
            .Slice => switch (try self.next()) {
                .str, .bin => |data| if (Child == u8) try self.a.dupe(u8, data) else error.InvalidType,
                .array => |len| {
                    const array = try self.a.alloc(Child, len);
                    for (array) |*element| {
                        element.* = try self.parse(Child);
                    }
                    return array;
                },
                else => error.InvalidType,
            },
            else => @compileError("cannot parse " ++ @typeName(T)),
        };
    }

    fn eat(
        self: *Parser,
        comptime expected: std.meta.Tag(StreamingParser.Token),
    ) !std.meta.TagPayload(StreamingParser.Token, expected) {
        const tok = try self.next();
        return if (tok == expected)
            @field(tok, @tagName(expected))
        else
            error.InvalidType;
    }

    fn next(self: *Parser) !StreamingParser.Token {
        if (self.lookahead) |lookahead| {
            self.lookahead = null;
            return lookahead;
        }
        return switch (self.tokenizer.next()) {
            .end => error.UnexpectedEnd,
            .invalid => error.InvalidFormat,
            else => |tok| tok,
        };
    }

    fn peek(self: *Parser) !StreamingParser.Token {
        if (self.lookahead == null) {
            self.lookahead = self.tokenizer.next();
        }
        return switch (self.lookahead.?) {
            .end => error.UnexpectedEnd,
            .invalid => error.InvalidFormat,
            else => |tok| tok,
        };
    }
};
