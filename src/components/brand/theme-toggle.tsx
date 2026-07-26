"use client";

import { useEffect, useState } from "react";

import { Moon, Sun } from "lucide-react";
import { useTranslations } from "next-intl";
import { useTheme } from "next-themes";

// Toggles light <-> dark. Renders a sun placeholder until mounted to
// avoid the hydration flash next-themes warns about.
export function ThemeToggle({ className }: { className?: string }) {
  const t = useTranslations("theme");
  const { theme, setTheme } = useTheme();
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
    // `system` was supported before the theme control became binary.
    // Preserve explicit light/dark choices and migrate only that legacy value.
    if (theme === "system") setTheme("light");
  }, [setTheme, theme]);

  function next() {
    setTheme(theme === "dark" ? "light" : "dark");
  }

  // Pre-mount: render the icon that matches the SSR background
  // (light) so the layout doesn't shift.
  const showDark = mounted && theme === "dark";
  const Icon = showDark ? Moon : Sun;
  const label = !mounted ? t("toggle") : showDark ? t("dark") : t("light");

  return (
    <button
      type="button"
      aria-label={t("ariaLabel", { label })}
      title={t("title", { label })}
      onClick={next}
      className={
        className ??
        "grid size-8 place-items-center rounded-full border border-border-base bg-surface/70 text-muted-2 backdrop-blur transition hover:bg-surface-muted hover:text-foreground"
      }
    >
      <Icon className="size-4" />
    </button>
  );
}
