//! The messages of the Settings window, in English.

pub const Messages = struct {
    title: [:0]const u8 = "Settings",
    not_saved: [:0]const u8 = "Settings not saved",
    // The pages, and their headings. Headings are in capitals, as the design writes them.
    appearance: [:0]const u8 = "Appearance",
    appearance_heading: [:0]const u8 = "APPEARANCE",
    language: [:0]const u8 = "Language",
    language_heading: [:0]const u8 = "LANGUAGE",
    // The page for picking the scanner and setting it up. Its heading is the Scan panel's.
    scanner: [:0]const u8 = "Scanner",
    // The resolution scans start at. The row above it, for previews, uses the Scan panel's
    // "Preview".
    scans: [:0]const u8 = "Scans",
    about: [:0]const u8 = "About",
    // Appearance.
    interface: [:0]const u8 = "Interface",
    viewer: [:0]const u8 = "Viewer",
    always_dark: [:0]const u8 = "Always dark",
    light_warning: [:0]const u8 = "Light can skew color perception",
    // Language. {0} is the system's language, in itself, like "Nederlands".
    system_language: [:0]const u8 = "System ({0})",
    no_japanese_font: [:0]const u8 = "Needs a Japanese font",
    // About.
    tagline: [:0]const u8 = "Scan, develop and export film, a roll at a time",
    website: [:0]const u8 = "Website",
    source_code: [:0]const u8 = "Source code on GitHub",
    built_with: [:0]const u8 = "BUILT WITH",
    built_with_icons: [:0]const u8 = "IBM Plex Sans, JetBrains Mono, Lucide icons",
    built_with_looks: [:0]const u8 = "GlassMeter, t3mujinpack and Street Monochrome looks",
    ai_disclosure: [:0]const u8 = "AI DISCLOSURE",
    ai_written: [:0]const u8 = "Written with the help of AI coding agents",
    ai_not_inside: [:0]const u8 = "No AI runs in the app, and nothing is sent to one",
};
