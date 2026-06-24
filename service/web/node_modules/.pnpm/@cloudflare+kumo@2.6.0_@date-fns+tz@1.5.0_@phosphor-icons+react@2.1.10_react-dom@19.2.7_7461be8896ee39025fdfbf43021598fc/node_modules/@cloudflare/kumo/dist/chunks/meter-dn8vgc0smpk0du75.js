"use client";
import { jsxs as r, jsx as e, Fragment as d } from "react/jsx-runtime";
import { c as t } from "./cn-ct4n7r74mh8y0f48.js";
import { a$ as c, b0 as f, b1 as b, b2 as x, b3 as h } from "./vendor-base-ui-f9z44m829vvptrg0.js";
function N({
  value: l,
  customValue: a,
  label: s,
  showValue: n = !0,
  className: o,
  trackClassName: m,
  indicatorClassName: u,
  ...i
}) {
  return /* @__PURE__ */ r(
    c,
    {
      value: l,
      ...i,
      className: t("flex w-full flex-col gap-2", o),
      children: [
        /* @__PURE__ */ r("div", { className: "flex items-center justify-between gap-4", children: [
          /* @__PURE__ */ e(f, { className: "text-xs text-kumo-subtle", children: s }),
          a ? /* @__PURE__ */ e("span", { className: "text-sm font-medium text-kumo-default tabular-nums", children: a }) : /* @__PURE__ */ e(d, { children: n && /* @__PURE__ */ e(b, { className: "text-sm font-medium text-kumo-default tabular-nums" }) })
        ] }),
        /* @__PURE__ */ e(
          x,
          {
            className: t(
              "relative h-2 w-full overflow-hidden rounded-full bg-kumo-fill",
              m
            ),
            children: /* @__PURE__ */ e(
              h,
              {
                className: t(
                  "absolute inset-y-0 left-0 rounded-full bg-linear-to-r from-kumo-brand via-kumo-brand to-kumo-brand transition-[width] duration-300 ease-out",
                  u
                )
              }
            )
          }
        )
      ]
    }
  );
}
export {
  N as M
};
//# sourceMappingURL=meter-dn8vgc0smpk0du75.js.map
