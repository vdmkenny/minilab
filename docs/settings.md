# Settings

The gear at the right end of the header opens Settings, and so does ⌘, (Ctrl+, on Windows and
Linux). What you set there belongs to your account, not to a library, so it holds whichever
library you open. Changes apply and save straight away.

Settings has a column of pages on the left: the settings from the top (Appearance and Language),
and About at the foot, under a line. About has the version, links to the website and the source
code, what minilab is built with, and an AI disclosure: minilab is written with the help of AI
coding agents (see `AGENTS.md`), and no AI runs in the app. A new page is a case in `Page` in
`src/app/settings_view.zig` and a function that draws it; `atFoot` says whether it goes at the
foot with About.

## Appearance

**Interface** picks the colours of everything around your pictures:

- **System** follows your computer's light or dark setting, and switches when it does.
- **Dark** is the default.
- **Light** uses light greys.

When the interface isn't Dark, Settings warns that light can skew how you see colour. The section
below says why.

**Viewer: Always dark** keeps the background around the picture dark when the interface is light.
It's on by default.

## Language

**Language** picks the interface's language: System, which follows the computer's language when
minilab has it (and English otherwise), or English, Dutch, French, German, Italian, Spanish or
Japanese by name. Japanese needs a Japanese font on the computer; without one, minilab stays in
English and the page says so. [translating.md](translating.md) has how the translations work and
how to add a language.

## The standards behind the colours

What surrounds a picture changes how you see it, and an editor that gets this wrong leads you to
edit pictures too dark or too light. So the colours follow published standards rather than taste.
`src/ui/theme.zig` holds both palettes and tests them against the numbers below.

### ISO 3664: the surround of a picture on a screen

ISO 3664 sets the viewing conditions for judging pictures, in print and on screen. For a picture
on a monitor, the 1999 edition (§4.5.5) asks that the area around it be neutral, preferably dark
grey or black to keep down flare, with the same chromaticity as the screen's white. Its luminance
should be at most 20% of the white's, and preferably at most 3%. The 2009 edition still describes
a monitor's border as normally dark grey or black, and limits the surrounds of prints and slides to
a CIELAB chroma of 2 or less.

What we take from it:

- **The viewer is dark by default.** minilab's viewer background, #262626, is about 2% of white:
  inside the preferred 3%.
- **Always dark is on by default**, so even the light interface keeps the picture's surround
  inside the standard. With it off, the viewer is a light grey, far over the 20% limit, which is
  why Settings warns.
- **Neutral greys.** Every grey in both palettes has the same red, green and blue, so its chroma
  is 0, well inside the limit of 2, and nothing next to a picture tints it.
- **Fixed colours over the picture.** The crop's shade, the labels drawn over the viewer and the
  frame numbers on thumbnails are a neutral dark grey in both appearances, and Looks' difference
  map always uses the dark palette's colours. They're part of reading the picture, so they mustn't
  change with the interface.

Sources: [ISO 3664:1999](https://www.gtilite.com/pdf/ISO3664%20Standard.pdf),
[ISO 3664:2009, preview](https://cdn.standards.iteh.ai/samples/43234/d3de25012f6b433e886679d3a450499f/ISO-3664-2009.pdf).
We couldn't read the 2009 edition's monitor clause in full, so the figures above come from the
1999 text.

### ISO 12646: soft proofing on a display

ISO 12646 covers displays used to proof colour. The 2004 edition (§4.7) asks for dim room light,
a surround of at most 10% of the screen's peak luminance, and neutral greys within 0.005 in
u′v′ of the white point. It points the same way as ISO 3664: a dark, neutral surround. We follow
ISO 3664's figures, since they're the stricter of the two for a picture's immediate surround.

Source: [ISO 12646:2004, preview](https://cdn.standards.iteh.ai/samples/40071/9ca481d9053740628234dd3545e4ffed/ISO-12646-2004.pdf).
Later editions are said to use 20% and 3% like ISO 3664, but we haven't confirmed that against
their text.

### CIECAM02 and surround studies: why the surround matters

The CIE's colour appearance model, CIECAM02, has three surround settings (average, dim and dark).
A darker surround lowers the lightness contrast and colourfulness the model predicts you'll see.
Liu and Fairchild measured this with real photographs: perceived contrast rises as the surround
gets lighter. In practice, against a dark surround a picture looks brighter and flatter than it is,
and against a light one darker and more contrasty. darktable's manual warns that editing against
the wrong surround leaves pictures too dark and overworked.

None of this sets a number we use. It's the reason the viewer has its own setting, and the reason
for the warning.

Sources: [CIECAM02](https://en.wikipedia.org/wiki/CIECAM02),
[Liu and Fairchild, CIC 12](https://library.imaging.org/cic/articles/12/1/art00050),
[CIC 15](https://library.imaging.org/cic/articles/15/1/art00013),
[darktable, colour assessment](https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/darkroom/color-assessment/).

### WCAG 2.2: contrast for reading and seeing controls

WCAG is the web's accessibility guideline, and its contrast rules suit any screen. Text needs a
contrast ratio of at least 4.5:1 with what's behind it (success criterion 1.4.3). The parts of a
control you need to see to use it, such as a border or a slider's track, need at least 3:1
(1.4.11).

What we take from it:

- In both palettes, text and secondary text are at least 4.5:1 on the page, panels and controls,
  and so is the accent, since notices in the header use it.
- Borders and slider tracks are at least 3:1 against the page, panels and header. This made the
  dark palette's borders lighter than they were (#707070, from #3B3B3F).
- The amber accent stays in both palettes, but it's darker in the light one (#8A5300), since the
  dark palette's amber is only about 2:1 on light grey.
- The light palette has no pure white: its lightest grey is #FAFAFA, so it doesn't glare beside
  the picture. That's our reading of ISO 3664's concern with flare, not a rule of its own.

The test "both palettes keep text readable and controls visible" in `theme.zig` checks every one
of these ratios.

Sources: [WCAG 2.2](https://www.w3.org/TR/WCAG22/),
[non-text contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html).

### What other photo editors do

darktable recommends a neutral grey interface for judging colour, and its themes are grey on
purpose. RawTherapee ships neutral grey themes and lets you set the preview's background apart.
Affinity Photo has dark and light styles plus a separate background grey. Capture One sets the
viewer's background apart from its interface. Lightroom Classic and Photoshop let you set the grey
behind the picture separately too. Wherever there's a light interface, the picture's surround is
its own setting, which is what Always dark is here.

Sources: [darktable](https://docs.darktable.org/usermanual/development/en/preferences-settings/general/),
[RawTherapee](https://rawpedia.pixls.us/preferences/),
[Affinity Photo](https://affinity.help/photo/en-US.lproj/pages/Workspace/preferences.html),
[Capture One](https://support.captureone.com/hc/en-us/articles/360002484197).
We couldn't open Adobe's own pages for Lightroom and Photoshop, so those two rest on third-party
guides.

## Icons

Buttons with a clear-cut, widely used icon show the icon instead of a word, with the word as a
tooltip: crop, turn left and right, mirror, pick the film base, copy, delete a frame, the loupe,
Settings, and the three appearances. The icons come from [Lucide](https://lucide.dev), an open
set (ISC licence) that grew out of Feather, drawn from its icon font (`src/ui/icons.zig`).
Buttons whose icon could mean several things, like Fit, Auto, Sync or Reset, keep their words.

## Where it's kept

`preferences.json`, in your account's settings folder:

- macOS: `~/Library/Application Support/minilab`
- Linux: `$XDG_CONFIG_HOME/minilab`, or `~/.config/minilab` when that isn't set
- Windows: `%APPDATA%\minilab`

If the file can't be read, minilab moves it aside to `preferences.json.bad` and starts from the
defaults, the same way it treats a library's `calibration.json` and `scanners.json`.

Screenshots (`minilab open --screenshot`) always use the defaults, so they look the same whoever
takes them.
