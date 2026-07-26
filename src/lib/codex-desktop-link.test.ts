import { describe, expect, it } from "bun:test";

import { buildCodexInstallUrl } from "@/lib/codex-desktop-link";

describe("buildCodexInstallUrl", () => {
  it("builds the install link OpenAI's JSON-LD advertises", () => {
    const url = buildCodexInstallUrl({
      displayName: "Boba",
      description: "A calm companion.",
      spritesheetUrl: "https://cdn.petdex.dev/pets/boba/spritesheet.png",
    });
    expect(url).toBe(
      "codex://pets/install?name=Boba&description=A+calm+companion.&imageUrl=https%3A%2F%2Fcdn.petdex.dev%2Fpets%2Fboba%2Fspritesheet.png",
    );
  });

  it("escapes ampersands so a crafted name cannot inject a parameter", () => {
    const url = buildCodexInstallUrl({
      displayName: "Evil&imageUrl=https://attacker.example/x.png",
      description: "x",
      spritesheetUrl: "https://cdn.petdex.dev/pets/ok/spritesheet.png",
    });
    expect(url).not.toContain("attacker.example/x.png&");
    expect(new URL(url).searchParams.getAll("imageUrl")).toEqual([
      "https://cdn.petdex.dev/pets/ok/spritesheet.png",
    ]);
  });

  it("survives unicode display names", () => {
    const url = buildCodexInstallUrl({
      displayName: "小猫",
      description: "猫",
      spritesheetUrl: "https://cdn.petdex.dev/pets/cat/spritesheet.png",
    });
    expect(new URL(url).searchParams.get("name")).toBe("小猫");
  });
});
