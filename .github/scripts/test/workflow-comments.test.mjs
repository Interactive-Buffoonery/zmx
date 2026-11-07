import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const hygiene = readFileSync(new URL("../../workflows/pr-template.yml", import.meta.url), "utf8");
const size = readFileSync(new URL("../../workflows/pr-size.yml", import.meta.url), "utf8");
const human = { id: 99, user: { login: "contributor", type: "User" } };
const bot = { id: 42, user: { login: "github-actions[bot]", type: "Bot" } };

function run(script, comments) {
  const result = spawnSync("bash", ["-c", `
set -euo pipefail
gh() {
  if [[ "$*" == *--paginate* ]]; then
    local query="\${!#}"
    printf '%s' "$COMMENTS" | jq -r "$query"
  else
    printf '%s\\n' "$*" >&3
  fi
}
${script}
`], {
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe", "pipe"],
    env: { ...process.env, COMMENTS: JSON.stringify(comments), MAINTAINER_LOGINS_JSON: "[]", PR_AUTHOR: "contributor", GITHUB_REPOSITORY: "example/zmx", PR_NUMBER: "1" },
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout + result.output[3];
}

test("managed comment lookups ignore human marker copies", () => {
  for (const workflow of [hygiene, size]) {
    const lookups = [...workflow.matchAll(/          marker='([^']+)'[\s\S]*?(          comment_id="\$\([\s\S]*?\n          \)")/g)];
    assert.equal(lookups.length, workflow === hygiene ? 2 : 1);
    for (const [, marker, lookup] of lookups) {
      const script = `marker='${marker}'\n${lookup}\nprintf '%s' "$comment_id"`;
      assert.equal(run(script, [{ ...human, body: marker }]), "");
      assert.equal(run(script, [{ ...bot, body: marker }, { ...human, body: marker }]), "42");
    }
  }
});

test("external checklist preserves existing confirmations", () => {
  const section = hygiene.split("      - name: Sync external contributor checklist\n")[1].split("      - name: Require a valid description")[0];
  const script = section.split("        run: |\n")[1].replace(/^          /gm, "");
  const marker = "<!-- zmx-external-pr-checklist -->";
  assert.equal(run(script, [{ ...bot, body: `${marker}\n- [x] Reviewed` }]), "");
  assert.match(run(script, [{ ...human, body: marker }]), /--method POST/);
});
