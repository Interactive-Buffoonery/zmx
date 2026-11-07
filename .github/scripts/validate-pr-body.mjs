#!/usr/bin/env node

import { appendFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const fullSections = ["Why", "What's Included", "UI / UX", "Notes"];
const docsSections = ["Why", "What's Included", "Notes"];
const marker = "<!-- zmx-pr-template-validation -->";
const codesmithFooterPattern =
  /<!-- codesmith:footer -->[\s\S]*?<!-- \/codesmith:footer -->/g;
const templatePlaceholderHints = [
  "explain why",
  "what changed, and why should this change exist",
  "keep this skimmable",
  "required for visible ui",
  "image/video/link",
];

function normalizeHeading(value) {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

export function parseSections(body) {
  const sections = new Map();
  let currentHeading = null;

  for (const line of body.split("\n")) {
    const heading = line.match(/^##\s+(.+?)\s*#*\s*$/);
    if (heading) {
      currentHeading = normalizeHeading(heading[1]);
      sections.set(currentHeading, []);
      continue;
    }
    if (currentHeading) sections.get(currentHeading).push(line);
  }

  return sections;
}

function visibleText(lines) {
  return lines
    .join("\n")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/^\s*[-*]\s*$/gm, "")
    .replace(/^\s*\|(?:\s*:?-+:?\s*\|)+\s*$/gm, "")
    .replace(/[|`*_#>[\]()!-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function isDocsOnly(files) {
  return files.length > 0 && files.every((file) => {
    const lower = file.toLowerCase();
    return (
      lower.endsWith(".md") ||
      lower.endsWith(".txt") ||
      lower.endsWith(".rst") ||
      lower.startsWith("docs/") ||
      ["license", "notice", "authors", "code_of_conduct.md"].includes(lower)
    );
  });
}

function hasModels(text) {
  // Emphasis is stripped first so `**Models:**` reads the same as `Models:`.
  return /^[ \t]*(?:[-*][ \t]*)?models:[ \t]*\S/im.test(
    text.replace(/<!--[\s\S]*?-->/g, "").replace(/[*_`]/g, ""),
  );
}

function hasTemplatePlaceholder(body) {
  const comments = body.match(/<!--[\s\S]*?-->/g) || [];
  return comments.some((comment) => {
    const normalized = comment.toLowerCase().replace(/\s+/g, " ");
    return templatePlaceholderHints.some((hint) => normalized.includes(hint));
  });
}

export function validatePullRequest({ body = "", files = [] }) {
  const bodyWithoutManagedFooters = body.replace(codesmithFooterPattern, "");
  const sections = parseSections(bodyWithoutManagedFooters);
  const docsOnly = isDocsOnly(files);
  const required = docsOnly ? docsSections : fullSections;
  const errors = [];

  for (const section of required) {
    const lines = sections.get(normalizeHeading(section));
    if (!lines) {
      errors.push(`Add the \`${section}\` section.`);
      continue;
    }
    if (!visibleText(lines)) errors.push(`Fill in the \`${section}\` section.`);
  }

  if (hasTemplatePlaceholder(bodyWithoutManagedFooters)) {
    errors.push("Remove all leftover placeholder comments from the PR description.");
  }

  const notes = sections.get(normalizeHeading("Notes"));
  if (notes && !hasModels(notes.join("\n"))) {
    errors.push("List the models used after `Models:` under `Notes`, or write None.");
  }

  return { valid: errors.length === 0, docsOnly, errors };
}

export function formatFailure(errors) {
  const items = errors.map((error) => `- ${error}`).join("\n");
  return `${marker}\n## PR description needs attention\n\n${items}\n\nEdit the PR description and this check will run again.`;
}

function readJsonEnv(name, fallback) {
  try {
    return JSON.parse(process.env[name] || JSON.stringify(fallback));
  } catch {
    return fallback;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const result = validatePullRequest({
    body: process.env.PR_BODY || "",
    files: readJsonEnv("PR_FILES_JSON", []),
  });
  const output = process.env.GITHUB_OUTPUT;
  if (output) {
    appendFileSync(output, `valid=${result.valid}\n`);
    appendFileSync(output, `message<<PR_VALIDATION_EOF\n${formatFailure(result.errors)}\nPR_VALIDATION_EOF\n`);
  }
  console.log(
    result.valid
      ? `PR description is valid (${result.docsOnly ? "docs-only" : "full"} template).`
      : result.errors.join("\n"),
  );
}
