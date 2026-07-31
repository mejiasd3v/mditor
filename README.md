# MDitor

A fast, native macOS Markdown editor and viewer built with the [Native SDK](https://github.com/vercel-labs/native) (markup + Zig, GPU-rendered, no browser). It installs as `/Applications/MDitor.app` and can register as the default handler for `.md` files: double-click any Markdown document in Finder (or `open file.md`) and it opens here, rendered live in a split editor/preview.

The left pane is a `textarea` mirrored elm-style into the model; the right pane is one `<markdown>` element bound to the same bytes, so the preview tracks every keystroke with no debounce and no drift. The view lives in `src/viewer.native` (hot-reloaded in dev builds); `src/main.zig` is the logic — `Model`, `Msg`, `update`, effects, and a two-mode stone/indigo theme that follows the system appearance live.

```sh
native dev        # run from the repo
```

## Opening .md files

Three delivery paths, all wired:

- **LaunchServices default handler** — `app.zon` declares `file_associations` (`md`, `markdown`, `mdown`, `mkd`; `text/markdown`; Editor role), the packaged Info.plist carries `CFBundleDocumentTypes`, and the LaunchServices default for `net.daringfireball.markdown` is set to `dev.mditor.app` (`scripts/set-default-handler.swift`, or `duti -s dev.mditor.app md all`).
- **Open-document AppleEvent** (the real macOS path) — modern macOS delivers a launch document by `odoc` AppleEvent, never argv. The Native SDK host had no `NSApplicationDelegate`, so this repo ships a small host patch (`scripts/apply-native-sdk-patch.sh`) that forwards `application:openFiles:` into the runtime as `open_files` events; the app maps them to `open_file` messages (`on_open_files` in `main.zig`). Works at cold launch and while the app is already running.
- **Command-line fallback** — `firstFileArg` in `main.zig` still picks a path out of argv (direct binary launches, older macOS).

After a CLI upgrade the patch must be re-applied (`scripts/apply-native-sdk-patch.sh`), then rebuild and reinstall (below).

## Install

### Homebrew (recommended)

```sh
brew tap mejiasd3v/homebrew-tap
brew install --cask mditor
```

The cask installs `/Applications/MDitor.app`, drops the quarantine attribute (unsigned build), registers it with LaunchServices, and asserts it as the default handler for Markdown documents.

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

- **`<markdown>` in markup** — headings on the span scale, inline styles, clickable links (opened in the system browser through `fx.spawn open`/`xdg-open`), fenced code with preserved indentation, blockquotes, GFM tables with column alignment, and `<details>` blocks whose expansion flags live in the model (`details_expanded: [16]bool`), toggled in `update`.
- **Real file I/O without native dialogs** — the Native SDK has no file-dialog service, so this app uses the honest pattern: an editable path field in the toolbar. **Open** reads it (`fx.readFile`), **Save** writes the editor back to the current document, **Save As** writes to whatever the field says and adopts it. Every result is one typed Msg with an explicit outcome; failures land in the status bar, never a dialog.
- **Recent files persisted through the same effects** — opened/saved paths join a sidebar list (the active document is highlighted) that persists to the per-app data directory (`native_sdk.app_dirs`, resolved once in `main`) via `fx.writeFile`, and is restored at boot by `init_fx` + `fx.readFile`.
- **System appearance, followed live** — a refined stone/indigo palette (light and dark) derives per rebuild through `tokens_fn` from the scheme `on_appearance` delivers; flipping the OS between light and dark re-themes the window immediately.
- **Controlled scrolling** — the preview's scroll offset is model-owned: `on-scroll` stores the applied offset, the `value` binding echoes it back, so rebuilds (every keystroke re-renders the preview) never lose the reading position.
- **Derived state, never stored** — word/line/byte counts in the status bar are computed from the live document at view time.

Selection and copy in the preview, native scrolling, and the standard edit context menus in the editor are framework defaults — no app code.

## Bundled documents

The sidebar ships four sample documents embedded from `src/samples/` (they live under `src/` because `@embedFile` is module-rooted there): a README-style welcome with a table, a full renderer tour, a spec with task lists and details blocks, and a notes page.

## Fixed capacities

Documents cap at 24 KiB (`max_document_bytes` — the view retains editor + preview text against the 64 KiB per-view widget-text budget; over-cap opens arrive cut with an explicit `.truncated` outcome, never silently), paths at 512 bytes, the recent list at 6 entries, and `<details>` expansion flags at 16 blocks.

## Assets

- `scripts/make-icon.swift` draws the app icon (indigo tile, document sheet, "M↓" monogram) and emits `assets/icon.png` plus the `assets/markdown.icns` document-type icon.
- `scripts/set-default-handler.swift` asserts the LaunchServices default handler.
- `scripts/apply-native-sdk-patch.sh` + `scripts/native-sdk-patch/` carry the host patch that delivers open-document AppleEvents (see above).

## Tests

`native test` drives the real dispatch paths: open/save/save-as round-trips and recent-list persistence through the fake effect executor, the open-document AppleEvent mapping (`on_open_files`), command-line file arguments (`firstFileArg`), link clicks spawning the browser command, details toggling via automation `widget-click`, editor edits updating the preview and derived counts, the system appearance re-deriving the tokens live through platform events, the controlled preview scroll round-trip, compiled/interpreter markup parity, and automation snapshot assertions over links, table cells, and task checkboxes.

> Note: the SDK's canvas text editing dropped undo/redo and vertical caret moves in 0.4.0; the tests cover the current contract (compound select+replace edits, home/end moves) through the real platform-event path.

## Releasing

1. Bump `.version` in `app.zon`.
2. `native build && native package --target macos`
3. Zip the app as `MDitor.zip` (`ditto -c -k --keepParent zig-out/package/mditor.app MDitor.zip` with the bundle renamed to `MDitor.app`).
4. `gh release create vX.Y.Z MDitor.zip`
5. Update `Casks/mditor.rb` in the [homebrew-tap](https://github.com/mejiasd3v/homebrew-tap) repo with the new version and `shasum -a 256 MDitor.zip`.

## License

MIT — see [LICENSE](LICENSE).
