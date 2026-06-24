"use client";
import { jsx as t } from "react/jsx-runtime";
import i, { createContext as w, Children as B, isValidElement as k, cloneElement as C } from "react";
import { c as T } from "./cn-ct4n7r74mh8y0f48.js";
import { B as f } from "./button-gtdhvogt5rlrf1is.js";
import { I as A } from "./input-f2ct7obgdzypjmp2.js";
import { I as L } from "./input-group-kcd3jin5pbdijmw8.js";
import { aq as O, ar as x, as as _ } from "./vendor-base-ui-f9z44m829vvptrg0.js";
const h = {
  size: {
    xs: {
      classes: "text-xs",
      description: "Extra small toolbar for compact UIs"
    },
    sm: {
      classes: "text-xs",
      description: "Small toolbar for secondary controls"
    },
    base: {
      classes: "text-base",
      description: "Default toolbar size"
    },
    lg: {
      classes: "text-base",
      description: "Large toolbar for prominent controls"
    }
  }
}, z = {
  size: "base"
}, p = w({
  size: z.size
});
function b(o) {
  return T(
    "relative min-w-0 border-0 bg-transparent shadow-none ring-0 focus:z-2 focus-within:z-2 focus-visible:z-2",
    "rounded-none first:rounded-l-lg last:rounded-r-lg only:rounded-lg",
    "not-first:border-l not-first:border-kumo-line",
    "focus:ring-kumo-focus/50 focus:ring-[1.5px] focus-visible:ring-2 focus-visible:ring-kumo-brand",
    o
  );
}
const g = i.forwardRef(
  ({
    children: o,
    className: r,
    size: a = z.size,
    ...e
  }, n) => /* @__PURE__ */ t(
    O,
    {
      ref: n,
      "data-kumo-component": "Toolbar",
      className: T(
        "inline-flex w-fit items-stretch rounded-lg ring ring-kumo-line bg-kumo-control shadow-xs",
        h.size[a].classes,
        r
      ),
      ...e,
      children: /* @__PURE__ */ t(p.Provider, { value: { size: a }, children: o })
    }
  )
);
g.displayName = "Toolbar";
const y = i.forwardRef(
  ({
    children: o,
    className: r,
    disabled: a,
    loading: e,
    shape: n,
    icon: l,
    type: u,
    ...c
  }, s) => {
    const m = i.useContext(p), d = n ?? (o == null && l ? "square" : "base"), R = c["aria-label"], v = d === "base" ? /* @__PURE__ */ t(
      f,
      {
        className: b(r),
        disabled: a,
        icon: l,
        loading: e,
        shape: "base",
        size: m.size,
        type: u ?? "button",
        variant: "ghost",
        children: o
      }
    ) : /* @__PURE__ */ t(
      f,
      {
        "aria-label": R,
        className: b(r),
        disabled: a,
        icon: l,
        loading: e,
        shape: d,
        size: m.size,
        type: u ?? "button",
        variant: "ghost",
        children: o
      }
    );
    return /* @__PURE__ */ t(
      _,
      {
        ref: s,
        "data-kumo-component": "Toolbar.Button",
        disabled: e || a,
        render: v,
        ...c
      }
    );
  }
);
y.displayName = "Toolbar.Button";
const I = i.forwardRef(
  ({ className: o, style: r, ...a }, e) => {
    const n = i.useContext(p), l = typeof o == "function" ? (u) => b(o(u)) : b(o);
    return /* @__PURE__ */ t(
      x,
      {
        ref: e,
        "data-kumo-component": "Toolbar.Input",
        render: /* @__PURE__ */ t(
          A,
          {
            className: l,
            size: n.size,
            style: r
          }
        ),
        ...a
      }
    );
  }
);
I.displayName = "Toolbar.Input";
const N = i.forwardRef(
  ({ children: o, className: r, ...a }, e) => {
    const n = i.useContext(p), l = a["aria-label"], u = a["aria-labelledby"], c = B.map(o, (s) => !k(s) || s.type?.displayName !== "InputGroup.Input" ? s : /* @__PURE__ */ t(
      x,
      {
        "aria-label": s.props["aria-label"] ?? l,
        "aria-labelledby": s.props["aria-labelledby"] ?? u,
        render: C(s)
      }
    ));
    return /* @__PURE__ */ t(
      L,
      {
        ref: e,
        className: b(r),
        size: n.size,
        ...a,
        children: c
      }
    );
  }
);
N.displayName = "Toolbar.InputGroup";
const G = Object.assign(g, {
  Button: y,
  Input: I,
  InputGroup: N
});
G.displayName = "Toolbar";
export {
  h as K,
  G as T,
  z as a
};
//# sourceMappingURL=toolbar-o7xe6pd189evdd53.js.map
