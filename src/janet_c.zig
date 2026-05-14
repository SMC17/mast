// janet_c.zig — single cImport of the Janet C header.
//
// Zig hashes `@cImport({ @cInclude("janet.h") })` per-block, so each
// translation unit that does its own @cImport gets a *distinct* set of
// generated types — `cimport.union_Janet` from main.zig is not the same
// type as `cimport.union_Janet` from sandbox.zig, and any cross-module
// function-pointer assignment fails to compile. Centralizing the cImport
// here gives every consumer the same generated types.
pub const c = @cImport({
    @cInclude("janet.h");
});
