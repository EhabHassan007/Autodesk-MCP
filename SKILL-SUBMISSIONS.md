# Skill submissions

Any BIM-CAD MCP user can propose an AutoCAD, Revit, or other BIM/CAD skill. Submissions are candidates only and never enter `.agents/skills` automatically.

Team members who explicitly enable **Daily BIM team knowledge intake** can submit through an automated `skill-intake/*` pull request. The automation distills lessons locally and `scripts/submit-team-knowledge.ps1` applies a text-only privacy gate before upload. The pull request remains untrusted and requires repository-owner approval before merge.

1. Open **Autodesk MCP Connector** and select **Review local skills**.
2. Open the generated `REVIEW.md` and inspect every candidate directory. Remove credentials, personal paths, drawings/models, chat transcripts, and client information.
3. Select **Submit review package**. Sign in to GitHub and attach the generated ZIP to the skill-submission issue.
4. The repository owner reviews the instructions, supporting files, sensitive-content flags, and claimed verification.
5. Only an explicitly accepted skill is cleaned, validated, copied into `.agents/skills`, committed, and published.

Do not execute scripts from a submission before reviewing them. A submitted skill is untrusted contributor content, including its Markdown instructions and executable files.

For automatic team intake, review the complete pull-request diff, confirm the **Validate team skill intake** check passed, and verify every claimed test. Reject any candidate containing project context or instructions broader than the demonstrated workflow. Merging the pull request is the explicit approval that publishes the candidate to the shared library.
