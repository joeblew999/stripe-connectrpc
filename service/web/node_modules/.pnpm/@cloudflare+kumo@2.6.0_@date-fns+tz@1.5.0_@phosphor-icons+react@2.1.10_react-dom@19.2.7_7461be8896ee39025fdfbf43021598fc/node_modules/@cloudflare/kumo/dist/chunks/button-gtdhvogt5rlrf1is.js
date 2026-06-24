"use client";
import { jsx as n, jsxs as x, Fragment as w } from "react/jsx-runtime";
import y from "react";
import { ArrowsClockwise as R } from "@phosphor-icons/react";
import { L as C } from "./loader-g8a6j76ue5nq0lr8.js";
import { T as U } from "./tooltip-eqnhjdbvwapy8gj4.js";
import { c as b } from "./cn-ct4n7r74mh8y0f48.js";
import { r as d } from "./resolve-variant-gw6eh7fa4st8ej7m.js";
import { u as D } from "./link-provider-mn2voeohon7cj9o4.js";
const m = {
  shape: {
    base: {
      classes: "",
      description: "Default rectangular button shape"
    },
    square: {
      classes: "items-center justify-center p-0",
      description: "Square button for icon-only actions"
    },
    circle: {
      classes: "items-center justify-center p-0 rounded-full",
      description: "Circular button for icon-only actions"
    }
  },
  size: {
    xs: {
      classes: "h-5 gap-1 rounded-sm px-1.5 text-xs",
      description: "Extra small button for compact UIs"
    },
    sm: {
      classes: "h-6.5 gap-1 rounded-md px-2 text-xs",
      description: "Small button for secondary actions"
    },
    base: {
      classes: "h-9 gap-1.5 rounded-lg px-3 text-base",
      description: "Default button size"
    },
    lg: {
      classes: "h-10 gap-2 rounded-lg px-4 text-base",
      description: "Large button for primary CTAs"
    }
  },
  compactSize: {
    xs: { classes: "size-3.5" },
    sm: { classes: "size-6.5" },
    base: { classes: "size-9" },
    lg: { classes: "size-10" }
  },
  variant: {
    primary: {
      classes: "relative overflow-hidden bg-(--kumo-button-emphasis-bg) !text-white ring ring-(--kumo-button-emphasis-ring) disabled:opacity-50",
      description: "High-emphasis button for primary actions"
    },
    secondary: {
      classes: "bg-kumo-base !text-kumo-default ring not-disabled:hover:bg-kumo-tint disabled:bg-kumo-base/50 disabled:!text-kumo-default/70 ring-kumo-line data-[state=open]:bg-kumo-base",
      description: "Default button style for most actions"
    },
    ghost: {
      classes: "text-kumo-default hover:bg-kumo-tint shadow-none bg-inherit",
      description: "Minimal button with no background"
    },
    destructive: {
      classes: "relative overflow-hidden bg-(--kumo-button-emphasis-bg) !text-white ring ring-(--kumo-button-emphasis-ring) disabled:opacity-50",
      description: "Danger button for destructive actions like delete"
    },
    "secondary-destructive": {
      classes: "bg-kumo-base !text-kumo-danger ring not-disabled:hover:!text-kumo-danger not-disabled:hover:ring-kumo-danger/30 disabled:bg-kumo-base/50 disabled:!text-kumo-danger/70 ring-kumo-line data-[state=open]:bg-kumo-base",
      description: "Secondary button with destructive text for less prominent dangerous actions"
    },
    outline: {
      classes: "bg-transparent text-kumo-default ring ring-kumo-line transition-colors not-disabled:hover:text-kumo-strong not-disabled:hover:ring-kumo-focus/25",
      description: "Bordered button with transparent background"
    }
  }
}, a = {
  shape: "base",
  size: "base",
  variant: "secondary"
};
function N({
  variant: e = a.variant,
  size: t = a.size,
  shape: s = a.shape
} = {}) {
  const o = s === "square" || s === "circle";
  return b(
    // Base styles
    "group flex w-max shrink-0 items-center font-medium select-none",
    "border-0 shadow-xs",
    "focus:outline-none focus:ring-kumo-focus/50 focus-visible:ring-2 focus-visible:ring-kumo-brand",
    "cursor-pointer",
    // Disabled state
    "disabled:cursor-not-allowed disabled:text-kumo-subtle",
    d(
      m.size,
      t,
      a.size
    ).classes,
    d(
      m.shape,
      s,
      a.shape
    ).classes,
    o && d(
      m.compactSize,
      t,
      a.size
    ).classes,
    d(
      m.variant,
      e,
      a.variant
    ).classes
  );
}
const B = (e) => e ? y.isValidElement(e) ? e : /* @__PURE__ */ n(e, {}) : null, S = (e) => {
  if (e === "primary") return "var(--color-kumo-brand)";
  if (e === "destructive") return "var(--color-kumo-danger)";
}, T = (e) => {
  const t = S(e);
  if (t)
    return {
      "--kumo-button-emphasis-ring": `color-mix(in oklch, ${t}, black 10%)`,
      "--kumo-button-emphasis-bg": `color-mix(in oklch, ${t}, white 30%)`,
      "--kumo-button-emphasis-gradient-start": `color-mix(in oklch, ${t}, white 15%)`,
      "--kumo-button-emphasis-gradient-end": t
    };
}, L = (e, t, s) => {
  const o = s != null ? /* @__PURE__ */ n("span", { className: "contents", children: s }) : null;
  return S(e) ? /* @__PURE__ */ x(w, { children: [
    /* @__PURE__ */ n(
      "span",
      {
        "aria-hidden": "true",
        className: "absolute inset-0 rounded-[inherit] bg-linear-to-b from-(--kumo-button-emphasis-gradient-start) to-(--kumo-button-emphasis-gradient-end) translate-y-px group-hover:from-(--kumo-button-emphasis-bg)"
      }
    ),
    /* @__PURE__ */ x("span", { className: "relative flex items-center gap-1.5", children: [
      t,
      o
    ] })
  ] }) : /* @__PURE__ */ x(w, { children: [
    t,
    o
  ] });
}, _ = y.forwardRef(
  ({
    children: e,
    className: t,
    disabled: s,
    loading: o,
    shape: p = "base",
    size: u = "base",
    variant: r = "secondary",
    icon: g,
    style: i,
    title: c,
    ...h
  }, f) => {
    const { type: l, ...k } = h, v = T(r), A = o ? /* @__PURE__ */ n(C, { size: u === "lg" ? 16 : 14 }) : B(g), z = /* @__PURE__ */ n(
      "button",
      {
        ref: f,
        "data-kumo-component": "Button",
        className: b(
          N({ variant: r, size: u, shape: p }),
          s && "cursor-not-allowed opacity-50",
          t
        ),
        disabled: o || s,
        style: v ? { ...v, ...i } : i,
        type: l ?? "button",
        ...k,
        children: L(r, A, e)
      }
    );
    return c ? /* @__PURE__ */ n(U, { content: c, render: z }) : z;
  }
);
_.displayName = "Button";
const P = ({
  "aria-label": e = "Refresh",
  loading: t,
  ...s
}) => /* @__PURE__ */ n(_, { shape: "square", "aria-label": e, ...s, children: /* @__PURE__ */ n(
  R,
  {
    className: b({
      "animate-refresh": t,
      "size-4.5": s.size === "base" || !s.size,
      "size-4": s.size === "sm",
      "size-5": s.size === "lg"
    })
  }
) }), E = y.forwardRef(
  ({
    children: e,
    className: t,
    external: s,
    href: o,
    shape: p = "base",
    size: u = "base",
    variant: r = "ghost",
    icon: g,
    style: i,
    // linksExternal = false,
    ...c
  }, h) => {
    const f = D(), l = T(r), k = s ? { target: "_blank", rel: "noopener noreferrer" } : {};
    return /* @__PURE__ */ n(
      f,
      {
        ref: h,
        "data-kumo-component": "LinkButton",
        className: b(
          N({ variant: r, size: u, shape: p }),
          "flex items-center no-underline!",
          t
        ),
        href: o,
        style: l ? { ...l, ...i } : i,
        to: typeof o == "string" ? o : void 0,
        ...k,
        ...c,
        children: L(r, B(g), e)
      }
    );
  }
);
E.displayName = "LinkButton";
export {
  _ as B,
  E as L,
  P as R,
  N as b
};
//# sourceMappingURL=button-gtdhvogt5rlrf1is.js.map
