import { default as React } from 'react';
import { Toolbar as ToolbarBase } from '@base-ui/react/toolbar';
import { ButtonProps } from '../button/button';
import { InputProps } from '../input/input';
import { InputGroup } from '../input-group/input-group';
export declare const KUMO_TOOLBAR_VARIANTS: {
    readonly size: {
        readonly xs: {
            readonly classes: "text-xs";
            readonly description: "Extra small toolbar for compact UIs";
        };
        readonly sm: {
            readonly classes: "text-xs";
            readonly description: "Small toolbar for secondary controls";
        };
        readonly base: {
            readonly classes: "text-base";
            readonly description: "Default toolbar size";
        };
        readonly lg: {
            readonly classes: "text-base";
            readonly description: "Large toolbar for prominent controls";
        };
    };
};
export declare const KUMO_TOOLBAR_DEFAULT_VARIANTS: {
    readonly size: "base";
};
export type ToolbarSize = keyof typeof KUMO_TOOLBAR_VARIANTS.size;
export interface ToolbarProps extends Omit<ToolbarBase.Root.Props, "children"> {
    /** Toolbar controls rendered as one grouped card. */
    children: React.ReactNode;
    /** Locks every toolbar item to this size. */
    size?: ToolbarSize;
}
export type ToolbarButtonProps = Omit<ButtonProps, "size" | "variant"> & Pick<ToolbarBase.Button.Props, "focusableWhenDisabled">;
export type ToolbarInputProps = Omit<InputProps, "size" | "variant" | "label" | "labelTooltip" | "description" | "hideLabel" | "error" | "passwordManagerIgnore" | "render"> & {
    /** When `true`, the item remains focusable when disabled. */
    focusableWhenDisabled?: ToolbarBase.Input.Props["focusableWhenDisabled"];
};
export type ToolbarInputGroupProps = Omit<React.ComponentPropsWithoutRef<typeof InputGroup>, "size">;
export declare const Toolbar: React.ForwardRefExoticComponent<Omit<ToolbarProps, "ref"> & React.RefAttributes<HTMLDivElement>> & {
    Button: React.ForwardRefExoticComponent<Omit<ButtonProps, "variant" | "size"> & Pick<import('@base-ui/react').ToolbarButtonProps, "focusableWhenDisabled"> & React.RefAttributes<HTMLButtonElement>>;
    Input: React.ForwardRefExoticComponent<Omit<InputProps, "error" | "variant" | "description" | "size" | "label" | "render" | "labelTooltip" | "hideLabel" | "passwordManagerIgnore"> & {
        /** When `true`, the item remains focusable when disabled. */
        focusableWhenDisabled?: ToolbarBase.Input.Props["focusableWhenDisabled"];
    } & React.RefAttributes<HTMLInputElement>>;
    InputGroup: React.ForwardRefExoticComponent<ToolbarInputGroupProps & React.RefAttributes<HTMLElement>>;
};
//# sourceMappingURL=toolbar.d.ts.map