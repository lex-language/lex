// std/lume.lex — utility-CSS for lex, written in lex.
//
// A `rule(token) -> CSS` engine in the spirit of Tailwind, but with no build
// step and no compiler support: it's just a library that runs in the thread's
// arena, using the native string helpers (split, strEq, startsWith,
// substring...).
//
// Two APIs over the same engine:
//   lm("classes")    -> inline style string  (for style="...")
//                       zero config, automatic purge, no :hover/responsive.
//   sheet("classes") -> "<style>.a{...}.b{...}</style>"  (for the <head>)
//                       keeps class="..." in the markup, dedupes the rules.
//
// Usage:
//   import { lm } from "lume";
//   `<div style="${lm("flex items-center gap-4 p-6 rounded-lg bg-white")}">`

// ---------------------------------------------------------------------------
// spacing/sizing scale: tailwind step (n * 0.25rem). "" = invalid.
// ---------------------------------------------------------------------------
fn scale(n: string): string {
    if strEq(n, "0") == 1 { return "0"; }
    if strEq(n, "1") == 1 { return "0.25rem"; }
    if strEq(n, "2") == 1 { return "0.5rem"; }
    if strEq(n, "3") == 1 { return "0.75rem"; }
    if strEq(n, "4") == 1 { return "1rem"; }
    if strEq(n, "5") == 1 { return "1.25rem"; }
    if strEq(n, "6") == 1 { return "1.5rem"; }
    if strEq(n, "7") == 1 { return "1.75rem"; }
    if strEq(n, "8") == 1 { return "2rem"; }
    if strEq(n, "9") == 1 { return "2.25rem"; }
    if strEq(n, "10") == 1 { return "2.5rem"; }
    if strEq(n, "11") == 1 { return "2.75rem"; }
    if strEq(n, "12") == 1 { return "3rem"; }
    if strEq(n, "14") == 1 { return "3.5rem"; }
    if strEq(n, "16") == 1 { return "4rem"; }
    if strEq(n, "20") == 1 { return "5rem"; }
    if strEq(n, "24") == 1 { return "6rem"; }
    return "";
}

// ---------------------------------------------------------------------------
// color palette (subset of tailwind). key: "slate-500", "white", ...
// ---------------------------------------------------------------------------
fn hex(k: string): string {
    if strEq(k, "white") == 1 { return "#ffffff"; }
    if strEq(k, "black") == 1 { return "#000000"; }
    // slate
    if strEq(k, "slate-50") == 1 { return "#f8fafc"; }
    if strEq(k, "slate-100") == 1 { return "#f1f5f9"; }
    if strEq(k, "slate-200") == 1 { return "#e2e8f0"; }
    if strEq(k, "slate-300") == 1 { return "#cbd5e1"; }
    if strEq(k, "slate-400") == 1 { return "#94a3b8"; }
    if strEq(k, "slate-500") == 1 { return "#64748b"; }
    if strEq(k, "slate-600") == 1 { return "#475569"; }
    if strEq(k, "slate-700") == 1 { return "#334155"; }
    if strEq(k, "slate-800") == 1 { return "#1e293b"; }
    if strEq(k, "slate-900") == 1 { return "#0f172a"; }
    // blue
    if strEq(k, "blue-100") == 1 { return "#dbeafe"; }
    if strEq(k, "blue-500") == 1 { return "#3b82f6"; }
    if strEq(k, "blue-600") == 1 { return "#2563eb"; }
    if strEq(k, "blue-700") == 1 { return "#1d4ed8"; }
    // red
    if strEq(k, "red-100") == 1 { return "#fee2e2"; }
    if strEq(k, "red-500") == 1 { return "#ef4444"; }
    if strEq(k, "red-600") == 1 { return "#dc2626"; }
    // green
    if strEq(k, "green-100") == 1 { return "#dcfce7"; }
    if strEq(k, "green-500") == 1 { return "#22c55e"; }
    if strEq(k, "green-600") == 1 { return "#16a34a"; }
    // amber
    if strEq(k, "amber-100") == 1 { return "#fef3c7"; }
    if strEq(k, "amber-500") == 1 { return "#f59e0b"; }
    return "";
}

// text-/bg-/border- + color. "" if the color isn't in the palette.
fn colorCss(c: string): string {
    const parts: string[] = split(c, "-");
    const n: i64 = len(parts);
    let key: string = "";
    if n == 2 { key = parts[1]; }                    // white, black
    if n == 3 { key = `${parts[1]}-${parts[2]}`; }   // slate-500
    const h: string = hex(key);
    if strEq(h, "") == 1 { return ""; }
    const prop: string = parts[0];
    if strEq(prop, "text") == 1 { return `color:${h}`; }
    if strEq(prop, "bg") == 1 { return `background-color:${h}`; }
    if strEq(prop, "border") == 1 { return `border-color:${h}`; }
    return "";
}

// text-* : font size / alignment, or fall through to color (text-<color>).
fn text(c: string): string {
    if strEq(c, "text-xs") == 1 { return "font-size:0.75rem"; }
    if strEq(c, "text-sm") == 1 { return "font-size:0.875rem"; }
    if strEq(c, "text-base") == 1 { return "font-size:1rem"; }
    if strEq(c, "text-lg") == 1 { return "font-size:1.125rem"; }
    if strEq(c, "text-xl") == 1 { return "font-size:1.25rem"; }
    if strEq(c, "text-2xl") == 1 { return "font-size:1.5rem"; }
    if strEq(c, "text-3xl") == 1 { return "font-size:1.875rem"; }
    if strEq(c, "text-center") == 1 { return "text-align:center"; }
    if strEq(c, "text-left") == 1 { return "text-align:left"; }
    if strEq(c, "text-right") == 1 { return "text-align:right"; }
    return colorCss(c);
}

// p*/m*/gap-* : split into prefix + number -> propert(ies) on the scale.
fn spacing(c: string): string {
    const parts: string[] = split(c, "-");
    if len(parts) != 2 { return ""; }
    const pre: string = parts[0];
    const val: string = scale(parts[1]);
    if strEq(val, "") == 1 { return ""; }
    if strEq(pre, "p") == 1 { return `padding:${val}`; }
    if strEq(pre, "px") == 1 { return `padding-left:${val};padding-right:${val}`; }
    if strEq(pre, "py") == 1 { return `padding-top:${val};padding-bottom:${val}`; }
    if strEq(pre, "pt") == 1 { return `padding-top:${val}`; }
    if strEq(pre, "pr") == 1 { return `padding-right:${val}`; }
    if strEq(pre, "pb") == 1 { return `padding-bottom:${val}`; }
    if strEq(pre, "pl") == 1 { return `padding-left:${val}`; }
    if strEq(pre, "m") == 1 { return `margin:${val}`; }
    if strEq(pre, "mx") == 1 { return `margin-left:${val};margin-right:${val}`; }
    if strEq(pre, "my") == 1 { return `margin-top:${val};margin-bottom:${val}`; }
    if strEq(pre, "mt") == 1 { return `margin-top:${val}`; }
    if strEq(pre, "mr") == 1 { return `margin-right:${val}`; }
    if strEq(pre, "mb") == 1 { return `margin-bottom:${val}`; }
    if strEq(pre, "ml") == 1 { return `margin-left:${val}`; }
    if strEq(pre, "gap") == 1 { return `gap:${val}`; }
    return "";
}

// numeric w-*/h-* (w-full/h-full are fixed in `rule`).
fn size(c: string): string {
    const parts: string[] = split(c, "-");
    if len(parts) != 2 { return ""; }
    const v: string = scale(parts[1]);
    if strEq(v, "") == 1 { return ""; }
    if strEq(parts[0], "w") == 1 { return `width:${v}`; }
    if strEq(parts[0], "h") == 1 { return `height:${v}`; }
    return "";
}

// ---------------------------------------------------------------------------
// rule(token) -> CSS body ("prop:val;prop:val"), or "" if unknown.
// It's the heart of the library; lm and sheet are just different formats of it.
// ---------------------------------------------------------------------------
fn rule(c: string): string {
    // display / flexbox
    if strEq(c, "flex") == 1 { return "display:flex"; }
    if strEq(c, "inline-flex") == 1 { return "display:inline-flex"; }
    if strEq(c, "grid") == 1 { return "display:grid"; }
    if strEq(c, "block") == 1 { return "display:block"; }
    if strEq(c, "inline-block") == 1 { return "display:inline-block"; }
    if strEq(c, "hidden") == 1 { return "display:none"; }
    if strEq(c, "flex-col") == 1 { return "flex-direction:column"; }
    if strEq(c, "flex-row") == 1 { return "flex-direction:row"; }
    if strEq(c, "flex-wrap") == 1 { return "flex-wrap:wrap"; }
    if strEq(c, "items-center") == 1 { return "align-items:center"; }
    if strEq(c, "items-start") == 1 { return "align-items:flex-start"; }
    if strEq(c, "items-end") == 1 { return "align-items:flex-end"; }
    if strEq(c, "justify-center") == 1 { return "justify-content:center"; }
    if strEq(c, "justify-between") == 1 { return "justify-content:space-between"; }
    if strEq(c, "justify-around") == 1 { return "justify-content:space-around"; }
    if strEq(c, "justify-end") == 1 { return "justify-content:flex-end"; }
    // position / misc
    if strEq(c, "relative") == 1 { return "position:relative"; }
    if strEq(c, "absolute") == 1 { return "position:absolute"; }
    if strEq(c, "overflow-hidden") == 1 { return "overflow:hidden"; }
    if strEq(c, "cursor-pointer") == 1 { return "cursor:pointer"; }
    // fixed typography
    if strEq(c, "font-bold") == 1 { return "font-weight:700"; }
    if strEq(c, "font-semibold") == 1 { return "font-weight:600"; }
    if strEq(c, "font-medium") == 1 { return "font-weight:500"; }
    if strEq(c, "font-normal") == 1 { return "font-weight:400"; }
    if strEq(c, "italic") == 1 { return "font-style:italic"; }
    if strEq(c, "underline") == 1 { return "text-decoration:underline"; }
    // borders / shadow
    if strEq(c, "rounded") == 1 { return "border-radius:0.25rem"; }
    if strEq(c, "rounded-md") == 1 { return "border-radius:0.375rem"; }
    if strEq(c, "rounded-lg") == 1 { return "border-radius:0.5rem"; }
    if strEq(c, "rounded-xl") == 1 { return "border-radius:0.75rem"; }
    if strEq(c, "rounded-full") == 1 { return "border-radius:9999px"; }
    if strEq(c, "border") == 1 { return "border:1px solid #e2e8f0"; }
    if strEq(c, "shadow") == 1 { return "box-shadow:0 1px 2px rgba(0,0,0,0.05)"; }
    if strEq(c, "shadow-md") == 1 { return "box-shadow:0 4px 6px rgba(0,0,0,0.1)"; }
    if strEq(c, "shadow-lg") == 1 { return "box-shadow:0 10px 15px rgba(0,0,0,0.1)"; }
    // fixed sizing
    if strEq(c, "w-full") == 1 { return "width:100%"; }
    if strEq(c, "h-full") == 1 { return "height:100%"; }
    if strEq(c, "w-screen") == 1 { return "width:100vw"; }
    if strEq(c, "min-h-screen") == 1 { return "min-height:100vh"; }
    if strEq(c, "mx-auto") == 1 { return "margin-left:auto;margin-right:auto"; }
    // parametric (prefix + value)
    if startsWith(c, "text-") == 1 { return text(c); }
    if startsWith(c, "bg-") == 1 { return colorCss(c); }
    if startsWith(c, "border-") == 1 { return colorCss(c); }
    if startsWith(c, "w-") == 1 { return size(c); }
    if startsWith(c, "h-") == 1 { return size(c); }
    if startsWith(c, "gap-") == 1 { return spacing(c); }
    if startsWith(c, "p") == 1 { return spacing(c); }
    if startsWith(c, "m") == 1 { return spacing(c); }
    return "";
}

// ---------------------------------------------------------------------------
// lm("classes") -> "prop:val;prop:val" for use in style="..."
// automatic purge: only existing elements produce style. no <head> needed.
// ---------------------------------------------------------------------------
fn lm(classes: string): string {
    const toks: string[] = split(classes, " ");
    let out: string = "";
    let i: i64 = 0;
    while i < len(toks) {
        const r: string = rule(toks[i]);
        if strEq(r, "") == 0 {
            out = `${out};${r}`;   // separator in front; we strip the 1st later
        }
        i = i + 1;
    }
    if len(out) > 0 {
        return substring(out, 1, len(out));
    }
    return out;
}

// ---------------------------------------------------------------------------
// sheet("classes") -> "<style>.a{...}.b{...}</style>" for the <head>.
// keeps class="..." in the markup; dedupes rules via a Map.
// ---------------------------------------------------------------------------
fn sheet(classes: string): string {
    const toks: string[] = split(classes, " ");
    let seen: Map<i64> = {};
    let css: string = "";
    let i: i64 = 0;
    while i < len(toks) {
        const c: string = toks[i];
        if strEq(c, "") == 0 {
            if mapHas(seen, c) == 0 {
                mapSet(seen, c, 1);
                const r: string = rule(c);
                if strEq(r, "") == 0 {
                    css = `${css}.${c}{${r}}`;
                }
            }
        }
        i = i + 1;
    }
    return `<style>${css}</style>`;
}
