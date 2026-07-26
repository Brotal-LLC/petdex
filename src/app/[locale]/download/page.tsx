import Image from "next/image";
import Link from "next/link";

import { ArrowRight, MonitorSmartphone, Pointer, Zap } from "lucide-react";
import { getLocale, type getMessages, getTranslations } from "next-intl/server";

import { buildLocaleAlternates } from "@/lib/locale-routing";

import { DownloadHero } from "@/components/download/download-hero";
import { StaticPetSprite } from "@/components/pets/static-pet-sprite";
import { SiteFooter } from "@/components/site-footer";
import { SiteHeader } from "@/components/site-header";

import { hasLocale } from "@/i18n/config";

const SITE_URL = "https://petdex.dev";
const _DEFAULT_PREVIEW_PET_SLUG = "boba";
const _DEFAULT_PREVIEW_PET = {
  spritesheetPath: "https://assets.petdex.dev/curated/boba/spritesheet.webp",
};

// Auto-detected /download/opengraph-image is locale-prefixed
// (/en/download/opengraph-image) and next-intl rewrites that with a
// 307. Most social scrapers (Discord, X) do not follow OG redirects
// and silently fall back to the parent layout's image, so unfurls
// would show the generic Petdex card instead of the desktop hero.
// Pin the URL to the locale-stripped path the same way per-collection
// metadata does.
const OG_IMAGE = `${SITE_URL}/download/opengraph-image`;

// Public page now (admin gate lifted on 2026-05-10 alongside the
// petdex:// URL scheme + 9-state bubble UI launch). Index + follow
// so the desktop landing surfaces in search.
export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  return {
    title: "Download Petdex Desktop",
    description:
      "Download Petdex Desktop for macOS. Your pet, floating beside every coding agent.",
    alternates: buildLocaleAlternates(
      "/download",
      hasLocale(locale) ? locale : undefined,
    ),
    openGraph: {
      title: "Petdex Desktop",
      description:
        "Your pet, floating beside every coding agent. macOS native.",
      url: `${SITE_URL}/download`,
      images: [{ url: OG_IMAGE, width: 1200, height: 630 }],
    },
    twitter: {
      card: "summary_large_image",
      title: "Petdex Desktop",
      description: "Your pet, floating beside every coding agent.",
      images: [OG_IMAGE],
    },
  };
}

export const dynamic = "force-static";
export const revalidate = 3600;

export default async function DownloadPage() {
  const t = await getTranslations("download");
  const locale = await getLocale();

  const features = [
    {
      icon: Zap,
      title: t("features.crossAgent.title"),
      description: t("features.crossAgent.description"),
    },
    {
      icon: MonitorSmartphone,
      title: t("features.alwaysWithYou.title"),
      description: t("features.alwaysWithYou.description"),
    },
    {
      icon: Pointer,
      title: t("features.pickYourFighter.title"),
      description: t("features.pickYourFighter.description"),
    },
  ];

  return (
    <main className="relative min-h-dvh bg-background text-foreground">
      <SiteHeader />

      <DownloadHero />

      <section
        id="what-it-does"
        className="mx-auto w-full max-w-[1440px] px-5 py-16 md:px-8"
      >
        <div className="text-center">
          <p className="font-mono text-xs tracking-[0.22em] text-brand uppercase">
            {t("features.eyebrow")}
          </p>
          <h2 className="mt-3 text-3xl font-semibold tracking-tight md:text-4xl">
            {t("features.title")}
          </h2>
        </div>

        <div className="mt-12 grid gap-6 md:grid-cols-3">
          {features.map((feature) => {
            const Icon = feature.icon;
            return (
              <div
                key={feature.title}
                className="flex flex-col gap-4 rounded-3xl border border-border-base bg-surface p-6"
              >
                <span className="grid size-10 shrink-0 place-items-center rounded-full bg-brand-tint text-brand ring-1 ring-brand/15 dark:bg-brand-tint-dark dark:ring-brand/25">
                  <Icon className="size-5" />
                </span>
                <div>
                  <h3 className="text-base font-semibold text-foreground">
                    {feature.title}
                  </h3>
                  <p className="mt-1.5 text-sm leading-6 text-muted-2">
                    {feature.description}
                  </p>
                </div>
              </div>
            );
          })}
        </div>
      </section>
      <section className="mx-auto w-full max-w-[1440px] px-5 py-10 md:px-8">
        <div className="mx-auto max-w-2xl">
          <Link
            href={`/${locale}/docs`}
            className="inline-flex items-center gap-1.5 text-sm font-medium text-brand transition hover:text-brand-deep"
          >
            {t("docsLink")}
            <ArrowRight className="size-4" />
          </Link>
        </div>
      </section>

      <SiteFooter />
    </main>
  );
}

function _getDownloadSetupTemplates(
  messages: Awaited<ReturnType<typeof getMessages>>,
) {
  return {
    installPetTitle: getMessageString(
      messages,
      ["download", "setup", "installPet", "title"],
      "Install {slug}",
    ),
    installPetsTitle: getMessageString(
      messages,
      ["download", "setup", "installPets", "title"],
      "Install {count} pets",
    ),
  };
}

function getMessageString(messages: unknown, path: string[], fallback: string) {
  let current = messages;
  for (const part of path) {
    if (!current || typeof current !== "object" || !(part in current)) {
      return fallback;
    }
    current = (current as Record<string, unknown>)[part];
  }
  return typeof current === "string" ? current : fallback;
}

function _DesktopActivationPreview({
  pendingLabel,
  pendingPet,
  title,
  status,
  terminalLabel,
  agentLabel,
  petLabel,
}: {
  pendingLabel: string | null;
  pendingPet: { displayName: string; spritesheetPath: string } | null;
  title: string;
  status: string;
  terminalLabel: string;
  agentLabel: string;
  petLabel: string;
}) {
  return (
    <div className="relative min-w-0 overflow-hidden rounded-lg border border-border-base bg-surface p-4 shadow-[0_32px_90px_-60px_rgba(15,23,42,0.6)]">
      <div className="absolute inset-x-0 top-0 h-1 bg-brand" />
      <div className="flex items-center gap-2 border-border-base border-b pb-3">
        <span className="size-3 rounded-full bg-rose-400" />
        <span className="size-3 rounded-full bg-amber-400" />
        <span className="size-3 rounded-full bg-emerald-400" />
        <span className="ml-2 truncate text-xs font-medium text-muted-3">
          Petdex Desktop
        </span>
      </div>

      <div className="grid gap-4 pt-5 sm:grid-cols-[1fr_160px]">
        <div className="space-y-3">
          <div className="rounded-lg border border-border-base bg-background p-4">
            <p className="text-xs font-medium text-muted-3">{terminalLabel}</p>
            <div className="mt-3 space-y-2 font-mono text-xs">
              <p>
                <span className="text-brand">$</span>{" "}
                <span className="text-foreground">npx petdex init</span>
              </p>
              <p className="text-muted-3">✓ {agentLabel}</p>
              <p className="text-muted-3">✓ {petLabel}</p>
            </div>
          </div>

          <div className="rounded-lg border border-border-base bg-background p-4">
            <div className="flex items-start gap-3">
              <div className="relative size-12 shrink-0">
                <Image
                  src="/brand/petdex-desktop-icon.png"
                  alt=""
                  fill
                  className="object-contain"
                  sizes="48px"
                />
              </div>
              <div className="min-w-0">
                <p className="font-semibold text-foreground">{title}</p>
                <p className="mt-1 text-sm leading-5 text-muted-2">{status}</p>
              </div>
            </div>
          </div>
        </div>

        <div className="relative min-h-[210px] overflow-hidden rounded-lg border border-border-base bg-[linear-gradient(135deg,var(--surface-muted),var(--surface))] p-3">
          <div className="absolute inset-x-3 top-3 rounded-lg border border-border-base bg-surface/80 p-3">
            <div className="h-2 w-24 rounded-full bg-border-base" />
            <div className="mt-2 h-2 w-16 rounded-full bg-border-base/70" />
          </div>
          {pendingPet ? (
            <div className="pet-sprite-stage absolute right-4 bottom-7 grid size-28 place-items-center rounded-lg border border-brand/20 bg-surface shadow-xl">
              <StaticPetSprite
                src={pendingPet.spritesheetPath}
                state="idle"
                scale={0.46}
                label={pendingPet.displayName}
              />
            </div>
          ) : (
            <div className="absolute right-5 bottom-7 grid size-24 place-items-center rounded-lg border border-brand/20 bg-surface shadow-xl">
              <Image
                src="/brand/petdex-desktop-icon.png"
                alt="Petdex Desktop"
                width={80}
                height={80}
                className="object-contain"
              />
            </div>
          )}
          {pendingLabel ? (
            <span className="absolute bottom-3 left-3 max-w-[120px] truncate rounded-lg bg-brand px-2 py-1 text-xs font-medium text-on-inverse">
              {pendingLabel}
            </span>
          ) : null}
        </div>
      </div>
    </div>
  );
}
