# Light and dark appearance

Use the **Dark / Light** selector in the top-right corner of the window to
change the interface. Light mode has neutral grey surfaces, pastel green main
buttons and darker green selections. Dark mode keeps the amber accent.
Changing appearance keeps the interface's size and spacing.

The viewer's background follows the appearance. Photograph pixels, film edge
markings and the red, green and blue data colours keep their values.

Your choice belongs to your account and applies to every library. MiniLab saves
it in `preferences.json` in its configuration folder:

- Linux: `$XDG_CONFIG_HOME/minilab`, or `~/.config/minilab` when unset.
- macOS: `~/Library/Application Support/minilab`.
- Windows: `%APPDATA%/minilab`.

The default is Dark. If the preference cannot be saved, the selected appearance
still applies for this session and a notice explains that it was not saved.
An unreadable preferences file is left intact.
