// Blocked-site list helpers. The user maintains a list of bare domains; we
// match the current host against them (exact or subdomain).

/// Seeded starter list (fully editable in the popup). Apple's iOS app can't
/// ship presets — a browser extension can.
export const DEFAULT_SITES = [
  "instagram.com",
  "tiktok.com",
  "youtube.com",
  "reddit.com",
  "x.com",
  "twitter.com",
  "facebook.com",
];

/// Reduce arbitrary user input ("https://www.Instagram.com/foo") to a bare,
/// lowercased registrable-ish domain ("instagram.com"). Strips scheme, path,
/// port, and a leading "www.". Returns "" if nothing usable remains.
export function normalizeDomain(input: string): string {
  let s = input.trim().toLowerCase();
  if (!s) return "";
  s = s.replace(/^[a-z]+:\/\//, ""); // scheme
  s = s.replace(/\/.*$/, ""); // path
  s = s.replace(/:\d+$/, ""); // port
  s = s.replace(/^www\./, ""); // common subdomain
  // Keep only host-legal characters.
  if (!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(s)) return "";
  return s;
}

/// True if `host` is the domain itself or a subdomain of it.
export function hostMatchesDomain(host: string, domain: string): boolean {
  const h = host.toLowerCase().replace(/^www\./, "");
  return h === domain || h.endsWith("." + domain);
}

/// First listed domain that matches the host, or null.
export function matchedDomain(host: string, domains: string[]): string | null {
  for (const d of domains) {
    if (hostMatchesDomain(host, d)) return d;
  }
  return null;
}
