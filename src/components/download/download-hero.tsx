"use client";

import Image from "next/image";

import { ArrowDownToLine } from "lucide-react";
import { useTranslations } from "next-intl";

import {
  type MacArch,
  type Platform,
  useMacArch,
  usePlatform,
} from "@/lib/use-platform";
import { cn } from "@/lib/utils";

import { buttonVariants } from "@/components/ui/button";

const ASSET = {
  "darwin-arm64": "/api/desktop/latest-release?asset=darwin-arm64",
  "darwin-x64": "/api/desktop/latest-release?asset=darwin-x64",
  "linux-x64": "/api/desktop/latest-release?asset=linux-x64",
  "win32-x64": "/api/desktop/latest-release?asset=win32-x64",
} as const;

type Build = { key: keyof typeof ASSET; os: "macos" | "windows" | "linux" };

const BUILDS: Build[] = [
  { key: "darwin-arm64", os: "macos" },
  { key: "win32-x64", os: "windows" },
  { key: "linux-x64", os: "linux" },
];

function primaryBuild(platform: Platform, arch: MacArch): Build | null {
  if (platform === "macos") {
    return {
      key: arch === "intel" ? "darwin-x64" : "darwin-arm64",
      os: "macos",
    };
  }
  if (platform === "windows") return { key: "win32-x64", os: "windows" };
  if (platform === "linux") return { key: "linux-x64", os: "linux" };
  return null;
}

/**
 * The whole download page above the fold: mark, one sentence, one
 * button for the visitor's own OS, and the other builds as quiet links.
 *
 * The page it replaces led with "Run one command" and a terminal
 * mockup, which described an install path that is no longer the one we
 * want people on. It also listed Linux and Windows as "coming soon"
 * long after both shipped.
 */
export function DownloadHero() {
  const t = useTranslations("downloadHero");
  const platform = usePlatform();
  const arch = useMacArch();
  const primary = primaryBuild(platform, arch);
  const others = BUILDS.filter((b) => b.os !== primary?.os);

  return (
    <section className="mx-auto flex w-full max-w-xl flex-col items-center px-5 pt-16 pb-20 text-center md:pt-24">
      <Image
        src="/brand/petdex-desktop-icon.png"
        alt=""
        width={112}
        height={112}
        priority
        className="size-24 md:size-28"
      />

      <h1 className="mt-7 text-pretty text-[38px] leading-[1.05] font-semibold tracking-tight md:text-[52px]">
        {t("title")}
      </h1>
      <p className="mt-4 text-pretty text-base leading-7 text-muted-1 md:text-lg">
        {t("subtitle")}
      </p>

      <div className="mt-9 flex min-h-11 w-full flex-col items-center gap-4">
        {/* Platform detection lands after hydration. Reserving the row
            keeps the layout from jumping once it resolves. */}
        {primary ? (
          <>
            <a
              href={ASSET[primary.key]}
              rel="noreferrer"
              className={cn(
                buttonVariants({
                  variant: "petdex-cta",
                  size: "petdex-pill",
                  className: "h-12 gap-2 px-7 text-[15px]",
                }),
              )}
            >
              <ArrowDownToLine className="size-[18px]" />
              {t(`for.${primary.os}`)}
            </a>
            <p className="font-mono text-xs text-muted-3">{t("freeNote")}</p>
          </>
        ) : platform === "unknown" || platform === "other" ? (
          <span className="h-12 w-56 animate-pulse rounded-xl bg-surface-muted" />
        ) : (
          // Phones and tablets: no build can run here, so the download
          // row becomes the honest sentence instead of a dead button.
          <p className="text-sm text-muted-2">{t("desktopOnly")}</p>
        )}

        <div className="flex flex-wrap items-center justify-center gap-x-5 gap-y-2 text-sm text-muted-2">
          {others.map((b) => (
            <a
              key={b.key}
              href={ASSET[b.key]}
              rel="noreferrer"
              className="underline decoration-border-strong underline-offset-4 transition hover:text-foreground"
            >
              {t(`for.${b.os}`)}
            </a>
          ))}
        </div>
      </div>
    </section>
  );
}
