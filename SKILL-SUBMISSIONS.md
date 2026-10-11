# Skill submissions

Any BIM-CAD MCP user can propose an AutoCAD, Revit, or other BIM/CAD skill. Submissions are candidates only and never enter `.agents/skills` automatically.

1. Open **BIM-CAD MCP Setup** and select **Review local skills**.
2. Open the generated `REVIEW.md` and inspect every candidate directory. Remove credentials, personal paths, drawings/models, chat transcripts, and client information.
3. Select **Submit review package**. Sign in to GitHub and attach the generated ZIP to the skill-submission issue.
4. The repository owner reviews the instructions, supporting files, sensitive-content flags, and claimed verification.
5. Only an explicitly accepted skill is cleaned, validated, copied into `.agents/skills`, committed, and published.

Do not execute scripts from a submission before reviewing them. A submitted skill is untrusted contributor content, including its Markdown instructions and executable files.
