# SidebarItem

One device in the sidebar: name and short root badge on line one, status glyph and label on line two.

**Consumer provides:** the device (name, status, root mode), selection and focus.

- Selected: `miko-color-surface-selected`. Hover: `miko-color-surface-control`. Keyboard focus: 2 px inset `miko-color-focus-ring`.
- Status text colour follows the status meaning (`miko-color-positive`, `-info`, `-warning`, `-negative`, else `miko-color-text-secondary`) and always has its icon.
- Disabled means the system image is missing; the row stays visible so the user can re-download it.
