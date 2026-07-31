//! MDitor's LaTeX math subset renderer.
//!
//! Two modes share one command/symbol vocabulary:
//! - `inlineText`: `$...$` inline math transliterates to a single Unicode
//!   string (real glyphs, not ASCII approximations) for one mono span in
//!   the surrounding paragraph.
//! - `display`: `$$...$$` display math parses into a small tree
//!   (fractions, roots, scripts, operator limits, matrices) and emits
//!   composed widgets, so fractions draw as stacked numerator/denominator
//!   over a rule, roots get an overline, and `\sum` limits sit above and
//!   below the glyph.
//!
//! Fonts: math spans set `.monospace = true`, which resolves to the
//! typography mono face — MDitor registers a JuliaMono subset
//! (`MDitorMathMono-Regular.ttf`, SIL OFL 1.1, see `src/fonts/OFL.txt`)
//! as its mono face so Greek, scripts, and symbols all have real glyphs
//! (the stock Geist face covers almost none of them). The same face also
//! renders fenced code, which is why the subset keeps the full Latin
//! range.
//!
//! Deliberately a subset: `\begin{aligned}`-style environments split on
//! `\\`/`&` into rows of cells (no alignment packing), and anything this
//! vocabulary does not know renders as its command name — never a
//! failure, never tofu.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const math_font_id: canvas.FontId = canvas.min_registered_font_id;
pub const math_font_name = "MDitorMathMono-Regular.ttf";
pub const math_font_ttf: []const u8 = @embedFile("fonts/MDitorMathMono-Regular.ttf");

/// Bounds that keep hostile math bounded (the app's fixed-capacity
/// conventions).
pub const max_math_atoms: usize = 96;
pub const max_math_script_depth: usize = 4;
pub const max_math_rows: usize = 16;
pub const max_math_cells_per_row: usize = 16;

/// `\command` → Unicode. Everything the vocabulary knows; the renderer
/// degrades unknown commands to their name (never tofu — the coverage
/// test in tests.zig pins the mono face against this exact set).
const Entry = struct { []const u8, []const u8 };

const symbol_entries = [_]Entry{
    .{ "alpha", "α" },
    .{ "beta", "β" },
    .{ "gamma", "γ" },
    .{ "delta", "δ" },
    .{ "epsilon", "ε" },
    .{ "varepsilon", "ε" },
    .{ "zeta", "ζ" },
    .{ "eta", "η" },
    .{ "theta", "θ" },
    .{ "vartheta", "ϑ" },
    .{ "iota", "ι" },
    .{ "kappa", "κ" },
    .{ "lambda", "λ" },
    .{ "mu", "μ" },
    .{ "nu", "ν" },
    .{ "xi", "ξ" },
    .{ "omicron", "ο" },
    .{ "pi", "π" },
    .{ "varpi", "ϖ" },
    .{ "rho", "ρ" },
    .{ "varrho", "ϱ" },
    .{ "sigma", "σ" },
    .{ "varsigma", "ς" },
    .{ "tau", "τ" },
    .{ "upsilon", "υ" },
    .{ "phi", "φ" },
    .{ "varphi", "ϕ" },
    .{ "chi", "χ" },
    .{ "psi", "ψ" },
    .{ "omega", "ω" },
    .{ "Gamma", "Γ" },
    .{ "Delta", "Δ" },
    .{ "Theta", "Θ" },
    .{ "Lambda", "Λ" },
    .{ "Xi", "Ξ" },
    .{ "Pi", "Π" },
    .{ "Sigma", "Σ" },
    .{ "Upsilon", "Υ" },
    .{ "Phi", "Φ" },
    .{ "Psi", "Ψ" },
    .{ "Omega", "Ω" },
    .{ "le", "≤" },
    .{ "leq", "≤" },
    .{ "leqslant", "≤" },
    .{ "ge", "≥" },
    .{ "geq", "≥" },
    .{ "geqslant", "≥" },
    .{ "ne", "≠" },
    .{ "neq", "≠" },
    .{ "approx", "≈" },
    .{ "simeq", "≃" },
    .{ "cong", "≅" },
    .{ "equiv", "≡" },
    .{ "propto", "∝" },
    .{ "sim", "∼" },
    .{ "lesssim", "≲" },
    .{ "gtrsim", "≳" },
    .{ "prec", "≺" },
    .{ "succ", "≻" },
    .{ "ll", "≪" },
    .{ "gg", "≫" },
    .{ "in", "∈" },
    .{ "notin", "∉" },
    .{ "ni", "∋" },
    .{ "subset", "⊂" },
    .{ "supset", "⊃" },
    .{ "subseteq", "⊆" },
    .{ "supseteq", "⊇" },
    .{ "subsetneq", "⊊" },
    .{ "supsetneq", "⊋" },
    .{ "perp", "⊥" },
    .{ "parallel", "∥" },
    .{ "mid", "∣" },
    .{ "nmid", "∤" },
    .{ "times", "×" },
    .{ "div", "÷" },
    .{ "cdot", "⋅" },
    .{ "cdotp", "⋅" },
    .{ "ast", "∗" },
    .{ "star", "⋆" },
    .{ "bullet", "∙" },
    .{ "circ", "∘" },
    .{ "pm", "±" },
    .{ "mp", "∓" },
    .{ "setminus", "∖" },
    .{ "cup", "∪" },
    .{ "cap", "∩" },
    .{ "wedge", "∧" },
    .{ "land", "∧" },
    .{ "vee", "∨" },
    .{ "lor", "∨" },
    .{ "oplus", "⊕" },
    .{ "ominus", "⊖" },
    .{ "otimes", "⊗" },
    .{ "oslash", "⊘" },
    .{ "odot", "⊙" },
    .{ "dagger", "†" },
    .{ "ddagger", "‡" },
    .{ "amalg", "⨿" },
    .{ "sum", "∑" },
    .{ "prod", "∏" },
    .{ "coprod", "∐" },
    .{ "int", "∫" },
    .{ "iint", "∬" },
    .{ "iiint", "∭" },
    .{ "oint", "∮" },
    .{ "bigcup", "⋃" },
    .{ "bigcap", "⋂" },
    .{ "bigoplus", "⨁" },
    .{ "bigotimes", "⨂" },
    .{ "biguplus", "⨄" },
    .{ "bigvee", "⋁" },
    .{ "bigwedge", "⋀" },
    .{ "rightarrow", "→" },
    .{ "to", "→" },
    .{ "leftarrow", "←" },
    .{ "gets", "←" },
    .{ "leftrightarrow", "↔" },
    .{ "Rightarrow", "⇒" },
    .{ "implies", "⇒" },
    .{ "Leftarrow", "⇐" },
    .{ "impliedby", "⇐" },
    .{ "Leftrightarrow", "⇔" },
    .{ "iff", "⇔" },
    .{ "uparrow", "↑" },
    .{ "downarrow", "↓" },
    .{ "updownarrow", "↕" },
    .{ "mapsto", "↦" },
    .{ "hookrightarrow", "↪" },
    .{ "hookleftarrow", "↢" },
    .{ "nearrow", "↗" },
    .{ "searrow", "↘" },
    .{ "swarrow", "↙" },
    .{ "nwarrow", "↖" },
    .{ "infty", "∞" },
    .{ "partial", "∂" },
    .{ "nabla", "∇" },
    .{ "prime", "′" },
    .{ "doubleprime", "″" },
    .{ "degree", "°" },
    .{ "angle", "∠" },
    .{ "measuredangle", "∡" },
    .{ "sphericalangle", "∢" },
    .{ "triangle", "△" },
    .{ "square", "□" },
    .{ "forall", "∀" },
    .{ "exists", "∃" },
    .{ "nexists", "∄" },
    .{ "neg", "¬" },
    .{ "lnot", "¬" },
    .{ "emptyset", "∅" },
    .{ "varnothing", "∅" },
    .{ "therefore", "∴" },
    .{ "because", "∵" },
    .{ "ell", "ℓ" },
    .{ "hbar", "ℏ" },
    .{ "aleph", "ℵ" },
    .{ "Re", "ℜ" },
    .{ "Im", "ℑ" },
    .{ "top", "⊤" },
    .{ "bot", "⊥" },
    .{ "backslash", "∖" },
    .{ "vert", "|" },
    .{ "Vert", "‖" },
    .{ "dots", "…" },
    .{ "ldots", "…" },
    .{ "cdots", "⋯" },
    .{ "vdots", "⋮" },
    .{ "ddots", "⋱" },
    .{ "frown", "⌢" },
    .{ "smile", "⌣" },
};
const symbol_map = std.StaticStringMap([]const u8).initComptime(symbol_entries);

/// `\command` → Unicode (see symbol_entries). Everything the
/// vocabulary knows; the renderer degrades unknown commands to their
/// name (never tofu — the coverage test in tests.zig pins the mono face
/// against this exact set).
fn symbolOf(name: []const u8) ?[]const u8 {
    return symbol_map.get(name);
}

/// `\command` → upright function name (sin, log, max, …). Functions
/// render upright in display math; the inline path appends the name.
const function_entries = [_]Entry{
    .{ "Pr", "Pr" },
    .{ "arccos", "arccos" },
    .{ "arcsin", "arcsin" },
    .{ "arctan", "arctan" },
    .{ "arg", "arg" },
    .{ "cos", "cos" },
    .{ "cosh", "cosh" },
    .{ "cot", "cot" },
    .{ "coth", "coth" },
    .{ "csc", "csc" },
    .{ "deg", "deg" },
    .{ "det", "det" },
    .{ "dim", "dim" },
    .{ "exp", "exp" },
    .{ "gcd", "gcd" },
    .{ "inf", "inf" },
    .{ "ker", "ker" },
    .{ "lg", "lg" },
    .{ "lim", "lim" },
    .{ "liminf", "liminf" },
    .{ "limsup", "limsup" },
    .{ "ln", "ln" },
    .{ "log", "log" },
    .{ "max", "max" },
    .{ "min", "min" },
    .{ "mod", "mod" },
    .{ "sec", "sec" },
    .{ "sin", "sin" },
    .{ "sinh", "sinh" },
    .{ "sup", "sup" },
    .{ "tan", "tan" },
    .{ "tanh", "tanh" },
};
const function_map = std.StaticStringMap([]const u8).initComptime(function_entries);

/// `\command` → upright function name (sin, log, max, …). Functions
/// render upright in display math; the inline path appends the name.
fn functionOf(name: []const u8) ?[]const u8 {
    return function_map.get(name);
}

/// Spacing commands map to a single space in the inline transliteration.
const spacing_entries = .{
    .{ " ", {} },
    .{ "!", {} },
    .{ ",", {} },
    .{ ":", {} },
    .{ ";", {} },
    .{ "enspace", {} },
    .{ "negmedspace", {} },
    .{ "negthickspace", {} },
    .{ "negthinspace", {} },
    .{ "qquad", {} },
    .{ "quad", {} },
    .{ "thickspace", {} },
    .{ "thinspace", {} },
};
const spacing_map = std.StaticStringMap(void).initComptime(spacing_entries);

/// Spacing commands map to a single space in the inline transliteration.
fn spacingOf(name: []const u8) bool {
    return spacing_map.has(name);
}

/// Delimiter commands (`\left(`/`\right)`, `\big` sizes): emit the
/// following character as literal text.
fn isDelimiterCommand(name: []const u8) bool {
    return std.mem.eql(u8, name, "left") or std.mem.eql(u8, name, "right") or
        std.mem.startsWith(u8, name, "big");
}

/// Superscript mapping: digits and letters that have Unicode superscript
/// forms, all covered by the bundled math mono face. Unmapped bytes fall
/// back to `^(...)` at the call site.
const superscript_entries = [_]Entry{
    .{ "0", "⁰" },
    .{ "1", "¹" },
    .{ "2", "²" },
    .{ "3", "³" },
    .{ "4", "⁴" },
    .{ "5", "⁵" },
    .{ "6", "⁶" },
    .{ "7", "⁷" },
    .{ "8", "⁸" },
    .{ "9", "⁹" },
    .{ "+", "⁺" },
    .{ "-", "⁻" },
    .{ "(", "⁽" },
    .{ ")", "⁾" },
    .{ "=", "⁼" },
    .{ "n", "ⁿ" },
    .{ "i", "ⁱ" },
    .{ "a", "ᵃ" },
    .{ "b", "ᵇ" },
    .{ "c", "ᶜ" },
    .{ "d", "ᵈ" },
    .{ "e", "ᵉ" },
    .{ "f", "ᶠ" },
    .{ "g", "ᵍ" },
    .{ "h", "ʰ" },
    .{ "j", "ʲ" },
    .{ "k", "ᵏ" },
    .{ "l", "ˡ" },
    .{ "m", "ᵐ" },
    .{ "o", "ᵒ" },
    .{ "p", "ᵖ" },
    .{ "r", "ʳ" },
    .{ "s", "ˢ" },
    .{ "t", "ᵗ" },
    .{ "u", "ᵘ" },
    .{ "v", "ᵛ" },
    .{ "w", "ʷ" },
    .{ "x", "ˣ" },
    .{ "y", "ʸ" },
    .{ "z", "ᶻ" },
};
const superscript_map = std.StaticStringMap([]const u8).initComptime(superscript_entries);

fn superscriptOf(byte: u8) ?[]const u8 {
    var key: [1]u8 = .{byte};
    return superscript_map.get(&key);
}

const subscript_entries = [_]Entry{
    .{ "0", "₀" },
    .{ "1", "₁" },
    .{ "2", "₂" },
    .{ "3", "₃" },
    .{ "4", "₄" },
    .{ "5", "₅" },
    .{ "6", "₆" },
    .{ "7", "₇" },
    .{ "8", "₈" },
    .{ "9", "₉" },
    .{ "+", "₊" },
    .{ "-", "₋" },
    .{ "(", "₍" },
    .{ ")", "₎" },
    .{ "=", "₌" },
    .{ "a", "ₐ" },
    .{ "e", "ₑ" },
    .{ "h", "ₕ" },
    .{ "i", "ᵢ" },
    .{ "j", "ⱼ" },
    .{ "k", "ₖ" },
    .{ "l", "ₗ" },
    .{ "m", "ₘ" },
    .{ "n", "ₙ" },
    .{ "o", "ₒ" },
    .{ "p", "ₚ" },
    .{ "r", "ᵣ" },
    .{ "s", "ₛ" },
    .{ "t", "ₜ" },
    .{ "u", "ᵤ" },
    .{ "v", "ᵥ" },
    .{ "x", "ₓ" },
};
const subscript_map = std.StaticStringMap([]const u8).initComptime(subscript_entries);

fn subscriptOf(byte: u8) ?[]const u8 {
    var key: [1]u8 = .{byte};
    return subscript_map.get(&key);
}

/// `\frac{a}{b}` with single small digits → the one-codepoint vulgar
/// fractions; anything else → `a⁄b` (U+2044 fraction slash).
fn vulgarFraction(numerator: []const u8, denominator: []const u8) ?[]const u8 {
    if (numerator.len == 1 and denominator.len == 1) {
        const pair: ?[]const u8 = switch (numerator[0]) {
            '1' => switch (denominator[0]) {
                '2' => "½",
                '3' => "⅓",
                '4' => "¼",
                '8' => "⅛",
                else => null,
            },
            '2' => if (denominator[0] == '3') "⅔" else null,
            '3' => if (denominator[0] == '4') "¾" else if (denominator[0] == '8') "⅜" else null,
            '5' => if (denominator[0] == '8') "⅝" else null,
            '7' => if (denominator[0] == '8') "⅞" else null,
            else => null,
        };
        if (pair) |p| return p;
    }
    return null;
}

/// Every glyph the math vocabulary can emit (symbols, functions, script
/// forms) — the coverage test pins the bundled mono face against this
/// exact set, so a font regeneration can never silently drop a glyph
/// the renderer relies on.
pub fn coverageGlyphs(buffer: [][]const u8) []const []const u8 {
    var count: usize = 0;
    const fill = struct {
        fn go(entries: []const Entry, out: [][]const u8, len: *usize) void {
            for (entries) |entry| {
                if (len.* >= out.len) return;
                out[len.*] = entry[1];
                len.* += 1;
            }
        }
    }.go;
    fill(&symbol_entries, buffer, &count);
    fill(&function_entries, buffer, &count);
    fill(&superscript_entries, buffer, &count);
    fill(&subscript_entries, buffer, &count);
    return buffer[0..count];
}

// ---------------------------------------------------------- inline math

/// Transliterate inline math into one Unicode string in `buffer`;
/// returns the written slice. Callers size the buffer generously (the
/// output can reach ~3x the input: script glyphs are multi-byte).
pub fn inlineText(src: []const u8, buffer: []u8) []const u8 {
    var out: usize = 0;
    var index: usize = 0;

    const write = struct {
        fn go(buf: []u8, len: *usize, text: []const u8) void {
            if (text.len == 0 or len.* >= buf.len) return;
            const take = @min(text.len, buf.len - len.*);
            @memcpy(buf[len.*..][0..take], text[0..take]);
            len.* += take;
        }
    }.go;

    while (index < src.len) {
        const byte = src[index];
        if (byte == '\\') {
            index += 1;
            if (index >= src.len) break;
            if (src[index] == '\\') {
                // Row break inside inline math reads as a space.
                write(buffer, &out, " ");
                index += 1;
                continue;
            }
            const name_start = index;
            while (index < src.len and std.ascii.isAlphabetic(src[index])) index += 1;
            const name = src[name_start..index];
            if (name.len == 0) {
                // Escaped punctuation: `\{`, `\%`, `\$`, `\,`, ...
                if (spacingOf(src[name_start .. name_start + 1])) {
                    write(buffer, &out, " ");
                } else {
                    write(buffer, &out, src[name_start .. name_start + 1]);
                }
                index += 1;
                continue;
            }
            if (symbolOf(name)) |symbol| {
                write(buffer, &out, symbol);
            } else if (functionOf(name)) |function| {
                write(buffer, &out, function);
            } else if (spacingOf(name)) {
                write(buffer, &out, " ");
            } else if (isDelimiterCommand(name)) {
                // `\left(`: the delimiter is the next character (or the
                // next escaped character).
                if (index < src.len and src[index] == '\\') {
                    if (index + 1 < src.len) {
                        write(buffer, &out, src[index + 1 .. index + 2]);
                        index += 2;
                    } else {
                        index += 1;
                    }
                } else if (index < src.len) {
                    write(buffer, &out, src[index .. index + 1]);
                    index += 1;
                }
            } else if (std.mem.eql(u8, name, "frac")) {
                if (parseBraced(src, &index)) |numerator| {
                    if (parseBraced(src, &index)) |denominator| {
                        if (vulgarFraction(numerator, denominator)) |vulgar| {
                            write(buffer, &out, vulgar);
                        } else {
                            write(buffer, &out, numerator);
                            write(buffer, &out, "⁄");
                            write(buffer, &out, denominator);
                        }
                    }
                }
            } else if (std.mem.eql(u8, name, "sqrt")) {
                var root: []const u8 = "";
                if (index < src.len and src[index] == '[') {
                    const close = std.mem.indexOfScalarPos(u8, src, index, ']') orelse src.len;
                    root = src[index + 1 .. close];
                    index = @min(close + 1, src.len);
                }
                if (parseBraced(src, &index)) |content| {
                    if (root.len == 1 and (root[0] == '2' or root[0] == '1')) {
                        write(buffer, &out, "√");
                    } else if (root.len == 1 and root[0] == '3') {
                        write(buffer, &out, "∛");
                    } else {
                        writeScript(buffer, &out, root, true);
                        write(buffer, &out, "√");
                    }
                    write(buffer, &out, content);
                }
            } else if (std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "textrm") or
                std.mem.eql(u8, name, "mathrm") or std.mem.eql(u8, name, "mathbf") or
                std.mem.eql(u8, name, "mathit") or std.mem.eql(u8, name, "operatorname"))
            {
                if (parseBraced(src, &index)) |content| write(buffer, &out, content);
            } else if (std.mem.eql(u8, name, "begin") or std.mem.eql(u8, name, "end")) {
                // Environments are display-math territory; inline they
                // degrade to their name.
                write(buffer, &out, name);
                if (parseBraced(src, &index)) |env_name| write(buffer, &out, env_name);
            } else {
                // Unknown command: keep its name — honest degradation.
                write(buffer, &out, name);
            }
            continue;
        }
        if (byte == '^') {
            index += 1;
            if (scriptGroup(src, &index)) |group| {
                writeScript(buffer, &out, group, true);
            } else {
                write(buffer, &out, "^");
            }
            continue;
        }
        if (byte == '_') {
            index += 1;
            if (scriptGroup(src, &index)) |group| {
                writeScript(buffer, &out, group, false);
            } else {
                write(buffer, &out, "_");
            }
            continue;
        }
        if (byte == '{' or byte == '}') {
            index += 1;
            continue;
        }
        if (byte == '~') {
            write(buffer, &out, " ");
            index += 1;
            continue;
        }
        write(buffer, &out, src[index .. index + 1]);
        index += 1;
    }
    return buffer[0..out];
}

/// The script content after `^`/`_`: a braced group or a single
/// character. Advances `index` past it; null when nothing follows.
fn scriptGroup(src: []const u8, index: *usize) ?[]const u8 {
    if (index.* >= src.len) return null;
    if (src[index.*] == '{') return parseBraced(src, index);
    if (src[index.*] == '\\') return null;
    const group = src[index.* .. index.* + 1];
    index.* += 1;
    return group;
}

/// `{...}` group contents at `index` (which must point at `{`); advances
/// past the closing `}`. Nested braces balance; a missing closer reads to
/// the end. Null when `index` does not point at `{`.
fn parseBraced(src: []const u8, index: *usize) ?[]const u8 {
    if (index.* >= src.len or src[index.*] != '{') return null;
    var depth: usize = 1;
    var scan = index.* + 1;
    while (scan < src.len) : (scan += 1) {
        if (src[scan] == '{') {
            depth += 1;
        } else if (src[scan] == '}') {
            depth -= 1;
            if (depth == 0) {
                const content = src[index.* + 1 .. scan];
                index.* = scan + 1;
                return content;
            }
        }
    }
    const content = src[index.* + 1 ..];
    index.* = src.len;
    return content;
}

/// Append a script (superscript or subscript) run: char-by-char through
/// the Unicode map; a single unmapped character degrades the whole run
/// to `^(...)` / `_(...)`.
fn writeScript(buffer: []u8, len: *usize, content: []const u8, sup: bool) void {
    if (content.len == 0) return;
    var mapped: [96]u8 = undefined;
    var mapped_len: usize = 0;
    var ok = true;
    for (content) |byte| {
        const maybe_glyph = if (sup) superscriptOf(byte) else subscriptOf(byte);
        if (maybe_glyph) |glyph| {
            if (mapped_len + glyph.len > mapped.len) {
                ok = false;
                break;
            }
            @memcpy(mapped[mapped_len..][0..glyph.len], glyph);
            mapped_len += glyph.len;
        } else {
            ok = false;
            break;
        }
    }
    if (ok) {
        const append = mapped[0..mapped_len];
        if (len.* + append.len <= buffer.len) {
            @memcpy(buffer[len.*..][0..append.len], append);
            len.* += append.len;
        }
        return;
    }
    const open: []const u8 = if (sup) "^(" else "_(";
    if (len.* + open.len + content.len + 1 > buffer.len) return;
    @memcpy(buffer[len.*..][0..open.len], open);
    len.* += open.len;
    // Transliterate what the vocabulary knows (so `i\pi` reads `iπ`)
    // and keep the rest literal.
    var index: usize = 0;
    while (index < content.len) {
        const byte = content[index];
        if (byte == '\\') {
            const name_start = index + 1;
            var name_end = name_start;
            while (name_end < content.len and std.ascii.isAlphabetic(content[name_end])) name_end += 1;
            if (name_end > name_start) {
                if (symbolOf(content[name_start..name_end])) |symbol| {
                    const take = @min(symbol.len, buffer.len - len.*);
                    @memcpy(buffer[len.*..][0..take], symbol[0..take]);
                    len.* += take;
                    index = name_end;
                    continue;
                }
                if (functionOf(content[name_start..name_end])) |function| {
                    const take = @min(function.len, buffer.len - len.*);
                    @memcpy(buffer[len.*..][0..take], function[0..take]);
                    len.* += take;
                    index = name_end;
                    continue;
                }
                if (spacingOf(content[name_start..name_end])) {
                    if (len.* < buffer.len) {
                        buffer[len.*] = ' ';
                        len.* += 1;
                    }
                    index = name_end;
                    continue;
                }
            }
        }
        const take = @min(@as(usize, 1), buffer.len - len.*);
        buffer[len.*] = byte;
        len.* += take;
        index += 1;
    }
    if (len.* >= buffer.len) return;
    buffer[len.*] = ')';
    len.* += 1;
}

// --------------------------------------------------------- display math

pub fn Math(comptime Msg: type) type {
    return struct {
        const Ui = canvas.Ui(Msg);
        const Node = Ui.Node;

        const MathNode = struct {
            kind: enum { row, span, func, text, frac, sqrt, script, op, matrix },
            /// `span`/`func`/`text`/`op`: the literal run.
            text: []const u8 = "",
            /// `row`: children; `frac`: [num, den]; `sqrt`: [content];
            /// `script`: [base]; `matrix`: flattened cells.
            children: []const MathNode = &.{},
            sup: ?*const MathNode = null,
            sub: ?*const MathNode = null,
            /// `sqrt`: root index (empty = square root).
            root: []const u8 = "",
            /// `matrix`: row/column structure (row-major flattened).
            rows: usize = 0,
            cols: usize = 0,
            bordered: bool = false,
        };

        const EMPTY: MathNode = .{ .kind = .row };

        const Parser = struct {
            ui: *Ui,
            src: []const u8,
            index: usize = 0,
            depth: usize = 0,
            failed: bool = false,

            fn child(self: *Parser, child_node: MathNode) *const MathNode {
                const copy = self.ui.arena.create(MathNode) catch {
                    self.failed = true;
                    return &EMPTY;
                };
                copy.* = child_node;
                return copy;
            }

            fn allocChildren(self: *Parser, count: usize) []MathNode {
                return self.ui.arena.alloc(MathNode, count) catch {
                    self.failed = true;
                    return &.{};
                };
            }

            /// A sequence of atoms up to end-of-input or a `}` (consumed
            /// when `stop_at_brace`).
            fn parseSequence(self: *Parser, stop_at_brace: bool) MathNode {
                var atoms = self.allocChildren(max_math_atoms);
                var count: usize = 0;
                while (self.index < self.src.len) {
                    const byte = self.src[self.index];
                    if (byte == '}' and stop_at_brace) {
                        self.index += 1;
                        break;
                    }
                    if (byte == '}') break;
                    if (count >= atoms.len) break;
                    const atom = self.parseAtom() orelse {
                        self.index += 1;
                        continue;
                    };
                    atoms[count] = self.attachScripts(atom);
                    count += 1;
                }
                if (count == 0) return .{ .kind = .row };
                return .{ .kind = .row, .children = atoms[0..count] };
            }

            fn parseAtom(self: *Parser) ?MathNode {
                const byte = self.src[self.index];
                if (byte == '\\') return self.parseCommand();
                if (byte == '{') {
                    self.index += 1;
                    self.depth += 1;
                    defer self.depth -= 1;
                    return self.parseSequence(true);
                }
                // Literal run: merge consecutive non-special bytes into one
                // span so atoms stay few and gaps stay meaningful.
                const start = self.index;
                while (self.index < self.src.len) : (self.index += 1) {
                    const b = self.src[self.index];
                    if (b == '\\' or b == '{' or b == '}' or b == '^' or b == '_') break;
                }
                const run = self.src[start..self.index];
                if (run.len == 0) return null;
                return .{ .kind = .span, .text = run };
            }

            fn parseCommand(self: *Parser) ?MathNode {
                self.index += 1; // backslash
                if (self.index >= self.src.len) return null;
                if (self.src[self.index] == '\\') {
                    self.index += 1;
                    return .{ .kind = .span, .text = " " };
                }
                const name_start = self.index;
                while (self.index < self.src.len and std.ascii.isAlphabetic(self.src[self.index])) self.index += 1;
                const name = self.src[name_start..self.index];
                if (name.len == 0) {
                    // Escaped punctuation (`\{` etc.) — literal character.
                    const escaped = self.src[self.index .. self.index + 1];
                    self.index += 1;
                    return .{ .kind = .span, .text = escaped };
                }
                if (symbolOf(name)) |symbol| {
                    return .{ .kind = if (largeOperator(name)) .op else .span, .text = symbol };
                }
                if (functionOf(name)) |function| return .{ .kind = .func, .text = function };
                if (spacingOf(name)) return .{ .kind = .span, .text = " " };
                if (isDelimiterCommand(name)) {
                    if (self.index < self.src.len) {
                        if (self.src[self.index] == '\\' and self.index + 1 < self.src.len) {
                            self.index += 1;
                        }
                        const delim = self.src[self.index .. self.index + 1];
                        self.index += 1;
                        return .{ .kind = .span, .text = delim };
                    }
                    return null;
                }
                if (std.mem.eql(u8, name, "frac")) {
                    const numerator = self.parseGroup() orelse return .{ .kind = .span, .text = name };
                    const denominator = self.parseGroup() orelse return .{ .kind = .span, .text = name };
                    // Children must live in the arena, never on this
                    // stack frame (ReleaseFast reuses the frame after
                    // return).
                    const parts = self.allocChildren(2);
                    parts[0] = numerator;
                    parts[1] = denominator;
                    return .{ .kind = .frac, .children = parts };
                }
                if (std.mem.eql(u8, name, "sqrt")) {
                    var root: []const u8 = "";
                    if (self.index < self.src.len and self.src[self.index] == '[') {
                        const close = std.mem.indexOfScalarPos(u8, self.src, self.index, ']') orelse self.src.len;
                        root = std.mem.trim(u8, self.src[self.index + 1 .. close], " \t");
                        self.index = @min(close + 1, self.src.len);
                    }
                    const content = self.parseGroup() orelse return .{ .kind = .span, .text = name };
                    const parts = self.allocChildren(1);
                    parts[0] = content;
                    return .{ .kind = .sqrt, .children = parts, .root = root };
                }
                if (std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "textrm") or
                    std.mem.eql(u8, name, "mathrm") or std.mem.eql(u8, name, "mathbf") or
                    std.mem.eql(u8, name, "mathit") or std.mem.eql(u8, name, "operatorname"))
                {
                    const content = self.parseGroup() orelse return .{ .kind = .span, .text = name };
                    const parts = self.allocChildren(1);
                    parts[0] = content;
                    return .{ .kind = .text, .children = parts };
                }
                if (std.mem.eql(u8, name, "begin")) return self.parseEnvironment();
                // Unknown command: keep its name.
                return .{ .kind = .span, .text = name };
            }

            fn parseGroup(self: *Parser) ?MathNode {
                if (self.index >= self.src.len or self.src[self.index] != '{') return null;
                self.index += 1;
                self.depth += 1;
                defer self.depth -= 1;
                return self.parseSequence(true);
            }

            /// `\begin{name} ... \end{name}`: matrix/array-ish environments.
            /// Rows split on `\\` and `&` at brace depth zero; `aligned` and
            /// friends get no frame, `matrix` variants get a bordered panel.
            fn parseEnvironment(self: *Parser) ?MathNode {
                const name = self.parseEnvironmentName() orelse return .{ .kind = .span, .text = "begin" };
                const close_marker = self.ui.fmt("\\end{{{s}}}", .{name});
                const end = std.mem.indexOfPos(u8, self.src, self.index, close_marker) orelse self.src.len;
                const body = self.src[self.index..end];
                self.index = @min(end + close_marker.len, self.src.len);

                const rows = splitTopLevel(max_math_rows, body, "\\\\");
                if (rows.len == 0) return .{ .kind = .row };

                var cells = self.allocChildren(rows.len * max_math_cells_per_row);
                var cells_len: usize = 0;
                var cols: usize = 0;
                for (rows) |row_text| {
                    const row_cells = splitTopLevel(max_math_cells_per_row, row_text, "&");
                    // Drop trailing empty cells (`a &= b` rows end with `&`).
                    var row_count = row_cells.len;
                    while (row_count > 0 and std.mem.trim(u8, row_cells[row_count - 1], " \t").len == 0) row_count -= 1;
                    for (row_cells[0..row_count]) |cell_text| {
                        if (cells_len >= cells.len) break;
                        cells[cells_len] = self.parseCell(cell_text);
                        cells_len += 1;
                    }
                    cols = @max(cols, row_count);
                }
                const bordered = !(std.mem.eql(u8, name, "aligned") or std.mem.eql(u8, name, "align") or
                    std.mem.eql(u8, name, "align*") or std.mem.eql(u8, name, "alignedat") or
                    std.mem.eql(u8, name, "gathered") or std.mem.eql(u8, name, "split") or
                    std.mem.eql(u8, name, "cases"));
                return .{
                    .kind = .matrix,
                    .children = cells[0..cells_len],
                    .rows = rows.len,
                    .cols = cols,
                    .bordered = bordered,
                };
            }

            /// Parse one matrix cell: a fresh sequence over the cell text.
            fn parseCell(self: *Parser, cell_text: []const u8) MathNode {
                const saved_src = self.src;
                const saved_index = self.index;
                const saved_depth = self.depth;
                self.src = cell_text;
                self.index = 0;
                self.depth = 0;
                const cell = self.parseSequence(false);
                self.src = saved_src;
                self.index = saved_index;
                self.depth = saved_depth;
                return cell;
            }

            fn parseEnvironmentName(self: *Parser) ?[]const u8 {
                if (self.index >= self.src.len or self.src[self.index] != '{') return null;
                const close = std.mem.indexOfScalarPos(u8, self.src, self.index, '}') orelse self.src.len;
                const name = self.src[self.index + 1 .. close];
                self.index = @min(close + 1, self.src.len);
                return name;
            }

            /// Script attachment: `^`/`_` groups directly after an atom.
            fn attachScripts(self: *Parser, atom: MathNode) MathNode {
                var sup: ?*const MathNode = null;
                var sub: ?*const MathNode = null;
                while (self.index < self.src.len) {
                    if (self.src[self.index] != '^' and self.src[self.index] != '_') break;
                    const is_sup = self.src[self.index] == '^';
                    self.index += 1;
                    const group = self.parseGroupOrChar() orelse break;
                    if (is_sup and sup == null) {
                        sup = self.child(group);
                    } else if (!is_sup and sub == null) {
                        sub = self.child(group);
                    }
                }
                if (sup == null and sub == null) return atom;
                const parts = self.allocChildren(1);
                parts[0] = atom;
                return .{
                    .kind = .script,
                    .children = parts,
                    .sup = sup,
                    .sub = sub,
                };
            }

            fn parseGroupOrChar(self: *Parser) ?MathNode {
                if (self.index >= self.src.len) return null;
                if (self.src[self.index] == '{') return self.parseGroup();
                if (self.src[self.index] == '\\') return self.parseCommand();
                const single = self.src[self.index .. self.index + 1];
                self.index += 1;
                return .{ .kind = .span, .text = single };
            }
        };

        /// Split `text` on `separator` at brace depth zero, into up to
        /// `max_parts` parts (slices into `text`).
        fn splitTopLevel(comptime max_parts: usize, text: []const u8, separator: []const u8) [][]const u8 {
            var parts_buf: [max_parts][]const u8 = undefined;
            var count: usize = 0;
            var start: usize = 0;
            var depth: usize = 0;
            var index: usize = 0;
            while (index + separator.len <= text.len) : (index += 1) {
                const byte = text[index];
                if (byte == '{') {
                    depth += 1;
                    continue;
                }
                if (byte == '}') {
                    depth = @max(0, depth - 1);
                    continue;
                }
                if (depth == 0 and std.mem.startsWith(u8, text[index..], separator)) {
                    if (count + 1 < max_parts) {
                        parts_buf[count] = text[start..index];
                        count += 1;
                        start = index + separator.len;
                    }
                    index += separator.len - 1;
                }
            }
            if (count + 1 <= max_parts) {
                parts_buf[count] = text[start..];
                count += 1;
            }
            return parts_buf[0..count];
        }

        const large_operator_entries = .{
            .{ "bigcap", {} },
            .{ "bigcup", {} },
            .{ "bigoplus", {} },
            .{ "bigotimes", {} },
            .{ "biguplus", {} },
            .{ "bigvee", {} },
            .{ "bigwedge", {} },
            .{ "coprod", {} },
            .{ "iiint", {} },
            .{ "iint", {} },
            .{ "int", {} },
            .{ "oint", {} },
            .{ "prod", {} },
            .{ "sum", {} },
        };
        const large_operator_map = std.StaticStringMap(void).initComptime(large_operator_entries);

        fn largeOperator(name: []const u8) bool {
            return large_operator_map.has(name);
        }

        // ----------------------------------------------------------- emit

        const Span = canvas.text_spans.TextSpan;

        const Emitter = struct {
            ui: *Ui,

            fn monoSpan(text: []const u8, scale: f32) Span {
                return .{ .text = text, .monospace = true, .scale = scale };
            }

            fn emitText(self: *Emitter, text: []const u8, scale: f32) Node {
                return self.ui.paragraph(.{}, &.{monoSpan(text, scale)});
            }

            fn emit(self: *Emitter, node: *const MathNode) Node {
                switch (node.kind) {
                    .text => return if (node.children.len > 0) self.emit(&node.children[0]) else emitText(self, node.text, 1),
                    .span, .func, .op => return emitText(self, node.text, if (node.kind == .op) 1.1 else 1),
                    .row => return self.emitRow(node),
                    .frac => return self.emitFrac(node),
                    .sqrt => return self.emitSqrt(node),
                    .script => return self.emitScript(node),
                    .matrix => return self.emitMatrix(node),
                }
            }

            fn emitRow(self: *Emitter, node: *const MathNode) Node {
                if (node.children.len == 0) return self.ui.spacer(0);
                if (node.children.len == 1) return self.emit(&node.children[0]);
                var out = self.ui.arena.alloc(Node, node.children.len) catch {
                    self.ui.failed = true;
                    return self.ui.spacer(0);
                };
                for (node.children, 0..) |*child, index| out[index] = self.emit(child);
                return self.ui.row(.{ .gap = 4, .cross = .center }, out);
            }

            /// Stacked numerator/denominator over a hairline rule. The
            /// fraction column stretches, so the rule spans the wider side.
            fn emitFrac(self: *Emitter, node: *const MathNode) Node {
                const numerator = if (node.children.len > 0) self.emit(&node.children[0]) else self.ui.spacer(0);
                const denominator = if (node.children.len > 1) self.emit(&node.children[1]) else self.ui.spacer(0);
                return self.ui.column(.{ .gap = 2, .cross = .stretch }, .{
                    self.ui.row(.{ .main = .center, .cross = .center }, .{numerator}),
                    self.ui.el(.panel, .{ .height = 1, .style_tokens = .{ .background = .text_muted } }, .{}),
                    self.ui.row(.{ .main = .center, .cross = .center }, .{denominator}),
                });
            }

            fn emitSqrt(self: *Emitter, node: *const MathNode) Node {
                const content = if (node.children.len > 0) self.emit(&node.children[0]) else self.ui.spacer(0);
                // The overline rule spans the content: the inner column
                // stretches, and the rule is its first child.
                const overline = self.ui.column(.{ .gap = 1, .cross = .stretch }, .{
                    self.ui.el(.panel, .{ .height = 1, .style_tokens = .{ .background = .text_muted } }, .{}),
                    self.ui.row(.{ .main = .center, .cross = .center }, .{content}),
                });
                if (node.root.len == 0 or (node.root.len == 1 and node.root[0] == '2')) {
                    return self.ui.row(.{ .gap = 2, .cross = .center }, .{
                        emitText(self, "√", 1.15),
                        overline,
                    });
                }
                if (node.root.len == 1 and node.root[0] == '3') {
                    return self.ui.row(.{ .gap = 2, .cross = .center }, .{
                        emitText(self, "∛", 1.15),
                        overline,
                    });
                }
                return self.ui.row(.{ .gap = 2, .cross = .center }, .{
                    self.emitScriptRun(node.root, 1),
                    emitText(self, "√", 1.15),
                    overline,
                });
            }

            /// A script run (the `^`/`_` content): simple runs render as a
            /// scaled paragraph; anything complex renders unscaled rather than
            /// misaligned.
            fn emitScriptRun(self: *Emitter, text: []const u8, scale: f32) Node {
                return emitText(self, text, scale * 0.72);
            }

            /// Base with superscript/subscript. A single script renders as a
            /// trailing small run (top-aligned = superscript, bottom-aligned
            /// = subscript); both stack in a side column. A large operator
            /// (`\sum`) instead takes display limits above and below.
            fn emitScript(self: *Emitter, node: *const MathNode) Node {
                const base = if (node.children.len > 0) self.emit(&node.children[0]) else self.ui.spacer(0);
                if (node.children.len > 0 and node.children[0].kind == .op) {
                    var children: [3]Node = undefined;
                    var count: usize = 0;
                    if (node.sup) |sup| {
                        children[count] = self.emitSubtree(sup);
                        count += 1;
                    }
                    children[count] = emitText(self, node.children[0].text, 1.1);
                    count += 1;
                    if (node.sub) |sub| {
                        children[count] = self.emitSubtree(sub);
                        count += 1;
                    }
                    if (count == 1) return children[0];
                    return self.ui.column(.{ .gap = 1, .cross = .center }, children[0..count]);
                }
                if (node.sup != null and node.sub != null) {
                    var scripts: [2]Node = undefined;
                    var count: usize = 0;
                    if (node.sup) |sup| {
                        scripts[count] = self.emitSubtree(sup);
                        count += 1;
                    }
                    if (node.sub) |sub| {
                        scripts[count] = self.emitSubtree(sub);
                        count += 1;
                    }
                    return self.ui.row(.{ .gap = 2, .cross = .center }, .{
                        base,
                        self.ui.column(.{ .gap = 1, .cross = .start }, scripts[0..count]),
                    });
                }
                const cross: canvas.WidgetCrossAlignment = if (node.sup != null) .start else .end;
                const script_node = if (node.sup) |sup| sup else node.sub.?;
                return self.ui.row(.{ .gap = 2, .cross = cross }, .{
                    base,
                    self.emitSubtree(script_node),
                });
            }

            /// Emit a script subtree at reduced size when it is a simple
            /// span; anything complex renders at full size.
            fn emitSubtree(self: *Emitter, node: *const MathNode) Node {
                if (node.kind == .span or node.kind == .func or node.kind == .text) {
                    return emitText(self, node.text, 0.72);
                }
                return self.emit(node);
            }

            fn emitMatrix(self: *Emitter, node: *const MathNode) Node {
                var row_nodes = self.ui.arena.alloc(Node, node.rows) catch {
                    self.ui.failed = true;
                    return self.ui.spacer(0);
                };
                var cell_index: usize = 0;
                for (0..node.rows) |row_index| {
                    const cols = @min(node.cols, node.children.len - cell_index);
                    var cells = self.ui.arena.alloc(Node, @max(cols, 1)) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                    if (cols == 0) {
                        cells[0] = self.ui.spacer(0);
                    } else {
                        for (0..cols) |col_index| {
                            cells[col_index] = self.emit(&node.children[cell_index + col_index]);
                        }
                    }
                    cell_index += cols;
                    row_nodes[row_index] = self.ui.row(.{ .gap = 12, .cross = .center }, cells);
                }
                const grid = self.ui.column(.{ .gap = 4, .cross = .center }, row_nodes);
                if (!node.bordered) return grid;
                return self.ui.el(.panel, .{ .padding = 8, .style_tokens = .{ .border_color = .border } }, .{grid});
            }
        };

        /// Parse `source` into a node tree and emit it, centered in the
        /// preview column (the display-math convention). Never fails: garbage
        /// degrades to literal spans.
        pub fn displayBlock(ui: *Ui, source: []const u8) Node {
            var parser = Parser{ .ui = ui, .src = source };
            const root = parser.parseSequence(false);
            if (parser.failed) return ui.spacer(0);
            var emitter = Emitter{ .ui = ui };
            return ui.row(.{ .grow = 1, .main = .center }, .{emitter.emit(&root)});
        }
    };
}
