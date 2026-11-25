//! The names of film types, sizes, formats and other choices, in English. Each group has a
//! message for each of its choices, named as the choice is in the code.

pub const Messages = struct {
    appearance: struct {
        system: [:0]const u8 = "System",
        dark: [:0]const u8 = "Dark",
        light: [:0]const u8 = "Light",
    } = .{},
};
