//! ringmpsc — HTML Report Generator (pure Zig, inline SVG charts)
//!
//! Takes the JSON output from suite.zig and produces a self-contained HTML file
//! with embedded SVG bar charts and tables. Zero external dependencies.

const std = @import("std");

pub const HtmlWriter = struct {
    buf: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HtmlWriter {
        return .{ .buf = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *HtmlWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn w(self: *HtmlWriter, s: []const u8) void {
        self.buf.appendSlice(self.allocator, s) catch {};
    }

    pub fn print(self: *HtmlWriter, comptime fmt: []const u8, args: anytype) void {
        std.fmt.format(self.buf.writer(self.allocator), fmt, args) catch {};
    }

    pub fn output(self: *HtmlWriter) []const u8 {
        return self.buf.items;
    }
};

// ============================================================================
// SVG CHART PRIMITIVES
// ============================================================================

const COLORS = [_][]const u8{
    "#4e79a7", "#f28e2b", "#e15759", "#76b7b2",
    "#59a14f", "#edc948", "#b07aa1", "#ff9da7",
};

pub fn barChart(
    h: *HtmlWriter,
    title: []const u8,
    labels: []const []const u8,
    values: []const f64,
    unit: []const u8,
    width: u32,
    height: u32,
) void {
    if (labels.len == 0) return;

    const margin_left: u32 = 80;
    const margin_right: u32 = 20;
    const margin_top: u32 = 40;
    const margin_bottom: u32 = 80;
    const chart_w = width - margin_left - margin_right;
    const chart_h = height - margin_top - margin_bottom;

    // Find max value
    var max_val: f64 = 0;
    for (values) |v| {
        if (v > max_val) max_val = v;
    }
    if (max_val == 0) max_val = 1;
    max_val *= 1.15; // 15% headroom

    const bar_w: f64 = @as(f64, @floatFromInt(chart_w)) / @as(f64, @floatFromInt(labels.len)) * 0.7;
    const gap: f64 = @as(f64, @floatFromInt(chart_w)) / @as(f64, @floatFromInt(labels.len)) * 0.3;

    h.print("<svg width=\"{}\" height=\"{}\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family: 'SF Mono', 'Fira Code', monospace;\">\n", .{ width, height });

    // Background
    h.print("<rect width=\"{}\" height=\"{}\" fill=\"#1a1a2e\" rx=\"8\"/>\n", .{ width, height });

    // Title
    h.print("<text x=\"{}\" y=\"28\" fill=\"#e0e0e0\" font-size=\"14\" font-weight=\"bold\" text-anchor=\"middle\">{s}</text>\n", .{ width / 2, title });

    // Grid lines
    const n_grid: usize = 5;
    for (0..n_grid + 1) |i| {
        const y_frac = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_grid));
        const y: u32 = margin_top + @as(u32, @intFromFloat(y_frac * @as(f64, @floatFromInt(chart_h))));
        const val = max_val * (1.0 - y_frac);
        h.print("<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\" stroke=\"#333\" stroke-dasharray=\"4\"/>\n", .{ margin_left, y, margin_left + chart_w, y });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#888\" font-size=\"10\" text-anchor=\"end\">{d:.1}</text>\n", .{ margin_left - 5, y + 4, val });
    }

    // Bars
    for (labels, 0..) |label, i| {
        const x_base: f64 = @as(f64, @floatFromInt(margin_left)) + @as(f64, @floatFromInt(i)) * (bar_w + gap) + gap / 2.0;
        const bar_h = (values[i] / max_val) * @as(f64, @floatFromInt(chart_h));
        const y_bar = @as(f64, @floatFromInt(margin_top + chart_h)) - bar_h;
        const color = COLORS[i % COLORS.len];

        // Bar
        h.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" fill=\"{s}\" rx=\"3\" opacity=\"0.9\"/>\n", .{ x_base, y_bar, bar_w, bar_h, color });

        // Value label
        h.print("<text x=\"{d:.1}\" y=\"{d:.1}\" fill=\"#e0e0e0\" font-size=\"10\" text-anchor=\"middle\" font-weight=\"bold\">{d:.2}</text>\n", .{ x_base + bar_w / 2.0, y_bar - 5, values[i] });

        // X-axis label
        h.print("<text x=\"{d:.1}\" y=\"{}\" fill=\"#aaa\" font-size=\"10\" text-anchor=\"middle\" transform=\"rotate(-30, {d:.1}, {})\">{s}</text>\n", .{ x_base + bar_w / 2.0, margin_top + chart_h + 20, x_base + bar_w / 2.0, margin_top + chart_h + 20, label });
    }

    // Y-axis label
    h.print("<text x=\"15\" y=\"{}\" fill=\"#888\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90, 15, {})\">{s}</text>\n", .{ margin_top + chart_h / 2, margin_top + chart_h / 2, unit });

    h.w("</svg>\n");
}

pub fn groupedBarChart(
    h: *HtmlWriter,
    title: []const u8,
    labels: []const []const u8,
    series_names: []const []const u8,
    series: []const []const f64,
    unit: []const u8,
    width: u32,
    height: u32,
) void {
    if (labels.len == 0 or series.len == 0) return;

    const margin_left: u32 = 80;
    const margin_right: u32 = 130;
    const margin_top: u32 = 40;
    const margin_bottom: u32 = 80;
    const chart_w = width - margin_left - margin_right;
    const chart_h = height - margin_top - margin_bottom;

    var max_val: f64 = 0;
    for (series) |s| {
        for (s) |v| {
            if (v > max_val) max_val = v;
        }
    }
    if (max_val == 0) max_val = 1;
    max_val *= 1.15;

    const n_groups = labels.len;
    const n_series = series.len;
    const group_w: f64 = @as(f64, @floatFromInt(chart_w)) / @as(f64, @floatFromInt(n_groups));
    const bar_w: f64 = group_w * 0.7 / @as(f64, @floatFromInt(n_series));

    h.print("<svg width=\"{}\" height=\"{}\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family: 'SF Mono', 'Fira Code', monospace;\">\n", .{ width, height });
    h.print("<rect width=\"{}\" height=\"{}\" fill=\"#1a1a2e\" rx=\"8\"/>\n", .{ width, height });
    h.print("<text x=\"{}\" y=\"28\" fill=\"#e0e0e0\" font-size=\"14\" font-weight=\"bold\" text-anchor=\"middle\">{s}</text>\n", .{ width / 2, title });

    // Grid
    const n_grid: usize = 5;
    for (0..n_grid + 1) |i| {
        const y_frac = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_grid));
        const y: u32 = margin_top + @as(u32, @intFromFloat(y_frac * @as(f64, @floatFromInt(chart_h))));
        const val = max_val * (1.0 - y_frac);
        h.print("<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\" stroke=\"#333\" stroke-dasharray=\"4\"/>\n", .{ margin_left, y, margin_left + chart_w, y });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#888\" font-size=\"10\" text-anchor=\"end\">{d:.1}</text>\n", .{ margin_left - 5, y + 4, val });
    }

    // Bars
    for (0..n_groups) |g| {
        const group_x: f64 = @as(f64, @floatFromInt(margin_left)) + @as(f64, @floatFromInt(g)) * group_w;
        for (series, 0..) |s, si| {
            const x = group_x + group_w * 0.15 + @as(f64, @floatFromInt(si)) * bar_w;
            const val = if (g < s.len) s[g] else 0;
            const bh = (val / max_val) * @as(f64, @floatFromInt(chart_h));
            const y = @as(f64, @floatFromInt(margin_top + chart_h)) - bh;
            const color = COLORS[si % COLORS.len];
            h.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" fill=\"{s}\" rx=\"2\" opacity=\"0.9\"/>\n", .{ x, y, bar_w, bh, color });
        }
        // X label
        h.print("<text x=\"{d:.1}\" y=\"{}\" fill=\"#aaa\" font-size=\"10\" text-anchor=\"middle\">{s}</text>\n", .{ group_x + group_w / 2.0, margin_top + chart_h + 18, labels[g] });
    }

    // Legend
    for (series_names, 0..) |name, si| {
        const ly: u32 = margin_top + 10 + @as(u32, @intCast(si)) * 20;
        const lx: u32 = width - margin_right + 10;
        const color = COLORS[si % COLORS.len];
        h.print("<rect x=\"{}\" y=\"{}\" width=\"12\" height=\"12\" fill=\"{s}\" rx=\"2\"/>\n", .{ lx, ly, color });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#ccc\" font-size=\"10\">{s}</text>\n", .{ lx + 16, ly + 10, name });
    }

    h.print("<text x=\"15\" y=\"{}\" fill=\"#888\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90, 15, {})\">{s}</text>\n", .{ margin_top + chart_h / 2, margin_top + chart_h / 2, unit });

    h.w("</svg>\n");
}

pub fn latencyBoxChart(
    h: *HtmlWriter,
    p50: u64,
    p90: u64,
    p99: u64,
    p999: u64,
    min_val: u64,
    max_val: u64,
    width: u32,
    height: u32,
) void {
    h.print("<svg width=\"{}\" height=\"{}\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family: 'SF Mono', 'Fira Code', monospace;\">\n", .{ width, height });
    h.print("<rect width=\"{}\" height=\"{}\" fill=\"#1a1a2e\" rx=\"8\"/>\n", .{ width, height });
    h.print("<text x=\"{}\" y=\"28\" fill=\"#e0e0e0\" font-size=\"14\" font-weight=\"bold\" text-anchor=\"middle\">SPSC Latency Distribution (ns)</text>\n", .{width / 2});

    const labels = [_][]const u8{ "min", "p50", "p90", "p99", "p999", "max" };
    const vals = [_]u64{ min_val, p50, p90, p99, p999, max_val };
    const colors = [_][]const u8{ "#59a14f", "#4e79a7", "#f28e2b", "#e15759", "#b07aa1", "#ff9da7" };

    const margin_left: u32 = 60;
    const margin_top: u32 = 50;
    const chart_w: u32 = width - margin_left - 30;
    const chart_h: u32 = height - margin_top - 50;

    var max_v: f64 = 0;
    for (vals) |v| {
        const fv = @as(f64, @floatFromInt(v));
        if (fv > max_v) max_v = fv;
    }
    if (max_v == 0) max_v = 1;
    max_v *= 1.2;

    const bar_w = @as(f64, @floatFromInt(chart_w)) / 6.0 * 0.7;
    const gap = @as(f64, @floatFromInt(chart_w)) / 6.0 * 0.3;

    for (labels, 0..) |label, i| {
        const x = @as(f64, @floatFromInt(margin_left)) + @as(f64, @floatFromInt(i)) * (bar_w + gap) + gap / 2.0;
        const bh = (@as(f64, @floatFromInt(vals[i])) / max_v) * @as(f64, @floatFromInt(chart_h));
        const y = @as(f64, @floatFromInt(margin_top + chart_h)) - bh;

        h.print("<rect x=\"{d:.0}\" y=\"{d:.0}\" width=\"{d:.0}\" height=\"{d:.0}\" fill=\"{s}\" rx=\"3\" opacity=\"0.85\"/>\n", .{ x, y, bar_w, bh, colors[i] });
        h.print("<text x=\"{d:.0}\" y=\"{d:.0}\" fill=\"#e0e0e0\" font-size=\"10\" text-anchor=\"middle\" font-weight=\"bold\">{}ns</text>\n", .{ x + bar_w / 2.0, y - 5, vals[i] });
        h.print("<text x=\"{d:.0}\" y=\"{}\" fill=\"#aaa\" font-size=\"10\" text-anchor=\"middle\">{s}</text>\n", .{ x + bar_w / 2.0, margin_top + chart_h + 18, label });
    }

    h.w("</svg>\n");
}

// ============================================================================
// BAR CHART WITH ERROR BARS (min/max whiskers)
// ============================================================================

pub fn barChartWithErrors(
    h: *HtmlWriter,
    title: []const u8,
    labels: []const []const u8,
    medians: []const f64,
    mins: []const f64,
    maxs: []const f64,
    unit: []const u8,
    width: u32,
    height: u32,
) void {
    if (labels.len == 0) return;

    const ml: u32 = 80;
    const mr: u32 = 20;
    const mt: u32 = 40;
    const mb: u32 = 80;
    const cw = width - ml - mr;
    const ch = height - mt - mb;

    var max_val: f64 = 0;
    for (maxs) |v| {
        if (v > max_val) max_val = v;
    }
    if (max_val == 0) max_val = 1;
    max_val *= 1.2;

    const bw: f64 = @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(labels.len)) * 0.7;
    const gap: f64 = @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(labels.len)) * 0.3;

    h.print("<svg width=\"{}\" height=\"{}\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family: 'SF Mono', 'Fira Code', monospace;\">\n", .{ width, height });
    h.print("<rect width=\"{}\" height=\"{}\" fill=\"#1a1a2e\" rx=\"8\"/>\n", .{ width, height });
    h.print("<text x=\"{}\" y=\"28\" fill=\"#e0e0e0\" font-size=\"14\" font-weight=\"bold\" text-anchor=\"middle\">{s}</text>\n", .{ width / 2, title });

    // Grid
    for (0..6) |i| {
        const yf = @as(f64, @floatFromInt(i)) / 5.0;
        const y: u32 = mt + @as(u32, @intFromFloat(yf * @as(f64, @floatFromInt(ch))));
        const val = max_val * (1.0 - yf);
        h.print("<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\" stroke=\"#333\" stroke-dasharray=\"4\"/>\n", .{ ml, y, ml + cw, y });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#888\" font-size=\"10\" text-anchor=\"end\">{d:.1}</text>\n", .{ ml - 5, y + 4, val });
    }

    for (labels, 0..) |label, i| {
        const xb: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(i)) * (bw + gap) + gap / 2.0;
        const med = medians[i];
        const bh = (med / max_val) * @as(f64, @floatFromInt(ch));
        const ybar = @as(f64, @floatFromInt(mt + ch)) - bh;
        const color = COLORS[i % COLORS.len];
        const cx = xb + bw / 2.0;

        // Bar (median)
        h.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" fill=\"{s}\" rx=\"3\" opacity=\"0.9\"/>\n", .{ xb, ybar, bw, bh, color });

        // Whisker line (min to max)
        const y_min = @as(f64, @floatFromInt(mt + ch)) - (mins[i] / max_val) * @as(f64, @floatFromInt(ch));
        const y_max = @as(f64, @floatFromInt(mt + ch)) - (maxs[i] / max_val) * @as(f64, @floatFromInt(ch));
        h.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"#fff\" stroke-width=\"1.5\"/>\n", .{ cx, y_max, cx, y_min });
        // Caps
        h.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"#fff\" stroke-width=\"1.5\"/>\n", .{ cx - 5.0, y_max, cx + 5.0, y_max });
        h.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"#fff\" stroke-width=\"1.5\"/>\n", .{ cx - 5.0, y_min, cx + 5.0, y_min });

        // Value label
        h.print("<text x=\"{d:.1}\" y=\"{d:.1}\" fill=\"#e0e0e0\" font-size=\"10\" text-anchor=\"middle\" font-weight=\"bold\">{d:.1}</text>\n", .{ cx, y_max - 8.0, med });

        // X label
        h.print("<text x=\"{d:.1}\" y=\"{}\" fill=\"#aaa\" font-size=\"10\" text-anchor=\"middle\" transform=\"rotate(-30, {d:.1}, {})\">{s}</text>\n", .{ cx, mt + ch + 20, cx, mt + ch + 20, label });
    }

    h.print("<text x=\"15\" y=\"{}\" fill=\"#888\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90, 15, {})\">{s}</text>\n", .{ mt + ch / 2, mt + ch / 2, unit });
    h.w("</svg>\n");
}

// ============================================================================
// LINE CHART (multi-series scaling curves)
// ============================================================================

pub fn lineChart(
    h: *HtmlWriter,
    title: []const u8,
    x_labels: []const []const u8,
    series_names: []const []const u8,
    series: []const []const f64,
    y_unit: []const u8,
    width: u32,
    height: u32,
) void {
    if (x_labels.len == 0 or series.len == 0) return;

    const ml: u32 = 80;
    const mr: u32 = 130;
    const mt: u32 = 40;
    const mb: u32 = 60;
    const cw = width - ml - mr;
    const ch = height - mt - mb;

    var max_val: f64 = 0;
    for (series) |s| {
        for (s) |v| {
            if (v > max_val) max_val = v;
        }
    }
    if (max_val == 0) max_val = 1;
    max_val *= 1.15;

    h.print("<svg width=\"{}\" height=\"{}\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family: 'SF Mono', 'Fira Code', monospace;\">\n", .{ width, height });
    h.print("<rect width=\"{}\" height=\"{}\" fill=\"#1a1a2e\" rx=\"8\"/>\n", .{ width, height });
    h.print("<text x=\"{}\" y=\"28\" fill=\"#e0e0e0\" font-size=\"14\" font-weight=\"bold\" text-anchor=\"middle\">{s}</text>\n", .{ width / 2, title });

    // Grid
    for (0..6) |i| {
        const yf = @as(f64, @floatFromInt(i)) / 5.0;
        const y: u32 = mt + @as(u32, @intFromFloat(yf * @as(f64, @floatFromInt(ch))));
        const val = max_val * (1.0 - yf);
        h.print("<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\" stroke=\"#333\" stroke-dasharray=\"4\"/>\n", .{ ml, y, ml + cw, y });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#888\" font-size=\"10\" text-anchor=\"end\">{d:.1}</text>\n", .{ ml - 5, y + 4, val });
    }

    // X labels
    const n = x_labels.len;
    for (x_labels, 0..) |label, i| {
        const x: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(if (n > 1) n - 1 else 1));
        h.print("<text x=\"{d:.0}\" y=\"{}\" fill=\"#aaa\" font-size=\"10\" text-anchor=\"middle\">{s}</text>\n", .{ x, mt + ch + 18, label });
    }

    // Series lines + dots
    for (series, 0..) |s, si| {
        const color = COLORS[si % COLORS.len];
        // Polyline
        h.print("<polyline fill=\"none\" stroke=\"{s}\" stroke-width=\"2.5\" points=\"", .{color});
        for (s, 0..) |v, j| {
            const x: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(j)) * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(if (n > 1) n - 1 else 1));
            const y: f64 = @as(f64, @floatFromInt(mt + ch)) - (v / max_val) * @as(f64, @floatFromInt(ch));
            h.print("{d:.1},{d:.1} ", .{ x, y });
        }
        h.w("\"/>\n");
        // Dots
        for (s, 0..) |v, j| {
            const x: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(j)) * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(if (n > 1) n - 1 else 1));
            const y: f64 = @as(f64, @floatFromInt(mt + ch)) - (v / max_val) * @as(f64, @floatFromInt(ch));
            h.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"4\" fill=\"{s}\"/>\n", .{ x, y, color });
        }
    }

    // Legend
    for (series_names, 0..) |name, si| {
        const ly: u32 = mt + 10 + @as(u32, @intCast(si)) * 20;
        const lx: u32 = width - mr + 10;
        const color = COLORS[si % COLORS.len];
        h.print("<rect x=\"{}\" y=\"{}\" width=\"12\" height=\"3\" fill=\"{s}\" rx=\"1\"/>\n", .{ lx, ly + 5, color });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#ccc\" font-size=\"10\">{s}</text>\n", .{ lx + 16, ly + 10, name });
    }

    h.print("<text x=\"15\" y=\"{}\" fill=\"#888\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90, 15, {})\">{s}</text>\n", .{ mt + ch / 2, mt + ch / 2, y_unit });
    h.w("</svg>\n");
}

// ============================================================================
// LINE CHART WITH ERROR BANDS (shaded min/max region)
// ============================================================================

pub fn lineChartWithErrors(
    h: *HtmlWriter,
    title: []const u8,
    x_labels: []const []const u8,
    series_names: []const []const u8,
    medians: []const []const f64,
    mins: []const []const f64,
    maxs: []const []const f64,
    y_unit: []const u8,
    width: u32,
    height: u32,
) void {
    if (x_labels.len == 0 or medians.len == 0) return;

    const ml: u32 = 80;
    const mr: u32 = 130;
    const mt: u32 = 40;
    const mb: u32 = 60;
    const cw = width - ml - mr;
    const ch = height - mt - mb;

    var max_val: f64 = 0;
    for (maxs) |s| {
        for (s) |v| {
            if (v > max_val) max_val = v;
        }
    }
    if (max_val == 0) max_val = 1;
    max_val *= 1.15;

    const n = x_labels.len;

    h.print("<svg width=\"{}\" height=\"{}\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family: 'SF Mono', 'Fira Code', monospace;\">\n", .{ width, height });
    h.print("<rect width=\"{}\" height=\"{}\" fill=\"#1a1a2e\" rx=\"8\"/>\n", .{ width, height });
    h.print("<text x=\"{}\" y=\"28\" fill=\"#e0e0e0\" font-size=\"14\" font-weight=\"bold\" text-anchor=\"middle\">{s}</text>\n", .{ width / 2, title });

    // Grid
    for (0..6) |i| {
        const yf = @as(f64, @floatFromInt(i)) / 5.0;
        const y: u32 = mt + @as(u32, @intFromFloat(yf * @as(f64, @floatFromInt(ch))));
        const val = max_val * (1.0 - yf);
        h.print("<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\" stroke=\"#333\" stroke-dasharray=\"4\"/>\n", .{ ml, y, ml + cw, y });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#888\" font-size=\"10\" text-anchor=\"end\">{d:.1}</text>\n", .{ ml - 5, y + 4, val });
    }

    // X labels
    for (x_labels, 0..) |label, i| {
        const x: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(if (n > 1) n - 1 else 1));
        h.print("<text x=\"{d:.0}\" y=\"{}\" fill=\"#aaa\" font-size=\"10\" text-anchor=\"middle\">{s}</text>\n", .{ x, mt + ch + 18, label });
    }

    // Error bands + median lines
    for (medians, 0..) |med, si| {
        const color = COLORS[si % COLORS.len];
        const mn = mins[si];
        const mx = maxs[si];

        // Shaded error band polygon (upper path forward, lower path backward)
        h.print("<polygon fill=\"{s}\" opacity=\"0.15\" points=\"", .{color});
        // Forward (max)
        for (mx, 0..) |v, j| {
            const x: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(j)) * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(if (n > 1) n - 1 else 1));
            const y: f64 = @as(f64, @floatFromInt(mt + ch)) - (v / max_val) * @as(f64, @floatFromInt(ch));
            h.print("{d:.1},{d:.1} ", .{ x, y });
        }
        // Backward (min)
        var j: usize = mn.len;
        while (j > 0) {
            j -= 1;
            const x: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(j)) * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(if (n > 1) n - 1 else 1));
            const y: f64 = @as(f64, @floatFromInt(mt + ch)) - (mn[j] / max_val) * @as(f64, @floatFromInt(ch));
            h.print("{d:.1},{d:.1} ", .{ x, y });
        }
        h.w("\"/>\n");

        // Median line
        h.print("<polyline fill=\"none\" stroke=\"{s}\" stroke-width=\"2.5\" points=\"", .{color});
        for (med, 0..) |v, k| {
            const x: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(if (n > 1) n - 1 else 1));
            const y: f64 = @as(f64, @floatFromInt(mt + ch)) - (v / max_val) * @as(f64, @floatFromInt(ch));
            h.print("{d:.1},{d:.1} ", .{ x, y });
        }
        h.w("\"/>\n");

        // Dots on median
        for (med, 0..) |v, k| {
            const x: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(if (n > 1) n - 1 else 1));
            const y: f64 = @as(f64, @floatFromInt(mt + ch)) - (v / max_val) * @as(f64, @floatFromInt(ch));
            h.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"4\" fill=\"{s}\"/>\n", .{ x, y, color });
        }
    }

    // Legend
    for (series_names, 0..) |name, si| {
        const ly: u32 = mt + 10 + @as(u32, @intCast(si)) * 20;
        const lx: u32 = width - mr + 10;
        const color = COLORS[si % COLORS.len];
        h.print("<rect x=\"{}\" y=\"{}\" width=\"12\" height=\"3\" fill=\"{s}\" rx=\"1\"/>\n", .{ lx, ly + 5, color });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#ccc\" font-size=\"10\">{s}</text>\n", .{ lx + 16, ly + 10, name });
    }

    h.print("<text x=\"15\" y=\"{}\" fill=\"#888\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90, 15, {})\">{s}</text>\n", .{ mt + ch / 2, mt + ch / 2, y_unit });
    h.w("</svg>\n");
}

// ============================================================================
// GROUPED BAR CHART WITH ERROR BARS
// ============================================================================

pub fn groupedBarChartWithErrors(
    h: *HtmlWriter,
    title: []const u8,
    labels: []const []const u8,
    series_names: []const []const u8,
    med: []const []const f64,
    mn: []const []const f64,
    mx: []const []const f64,
    unit: []const u8,
    width: u32,
    height: u32,
) void {
    if (labels.len == 0 or med.len == 0) return;

    const ml: u32 = 80;
    const mr: u32 = 130;
    const mt: u32 = 40;
    const mb: u32 = 80;
    const cw = width - ml - mr;
    const ch = height - mt - mb;

    var max_val: f64 = 0;
    for (mx) |s| {
        for (s) |v| {
            if (v > max_val) max_val = v;
        }
    }
    if (max_val == 0) max_val = 1;
    max_val *= 1.2;

    const ng = labels.len;
    const ns = med.len;
    const gw: f64 = @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(ng));
    const bw: f64 = gw * 0.7 / @as(f64, @floatFromInt(ns));

    h.print("<svg width=\"{}\" height=\"{}\" xmlns=\"http://www.w3.org/2000/svg\" style=\"font-family: 'SF Mono', 'Fira Code', monospace;\">\n", .{ width, height });
    h.print("<rect width=\"{}\" height=\"{}\" fill=\"#1a1a2e\" rx=\"8\"/>\n", .{ width, height });
    h.print("<text x=\"{}\" y=\"28\" fill=\"#e0e0e0\" font-size=\"14\" font-weight=\"bold\" text-anchor=\"middle\">{s}</text>\n", .{ width / 2, title });

    // Grid
    for (0..6) |i| {
        const yf = @as(f64, @floatFromInt(i)) / 5.0;
        const y: u32 = mt + @as(u32, @intFromFloat(yf * @as(f64, @floatFromInt(ch))));
        const val = max_val * (1.0 - yf);
        h.print("<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\" stroke=\"#333\" stroke-dasharray=\"4\"/>\n", .{ ml, y, ml + cw, y });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#888\" font-size=\"10\" text-anchor=\"end\">{d:.1}</text>\n", .{ ml - 5, y + 4, val });
    }

    for (0..ng) |g| {
        const gx: f64 = @as(f64, @floatFromInt(ml)) + @as(f64, @floatFromInt(g)) * gw;
        for (med, 0..) |s, si| {
            const x = gx + gw * 0.15 + @as(f64, @floatFromInt(si)) * bw;
            const val = if (g < s.len) s[g] else 0;
            const bh = (val / max_val) * @as(f64, @floatFromInt(ch));
            const y = @as(f64, @floatFromInt(mt + ch)) - bh;
            const color = COLORS[si % COLORS.len];
            const cx = x + bw / 2.0;

            h.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" fill=\"{s}\" rx=\"2\" opacity=\"0.9\"/>\n", .{ x, y, bw, bh, color });

            // Whiskers
            if (g < mn[si].len and g < mx[si].len) {
                const y_lo = @as(f64, @floatFromInt(mt + ch)) - (mn[si][g] / max_val) * @as(f64, @floatFromInt(ch));
                const y_hi = @as(f64, @floatFromInt(mt + ch)) - (mx[si][g] / max_val) * @as(f64, @floatFromInt(ch));
                h.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"#fff\" stroke-width=\"1\"/>\n", .{ cx, y_hi, cx, y_lo });
                h.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"#fff\" stroke-width=\"1\"/>\n", .{ cx - 3, y_hi, cx + 3, y_hi });
                h.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"#fff\" stroke-width=\"1\"/>\n", .{ cx - 3, y_lo, cx + 3, y_lo });
            }
        }
        h.print("<text x=\"{d:.1}\" y=\"{}\" fill=\"#aaa\" font-size=\"10\" text-anchor=\"middle\">{s}</text>\n", .{ gx + gw / 2.0, mt + ch + 18, labels[g] });
    }

    // Legend
    for (series_names, 0..) |name, si| {
        const ly: u32 = mt + 10 + @as(u32, @intCast(si)) * 20;
        const lx: u32 = width - mr + 10;
        const color = COLORS[si % COLORS.len];
        h.print("<rect x=\"{}\" y=\"{}\" width=\"12\" height=\"12\" fill=\"{s}\" rx=\"2\"/>\n", .{ lx, ly, color });
        h.print("<text x=\"{}\" y=\"{}\" fill=\"#ccc\" font-size=\"10\">{s}</text>\n", .{ lx + 16, ly + 10, name });
    }

    h.print("<text x=\"15\" y=\"{}\" fill=\"#888\" font-size=\"11\" text-anchor=\"middle\" transform=\"rotate(-90, 15, {})\">{s}</text>\n", .{ mt + ch / 2, mt + ch / 2, unit });
    h.w("</svg>\n");
}

// ============================================================================
// HTML REPORT TEMPLATE
// ============================================================================

pub fn writeHtmlHeader(h: *HtmlWriter) void {
    h.w(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<title>ringmpsc Benchmark Report</title>
        \\<style>
        \\:root { --bg: #0d1117; --surface: #161b22; --border: #30363d; --text: #c9d1d9; --muted: #8b949e; --accent: #58a6ff; }
        \\* { margin: 0; padding: 0; box-sizing: border-box; }
        \\body { background: var(--bg); color: var(--text); font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', monospace; padding: 2rem; max-width: 1200px; margin: 0 auto; }
        \\h1 { font-size: 1.8rem; margin-bottom: 0.5rem; color: #fff; }
        \\.subtitle { color: var(--muted); margin-bottom: 2rem; font-size: 0.85rem; }
        \\h2 { font-size: 1.2rem; margin: 2rem 0 1rem; color: var(--accent); border-bottom: 1px solid var(--border); padding-bottom: 0.5rem; }
        \\.card { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem; }
        \\.chart-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; }
        \\.chart-grid .card { margin-bottom: 0; }
        \\@media (max-width: 900px) { .chart-grid { grid-template-columns: 1fr; } }
        \\svg { width: 100%; height: auto; }
        \\table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
        \\th { text-align: left; padding: 8px 12px; background: #1c2128; color: var(--muted); border-bottom: 1px solid var(--border); }
        \\td { padding: 8px 12px; border-bottom: 1px solid var(--border); }
        \\tr:hover td { background: #1c2128; }
        \\.metric { display: inline-block; background: #1c2128; border: 1px solid var(--border); border-radius: 6px; padding: 0.75rem 1rem; margin: 0.25rem; text-align: center; }
        \\.metric .value { font-size: 1.4rem; font-weight: bold; color: #fff; }
        \\.metric .label { font-size: 0.75rem; color: var(--muted); margin-top: 0.25rem; }
        \\.metrics-row { display: flex; flex-wrap: wrap; gap: 0.5rem; margin: 1rem 0; }
        \\</style>
        \\</head>
        \\<body>
        \\
    );
}

pub fn writeHtmlFooter(h: *HtmlWriter) void {
    h.w(
        \\<div style="margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--border); color: var(--muted); font-size: 0.75rem;">
        \\Generated by ringmpsc bench-suite &middot; pure Zig, zero dependencies
        \\</div>
        \\</body>
        \\</html>
        \\
    );
}
