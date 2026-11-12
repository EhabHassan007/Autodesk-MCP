# Literal TEXT and MTEXT

Capture a local before-record keyed by drawing path and handle: original content, entity type, layer, color, height, rotation, insertion point, and any exposed text style, width, attachment/alignment, or line-spacing properties. Supplemental non-UI API reads may supply properties that the connector omits. Do not claim verification of properties that were unavailable.

For MTEXT, change only the literal project-name substring inside the original `TextString`. Preserve formatting groups and controls, including font runs (`\f...;`), color (`\C...;`), height overrides (`\H...;`), paragraph/alignment settings, and intentional paragraph breaks (`\P`). Escape backslashes as required by the tool-call serialization; do not add literal duplicate backslashes to the stored text. Replacing the entire formatted string with plain text loses inline styling even when the entity's style name is unchanged.

Immediately before writing, re-read the object and confirm that its text still matches the before-record. Use `edit_entity` with `action: replace_text` and the complete original formatted string containing only the requested wording substitution. Keep the existing height, width, position, alignment, font, and color. Do not shrink or move the title simply because the new name is longer. Report any demonstrated fit problem separately.

Process drawings and mutations sequentially; the active drawing can change between calls. After a failed or interrupted write, re-read the identity and target before deciding whether to retry. Undo groups are not atomic transactions.
