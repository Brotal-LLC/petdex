/** codex:// deep link builder for installing a Petdex pet into Codex Desktop. */

/**
 * Codex Desktop ships for macOS and Windows, unlike Petdex Desktop
 * (mac-only), so this checks both instead of reusing isMacDesktop from
 * petdex-desktop-link.ts.
 */
export function isCodexDesktopOs(): boolean {
  if (typeof navigator === "undefined") return false;
  const ua = navigator.userAgent ?? "";
  const platform =
    (navigator as Navigator & { platform?: string }).platform ?? "";
  const isIos =
    /iPhone|iPad|iPod/i.test(platform) || /iPhone|iPad|iPod/i.test(ua);
  const looksLikeIpadDesktopMode =
    platform === "MacIntel" &&
    typeof navigator.maxTouchPoints === "number" &&
    navigator.maxTouchPoints > 1;
  if (isIos || looksLikeIpadDesktopMode) return false;
  const isMac = /^Mac/i.test(platform) || /Mac OS X/i.test(ua);
  const isWindows = /^Win/i.test(platform) || /Windows/i.test(ua);
  return isMac || isWindows;
}

export type CodexInstallPet = {
  displayName: string;
  description: string;
  spritesheetUrl: string;
};

/**
 * `codex://pets/install?name=…&description=…&imageUrl=…`
 *
 * The shape is OpenAI's, read off the JSON-LD `InstallAction` that
 * chatgpt.com/s/sharepet_<id> publishes for its own shared pets. It is not a
 * documented contract, so treat a dead link as expected breakage and always
 * offer the petdex:// path beside it — see openCodexDeepLink.
 *
 * `imageUrl` is a plain spritesheet URL, which is the whole reason this works:
 * Codex Desktop accepts any host, so a pet served from Petdex R2 installs the
 * same way one served from OpenAI does.
 */
export function buildCodexInstallUrl(pet: CodexInstallPet): string {
  const query = new URLSearchParams({
    name: pet.displayName,
    description: pet.description,
    imageUrl: pet.spritesheetUrl,
  });
  return `codex://pets/install?${query.toString()}`;
}

/**
 * Navigate to a codex:// URL, falling back when nothing handles the scheme.
 *
 * Same blur-race as openPetdexDeepLink: a registered handler moves focus off
 * the page before the timer fires, an unregistered one leaves focus put and the
 * fallback runs. The window is longer here because Codex Desktop is a heavier
 * app than Petdex Desktop and a cold launch can outrun a 1200ms bet.
 */
export function openCodexDeepLink(
  deepLink: string,
  fallbackHref: string,
  onBeforeNavigate?: () => void,
): void {
  onBeforeNavigate?.();
  let cancelled = false;
  const timeout = window.setTimeout(() => {
    if (cancelled) return;
    window.location.href = fallbackHref;
  }, 2000);
  const onBlur = () => {
    cancelled = true;
    window.clearTimeout(timeout);
    window.removeEventListener("blur", onBlur);
    window.removeEventListener("pagehide", onBlur);
  };
  window.addEventListener("blur", onBlur);
  window.addEventListener("pagehide", onBlur);
  window.location.href = deepLink;
}
