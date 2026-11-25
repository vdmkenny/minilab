# Translating minilab

minilab's interface comes in English, Dutch, French, German, Italian, Spanish and Japanese. It
starts in the computer's language when it has it, and in English otherwise. Settings › Language
picks one by hand.

## How it works

- **English is the source.** Every message is a field in a file in `src/i18n/en/`, one file per
  part of the app (`rolls.zig`, `develop.zig` and so on), with the English text as the field's
  value. Notes for translators are the `//` comments above a message.
- **Each other language is one file**, like `src/i18n/nl.zon`, with the same groups and keys and
  the messages translated.
- **English fills the gaps.** A message a language's file leaves out shows in English, so a half
  finished translation still works. The tests make sure none is left out by mistake.
- **Values go in placeholders.** A message with a value marks where it goes with `{0}`, `{1}` and
  so on: `"Added {0} of {1} scans to {2}"`. Put them wherever your language wants them. The tests
  check that a translation keeps every placeholder of its message.
- **Headings are in capitals**, as the design writes them (`APPEARANCE`). Write them in capitals
  in your language too, where it has capitals.
- **Names stay as they are**: film stocks, look collections, colour spaces, file types, units and
  shell commands.

## Adding a language

1. Add the language to `Language` in `src/core/preferences.zig`: its ISO 639-1 code (like `pt`)
   and its name in itself (`Português`) in `autonym`. If its script isn't Latin, say so in
   `needsCjkFont` or add a font for it, as Japanese has.
2. Make its file from the English, which prints every message ready to translate:

   ```bash
   zig build translation-template > src/i18n/pt.zon
   ```

3. Add the file to the two tables at the top of `src/i18n/i18n.zig`, `catalogue` and `sources`.
4. Translate. `zig build test` lists every message the file is missing, with its English, and
   every translation whose placeholders don't match.
5. Look at every screen in your language for text that doesn't fit:

   ```bash
   zig-out/bin/minilab open --library <a copy of a library> --workspace develop --screenshot develop.png
   ```

   with the language set in Settings first, since screenshots use the defaults otherwise.

## Translating well

- Use the words photographers already see in their language: what Lightroom, Capture One and
  darktable call a thing in it. A loan word is fine when that's what people use (many languages say
  "look" or "preset").
- Keep labels short. Row labels sit in a column about 96 pixels wide, and buttons fit their text.
- On-screen text is labels and short fragments, not sentences. Keep yours the same.
- Japanese uses the system's Japanese font (Hiragino on macOS, Yu Gothic or Meiryo on Windows,
  Noto Sans CJK on Linux). Without one, minilab stays in English and Settings says why.
