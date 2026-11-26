//! The messages of the update notice and window, in English.

pub const Messages = struct {
    // In the header. {0} is the new version, like "0.8.0".
    update_available: [:0]const u8 = "Update {0}",
    // In the header, while the app closes to start the new version.
    restarting: [:0]const u8 = "Restarting",
    // Under the window's title. {0} is the version running now.
    installed: [:0]const u8 = "Installed {0}",
    // {0} and {1} are megabytes.
    downloading: [:0]const u8 = "Downloading {0} of {1} MB",
    installing: [:0]const u8 = "Installing",
    // {0} is why, one of the reasons below.
    failed: [:0]const u8 = "Update failed · {0}",
    // The app's folder can't be written to, so it can only send you to the download.
    folder_not_writable: [:0]const u8 = "Folder not writable",
    busy: [:0]const u8 = "Scan or export running",
    gatekeeper: [:0]const u8 = "You may need to turn off macOS Gatekeeper for minilab after updating",
    // The buttons.
    update_and_restart: [:0]const u8 = "Update and restart",
    release_notes: [:0]const u8 = "Release notes",
    // A verb: go to the download page.
    download: [:0]const u8 = "Download",
    // Hides the window while the update downloads.
    hide: [:0]const u8 = "Hide",
    // Closes the window, leaving the update for later.
    later: [:0]const u8 = "Later",
    // Why an update failed, in a few words, after "Update failed · ".
    failure: struct {
        unknown: [:0]const u8 = "unknown",
        out_of_memory: [:0]const u8 = "out of memory",
        // The download's signature, which says it was built from minilab's code, isn't right.
        attestation: [:0]const u8 = "attestation doesn't verify",
        offline: [:0]const u8 = "no connection to GitHub",
        checksum: [:0]const u8 = "checksum doesn't match",
        not_writable: [:0]const u8 = "folder not writable",
        not_a_build: [:0]const u8 = "download isn't a minilab build",
        too_large: [:0]const u8 = "download too large",
        cancelled: [:0]const u8 = "canceled",
    } = .{},
};
