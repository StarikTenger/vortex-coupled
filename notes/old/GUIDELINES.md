# GUIDELINES.md

## Purpose
These guidelines describe how an AI assistant should write technical notes in this repository.

## General note-writing rules
- Write for engineers who will use the note later without extra context.
- Prefer concrete findings over speculation.
- Separate facts, interpretations, and recommendations clearly.
- Keep structure shallow and easy to scan.
- Use short sections with descriptive headings.
- Prefer bullet lists over long paragraphs.
- State assumptions explicitly when something is inferred rather than confirmed.
- If a claim depends on code evidence, include a file link.
- Summarize the architectural takeaway, not just raw file names.

## What a good note should contain
- The goal or question being answered.
- The files or subsystems inspected.
- The important findings.
- The practical implications of those findings.
- Recommended next steps, if relevant.

## Style rules
- Be concise and technical.
- Avoid filler and repetition.
- Use repository-relative Markdown links for files.
- Notes live in the `/notes` folder, so links written inside notes should normally start with `../`.
- This `../` rule applies to links written in note content, not to external previews or UI-generated link previews.
- Prefer consistent naming for sections such as:
  - `Scope`
  - `Findings`
  - `Boundaries`
  - `Recommendations`
  - `Next steps`

## Code reference rules
- When referencing a whole file, use a normal relative Markdown link.
  - Example inside a note: `[sim/simx/core.cpp](../sim/simx/core.cpp)`
- When referencing a specific line, the visible link text must include the line number.
  - Example inside a note: `[sim/simx/core.cpp L205](../sim/simx/core.cpp#L205)`
- When referencing a line range, VS Code-compatible links must still target a single line anchor.
  - Put the full range in the link text.
  - Anchor the URL to the first line only.
  - Example inside a note: `[sim/simx/emulator.cpp L284-L298](../sim/simx/emulator.cpp#L284)`
- Do not use `#Lx-Ly` in the URL target.
- Do not mention bare line numbers in prose when a link should be used.

## Boundary-analysis rules
When writing architecture or extraction notes:
- Identify what should be kept.
- Identify what should be replaced.
- Call out hidden couplings.
- Distinguish timing-only integration from functionally authoritative integration.
- Highlight root-cause blockers, not just symptoms.

## Evidence rules
- Prefer direct inspection of source files over guesswork.
- If something was not found, say that explicitly.
- If coverage is partial, state what was searched.

## Editing rules for notes
- Preserve existing note intent unless the task requires restructuring.
- Avoid changing terminology mid-note.
- Keep link formatting consistent throughout the file.
- **When creating a new note, update [README.md](README.md) with a link and brief description in the appropriate section.**
