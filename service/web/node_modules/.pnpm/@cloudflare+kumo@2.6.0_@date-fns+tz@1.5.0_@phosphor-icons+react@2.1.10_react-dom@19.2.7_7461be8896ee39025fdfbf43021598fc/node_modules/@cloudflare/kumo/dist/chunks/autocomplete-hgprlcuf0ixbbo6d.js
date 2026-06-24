"use client";
import { jsx as t, jsxs as C } from "react/jsx-runtime";
import { CheckIcon as y } from "@phosphor-icons/react";
import { createContext as v, useContext as I } from "react";
import { K as u, i as k } from "./input-f2ct7obgdzypjmp2.js";
import { c as r } from "./cn-ct4n7r74mh8y0f48.js";
import { r as E } from "./resolve-variant-gw6eh7fa4st8ej7m.js";
import { F as z } from "./field-f1hy08um3jf9jos6.js";
import { bB as T, aa as G, af as L, bA as O, ac as P, S as _, ad as w, ae as S, bz as U, an as R, ao as V, ap as F, ag as K } from "./vendor-base-ui-f9z44m829vvptrg0.js";
const p = v({
  hasError: !1
}), W = {
  size: u.size
}, l = {
  size: "base"
};
function X({
  size: o = l.size
} = {}) {
  return r(
    E(
      u.size,
      o,
      l.size
    ).classes
  );
}
function d({
  label: o,
  required: e,
  labelTooltip: s,
  description: n,
  error: a,
  children: m,
  ...i
}) {
  const g = i, c = /* @__PURE__ */ t(p.Provider, { value: { hasError: !!a }, children: /* @__PURE__ */ t(O, { ...g, children: m }) });
  return o ? /* @__PURE__ */ t(
    z,
    {
      label: o,
      required: e,
      labelTooltip: s,
      description: n,
      error: a ? typeof a == "string" ? { message: a, match: !0 } : a : void 0,
      children: c
    }
  ) : c;
}
function b({
  className: o,
  size: e = l.size,
  placeholder: s
}) {
  const { hasError: n } = I(p);
  return /* @__PURE__ */ t(
    K,
    {
      className: r(
        k({
          size: e,
          variant: n ? "error" : "default",
          focusIndicator: !0
        }),
        "w-full",
        o
      ),
      placeholder: s
    }
  );
}
function f({
  children: o,
  className: e,
  align: s = "start",
  sideOffset: n = 4,
  alignOffset: a,
  side: m
}) {
  return /* @__PURE__ */ t(R, { children: /* @__PURE__ */ t(
    V,
    {
      className: "outline-none",
      align: s,
      sideOffset: n,
      alignOffset: a,
      side: m,
      children: /* @__PURE__ */ t(
        F,
        {
          className: (i) => r(
            "flex flex-col",
            "max-h-[min(var(--available-height),24rem)] max-w-(--available-width) min-w-(--anchor-width) py-1.5",
            "bg-kumo-control text-kumo-default",
            "rounded-lg shadow-lg ring ring-kumo-line",
            i.empty && "hidden",
            e
          ),
          children: o
        }
      )
    }
  ) });
}
function M({
  className: o,
  ...e
}) {
  return /* @__PURE__ */ t(
    P,
    {
      ...e,
      className: r(
        "min-h-0 flex-1 overflow-y-auto overscroll-contain scroll-pt-2 scroll-pb-2",
        o
      )
    }
  );
}
function x({ children: o, ...e }) {
  return /* @__PURE__ */ C(
    U,
    {
      "data-kumo-component": "Autocomplete",
      "data-kumo-part": "item",
      ...e,
      className: "group mx-1.5 grid cursor-pointer grid-cols-[1fr_16px] gap-2 rounded px-2 py-1.5 text-base data-highlighted:bg-kumo-overlay data-selected:font-medium",
      children: [
        /* @__PURE__ */ t("div", { className: "col-start-1", children: o }),
        /* @__PURE__ */ t("span", { className: "col-start-2 hidden items-center group-data-selected:flex", children: /* @__PURE__ */ t(y, { size: 14 }) })
      ]
    }
  );
}
function h(o) {
  return /* @__PURE__ */ t(
    S,
    {
      ...o,
      className: r(
        "mx-1.5 px-2 py-1.5 text-sm text-kumo-strong",
        o.className
      )
    }
  );
}
function A(o) {
  return /* @__PURE__ */ t(
    w,
    {
      ...o,
      className: "border-t border-kumo-line mt-2 pt-2 first:border-t-0 first:mt-0 first:pt-0"
    }
  );
}
function N(o) {
  return /* @__PURE__ */ t(
    _,
    {
      ...o,
      className: r("mx-0 my-1 h-px bg-kumo-line", o.className)
    }
  );
}
d.displayName = "Autocomplete.Root";
b.displayName = "Autocomplete.InputGroup";
f.displayName = "Autocomplete.Content";
x.displayName = "Autocomplete.Item";
h.displayName = "Autocomplete.GroupLabel";
A.displayName = "Autocomplete.Group";
N.displayName = "Autocomplete.Separator";
const Y = Object.assign(d, {
  // Styled compound sub-components
  InputGroup: b,
  Content: f,
  Item: x,
  GroupLabel: h,
  Group: A,
  Separator: N,
  List: M,
  // Pass-through Base UI sub-components
  Empty: L,
  Collection: G,
  // Filtering
  useFilter: T
});
export {
  Y as A,
  W as K,
  X as a,
  l as b
};
//# sourceMappingURL=autocomplete-hgprlcuf0ixbbo6d.js.map
