# MDitor

A fast, native macOS Markdown editor and viewer built with the [Native SDK](https://github.com/vercel-labs/native) (Zig, GPU-rendered, no browser). It installs as `/Applications/MDitor.app` and can register as the default handler for `.md` files: double-click any Markdown document in Finder (or `open file.md`) and it opens here, rendered live in a split editor/preview.

The left pane is a `textarea` mirrored elm-style into the model; the right pane renders the same bytes through the app's own markdown engine (the SDK's GFM subset, vendored and extended), so the preview tracks every keystroke with no debounce and no drift. The preview understands the full GFM subset plus **LaTeX math** (`$...$` inline, `$$...$$` display blocks with composed fractions, roots, scripts, and operator limits) and **Mermaid diagrams** (`flowchart`/`graph`, `sequenceDiagram`, and `pie` fenced blocks). The view is a Zig-built tree in `src/main.zig`; `src/markdown.zig`, `src/math.zig`, and `src/mermaid.zig` hold the renderers, and a bundled JuliaMono subset (OFL) serves as the app's mono face so Greek letters, scripts, and symbols all draw real glyphs.

```sh
native dev        # run from the repo
```

## Opening .md files

Three delivery paths, all wired:

- **LaunchServices default handler** — `app.zon` declares `file_associations` (`md`, `markdown`, `mdown`, `mkd`; `text/markdown`; Editor role), the packaged Info.plist carries `CFBundleDocumentTypes`, and on first launch the app politely claims itself as the default handler for `net.daringfireball.markdown` (the NSWorkspace `setDefaultApplicationAtURL:toOpenContentType:` path in the host patch): it only takes the role when no default is set, when it is already the default, or when the default is still the pre-rename `dev.native_sdk.markdown_viewer` — an existing default held by another app is never overridden. `scripts/set-default-handler.swift` (or `duti -s dev.mditor.app md all`) remains for manual/dev setups.
- **Open-document AppleEvent** (the real macOS path) — modern macOS delivers a launch document by `odoc` AppleEvent, never argv. The Native SDK host had no `NSApplicationDelegate`, so this repo ships a small host patch (`scripts/apply-native-sdk-patch.sh`) that forwards `application:openFiles:` into the runtime as `open_files` events; the app maps them to `open_file` messages (`on_open_files` in `main.zig`). Works at cold launch and while the app is already running.
- **Command-line fallback** — `firstFileArg` in `main.zig` still picks a path out of argv (direct binary launches, older macOS).

After a CLI upgrade the patch must be re-applied (`scripts/apply-native-sdk-patch.sh`), then rebuild and reinstall (below).

## Install

### Homebrew (recommended)

```sh
brew tap mejiasd3v/homebrew-tap
brew install --cask mditor
```

The cask installs `/Applications/MDitor.app`; the app claims the Markdown default handler itself on first launch. The official [homebrew/cask](https://github.com/Homebrew/homebrew-cask) tap requires every app to be signed and notarized by Apple, and the repo to meet notability thresholds — until MDitor has a Developer ID signature (and the repo has some mileage), it ships from the personal tap. The cask file is staged on the `mditor-cask` branch of [mejiasd3v/homebrew-cask](https://github.com/mejiasd3v/homebrew-cask/tree/mditor-cask) ready for the PR once those requirements are met.

MDitor is unsigned, so on a fresh Mac the first launch may ask you to right-click MDitor → Open (or run `xattr -dr com.apple.quarantine /Applications/MDitor.app`) once — after that, normal launches.

### From source

```sh
native build                 # ReleaseFast
native package --target macos
rm -rf /Applications/MDitor.app
cp -R zig-out/package/mditor.app /Applications/MDitor.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MDitor.app
swift scripts/set-default-handler.swift   # assert default .md handler
```

## What it demonstrates

- **LaTeX math in the preview** — `$...$` inline math transliterates to Unicode (scripts, Greek, symbols) in one span; `$$...$$` display blocks parse into a small tree (fractions stack over a hairline rule, roots get an overline, `\sum` limits sit above and below, `aligned`/`matrix` environments split into cell grids) and emit composed widgets. The vocabulary lives in `src/math.zig`; unknown commands degrade to their names, never tofu.
- **Mermaid diagrams in the preview** — ` ```mermaid ` fences render as widgets: `flowchart`/`graph` (TD/TB/LR/RL/BT, the common node shapes, labeled edges with `-- text -->`/`-->|text|`/`&` fan-outs/chains, `subgraph` groups; layers derive from edge depth and render as centered rows with arrow rows between them), `sequenceDiagram` (participants, message arrows, notes, `loop`/`alt`/`opt` blocks), and `pie` (a proportional stacked bar plus a color legend). Unsupported types and unparseable sources fall back to the ordinary code panel with a muted note. See `src/mermaid.zig`.
- **`<markdown>` under the hood** — the SDK's GFM subset (headings, inline styles, clickable links opened in the system browser through `fx.spawn open`, fenced code with preserved indentation, blockquotes, GFM tables with column alignment, and `<details>` blocks whose expansion flags live in the model) is vendored into `src/markdown.zig` and extended with the two above; the rest of the app's widget surface is unchanged.
- **A math-capable mono face** — the stock Geist face covers almost none of the Greek/math glyphs, so MDitor bundles a JuliaMono subset (`src/fonts/MDitorMathMono-Regular.ttf`, SIL OFL 1.1 — `src/fonts/OFL.txt`), registers it at boot, and points the typography mono slot at it. Math spans and code fences share the face; a coverage test pins every glyph the renderers emit against the bundled cmap, so a font regeneration can never silently drop one.
- **Real file I/O without native dialogs** — the Native SDK has no file-dialog service, so this app uses the honest pattern: an editable path field in the toolbar. **Open** reads it (`fx.readFile`), **Save** writes the editor back to the current document, **Save As** writes to whatever the field says and adopts it. Every result is one typed Msg with an explicit outcome; failures land in the status bar, never a dialog.
- **Recent files persisted through the same effects** — opened/saved paths join a sidebar list (the active document is highlighted) that persists to the per-app data directory (`native_sdk.app_dirs`, resolved once in `main`) via `fx.writeFile`, and is restored at boot by `init_fx` + `fx.readFile`.
- **System appearance, followed live** — a refined stone/indigo palette (light and dark) derives per rebuild through `tokens_fn` from the scheme `on_appearance` delivers; flipping the OS between light and dark re-themes the window immediately.
- **Controlled scrolling** — the preview's scroll offset is model-owned: `on-scroll` stores the applied offset, the `value` binding echoes it back, so rebuilds (every keystroke re-renders the preview) never lose the reading position.
- **Derived state, never stored** — word/line/byte counts in the status bar are computed from the live document at view time.

Selection and copy in the preview, native scrolling, and the standard edit context menus in the editor are framework defaults — no app code.

## Bundled documents

The sidebar ships four sample documents embedded from `src/samples/` (they live under `src/` because `@embedFile` is module-rooted there): a README-style welcome with a table, a full renderer tour, a spec with task lists and details blocks, and a notes page.

## Fixed capacities

Documents cap at 24 KiB (`max_document_bytes` — the view retains editor + preview text against the 64 KiB per-view widget-text budget; over-cap opens arrive cut with an explicit `.truncated` outcome, never silently), paths at 512 bytes, the recent list at 6 entries, and `<details>` expansion flags at 16 blocks. The renderers carry their own bounds (documented in the modules): 64 blocks per container, 8 table columns, 96 math atoms, 16 matrix rows/cells, 48 flowchart nodes, 96 edges, 12 layers, 8 subgraphs, 8 participants, 64 messages, and 16 pie slices — overflow drops trailing content deterministically.

## Assets

- `scripts/make-icon.swift` draws the app icon (indigo tile, document sheet, "M↓" monogram) and emits `assets/icon.png` plus the `assets/markdown.icns` document-type icon.
- `scripts/set-default-handler.swift` asserts the LaunchServices default handler.
- `scripts/apply-native-sdk-patch.sh` + `scripts/native-sdk-patch/` carry the host patch that delivers open-document AppleEvents (see above).
- `src/fonts/MDitorMathMono-Regular.ttf` + `src/fonts/OFL.txt` — the math-mono face: a JuliaMono subset (SIL OFL 1.1, reserved name honored by renaming the derivative) covering Latin, Greek, scripts, and the math/diagram symbols the renderers emit; it is embedded at build time and registered at boot.

## Tests

`native test` drives the real dispatch paths: open/save/save-as round-trips and recent-list persistence through the fake effect executor, the open-document AppleEvent mapping (`on_open_files`), command-line file arguments (`firstFileArg`), link clicks spawning the browser command, details toggling via automation `widget-click`, editor edits updating the preview and derived counts, the system appearance re-deriving the tokens live through platform events, the controlled preview scroll round-trip, view determinism across rebuilds, and automation snapshot assertions over links, table cells, and task checkboxes. The math and mermaid renderers get their own tests: inline transliteration (including the `^(...)` fallback and literal `$` degradation), display-math widget composition (fraction/root/scripts), flowchart/sequence/pie rendering, unsupported-type fallback, and a coverage test pinning every emitted glyph against the bundled font's cmap. `MATHSHOTS=1 native test` renders the showcase document (math + all three diagram types) offscreen for visual review.

> Note: the SDK's canvas text editing dropped undo/redo and vertical caret moves in 0.4.0; the tests cover the current contract (compound select+replace edits, home/end moves) through the real platform-event path.

## Releasing

1. Bump `.version` in `app.zon`.
2. `native build && native package --target macos`
3. Zip the app as `MDitor.zip` (`ditto -c -k --keepParent zig-out/package/mditor.app MDitor.zip` with the bundle renamed to `MDitor.app`).
4. `gh release create vX.Y.Z MDitor.zip`
5. Update `Casks/mditor.rb` in the [homebrew-tap](https://github.com/mejiasd3v/homebrew-tap) repo with the new version and `shasum -a 256 MDitor.zip`. When the app is Developer ID signed/notarized and the repo meets homebrew/cask's notability thresholds, also open the matching PR against [homebrew/cask](https://github.com/Homebrew/homebrew-cask) (`Casks/m/mditor.rb` — the same file, no postflight; the branch is already staged on [mejiasd3v/homebrew-cask](https://github.com/mejiasd3v/homebrew-cask/tree/mditor-cask)).

## License

MIT — see [LICENSE](LICENSE).
