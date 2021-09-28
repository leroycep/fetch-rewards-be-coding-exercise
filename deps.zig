const std = @import("std");
const Pkg = std.build.Pkg;
const string = []const u8;

pub const cache = ".zigmod/deps";

pub fn addAllTo(exe: *std.build.LibExeObjStep) void {
    @setEvalBranchQuota(1_000_000);
    for (packages) |pkg| {
        exe.addPackage(pkg.pkg.?);
    }
    inline for (std.meta.declarations(package_data)) |decl| {
        const pkg = @as(Package, @field(package_data, decl.name));
        var llc = false;
        inline for (pkg.system_libs) |item| {
            exe.linkSystemLibrary(item);
            llc = true;
        }
        inline for (pkg.c_include_dirs) |item| {
            exe.addIncludeDir(@field(dirs, decl.name) ++ "/" ++ item);
            llc = true;
        }
        inline for (pkg.c_source_files) |item| {
            exe.addCSourceFile(@field(dirs, decl.name) ++ "/" ++ item, pkg.c_source_flags);
            llc = true;
        }
        if (llc) {
            exe.linkLibC();
        }
    }
}

pub const Package = struct {
    directory: string,
    pkg: ?Pkg = null,
    c_include_dirs: []const string = &.{},
    c_source_files: []const string = &.{},
    c_source_flags: []const string = &.{},
    system_libs: []const string = &.{},
};

const dirs = struct {
    pub const _root = "";
    pub const _vyiyxl5s2mu1 = cache ++ "/../..";
    pub const _hm449ur2xup4 = cache ++ "/git/github.com/Luukdegram/apple_pie";
};

pub const package_data = struct {
    pub const _vyiyxl5s2mu1 = Package{
        .directory = dirs._vyiyxl5s2mu1,
    };
    pub const _hm449ur2xup4 = Package{
        .directory = dirs._hm449ur2xup4,
        .pkg = Pkg{ .name = "apple_pie", .path = .{ .path = dirs._hm449ur2xup4 ++ "/src/apple_pie.zig" }, .dependencies = null },
    };
    pub const _root = Package{
        .directory = dirs._root,
    };
};

pub const packages = &[_]Package{
    package_data._hm449ur2xup4,
};

pub const pkgs = struct {
    pub const apple_pie = package_data._hm449ur2xup4;
};

pub const imports = struct {
    pub const apple_pie = @import(".zigmod/deps/git/github.com/Luukdegram/apple_pie/src/apple_pie.zig");
};
