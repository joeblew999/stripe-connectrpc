"use client";
import { jsx as d, jsxs as k, Fragment as we } from "react/jsx-runtime";
import { forwardRef as he, useRef as A, useEffect as P, useCallback as be, useState as Ne, useMemo as ee, memo as $e } from "react";
import { W as Se, X as Fe, Y as Te, Z as Ie, _ as Re } from "./vendor-base-ui-f9z44m829vvptrg0.js";
import { c as B } from "./cn-ct4n7r74mh8y0f48.js";
var ye = /* @__PURE__ */ ((e) => (e.Attention = "#FC574A", e.Warning = "#F8A054", e.Success = "#00A63E", e.Neutral = "#B9D6FF", e.Disabled = "#CBCBCB", e.Skeleton = "#DDDDDD", e))(ye || {}), xe = /* @__PURE__ */ ((e) => (e.Attention = "#FC574A", e.Warning = "#F8A054", e.Success = "#00A63E", e.Neutral = "#8EC5FF", e.Disabled = "#878787", e.Skeleton = "#5C5C5C", e))(xe || {});
const Ae = {
  blues: ["#E1EAF4", "#8EBCF6", "#4290F0", "#0E58B4", "#03254F"]
}, Ce = {
  blues: ["#03254F", "#0E58B4", "#4290F0", "#A6BFDD", "#E1EAF4"]
}, le = [
  "#4290F0",
  "#F5B647",
  "#E8649D",
  "#8D58EE",
  "#50C3B6",
  "#D37536"
  /* Orange */
], ie = [
  "#4290F0",
  "#EEB720",
  "#E8649D",
  "#8D58EE",
  "#50C3B6",
  "#D37536"
  /* Orange */
];
var Y;
((e) => {
  function n(o, s = !1) {
    return s ? xe[o] : ye[o];
  }
  e.semantic = n;
  function t(o, s = !1) {
    return s ? ie[o % ie.length] : le[o % le.length];
  }
  e.categorical = t;
  function a(o, s = !1) {
    return s ? [...Ce[o]] : [...Ae[o]];
  }
  e.sequential = a;
  function r(o, s = !1) {
    const c = {
      light: { primary: "#6B7280", secondary: "#9CA3AF" },
      dark: { primary: "#9CA3AF", secondary: "#6B7280" }
    };
    return s ? c.dark[o] : c.light[o];
  }
  e.text = r;
})(Y || (Y = {}));
const me = (e) => {
  const { dangerousHtmlFormatter: n, ...t } = e;
  return {
    ...t,
    formatter: n
  };
}, Ee = ({
  options: e,
  isDarkMode: n
}) => {
  const t = {
    backgroundColor: "transparent",
    color: n ? ie : le,
    ...e
  };
  return t.tooltip ? {
    ...t,
    tooltip: Array.isArray(t.tooltip) ? t.tooltip.map(me) : me(t.tooltip)
  } : t;
}, ce = he(function({
  echarts: n,
  options: t,
  optionUpdateBehavior: a,
  className: r,
  isDarkMode: o,
  height: s = 350,
  onEvents: c
}, x) {
  const b = A(null), v = A(null), D = A({}), T = A({}), I = A(/* @__PURE__ */ new Set());
  return P(() => {
    if (!b.current) return;
    const f = n.init(b.current, o ? "dark" : void 0);
    return v.current = f, typeof x == "function" ? x(f) : x && (x.current = f), () => {
      for (const w of I.current) {
        const u = T.current[w];
        u && f.off(w, u);
      }
      I.current.clear(), typeof x == "function" ? x(null) : x && (x.current = null), v.current = null, f.dispose();
    };
  }, [b, o]), P(() => {
    const f = v.current;
    f && f.setOption(Ee({ options: t, isDarkMode: o }), {
      notMerge: !1,
      lazyUpdate: !0,
      ...a
    });
  }, [o, a, t]), P(() => {
    D.current = c ?? {};
  }, [c]), P(() => {
    const f = v.current;
    if (!f) return;
    const w = /* @__PURE__ */ new Set();
    for (const [u, N] of Object.entries(c ?? {}))
      typeof N == "function" && (w.add(u), T.current[u] || (T.current[u] = (O) => {
        D.current[u]?.(O);
      }), I.current.has(u) || f.on(u, T.current[u]));
    for (const u of I.current) {
      if (w.has(u)) continue;
      const N = T.current[u];
      N && f.off(u, N);
    }
    I.current = w;
  }, [n, o, c]), P(() => {
    const f = v.current, w = b.current;
    if (!f || !w) return;
    let u = !0;
    const N = new ResizeObserver(() => {
      if (u) {
        u = !1;
        return;
      }
      f.resize();
    });
    return N.observe(w), () => N.disconnect();
  }, []), /* @__PURE__ */ d(
    "div",
    {
      ref: b,
      className: B("w-full", r),
      style: { height: s },
      tabIndex: t.aria?.enabled ? 0 : void 0,
      role: t.aria?.enabled ? "img" : void 0
    }
  );
});
ce.displayName = "Chart";
const Be = he(function({
  echarts: n,
  type: t = "line",
  data: a,
  xAxisName: r,
  xAxisTickCount: o,
  xAxisTickFormat: s,
  yAxisTickFormat: c,
  yAxisTickLabelFormat: x,
  yAxisName: b,
  yAxisTickCount: v,
  tooltipValueFormat: D,
  onTimeRangeChange: T,
  height: I = 350,
  incomplete: f,
  enableLegendSelection: w = !1,
  isDarkMode: u,
  gradient: N,
  loading: O,
  ariaDescription: L,
  optionUpdateBehavior: te,
  tooltipMode: q = "all",
  tooltipMaxItems: V = 10,
  tooltipFollowCursor: ne = "both",
  tooltipBoundary: Z
}, G) {
  const h = A(null), $ = A(null), H = be(
    (i) => {
      h.current = i, typeof G == "function" ? G(i) : G && (G.current = i);
    },
    [G]
  ), C = A(a);
  C.current = a;
  const R = A(null);
  P(() => {
    R.current = null;
  }, [w, u]);
  const z = A(q);
  z.current = q;
  const l = A(V);
  l.current = V;
  const [m, S] = Ne(null), y = A({ x: 0, y: 0 });
  P(() => {
    const i = $.current;
    if (!i) return;
    const E = (p) => {
      const F = i.getBoundingClientRect();
      y.current = {
        x: p.clientX - F.left,
        y: p.clientY - F.top
      };
    };
    return i.addEventListener("mousemove", E), () => i.removeEventListener("mousemove", E);
  }, []);
  const M = f?.before, K = f?.after, re = ee(() => {
    const i = [], E = t === "bar" ? { type: "bar", stack: "total" } : { type: "line", showSymbol: !1 };
    for (const p of a) {
      const F = M && t === "line" ? p.data.filter((g) => g[0] <= M) : [], W = K && t === "line" ? p.data.filter((g) => g[0] >= K) : [], _ = F.length > 0 || W.length > 0 ? p.data.slice(
        Math.max(0, F.length - 1),
        Math.max(0, p.data.length - W.length + 1)
      ) : p.data, X = N && t === "line" ? {
        color: new n.graphic.LinearGradient(0, 0, 0, 1, [
          { offset: 0, color: pe(p.color, 0.4) },
          { offset: 1, color: pe(p.color, 0) }
        ])
      } : void 0;
      i.push({
        data: _,
        color: p.color,
        name: p.name,
        emphasis: { focus: "series" },
        ...X ? { areaStyle: X } : {},
        ...E
      });
      const U = {
        color: p.color,
        name: p.name,
        type: "line",
        lineStyle: { type: "dashed" },
        showSymbol: !1,
        emphasis: { focus: "series" }
      };
      F.length > 0 && i.push({
        ...U,
        data: F
      }), W.length > 0 && i.push({
        ...U,
        data: W
      });
    }
    return {
      aria: {
        enabled: !0,
        ...L && { label: { description: L } }
      },
      brush: {
        xAxisIndex: "all",
        brushType: "lineX",
        brushMode: "single",
        outOfBrush: {
          colorAlpha: 0.3
        },
        brushStyle: {
          borderWidth: 1,
          color: "rgba(120,140,180,0.3)",
          borderColor: "rgba(120,140,180,0.8)"
        }
      },
      tooltip: {
        trigger: "axis",
        showContent: !1,
        axisPointer: { type: "shadow" }
      },
      backgroundColor: "transparent",
      toolbox: { show: !1 },
      ...w ? { legend: { show: !1 } } : {},
      xAxis: {
        name: r,
        nameLocation: "middle",
        nameGap: 30,
        type: "time",
        splitLine: {
          show: !1
        },
        axisLine: { show: !1 },
        splitNumber: o ?? 5,
        ...s && {
          axisLabel: {
            formatter: (p) => s(p)
          }
        }
      },
      yAxis: {
        name: b,
        nameLocation: "middle",
        nameGap: 40,
        type: "value",
        axisTick: { show: !0 },
        axisLabel: {
          margin: 15,
          ...c && {
            formatter: (p) => c(p)
          }
        },
        splitLine: {
          show: !0,
          lineStyle: { type: "dashed", width: 1 }
        },
        splitNumber: v
      },
      grid: {
        left: b ? 30 : 24,
        right: 24,
        top: 24,
        bottom: r ? 30 : 24
      },
      series: i
    };
  }, [
    a,
    r,
    o,
    s,
    c,
    b,
    v,
    M,
    K,
    t,
    N,
    w,
    n,
    L
  ]), oe = ee(() => ({
    updateaxispointer: (i) => {
      const E = i?.axesInfo?.[0]?.value;
      if (E == null) return;
      const p = /* @__PURE__ */ new Set(), F = [], W = R.current;
      for (const g of C.current) {
        if (p.has(g.name) || W && W[g.name] === !1) continue;
        p.add(g.name);
        const j = De(g.data, E);
        j != null && F.push({ name: g.name, value: j, color: g.color });
      }
      F.sort((g, j) => j.value - g.value);
      let _, X = 0;
      if (z.current === "single") {
        const g = h.current, j = g ? g.convertFromPixel("grid", [0, y.current.y])?.[1] : null;
        j != null && F.length > 0 ? _ = [F.reduce(
          (de, fe) => Math.abs(fe.value - j) < Math.abs(de.value - j) ? fe : de
        )] : _ = F.slice(0, 1);
      } else {
        const g = l.current;
        _ = F.slice(0, g), X = Math.max(0, F.length - g);
      }
      const U = { ts: E, rows: _, hiddenCount: X };
      S((g) => Oe(g, U) ? g : U);
    },
    globalout: () => {
      S(null);
    },
    // Keep the tooltip in sync with legend selection. Each action fires a
    // different event — `legendToggleSelect` → `legendselectchanged`,
    // `legendSelect` → `legendselected`, `legendUnSelect` → `legendunselected`
    // — and all three carry the full `selected` map, so we listen to all of
    // them (params type inferred from `ChartEvents`).
    legendselectchanged: (i) => {
      R.current = i.selected;
    },
    legendselected: (i) => {
      R.current = i.selected;
    },
    legendunselected: (i) => {
      R.current = i.selected;
    },
    ...T && {
      brushend: (i) => {
        const E = i.areas[0].coordRange;
        T(E[0], E[1]), h.current?.dispatchAction({ type: "brush", areas: [] });
      }
    }
  }), [T]), J = !!T;
  P(() => {
    const i = h.current;
    if (i && J)
      return i.dispatchAction({
        type: "takeGlobalCursor",
        key: "brush",
        brushOption: {
          brushType: "lineX",
          brushMode: "single"
        }
      }), () => {
        i.dispatchAction({
          type: "takeGlobalCursor",
          key: "brush",
          brushOption: {
            brushType: !1
          }
        });
      };
  }, [h, J, O]);
  const se = D ?? x, ue = m !== null;
  return /* @__PURE__ */ k(
    Se,
    {
      open: ue,
      trackCursorAxis: ne,
      children: [
        /* @__PURE__ */ k(
          Fe,
          {
            render: /* @__PURE__ */ d(
              "div",
              {
                ref: $,
                className: "relative w-full",
                style: { height: I }
              }
            ),
            children: [
              O && /* @__PURE__ */ d(Me, { height: I, isDarkMode: u }),
              !O && /* @__PURE__ */ d(
                ce,
                {
                  echarts: n,
                  ref: H,
                  options: re,
                  height: I,
                  isDarkMode: u,
                  onEvents: oe,
                  optionUpdateBehavior: te
                }
              )
            ]
          }
        ),
        ue && /* @__PURE__ */ d(Te, { children: /* @__PURE__ */ d(
          Ie,
          {
            side: "right",
            align: "start",
            sideOffset: 12,
            collisionAvoidance: { side: "flip", align: "shift" },
            collisionBoundary: Z,
            collisionPadding: 8,
            children: /* @__PURE__ */ d(
              Re,
              {
                "data-mode": u ? "dark" : "light",
                className: "bg-kumo-base rounded-lg shadow-lg shadow-kumo-tip-shadow outline outline-1 outline-kumo-fill p-2 min-w-[150px] max-w-xs",
                children: /* @__PURE__ */ d(ke, { state: m, formatValue: se })
              }
            )
          }
        ) })
      ]
    }
  );
});
Be.displayName = "TimeseriesChart";
const ke = $e(function({
  state: n,
  formatValue: t
}) {
  const { ts: a, rows: r, hiddenCount: o } = n;
  return /* @__PURE__ */ k(we, { children: [
    /* @__PURE__ */ d("div", { className: "text-xs font-semibold text-kumo-default mb-1", children: Pe(a) }),
    r.map((s) => /* @__PURE__ */ k(
      "div",
      {
        className: "flex items-center justify-between gap-4 py-0.5",
        children: [
          /* @__PURE__ */ k("div", { className: "flex items-center gap-2 min-w-0", children: [
            /* @__PURE__ */ d(
              "span",
              {
                className: "w-3 h-3 rounded-full shrink-0",
                style: { backgroundColor: s.color }
              }
            ),
            /* @__PURE__ */ d(
              "span",
              {
                className: "text-xs font-medium text-kumo-default truncate",
                title: s.name,
                children: s.name
              }
            )
          ] }),
          /* @__PURE__ */ d("span", { className: "text-xs font-semibold text-kumo-default shrink-0", children: t ? t(s.value) : ze(s.value) })
        ]
      },
      s.name
    )),
    o > 0 && /* @__PURE__ */ k("div", { className: "text-xs text-kumo-subtle mt-1", children: [
      "+",
      o,
      " more"
    ] })
  ] });
});
function De(e, n) {
  if (e.length === 0) return null;
  let t = 0, a = e.length - 1;
  for (; t < a; ) {
    const r = t + a >> 1;
    e[r][0] < n ? t = r + 1 : a = r;
  }
  return t > 0 && Math.abs(e[t - 1][0] - n) < Math.abs(e[t][0] - n) && t--, e[t][1];
}
function Oe(e, n) {
  return !e || e.ts !== n.ts || e.hiddenCount !== n.hiddenCount || e.rows.length !== n.rows.length ? !1 : e.rows.every((t, a) => {
    const r = n.rows[a];
    return t.name === r.name && t.value === r.value && t.color === r.color;
  });
}
const Le = new Intl.NumberFormat(void 0, {
  maximumFractionDigits: 3
});
function ze(e) {
  return Number.isInteger(e) ? String(e) : Le.format(e);
}
function Me({
  height: e,
  isDarkMode: n
}) {
  const t = e / 2, a = Math.min(e * 0.12, 28), r = 400, o = 120, s = [];
  for (let b = 0; b <= o; b++) {
    const v = -r + b / o * r * 3, D = t + Math.sin(b / o * 2 * Math.PI * 3) * a;
    s.push(`${b === 0 ? "M" : "L"}${v.toFixed(2)},${D.toFixed(2)}`);
  }
  const c = s.join(" "), x = n ? "rgba(255,255,255,0.5)" : "rgba(0,0,0,0.2)";
  return /* @__PURE__ */ d(
    "div",
    {
      "aria-hidden": "true",
      className: "absolute inset-0 overflow-hidden",
      style: { height: e },
      children: /* @__PURE__ */ d(
        "svg",
        {
          width: "100%",
          height: e,
          viewBox: `0 0 ${r} ${e}`,
          preserveAspectRatio: "none",
          className: "w-full animate-pulse",
          children: /* @__PURE__ */ d(
            "path",
            {
              d: c,
              fill: "none",
              stroke: x,
              strokeWidth: "2",
              style: {
                animation: "kumo-chart-wave 2.4s linear infinite",
                transformOrigin: "0 0"
              }
            }
          )
        }
      )
    }
  );
}
function pe(e, n) {
  const t = Math.max(0, Math.min(1, n)), a = e.match(
    /rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/i
  );
  if (a)
    return `rgba(${a[1]}, ${a[2]}, ${a[3]}, ${t})`;
  let r = e.replace(/^#/, "");
  r.length === 3 && (r = r[0] + r[0] + r[1] + r[1] + r[2] + r[2]), r.length === 8 && (r = r.slice(0, 6));
  const o = parseInt(r.slice(0, 2), 16), s = parseInt(r.slice(2, 4), 16), c = parseInt(r.slice(4, 6), 16);
  return `rgba(${o}, ${s}, ${c}, ${t})`;
}
const je = new Intl.DateTimeFormat(void 0, {
  month: "short",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: !1
});
function Pe(e) {
  return je.format(new Date(e));
}
const ve = (e) => {
  e.key !== "Enter" && e.key !== " " || (e.preventDefault(), e.currentTarget.click());
};
function Ge({
  color: e,
  value: n,
  name: t,
  unit: a,
  inactive: r,
  onPointerEnter: o,
  onPointerLeave: s,
  onClick: c,
  className: x
}) {
  return /* @__PURE__ */ k(
    "div",
    {
      role: "button",
      tabIndex: c ? 0 : -1,
      className: B(
        "inline-flex flex-col gap-2 min-w-42 py-2",
        { "cursor-pointer": !!c },
        x
      ),
      onPointerEnter: o,
      onPointerLeave: s,
      onClick: c,
      onKeyDown: c ? ve : void 0,
      children: [
        /* @__PURE__ */ k("div", { className: "flex items-center gap-2", children: [
          /* @__PURE__ */ d(
            "span",
            {
              className: B("size-2 rounded-full inline-block", {
                "opacity-50": r
              }),
              style: { backgroundColor: e }
            }
          ),
          /* @__PURE__ */ d("span", { className: B("text-xs", { "opacity-50": r }), children: t })
        ] }),
        /* @__PURE__ */ k("div", { className: "flex items-baseline gap-0.5", children: [
          /* @__PURE__ */ d(
            "span",
            {
              className: B("text-lg font-medium leading-none", {
                "opacity-50": r
              }),
              children: n
            }
          ),
          a && /* @__PURE__ */ d(
            "span",
            {
              className: B("text-xs text-kumo-subtle leading-none", {
                "opacity-50": r
              }),
              children: a
            }
          )
        ] })
      ]
    }
  );
}
function He({
  color: e,
  value: n,
  name: t,
  inactive: a,
  onPointerEnter: r,
  onPointerLeave: o,
  onClick: s,
  className: c
}) {
  return /* @__PURE__ */ k(
    "div",
    {
      role: "button",
      tabIndex: s ? 0 : -1,
      className: B(
        "inline-flex items-center gap-2",
        { "cursor-pointer": !!s },
        c
      ),
      onPointerEnter: r,
      onPointerLeave: o,
      onClick: s,
      onKeyDown: s ? ve : void 0,
      children: [
        /* @__PURE__ */ d(
          "span",
          {
            className: B("size-2 rounded-full inline-block", {
              "opacity-50": a
            }),
            style: { backgroundColor: e }
          }
        ),
        /* @__PURE__ */ d("span", { className: B("text-xs", { "opacity-50": a }), children: t }),
        /* @__PURE__ */ d("span", { className: B("text-xs font-medium", { "opacity-50": a }), children: n })
      ]
    }
  );
}
const Ze = {
  SmallItem: He,
  LargeItem: Ge
}, We = (e) => e.toLocaleString();
function qe(e) {
  return typeof e == "object" && e !== null;
}
const Q = (e) => e.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;"), ge = (e) => e.replace(/[{}|]/g, (n) => `\\${n}`), ae = (e) => {
  const n = "#666";
  return !e || typeof e != "string" ? n : /^#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(e) || /^rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*(?:,\s*[\d.]+\s*)?\)$/i.test(
    e
  ) || /^hsla?\(\s*\d{1,3}\s*,\s*\d{1,3}%\s*,\s*\d{1,3}%\s*(?:,\s*[\d.]+\s*)?\)$/i.test(
    e
  ) || /^[a-z]{3,20}$/i.test(e) ? e : n;
};
function Ve({
  echarts: e,
  nodes: n,
  links: t,
  height: a = 400,
  nodeWidth: r = 8,
  nodePadding: o = 10,
  showTooltip: s = !0,
  showNodeValues: c,
  nodeLabelLayout: x = "stacked",
  formatValue: b = We,
  tooltipFormatter: v,
  defaultNodeColor: D,
  left: T,
  right: I,
  linkColor: f = "gradient",
  linkOpacity: w = 0.5,
  className: u,
  isDarkMode: N,
  onNodeClick: O,
  onLinkClick: L
}) {
  const te = n.some((h) => h.value !== void 0), q = c ?? te, V = x === "inline", ne = ee(() => {
    const h = Y.text("primary", N), $ = Y.text("secondary", N), H = n.map(
      (l, m) => l.color ?? D ?? Y.categorical(m, N)
    ), C = new Map(
      n.map((l, m) => [l.name, { ...l, computedColor: H[m] }])
    ), R = n.map((l, m) => ({
      name: l.name,
      value: l.value,
      itemStyle: {
        color: H[m]
      }
    })), z = t.map((l) => ({
      source: n[l.source]?.name ?? "",
      target: n[l.target]?.name ?? "",
      value: l.value
    }));
    return {
      backgroundColor: "transparent",
      animation: !0,
      animationDuration: 500,
      animationDurationUpdate: 300,
      animationEasingUpdate: "cubicInOut",
      tooltip: s ? {
        trigger: "item",
        triggerOn: "mousemove",
        dangerousHtmlFormatter: (l) => {
          if (!qe(l)) return "";
          if (l.dataType === "node" && l.name) {
            const m = C.get(l.name), S = ae(
              m?.computedColor ?? l.color ?? "#666"
            );
            if (v)
              return v({
                type: "node",
                name: l.name,
                node: m,
                color: S
              });
            const y = Q(l.name);
            return `<div style="display:flex;align-items:center;gap:6px;"><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:${S}"></span><strong>${y}</strong></div>`;
          }
          if (l.dataType === "edge" && l.data) {
            const { source: m, target: S, value: y } = l.data;
            if (v)
              return v({
                type: "link",
                name: `${m} → ${S}`,
                link: {
                  source: m ?? "",
                  target: S ?? "",
                  value: y ?? 0
                }
              });
            const M = C.get(m ?? ""), K = C.get(S ?? ""), re = ae(
              M?.computedColor ?? "#666"
            ), oe = ae(
              K?.computedColor ?? "#666"
            ), J = Q(m ?? ""), se = Q(S ?? "");
            return `<div style="display:flex;align-items:center;gap:6px;margin-bottom:4px;">
                  <span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:${re}"></span>
                  <strong>${J}</strong>
                  <span style="color:${$}">→</span>
                  <span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:${oe}"></span>
                  <strong>${se}</strong>
                </div>
                <strong>${y !== void 0 ? Q(b(y)) : ""}</strong>`;
          }
          return "";
        }
      } : void 0,
      series: [
        {
          type: "sankey",
          ...T !== void 0 && { left: T },
          ...I !== void 0 && { right: I },
          data: R,
          links: z,
          draggable: !1,
          emphasis: {
            focus: "adjacency"
          },
          nodeWidth: r,
          nodeGap: o,
          lineStyle: {
            color: f === "gradient" ? "source" : "#d1d5db",
            opacity: f === "gradient" ? w : 0.4,
            curveness: 0.5
          },
          label: {
            show: !0,
            color: h,
            fontSize: 12,
            formatter: q ? (l) => {
              const m = l.name ?? "", S = C.get(m), y = ge(m);
              if (S?.value !== void 0) {
                const M = ge(
                  b(S.value)
                );
                return V ? `{name|${y}} {value|${M}}` : `{value|${M}}
{name|${y}}`;
              }
              return y;
            } : void 0,
            rich: q ? {
              value: {
                fontSize: 11,
                color: h,
                lineHeight: V ? void 0 : 16
              },
              name: {
                fontSize: 12,
                color: h,
                fontWeight: 700
              }
            } : void 0
          }
        }
      ]
    };
  }, [
    n,
    t,
    s,
    r,
    o,
    D,
    T,
    I,
    N,
    f,
    w,
    q,
    V,
    b,
    v
  ]), Z = be(
    (h) => {
      if (h.dataType === "node" && O && h.name) {
        const $ = n.findIndex((R) => R.name === h.name), C = {
          ...$ >= 0 ? n[$] : null,
          name: h.name
        };
        O(C);
      } else if (h.dataType === "edge" && L && h.data) {
        const $ = h.data, H = typeof $ == "object" && $ !== null && "source" in $ ? String($.source) : "", C = typeof $ == "object" && $ !== null && "target" in $ ? String($.target) : "", R = n.findIndex((y) => y.name === H), z = n.findIndex((y) => y.name === C);
        if (R === -1 || z === -1) return;
        const l = h.value, m = typeof l == "number" ? l : Array.isArray(l) && typeof l[0] == "number" ? l[0] : 0, S = t.find(
          (y) => y.source === R && y.target === z
        );
        L({
          ...S,
          source: R,
          target: z,
          value: m
        });
      }
    },
    [n, t, O, L]
  ), G = ee(
    () => ({
      click: Z
    }),
    [Z]
  );
  return /* @__PURE__ */ d(
    ce,
    {
      echarts: e,
      options: ne,
      className: u,
      isDarkMode: N,
      height: a,
      onEvents: G
    }
  );
}
Ve.displayName = "SankeyChart";
export {
  ce as C,
  Ve as S,
  Be as T,
  Ze as a,
  Y as b
};
//# sourceMappingURL=SankeyChart-g1tng405ml2e0qg2.js.map
