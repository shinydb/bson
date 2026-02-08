const std = @import("std");
const bson = @import("bson");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║              BSON Encoder/Decoder Demo                  ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Demo 1: Simple struct
    try demoSimpleStruct(allocator);

    // Demo 2: With ObjectId
    try demoObjectId(allocator);

    // Demo 3: Arrays
    try demoArrays(allocator);

    // Demo 4: Nested documents
    try demoNestedDocuments(allocator);

    // Demo 5: Array of structs
    try demoArrayOfStructs(allocator);

    // Demo 6: BsonDocument API
    try demoBsonDocument(allocator);

    std.debug.print("\n✅ All demos completed successfully!\n\n", .{});
}

fn demoSimpleStruct(allocator: std.mem.Allocator) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Demo 1: Simple Struct\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    const Person = struct {
        name: []const u8,
        age: i32,
        email: []const u8,
        active: bool,
    };

    const person = Person{
        .name = "Alice Johnson",
        .age = 30,
        .email = "alice@example.com",
        .active = true,
    };

    std.debug.print("Original:\n", .{});
    std.debug.print("  Name: {s}\n", .{person.name});
    std.debug.print("  Age: {d}\n", .{person.age});
    std.debug.print("  Email: {s}\n", .{person.email});
    std.debug.print("  Active: {}\n\n", .{person.active});

    // Encode
    const bson_data = try bson.encode(allocator, person);
    defer allocator.free(bson_data);

    std.debug.print("BSON size: {} bytes\n", .{bson_data.len});
    std.debug.print("BSON hex: ", .{});
    for (bson_data[0..@min(32, bson_data.len)]) |byte| {
        std.debug.print("{x:0>2} ", .{byte});
    }
    std.debug.print("\n\n", .{});

    // Decode
    const decoded = try bson.decode(allocator, Person, bson_data);
    defer allocator.free(decoded.name);
    defer allocator.free(decoded.email);

    std.debug.print("Decoded:\n", .{});
    std.debug.print("  Name: {s}\n", .{decoded.name});
    std.debug.print("  Age: {d}\n", .{decoded.age});
    std.debug.print("  Email: {s}\n", .{decoded.email});
    std.debug.print("  Active: {}\n\n", .{decoded.active});
}

fn demoObjectId(allocator: std.mem.Allocator) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Demo 2: With ObjectId\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    const Document = struct {
        id: bson.ObjectId,
        title: []const u8,
        created_at: i64,
    };

    const timespec = try std.posix.clock_gettime(std.posix.CLOCK.REALTIME);
    const created_at_ms = @as(i64, @intCast(timespec.sec)) * 1000 + @divFloor(@as(i64, @intCast(timespec.nsec)), 1_000_000);

    const doc = Document{
        .id = bson.ObjectId.generate(),
        .title = "BSON Documentation",
        .created_at = created_at_ms,
    };

    var hex_buf: [24]u8 = undefined;
    doc.id.toHexString(&hex_buf);

    std.debug.print("Original:\n", .{});
    std.debug.print("  ID: {s}\n", .{hex_buf});
    std.debug.print("  Title: {s}\n", .{doc.title});
    std.debug.print("  Created: {d}\n\n", .{doc.created_at});

    // Encode & Decode
    const bson_data = try bson.encode(allocator, doc);
    defer allocator.free(bson_data);

    const decoded = try bson.decode(allocator, Document, bson_data);
    defer allocator.free(decoded.title);

    decoded.id.toHexString(&hex_buf);

    std.debug.print("Decoded:\n", .{});
    std.debug.print("  ID: {s}\n", .{hex_buf});
    std.debug.print("  Title: {s}\n", .{decoded.title});
    std.debug.print("  Created: {d}\n\n", .{decoded.created_at});
}

fn demoArrays(allocator: std.mem.Allocator) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Demo 3: Arrays\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    const Document = struct {
        tags: []const []const u8,
        scores: []const i32,
    };

    const doc = Document{
        .tags = &[_][]const u8{ "database", "nosql", "bson", "zig" },
        .scores = &[_]i32{ 95, 87, 92, 88, 90 },
    };

    std.debug.print("Original:\n", .{});
    std.debug.print("  Tags: [", .{});
    for (doc.tags, 0..) |tag, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("\"{s}\"", .{tag});
    }
    std.debug.print("]\n  Scores: [", .{});
    for (doc.scores, 0..) |score, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{d}", .{score});
    }
    std.debug.print("]\n\n", .{});

    // Encode & Decode
    const bson_data = try bson.encode(allocator, doc);
    defer allocator.free(bson_data);

    const decoded = try bson.decode(allocator, Document, bson_data);
    defer {
        for (decoded.tags) |tag| allocator.free(tag);
        allocator.free(decoded.tags);
        allocator.free(decoded.scores);
    }

    std.debug.print("Decoded:\n", .{});
    std.debug.print("  Tags: [", .{});
    for (decoded.tags, 0..) |tag, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("\"{s}\"", .{tag});
    }
    std.debug.print("]\n  Scores: [", .{});
    for (decoded.scores, 0..) |score, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{d}", .{score});
    }
    std.debug.print("]\n\n", .{});
}

fn demoNestedDocuments(allocator: std.mem.Allocator) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Demo 4: Nested Documents\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    const Address = struct {
        street: []const u8,
        city: []const u8,
        state: []const u8,
        zip: i32,
    };

    const Person = struct {
        name: []const u8,
        age: i32,
        address: Address,
    };

    const person = Person{
        .name = "Bob Smith",
        .age = 35,
        .address = .{
            .street = "123 Main Street",
            .city = "San Francisco",
            .state = "CA",
            .zip = 94102,
        },
    };

    std.debug.print("Original:\n", .{});
    std.debug.print("  Name: {s}\n", .{person.name});
    std.debug.print("  Age: {d}\n", .{person.age});
    std.debug.print("  Address:\n", .{});
    std.debug.print("    Street: {s}\n", .{person.address.street});
    std.debug.print("    City: {s}\n", .{person.address.city});
    std.debug.print("    State: {s}\n", .{person.address.state});
    std.debug.print("    ZIP: {d}\n\n", .{person.address.zip});

    // Encode & Decode
    const bson_data = try bson.encode(allocator, person);
    defer allocator.free(bson_data);

    std.debug.print("BSON size: {} bytes\n\n", .{bson_data.len});

    const decoded = try bson.decode(allocator, Person, bson_data);
    defer {
        allocator.free(decoded.name);
        allocator.free(decoded.address.street);
        allocator.free(decoded.address.city);
        allocator.free(decoded.address.state);
    }

    std.debug.print("Decoded:\n", .{});
    std.debug.print("  Name: {s}\n", .{decoded.name});
    std.debug.print("  Age: {d}\n", .{decoded.age});
    std.debug.print("  Address:\n", .{});
    std.debug.print("    Street: {s}\n", .{decoded.address.street});
    std.debug.print("    City: {s}\n", .{decoded.address.city});
    std.debug.print("    State: {s}\n", .{decoded.address.state});
    std.debug.print("    ZIP: {d}\n\n", .{decoded.address.zip});
}

fn demoArrayOfStructs(allocator: std.mem.Allocator) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Demo 5: Array of Structs\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    const Address = struct {
        street: []const u8,
        city: []const u8,
        state: []const u8,
        zip: i32,
        type: []const u8, // "home", "work", etc.
    };

    const Person = struct {
        name: []const u8,
        age: i32,
        addresses: []const Address,
    };

    const person = Person{
        .name = "John Doe",
        .age = 40,
        .addresses = &[_]Address{
            .{
                .street = "123 Main St",
                .city = "New York",
                .state = "NY",
                .zip = 10001,
                .type = "home",
            },
            .{
                .street = "456 Office Ave",
                .city = "New York",
                .state = "NY",
                .zip = 10002,
                .type = "work",
            },
            .{
                .street = "789 Beach Rd",
                .city = "Miami",
                .state = "FL",
                .zip = 33101,
                .type = "vacation",
            },
        },
    };

    std.debug.print("Original:\n", .{});
    std.debug.print("  Name: {s}\n", .{person.name});
    std.debug.print("  Age: {d}\n", .{person.age});
    std.debug.print("  Addresses:\n", .{});
    for (person.addresses, 0..) |addr, i| {
        std.debug.print("    [{d}] {s}: {s}, {s}, {s} {d}\n", .{ i, addr.type, addr.street, addr.city, addr.state, addr.zip });
    }
    std.debug.print("\n", .{});

    // Encode & Decode
    const bson_data = try bson.encode(allocator, person);
    defer allocator.free(bson_data);

    std.debug.print("BSON size: {} bytes\n\n", .{bson_data.len});

    const decoded = try bson.decode(allocator, Person, bson_data);
    defer {
        allocator.free(decoded.name);
        for (decoded.addresses) |addr| {
            allocator.free(addr.street);
            allocator.free(addr.city);
            allocator.free(addr.state);
            allocator.free(addr.type);
        }
        allocator.free(decoded.addresses);
    }

    std.debug.print("Decoded:\n", .{});
    std.debug.print("  Name: {s}\n", .{decoded.name});
    std.debug.print("  Age: {d}\n", .{decoded.age});
    std.debug.print("  Addresses:\n", .{});
    for (decoded.addresses, 0..) |addr, i| {
        std.debug.print("    [{d}] {s}: {s}, {s}, {s} {d}\n", .{ i, addr.type, addr.street, addr.city, addr.state, addr.zip });
    }
    std.debug.print("\n", .{});
}

fn demoBsonDocument(allocator: std.mem.Allocator) !void {
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Demo 6: BsonDocument API (Dynamic Access)\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

    // Create a document with various field types
    const Product = struct {
        id: bson.ObjectId,
        name: []const u8,
        price: f64,
        in_stock: bool,
        quantity: i32,
        tags: []const []const u8,
    };

    const product = Product{
        .id = bson.ObjectId.generate(),
        .name = "Laptop Computer",
        .price = 999.99,
        .in_stock = true,
        .quantity = 25,
        .tags = &[_][]const u8{ "electronics", "computers", "featured" },
    };

    std.debug.print("Original Product:\n", .{});
    var hex_buf: [24]u8 = undefined;
    product.id.toHexString(&hex_buf);
    std.debug.print("  ID: {s}\n", .{hex_buf});
    std.debug.print("  Name: {s}\n", .{product.name});
    std.debug.print("  Price: ${d:.2}\n", .{product.price});
    std.debug.print("  In Stock: {}\n", .{product.in_stock});
    std.debug.print("  Quantity: {d}\n\n", .{product.quantity});

    // Encode to BSON
    const bson_data = try bson.encode(allocator, product);
    defer allocator.free(bson_data);

    std.debug.print("Encoded to {} bytes of BSON\n\n", .{bson_data.len});

    // Now use BsonDocument API to read fields dynamically
    std.debug.print("Reading with BsonDocument API:\n", .{});

    var doc = try bson.BsonDocument.init(allocator, bson_data, false);
    defer doc.deinit();

    // Get field names
    const field_names = try doc.getFieldNames(allocator);
    defer {
        for (field_names) |name| allocator.free(name);
        allocator.free(field_names);
    }

    std.debug.print("  Fields in document: [", .{});
    for (field_names, 0..) |name, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("\"{s}\"", .{name});
    }
    std.debug.print("]\n\n", .{});

    // Read individual fields
    if (try doc.getObjectId("id")) |id| {
        id.toHexString(&hex_buf);
        std.debug.print("  doc.getObjectId(\"id\") = {s}\n", .{hex_buf});
    }

    if (try doc.getString("name")) |name| {
        defer allocator.free(name);
        std.debug.print("  doc.getString(\"name\") = \"{s}\"\n", .{name});
    }

    if (try doc.getDouble("price")) |price| {
        std.debug.print("  doc.getDouble(\"price\") = ${d:.2}\n", .{price});
    }

    if (try doc.getBool("in_stock")) |in_stock| {
        std.debug.print("  doc.getBool(\"in_stock\") = {}\n", .{in_stock});
    }

    if (try doc.getInt32("quantity")) |quantity| {
        std.debug.print("  doc.getInt32(\"quantity\") = {d}\n", .{quantity});
    }

    // Read array field
    if (try doc.getArray("tags")) |tags_array| {
        const array_len = try tags_array.len();
        std.debug.print("  doc.getArray(\"tags\") has {d} elements:\n", .{array_len});

        var i: usize = 0;
        while (i < array_len) : (i += 1) {
            if (try tags_array.get(i)) |value| {
                switch (value) {
                    .string => |s| {
                        defer allocator.free(s);
                        std.debug.print("    [{d}] \"{s}\"\n", .{ i, s });
                    },
                    else => {},
                }
            }
        }
    }

    // Try to get non-existent field
    std.debug.print("\n  doc.getString(\"nonexistent\") = ", .{});
    if (try doc.getString("nonexistent")) |_| {
        std.debug.print("found\n", .{});
    } else {
        std.debug.print("null (field not found)\n", .{});
    }

    std.debug.print("\n✨ BsonDocument API allows dynamic field access without knowing struct types!\n\n", .{});
}
