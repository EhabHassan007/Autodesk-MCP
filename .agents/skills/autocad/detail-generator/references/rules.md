# Detail Generator rules

- Millimetres only. Never convert or reinterpret units.
- Existing layers are left as they are (their colours and lineweights are not changed). Pass `update_layers` only when the user asks for the generator's layer settings.
- **The accessible section has no built-in numbers.** It needs `accessible_height`, `knee_clearance_height`, `knee_clearance_depth` and `code_reference`, taken from the code and edition the project uses. Never fill them from memory, and never carry a figure from one jurisdiction into another. The generator prints the code reference on the drawing, marked "to be verified".
- Top material follows the item: Corian (the default) for counters, stone for kitchens and F&B.
- Do not copy dimensions or curves from one project's drawing into a default. The defaults come from conventions repeated across the office's kitchen and joinery sheets; anything specific to one counter is an option.
- **Annotation follows the reference sheets.** When the drawing has them, dimensions use style `na1`, notes and levels use text style `EN-S`, and titles use `EN-SCB`; the result lists them under `reference_styles` and says in `style_notes` which are missing. Pass `dimension_style` or `text_style` to override, or `use_reference_styles` false to use the current styles. See the reference for the numbers behind these styles.
- Dimension and text sizes depend on the style and the detail scale. In model space the generator sets each dimension's scale to the detail scale, so a 3.5 mm style prints 3.5 mm at that scale; check the first dimension on screen, and if the size is wrong pass `dimension_scale` or fix the style. In paper space the style's own size applies (no scale is set unless `dimension_scale` is given).
- If the plan is refused, the message names the step; fix the parameter and retry. A failed plan removes what it created.
