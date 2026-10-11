---
name: cad-skill-library
description: Save or update reusable AutoCAD, Revit, and other CAD/BIM Codex skills in the BIM-CAD---MCP GitHub repository and synchronize them across computers.
---

# CAD/BIM skill library

Treat the clone's `.agents/skills` directory as the source of truth. Use this skill when the user asks to save, preserve, share, publish, or update a reusable CAD/BIM workflow as a skill.

1. Work in a clone of the `BIM-CAD---MCP` repository. If the current project is elsewhere, locate an existing clone or ask the user to clone/open it; never invent a local path.
2. Create or update `.agents/skills/<skill-name>/SKILL.md` and only the scripts, references, or assets the workflow needs. Keep names lowercase and hyphenated. Record demonstrated behavior accurately and distinguish mock, file, and live application verification.
3. Keep drawings, models, credentials, chat transcripts, generated logs, temporary outputs, and client project data out of the skill library. Check for personal absolute paths and expired local references before publishing.
4. Run `scripts/sync-codex-skills.ps1 -Action Publish -Message "<concise change>"`. It validates the library, commits only `.agents/skills`, rebases on `origin/main`, pushes, and installs the library for the current Codex user.
5. If GitHub authentication, network access, or a merge conflict blocks publishing, preserve the local commit and give the user the exact recovery step. Do not force-push or discard either version.

On another computer, clone the repository and run `scripts/sync-codex-skills.ps1 -Action Update`. Restart Codex if newly installed skills are not discovered immediately.
