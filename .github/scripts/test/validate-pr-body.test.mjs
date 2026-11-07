import test from "node:test";
import assert from "node:assert/strict";
import { validatePullRequest } from "../validate-pr-body.mjs";

const fullBody = `## Why
Make review safer.

## What's Included
- Add a trusted workflow.

## UI / UX
Not applicable because there is no visible change.

## Notes
Models: n/a

Merge risk: <!-- low / medium / high / unknown, the main reason, and how to recover -->
`;

const rejectionCases = [
  ...["Why", "What's Included", "UI / UX", "Notes"].map((heading) => ({
    name: `missing ${heading}`,
    body: fullBody.split(/(?=^## )/m).filter((section) => !section.startsWith(`## ${heading}\n`)).join(""),
    error: heading,
  })),
  { name: "placeholder", body: fullBody.replace("Make review safer.", "<!-- explain why -->"), error: "placeholder" },
  { name: "template instruction", body: fullBody.replace("Make review safer.", "<!-- What changed, and why should this change exist? Lead with the reviewer-facing outcome. -->"), error: "placeholder" },
  { name: "footer filling a section", body: fullBody.replace(/## Notes[\s\S]*$/, "## Notes\n") + "<!-- codesmith:footer -->\nManaged footer content.\n<!-- codesmith:autofix:enabled -->\n<!-- /codesmith:footer -->", error: "Notes" },
  { name: "blank models", body: fullBody.replace("Models: n/a", "Models: <!-- e.g. Claude Opus 5.5, or \"None\" -->"), error: "Models" },
];

test("rejects missing headings and template placeholders", () => {
  assert.equal(validatePullRequest({ body: fullBody, files: ["src/main.zig"] }).valid, true);
  for (const entry of rejectionCases) {
    assert.notEqual(entry.body, fullBody, entry.name);
    const result = validatePullRequest({ body: entry.body, files: ["src/main.zig"] });
    assert.equal(result.valid, false, entry.name);
    assert(result.errors.some((error) => error.includes(entry.error)), entry.name);
  }
});

test("accepts docs without UI and explicit model values", () => {
  const docsBody = fullBody.replace(/## UI \/ UX[\s\S]*?(?=## Notes)/, "");
  for (const models of ["None", "n/a", "gpt-6.1-sol"]) {
    const body = docsBody.replace("Models: n/a", `Models: ${models}`);
    assert.equal(validatePullRequest({ body, files: ["CONTRIBUTING.md"] }).valid, true);
    assert.equal(validatePullRequest({ body, files: ["src/main.zig"] }).valid, false);
  }
});

test("rejects an untouched template and empty bodies", async () => {
  const { readFileSync } = await import("node:fs");
  const template = readFileSync(new URL("../../pull_request_template.md", import.meta.url), "utf8");
  assert.equal(validatePullRequest({ body: template, files: ["src/main.zig"] }).valid, false);
  assert.equal(validatePullRequest({ body: "", files: [] }).valid, false);
});

test("Kody summaries cannot fill or replace author sections", () => {
  const summary = `\n<!-- kody-pr-summary:start -->\n${fullBody}\n<!-- kody-pr-summary:end -->`;
  assert.equal(validatePullRequest({ body: summary, files: ["src/main.zig"] }).valid, false);
  assert.equal(validatePullRequest({ body: fullBody.replace("Models: n/a", "Models:") + summary, files: ["src/main.zig"] }).valid, false);
  const incompleteSummary = "\n<!-- kody-pr-summary:start -->\n## Notes\nModels:\n<!-- kody-pr-summary:end -->";
  assert.equal(validatePullRequest({ body: fullBody + incompleteSummary, files: ["src/main.zig"] }).valid, true);
});
