//! MDitor's Mermaid diagram subset renderer.
//!
//! Renders three diagram types as composed widgets (no SVG, no browser —
//! the app's native widget engine draws everything):
//! - `flowchart`/`graph` (TD/TB/LR/RL/BT): nodes with the common shapes
//!   (`[]` rect, `()` rounded, `([ ])` stadium, `[[ ]]` subroutine,
//!   `{}` decision, `(())` circle), labeled edges (`-->`, `---`, `-.->`,
//!   `==>`, `<-->`, `o--o`, `-- label -->`, `-->|label|`, `&` fan-out,
//!   chains), and `subgraph` groups. Layers derive from edge depth and
//!   render as centered rows; each layer boundary carries the crossing
//!   edges as arrow rows (long-hop edges name their endpoints).
//! - `sequenceDiagram`: participants (explicit or discovered), messages
//!   with solid/dashed/cross/open arrows, `Note` rows, and
//!   `loop`/`alt`/`opt`/`par`/`rect` blocks (indented).
//! - `pie`: a proportional stacked bar plus a color-coded legend.
//!
//! Everything else degrades gracefully: unknown diagram types and
//! unparseable sources render as the ordinary fenced-code panel (plus a
//! muted note) — never a failure. Arrow glyphs stay inside the bundled
//! math-mono face's coverage (the same face renders code fences).

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const max_mermaid_nodes: usize = 48;
pub const max_mermaid_edges: usize = 96;
pub const max_mermaid_layers: usize = 12;
pub const max_mermaid_subgraphs: usize = 8;
pub const max_mermaid_participants: usize = 8;
pub const max_mermaid_messages: usize = 64;
pub const max_mermaid_slices: usize = 16;
/// Diagram sources cap at this many lines (a 24 KiB document, worst
/// case); longer fences truncate deterministically.
pub const max_mermaid_lines: usize = 128;

const KnownType = enum { flowchart, sequence, pie };

fn typeOf(first: []const u8) ?KnownType {
    const trimmed = std.mem.trim(u8, first, " \t");
    if (std.ascii.startsWithIgnoreCase(trimmed, "flowchart") or std.ascii.startsWithIgnoreCase(trimmed, "graph")) return .flowchart;
    if (std.ascii.startsWithIgnoreCase(trimmed, "sequenceDiagram")) return .sequence;
    if (std.mem.eql(u8, trimmed, "pie") or std.ascii.startsWithIgnoreCase(trimmed, "pie ")) return .pie;
    return null;
}

pub fn Mermaid(comptime Msg: type) type {
    return struct {
        const Ui = canvas.Ui(Msg);
        const Node = Ui.Node;

        const Span = canvas.text_spans.TextSpan;

        const FlowShape = enum { rect, rounded, stadium, subroutine, decision, circle };

        const FlowNode = struct {
            id: []const u8 = "",
            label: []const u8 = "",
            shape: FlowShape = .rect,
            layer: usize = 0,
            /// 1-based subgraph id; 0 = no subgraph.
            subgraph: usize = 0,
        };

        const FlowArrow = enum { solid, dashed, thick, plain, double, circle };

        const FlowEdge = struct {
            from: usize = 0,
            to: usize = 0,
            label: []const u8 = "",
            arrow: FlowArrow = .solid,
        };

        const Flowchart = struct {
            nodes: [max_mermaid_nodes]FlowNode = undefined,
            node_count: usize = 0,
            edges: [max_mermaid_edges]FlowEdge = undefined,
            edge_count: usize = 0,
            subgraph_titles: [max_mermaid_subgraphs][]const u8 = [_][]const u8{""} ** max_mermaid_subgraphs,
            subgraph_count: usize = 0,
            horizontal: bool = false,
            reverse: bool = false,
            failed: bool = false,

            fn nodeIndex(self: *Flowchart, id: []const u8) ?usize {
                for (self.nodes[0..self.node_count], 0..) |entry, index| {
                    if (std.mem.eql(u8, entry.id, id)) return index;
                }
                return null;
            }

            /// Node by id, creating it (with the id as its label) when new.
            fn node(self: *Flowchart, id: []const u8) ?usize {
                if (self.nodeIndex(id)) |index| return index;
                if (self.node_count >= max_mermaid_nodes) return null;
                const index = self.node_count;
                self.nodes[index] = .{ .id = id, .label = id };
                self.node_count += 1;
                return index;
            }

            fn addEdge(self: *Flowchart, from_id: []const u8, to_id: []const u8, label: []const u8, arrow: FlowArrow) void {
                const from = self.node(from_id) orelse return;
                const to = self.node(to_id) orelse return;
                if (self.edge_count >= max_mermaid_edges) {
                    self.failed = true;
                    return;
                }
                self.edges[self.edge_count] = .{ .from = from, .to = to, .label = label, .arrow = arrow };
                self.edge_count += 1;
            }

            /// Longest-path layering from the roots (fixpoint over edges);
            /// layers cap at `max_mermaid_layers`.
            fn layer(self: *Flowchart) void {
                var changed = true;
                var passes: usize = 0;
                while (changed and passes < max_mermaid_layers + 1) : (passes += 1) {
                    changed = false;
                    for (self.edges[0..self.edge_count]) |edge| {
                        const candidate = self.nodes[edge.from].layer + 1;
                        if (candidate > self.nodes[edge.to].layer) {
                            self.nodes[edge.to].layer = candidate;
                            changed = true;
                        }
                    }
                }
                for (self.nodes[0..self.node_count]) |*entry| {
                    if (entry.layer >= max_mermaid_layers) entry.layer = max_mermaid_layers - 1;
                }
            }
        };

        const Parser = struct {
            lines: []const []const u8,
            index: usize = 0,

            fn peek(self: *Parser) ?[]const u8 {
                while (self.index < self.lines.len) {
                    const trimmed = std.mem.trim(u8, self.lines[self.index], " \t");
                    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "%%")) {
                        self.index += 1;
                        continue;
                    }
                    return trimmed;
                }
                return null;
            }

            fn next(self: *Parser) ?[]const u8 {
                const line = self.peek() orelse return null;
                self.index += 1;
                return line;
            }
        };

        // --------------------------------------------------- flowchart

        fn parseFlowchart(lines: []const []const u8) ?Flowchart {
            var chart = Flowchart{};
            var parser = Parser{ .lines = lines };

            const header = parser.next() orelse return null;
            const direction = std.mem.lastIndexOfScalar(u8, header, ' ') orelse header.len;
            const dir = std.mem.trim(u8, header[direction..], " \t");
            if (std.ascii.eqlIgnoreCase(dir, "LR") or std.ascii.eqlIgnoreCase(dir, "RL")) {
                chart.horizontal = true;
                chart.reverse = std.ascii.eqlIgnoreCase(dir, "RL");
            }
            if (std.ascii.eqlIgnoreCase(dir, "BT")) chart.reverse = true;

            while (parser.peek()) |line| {
                _ = parser.next();
                if (std.mem.startsWith(u8, line, "subgraph")) {
                    parseSubgraph(&chart, &parser, line);
                    continue;
                }
                if (std.mem.eql(u8, line, "end")) continue;
                if (std.mem.startsWith(u8, line, "style ") or std.mem.startsWith(u8, line, "classDef") or
                    std.mem.startsWith(u8, line, "class ") or std.mem.startsWith(u8, line, "linkStyle") or
                    std.mem.startsWith(u8, line, "direction")) continue;
                parseFlowStatement(&chart, line, 0);
            }
            if (chart.node_count == 0 and chart.edge_count == 0) return null;
            chart.layer();
            return chart;
        }

        /// `subgraph id [Title]` ... `end` (one nesting level: statements
        /// inside a nested subgraph join the outer group).
        fn parseSubgraph(chart: *Flowchart, parser: *Parser, header: []const u8) void {
            if (chart.subgraph_count >= max_mermaid_subgraphs) {
                chart.failed = true;
                return;
            }
            var rest = std.mem.trim(u8, header["subgraph".len..], " \t");
            if (std.mem.indexOfScalar(u8, rest, ' ')) |space| {
                rest = std.mem.trim(u8, rest[space..], " \t");
            }
            var title = rest;
            if (title.len >= 2 and title[0] == '[' and title[title.len - 1] == ']') {
                title = std.mem.trim(u8, title[1 .. title.len - 1], " \t");
            }
            const subgraph = chart.subgraph_count + 1; // 1-based: 0 = none
            chart.subgraph_titles[chart.subgraph_count] = title;
            chart.subgraph_count += 1;

            while (parser.peek()) |inner| {
                if (std.mem.eql(u8, inner, "end")) {
                    _ = parser.next();
                    return;
                }
                _ = parser.next();
                if (std.mem.startsWith(u8, inner, "subgraph")) {
                    parseSubgraph(chart, parser, inner);
                    continue;
                }
                if (std.mem.startsWith(u8, inner, "style ") or std.mem.startsWith(u8, inner, "classDef") or
                    std.mem.startsWith(u8, inner, "class ") or std.mem.startsWith(u8, inner, "linkStyle") or
                    std.mem.startsWith(u8, inner, "direction")) continue;
                parseFlowStatement(chart, inner, subgraph);
            }
        }

        /// One flowchart statement: a node definition and/or edges. Edge
        /// lists split on `&` and chain on repeated edge operators.
        fn parseFlowStatement(chart: *Flowchart, line: []const u8, subgraph: usize) void {
            var rest = line;
            var from_id: []const u8 = "";
            var have_from = false;

            while (rest.len > 0) {
                const node = parseFlowNode(rest);
                if (node.id.len == 0) return;
                if (chart.node(node.id)) |index| {
                    if (node.label.len > 0) chart.nodes[index].label = node.label;
                    chart.nodes[index].shape = node.shape;
                    if (subgraph != 0) chart.nodes[index].subgraph = subgraph;
                    // A lone node statement (`A` or `A[text]`) has no edges.
                    if (std.mem.trim(u8, node.rest, " \t").len == 0) return;
                }
                if (!have_from) {
                    from_id = node.id;
                    have_from = true;
                }
                rest = node.rest;

                // Edge operator(s) from the current node.
                var source = from_id;
                var continue_chain = true;
                while (continue_chain) {
                    const edge = parseFlowEdge(rest) orelse {
                        continue_chain = false;
                        break;
                    };
                    rest = edge.rest;
                    const target = parseFlowNode(rest);
                    if (target.id.len == 0) {
                        continue_chain = false;
                        break;
                    }
                    if (chart.node(target.id)) |index| {
                        if (target.label.len > 0) chart.nodes[index].label = target.label;
                        chart.nodes[index].shape = target.shape;
                        if (subgraph != 0) chart.nodes[index].subgraph = subgraph;
                    }
                    chart.addEdge(source, target.id, edge.label, edge.arrow);
                    source = target.id;
                    rest = target.rest;
                    const trimmed = std.mem.trim(u8, rest, " \t");
                    if (trimmed.len > 0 and trimmed[0] == '&') {
                        // Fan-out: the edge list continues from the ORIGINAL
                        // source.
                        rest = std.mem.trim(u8, trimmed[1..], " \t");
                        source = from_id;
                        continue;
                    }
                    continue_chain = parseFlowEdge(rest) != null;
                }
            }
        }

        const FlowNodeParse = struct {
            id: []const u8 = "",
            label: []const u8 = "",
            shape: FlowShape = .rect,
            rest: []const u8 = "",
        };

        /// `id`, `id[...]`, `id(...)`, `id([...])`, `id[[...]]`, `id{...}`,
        /// `id(("..."))`. The id is [a-zA-Z0-9_]; the label may be quoted.
        fn parseFlowNode(text: []const u8) FlowNodeParse {
            var index: usize = 0;
            while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '_')) index += 1;
            if (index == 0) return .{};
            const id = text[0..index];
            const shapes = [_]struct { open: []const u8, close: []const u8, shape: FlowShape }{
                .{ .open = "[[", .close = "]]", .shape = .subroutine },
                .{ .open = "((", .close = "))", .shape = .circle },
                .{ .open = "([", .close = "])", .shape = .stadium },
                .{ .open = "{", .close = "}", .shape = .decision },
                .{ .open = "[", .close = "]", .shape = .rect },
                .{ .open = "(", .close = ")", .shape = .rounded },
            };
            for (shapes) |shape| {
                if (std.mem.startsWith(u8, text[index..], shape.open)) {
                    const close = std.mem.indexOfPos(u8, text, index + shape.open.len, shape.close) orelse text.len;
                    const label = unquote(std.mem.trim(u8, text[index + shape.open.len .. close], " \t"));
                    const end = @min(close + shape.close.len, text.len);
                    return .{ .id = id, .label = label, .shape = shape.shape, .rest = text[end..] };
                }
            }
            return .{ .id = id, .rest = text[index..] };
        }

        const FlowEdgeParse = struct {
            label: []const u8 = "",
            arrow: FlowArrow = .solid,
            rest: []const u8 = "",
        };

        const EdgeForm = struct {
            opener: []const u8,
            closer: []const u8,
            arrow: FlowArrow,
        };

        const direct_forms = [_]EdgeForm{
            .{ .opener = "<-->", .closer = "<-->", .arrow = .double },
            .{ .opener = "o--o", .closer = "o--o", .arrow = .circle },
            .{ .opener = "-.->", .closer = "-.->", .arrow = .dashed },
            .{ .opener = "==>", .closer = "==>", .arrow = .thick },
            .{ .opener = "-->", .closer = "-->", .arrow = .solid },
            .{ .opener = "---", .closer = "---", .arrow = .plain },
            .{ .opener = "--o", .closer = "--o", .arrow = .circle },
            .{ .opener = "o--", .closer = "o--", .arrow = .circle },
        };

        /// `-->`, `---`, `-.->`, `==>`, `<-->`, `o--o`, `--o`, `o--`,
        /// `-->|label|`, `-- label -->`, `-. label .->`, `== label ==>`,
        /// `-- label --` (plain). Returns the parsed edge and the rest.
        fn parseFlowEdge(text: []const u8) ?FlowEdgeParse {
            const t = std.mem.trim(u8, text, " \t");
            if (t.len == 0) return null;

            // Inline label: `-->|label|`.
            if (t.len > 4 and std.mem.startsWith(u8, t, "-->|")) {
                const close = std.mem.indexOfScalarPos(u8, t, 4, '|') orelse return null;
                return .{
                    .label = t[4..close],
                    .arrow = .solid,
                    .rest = std.mem.trim(u8, t[close + 1 ..], " \t"),
                };
            }

            for (direct_forms) |form| {
                if (std.mem.startsWith(u8, t, form.opener)) {
                    return .{ .arrow = form.arrow, .rest = std.mem.trim(u8, t[form.opener.len..], " \t") };
                }
            }

            // `-- label -->` / `-. label .->` / `== label ==>`, and the
            // plain `-- label --` tails.
            const openers = [_]EdgeForm{
                .{ .opener = "-.", .closer = "-.->", .arrow = .dashed },
                .{ .opener = "==", .closer = "==>", .arrow = .thick },
                .{ .opener = "--", .closer = "-->", .arrow = .solid },
            };
            for (openers) |form| {
                if (!std.mem.startsWith(u8, t, form.opener)) continue;
                var scan = form.opener.len;
                while (scan < t.len) : (scan += 1) {
                    if (std.mem.startsWith(u8, t[scan..], form.closer)) {
                        const label = std.mem.trim(u8, t[form.opener.len..scan], " \t");
                        return .{ .label = label, .arrow = form.arrow, .rest = std.mem.trim(u8, t[scan + form.closer.len ..], " \t") };
                    }
                    if (std.mem.startsWith(u8, t[scan..], form.opener)) {
                        // A bare opener closes a labeled plain edge
                        // (`-- text --`). `==` never does (no plain `==`).
                        if (form.arrow == .thick) continue;
                        const label = std.mem.trim(u8, t[form.opener.len..scan], " \t");
                        return .{ .label = label, .arrow = .plain, .rest = std.mem.trim(u8, t[scan + form.opener.len ..], " \t") };
                    }
                }
                // Opener with no closer: the remainder is the target
                // (`A -- B` plain edge), not a label.
                return .{ .arrow = form.arrow, .rest = std.mem.trim(u8, t[form.opener.len..], " \t") };
            }
            return null;
        }

        fn unquote(text: []const u8) []const u8 {
            if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                return text[1 .. text.len - 1];
            }
            return text;
        }

        // --------------------------------------------------- render

        const Renderer = struct {
            ui: *Ui,

            const MessageArrow = enum { solid, dashed, cross, open };

            fn mono(text: []const u8, scale: f32, weight: canvas.TextSpanWeight) Span {
                return .{ .text = text, .monospace = true, .scale = scale, .weight = weight };
            }

            fn nodePanel(self: *Renderer, label: []const u8, shape: FlowShape) Node {
                const style: canvas.StyleTokenRefs = switch (shape) {
                    .decision => .{ .background = .surface, .border_color = .accent },
                    else => .{ .background = .surface, .border_color = .border },
                };
                return self.ui.el(.panel, .{ .padding = 10, .style_tokens = style }, .{
                    self.ui.paragraph(.{}, &.{mono(label, 1, .regular)}),
                });
            }

            fn arrowGlyph(arrow: FlowArrow, horizontal: bool) []const u8 {
                return switch (arrow) {
                    .plain => if (horizontal) "—" else "|",
                    .dashed => if (horizontal) "▷" else "▽",
                    .thick => if (horizontal) "▶" else "▼",
                    .double => if (horizontal) "⇄" else "⇅",
                    .circle => if (horizontal) "▶" else "▼",
                    .solid => if (horizontal) "▶" else "▼",
                };
            }

            fn flowLayerRow(self: *Renderer, chart: *const Flowchart, layer: usize) Node {
                // Nodes of this layer, in discovery order, grouped by
                // subgraph membership.
                var plain = std.ArrayListUnmanaged(Node).empty;
                defer plain.deinit(self.ui.arena);
                var groups: [max_mermaid_subgraphs]std.ArrayListUnmanaged(Node) = undefined;
                for (&groups) |*group| group.* = .empty;
                var used_groups: [max_mermaid_subgraphs]bool = [_]bool{false} ** max_mermaid_subgraphs;

                for (chart.nodes[0..chart.node_count]) |*node| {
                    if (node.layer != layer) continue;
                    if (node.subgraph != 0) {
                        const sub = node.subgraph - 1;
                        if (sub < max_mermaid_subgraphs) {
                            groups[sub].append(self.ui.arena, self.nodePanel(node.label, node.shape)) catch {
                                self.ui.failed = true;
                                return self.ui.spacer(0);
                            };
                            used_groups[sub] = true;
                            continue;
                        }
                    }
                    plain.append(self.ui.arena, self.nodePanel(node.label, node.shape)) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }

                var parts = std.ArrayListUnmanaged(Node).empty;
                defer parts.deinit(self.ui.arena);
                if (plain.items.len > 0) {
                    parts.append(self.ui.arena, self.ui.row(.{ .gap = 16, .main = .center }, plain.items)) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }
                for (0..max_mermaid_subgraphs) |sub| {
                    if (!used_groups[sub]) continue;
                    const title = if (chart.subgraph_titles[sub].len > 0) chart.subgraph_titles[sub] else "subgraph";
                    const header = self.ui.paragraph(.{}, &.{mono(title, 0.9, .medium)});
                    const body = self.ui.row(.{ .gap = 16, .main = .center }, groups[sub].items);
                    parts.append(self.ui.arena, self.ui.el(.panel, .{ .padding = 10, .style_tokens = .{ .border_color = .border } }, .{
                        self.ui.column(.{ .gap = 8 }, .{ header, body }),
                    })) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }
                if (parts.items.len == 0) return self.ui.spacer(0);
                return self.ui.row(.{ .gap = 16, .main = .center }, parts.items);
            }

            fn flowEdgeRow(self: *Renderer, chart: *const Flowchart, edge: *const FlowEdge) Node {
                const from = &chart.nodes[edge.from];
                const to = &chart.nodes[edge.to];
                const glyph = arrowGlyph(edge.arrow, chart.horizontal);
                const adjacent = to.layer == from.layer + 1;
                if (adjacent and edge.label.len == 0) {
                    // Position implies the endpoints: a bare arrow, centered.
                    return self.ui.paragraph(.{ .grow = 1, .text_alignment = .center }, &.{mono(glyph, 0.85, .regular)});
                }
                // Long hops and labeled edges name their endpoints; the
                // label rides its own centered line underneath so long
                // labels never widen the endpoint row past the preview.
                var parts = std.ArrayListUnmanaged(Node).empty;
                defer parts.deinit(self.ui.arena);
                parts.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(from.label, 1, .regular)})) catch return self.ui.spacer(0);
                parts.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(glyph, 0.85, .regular)})) catch return self.ui.spacer(0);
                parts.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(to.label, 1, .regular)})) catch return self.ui.spacer(0);
                const endpoint_row = self.ui.row(.{ .gap = 6, .main = .center, .cross = .center }, parts.items);
                if (edge.label.len == 0) return endpoint_row;
                const label = self.ui.fmt("({s})", .{edge.label});
                return self.ui.column(.{ .gap = 2, .main = .center }, .{
                    endpoint_row,
                    self.ui.paragraph(.{ .grow = 1, .text_alignment = .center }, &.{mono(label, 0.9, .regular)}),
                });
            }

            fn flowEdgeRowsBetween(self: *Renderer, chart: *const Flowchart, layer: usize) Node {
                var rows = std.ArrayListUnmanaged(Node).empty;
                defer rows.deinit(self.ui.arena);
                for (chart.edges[0..chart.edge_count]) |*edge| {
                    if (chart.nodes[edge.from].layer != layer) continue;
                    if (chart.nodes[edge.to].layer <= layer) continue;
                    rows.append(self.ui.arena, self.flowEdgeRow(chart, edge)) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }
                if (rows.items.len == 0) return self.ui.spacer(0);
                return self.ui.column(.{ .gap = 3, .main = .center }, rows.items);
            }

            fn renderFlowchart(self: *Renderer, chart: *const Flowchart) Node {
                var blocks = std.ArrayListUnmanaged(Node).empty;
                defer blocks.deinit(self.ui.arena);
                for (0..max_mermaid_layers) |layer| {
                    var has = false;
                    for (chart.nodes[0..chart.node_count]) |node| {
                        if (node.layer == layer) {
                            has = true;
                            break;
                        }
                    }
                    if (!has) continue;
                    blocks.append(self.ui.arena, self.flowLayerRow(chart, layer)) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                    blocks.append(self.ui.arena, self.flowEdgeRowsBetween(chart, layer)) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }
                return self.ui.column(.{ .gap = 8, .main = .center }, blocks.items);
            }

            // ------------------------------------------------- sequence

            const Participant = struct {
                id: []const u8 = "",
                name: []const u8 = "",
            };

            const Message = struct {
                from: usize = 0,
                to: usize = 0,
                text: []const u8 = "",
                arrow: MessageArrow = .solid,
                depth: usize = 0,
                is_note: bool = false,
            };

            fn renderSequence(self: *Renderer, lines: []const []const u8) Node {
                var participants: [max_mermaid_participants]Participant = undefined;
                var participant_count: usize = 0;
                var messages: [max_mermaid_messages]Message = undefined;
                var message_count: usize = 0;
                var depth: usize = 0;
                var failed = false;

                const participantIndex = struct {
                    fn go(parts: []Participant, count: *usize, id: []const u8) ?usize {
                        for (parts[0..count.*], 0..) |participant, index| {
                            if (std.mem.eql(u8, participant.id, id)) return index;
                        }
                        if (count.* >= max_mermaid_participants) return null;
                        const index = count.*;
                        parts[index] = .{ .id = id, .name = id };
                        count.* += 1;
                        return index;
                    }
                }.go;

                for (lines, 0..) |raw_line, line_index| {
                    if (line_index == 0) continue; // sequenceDiagram header
                    const line = std.mem.trim(u8, raw_line, " \t");
                    if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
                    if (std.mem.startsWith(u8, line, "participant ") or std.mem.startsWith(u8, line, "actor ")) {
                        var rest = if (std.mem.startsWith(u8, line, "participant "))
                            line["participant ".len..]
                        else
                            line["actor ".len..];
                        const as_pos = std.mem.indexOf(u8, rest, " as ");
                        const id = std.mem.trim(u8, if (as_pos) |pos| rest[0..pos] else rest, " \t");
                        const name = if (as_pos) |pos| unquote(std.mem.trim(u8, rest[pos + 4 ..], " \t")) else id;
                        const index = participantIndex(&participants, &participant_count, id) orelse {
                            failed = true;
                            continue;
                        };
                        participants[index].name = name;
                        continue;
                    }
                    if (std.mem.eql(u8, line, "end")) {
                        depth = @max(0, depth - 1);
                        continue;
                    }
                    if (std.mem.startsWith(u8, line, "loop ") or std.mem.startsWith(u8, line, "alt ") or
                        std.mem.startsWith(u8, line, "opt ") or std.mem.startsWith(u8, line, "par ") or
                        std.mem.startsWith(u8, line, "rect "))
                    {
                        if (message_count >= max_mermaid_messages) {
                            failed = true;
                            continue;
                        }
                        messages[message_count] = .{ .text = line, .is_note = true, .depth = depth };
                        message_count += 1;
                        depth = @min(depth + 1, 4);
                        continue;
                    }
                    if (std.mem.startsWith(u8, line, "activate ") or std.mem.startsWith(u8, line, "deactivate ")) continue;
                    if (std.mem.startsWith(u8, line, "Note ")) {
                        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
                        const text = std.mem.trim(u8, line[@min(colon + 1, line.len)..], " \t");
                        if (message_count >= max_mermaid_messages) {
                            failed = true;
                            continue;
                        }
                        messages[message_count] = .{ .text = text, .is_note = true, .depth = depth };
                        message_count += 1;
                        continue;
                    }
                    // Message: `A->>B: text`.
                    const arrow_at = arrowAt(line) orelse continue;
                    const from_id = std.mem.trim(u8, line[0..arrow_at.start], " \t");
                    const to_part = line[arrow_at.end..];
                    const colon = std.mem.indexOfScalar(u8, to_part, ':');
                    const to_id = std.mem.trim(u8, if (colon) |pos| to_part[0..pos] else to_part, " \t");
                    const text = if (colon) |pos| std.mem.trim(u8, to_part[pos + 1 ..], " \t") else "";
                    const from = participantIndex(&participants, &participant_count, from_id) orelse {
                        failed = true;
                        continue;
                    };
                    const to = participantIndex(&participants, &participant_count, to_id) orelse {
                        failed = true;
                        continue;
                    };
                    if (message_count >= max_mermaid_messages) {
                        failed = true;
                        continue;
                    }
                    messages[message_count] = .{ .from = from, .to = to, .text = text, .arrow = arrow_at.arrow, .depth = depth };
                    message_count += 1;
                }
                if (failed or participant_count == 0) return self.codeFallback(lines, "sequenceDiagram", "couldn't parse this sequence diagram");

                var blocks = std.ArrayListUnmanaged(Node).empty;
                defer blocks.deinit(self.ui.arena);

                var header_parts = std.ArrayListUnmanaged(Node).empty;
                defer header_parts.deinit(self.ui.arena);
                for (participants[0..participant_count]) |participant| {
                    header_parts.append(self.ui.arena, self.ui.el(.panel, .{ .padding = 8, .style_tokens = .{ .border_color = .border } }, .{
                        self.ui.paragraph(.{ .main = .center }, &.{mono(participant.name, 1, .medium)}),
                    })) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }
                blocks.append(self.ui.arena, self.ui.row(.{ .gap = 24, .main = .center }, header_parts.items)) catch {
                    self.ui.failed = true;
                    return self.ui.spacer(0);
                };

                for (messages[0..message_count]) |message| {
                    var row_parts = std.ArrayListUnmanaged(Node).empty;
                    defer row_parts.deinit(self.ui.arena);
                    if (message.depth > 0) {
                        row_parts.append(self.ui.arena, self.ui.el(.stack, .{ .width = @as(f32, @floatFromInt(message.depth)) * 24 }, .{})) catch {
                            self.ui.failed = true;
                            return self.ui.spacer(0);
                        };
                    }
                    if (message.is_note) {
                        row_parts.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(message.text, 0.9, .regular)})) catch {
                            self.ui.failed = true;
                            return self.ui.spacer(0);
                        };
                    } else {
                        const glyph: []const u8 = switch (message.arrow) {
                            .solid => "▶",
                            .dashed => "▷",
                            .cross => "×",
                            .open => "⊙",
                        };
                        row_parts.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(participants[message.from].name, 0.9, .regular)})) catch {
                            self.ui.failed = true;
                            return self.ui.spacer(0);
                        };
                        row_parts.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(glyph, 0.85, .regular)})) catch {
                            self.ui.failed = true;
                            return self.ui.spacer(0);
                        };
                        row_parts.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(participants[message.to].name, 0.9, .regular)})) catch {
                            self.ui.failed = true;
                            return self.ui.spacer(0);
                        };
                        if (message.text.len > 0) {
                            const label = self.ui.fmt(": {s}", .{message.text});
                            row_parts.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(label, 1, .regular)})) catch {
                                self.ui.failed = true;
                                return self.ui.spacer(0);
                            };
                        }
                    }
                    blocks.append(self.ui.arena, self.ui.row(.{ .gap = 8, .main = .center, .cross = .center }, row_parts.items)) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }
                return self.ui.column(.{ .gap = 8 }, blocks.items);
            }

            const ArrowAt = struct {
                start: usize,
                end: usize,
                arrow: MessageArrow,
            };

            fn arrowAt(line: []const u8) ?ArrowAt {
                const patterns = [_]struct { pattern: []const u8, arrow: MessageArrow }{
                    .{ .pattern = "-->>", .arrow = .dashed },
                    .{ .pattern = "->>", .arrow = .solid },
                    .{ .pattern = "--x", .arrow = .cross },
                    .{ .pattern = "-x", .arrow = .cross },
                    .{ .pattern = "--)", .arrow = .open },
                    .{ .pattern = "-)", .arrow = .open },
                    .{ .pattern = "-->", .arrow = .dashed },
                    .{ .pattern = "->", .arrow = .solid },
                };
                var best: ?ArrowAt = null;
                for (patterns) |entry| {
                    if (std.mem.indexOf(u8, line, entry.pattern)) |pos| {
                        if (best == null or pos < best.?.start) {
                            best = .{ .start = pos, .end = pos + entry.pattern.len, .arrow = entry.arrow };
                        }
                    }
                }
                return best;
            }

            // ------------------------------------------------------ pie

            fn renderPie(self: *Renderer, lines: []const []const u8) Node {
                var title: []const u8 = "";
                var slices_buf: [max_mermaid_slices]struct { label: []const u8, value: f64 } = undefined;
                var slice_count: usize = 0;
                var total: f64 = 0;
                var failed = false;

                for (lines, 0..) |raw_line, line_index| {
                    var line = std.mem.trim(u8, raw_line, " \t");
                    // Line 0 is the `pie` header; the title and options
                    // ride the same line in the canonical syntax
                    // (`pie title Pets`), so strip the keyword and parse
                    // the rest normally.
                    if (line_index == 0 and std.ascii.startsWithIgnoreCase(line, "pie")) {
                        line = std.mem.trim(u8, line["pie".len..], " \t");
                    }
                    if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
                    if (std.ascii.startsWithIgnoreCase(line, "title ")) {
                        title = std.mem.trim(u8, line["title ".len..], " \t");
                        continue;
                    }
                    if (std.mem.eql(u8, line, "showData")) continue;
                    const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                    const label = unquote(std.mem.trim(u8, line[0..colon], " \t"));
                    const value = std.fmt.parseFloat(f64, std.mem.trim(u8, line[colon + 1 ..], " \t")) catch {
                        failed = true;
                        continue;
                    };
                    if (slice_count >= max_mermaid_slices) {
                        failed = true;
                        continue;
                    }
                    slices_buf[slice_count] = .{ .label = label, .value = value };
                    slice_count += 1;
                    total += value;
                }
                if (failed or slice_count == 0 or total <= 0) return self.codeFallback(lines, "pie", "couldn't parse this pie chart");

                var blocks = std.ArrayListUnmanaged(Node).empty;
                defer blocks.deinit(self.ui.arena);
                if (title.len > 0) {
                    blocks.append(self.ui.arena, self.ui.paragraph(.{ .grow = 1, .text_alignment = .center }, &.{mono(title, 1, .medium)})) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }

                const colors = [_]canvas.ColorTokenName{ .accent, .info, .success, .warning, .destructive };
                const bar_width: f32 = 380;
                var bar_parts = std.ArrayListUnmanaged(Node).empty;
                defer bar_parts.deinit(self.ui.arena);
                for (slices_buf[0..slice_count], 0..) |slice, index| {
                    const fraction: f32 = @floatCast(slice.value / total);
                    const width = @max(@as(f32, 2), fraction * bar_width);
                    const color = colors[index % colors.len];
                    bar_parts.append(self.ui.arena, self.ui.el(.panel, .{
                        .width = width,
                        .height = 14,
                        // Square segments: the bar reads as one
                        // continuous track (the default radius gaps it).
                        .style = .{ .radius = 0 },
                        .style_tokens = .{ .background = color },
                    }, .{})) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }
                blocks.append(self.ui.arena, self.ui.row(.{ .gap = 2, .main = .center }, bar_parts.items)) catch {
                    self.ui.failed = true;
                    return self.ui.spacer(0);
                };

                var legend_parts = std.ArrayListUnmanaged(Node).empty;
                defer legend_parts.deinit(self.ui.arena);
                for (slices_buf[0..slice_count], 0..) |slice, index| {
                    const color = colors[index % colors.len];
                    var entry = std.ArrayListUnmanaged(Node).empty;
                    defer entry.deinit(self.ui.arena);
                    entry.append(self.ui.arena, self.ui.el(.panel, .{ .width = 10, .height = 10, .style_tokens = .{ .background = color } }, .{})) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                    entry.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(slice.label, 1, .regular)})) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                    var value_buffer: [32]u8 = undefined;
                    const value_text = std.fmt.bufPrint(&value_buffer, "{d:.1}", .{slice.value}) catch "";
                    entry.append(self.ui.arena, self.ui.paragraph(.{}, &.{mono(value_text, 0.85, .regular)})) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                    legend_parts.append(self.ui.arena, self.ui.row(.{ .gap = 8, .cross = .center }, entry.items)) catch {
                        self.ui.failed = true;
                        return self.ui.spacer(0);
                    };
                }
                blocks.append(self.ui.arena, self.ui.column(.{ .gap = 4, .main = .center }, legend_parts.items)) catch {
                    self.ui.failed = true;
                    return self.ui.spacer(0);
                };
                return self.ui.column(.{ .gap = 8 }, blocks.items);
            }

            // ------------------------------------------------- fallback

            /// The ordinary fenced-code panel plus a muted note.
            fn codeFallback(self: *Renderer, lines: []const []const u8, diagram_type: []const u8, reason: []const u8) Node {
                var source = std.ArrayListUnmanaged(u8).empty;
                defer source.deinit(self.ui.arena);
                for (lines) |line| {
                    source.appendSlice(self.ui.arena, line) catch break;
                    source.append(self.ui.arena, '\n') catch break;
                }
                const note = self.ui.fmt("mermaid {s}: {s} - source below", .{ diagram_type, reason });
                return self.ui.column(.{ .gap = 6 }, .{
                    self.ui.paragraph(.{}, &.{mono(note, 0.85, .regular)}),
                    self.ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .background = .surface_subtle } }, .{
                        self.ui.paragraph(.{}, &.{mono(source.items, 1, .regular)}),
                    }),
                });
            }
        };

        /// Render the mermaid source (fence contents, without the fence
        /// lines). Returns a diagram node, or a styled code panel when the
        /// diagram type is unsupported or unparseable.
        pub fn view(ui: *Ui, source: []const u8) Node {
            var lines_buf: [max_mermaid_lines][]const u8 = undefined;
            var line_count: usize = 0;
            var it = std.mem.splitScalar(u8, source, '\n');
            while (it.next()) |line| {
                if (line_count >= lines_buf.len) break;
                lines_buf[line_count] = line;
                line_count += 1;
            }
            const lines = lines_buf[0..line_count];
            const first = std.mem.trim(u8, if (lines.len > 0) lines[0] else "", " \t");
            var renderer = Renderer{ .ui = ui };
            const kind = typeOf(first) orelse {
                const unknown = if (first.len > 0) first else "?";
                return renderer.codeFallback(lines, unknown, "isn't a supported diagram type");
            };
            switch (kind) {
                .flowchart => {
                    const chart = parseFlowchart(lines) orelse return renderer.codeFallback(lines, "flowchart", "couldn't parse this flowchart");
                    if (chart.failed) return renderer.codeFallback(lines, "flowchart", "couldn't parse this flowchart");
                    return renderer.renderFlowchart(&chart);
                },
                .sequence => return renderer.renderSequence(lines),
                .pie => return renderer.renderPie(lines),
            }
        }
    };
}
