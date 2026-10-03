//
// You can even create anonymous struct literals without field
// names:
//
//     .{
//         false,
//         @as(u32, 15),
//         @as(f64, 67.12)
//     }
//
// We call these "tuples", which is a term used by many
// programming languages for a data type with fields referenced
// by index order rather than name. To make this possible, the Zig
// compiler automatically assigns numeric field names 0, 1, 2,
// etc. to the struct.
//
// Since bare numbers are not legal identifiers (foo.0 is a
// syntax error), we have to quote them with the @"" syntax.
// Example:
//
//     const foo = .{ true, false };
//
//     print("{} {}\n", .{foo.@"0", foo.@"1"});
//
// The example above prints "true false".
//
// Hey, WAIT A SECOND...
//
// If a .{} thing is what the print function wants, do we need to
// break our "tuple" apart and put it in another one? No! It's
// redundant! This will print the same thing:
//
//     print("{} {}\n", foo);
//
// Aha! So now we know that print() takes a "tuple". Things are
// really starting to come together now.
//
const print = @import("std").debug.print;

pub fn main() void {
    // A "tuple":
    const foo = .{
        true,
        false,
        @as(i32, 42),
        @as(f32, 3.141592),
    };

    // We'll be implementing this:
    printTuple(foo);

    // This is just for fun, because we can:
    const nothing = .{};
    print("\n", nothing);
}

// Let's make our own generic "tuple" printer. This should take a
// "tuple" and print out each field in the following format:
//
//     "name"(type):value
//
// Example:
//
//     "0"(bool):true
//
// You'll be putting this together. But don't worry, everything
// you need is documented in the comments.
fn printTuple(tuple: anytype) void {
    // 1. Get a list of fields in the input 'tuple'
    // parameter. You'll need:
    //
    //     @TypeOf() - takes a value, returns its type.
    //
    //     @typeInfo() - takes a type, returns a TypeInfo union
    //                   with fields specific to that type.
    //
    //     The list of a struct type's field names and field types
    //     can be found in TypeInfo's @"struct".field_names and
    //     @"struct".field_types.
    //
    //     Example:
    //
    //         @typeInfo(Circle).@"struct".field_names
    //
    // This will be a slice of field name strings.
    const field_names = @typeInfo(@TypeOf(tuple)).@"struct".field_names;

    // And this will be a slice of field types, with the same length
    // as 'field_names'.
    const field_types = @typeInfo(@TypeOf(tuple)).@"struct".field_types;

    // 2. Loop through each field. This must be done at compile
    // time.
    //
    //     Hint: remember 'inline' loops?
    //
    inline for (field_names, field_types) |field_name, field_type| {
        // 3. Print the field's name, type, and value.
        //
        //     'field_name' holds the field name and 'field_type'
        //     holds the field type.
        //
        //     Note we will learn about 'anyopaque' type later
        //
        //     You'll need this builtin:
        //
        //         @field(lhs: anytype, comptime field_name: []const u8)
        //
        //     The first parameter is the value to be accessed,
        //     the second parameter is a string with the name of
        //     the field you wish to access. The value of the
        //     field is returned.
        //
        //     Example:
        //
        //         @field(foo, "x"); // returns the value at foo.x
        //
        // The first field should print as: "0"(bool):true
        //
        // Hint: Be careful! If your 'lhs' is a type, @field() looks
        // for declarations. If it's a value, it looks for data.
        //
        print("\"{s}\"({any}):{any} ", .{
            field_name,
            field_type,
            @field(tuple, field_name),
        });
    }
}
