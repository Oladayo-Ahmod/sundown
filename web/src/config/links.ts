import deployment from "@/data/deployment.json";

export const REPO_URL = "https://github.com/Oladayo-Ahmod/sundown";

/**
 * The demo video link. While the token is unfilled (scripts/check_pending.sh lists it) the "Demo video" link is
 * not rendered at all: no dead link. Replace the token with the URL when the video exists.
 */
const VIDEO = "{{PENDING:video_url}}";
export const VIDEO_URL: string | null = VIDEO.startsWith("{{") ? null : VIDEO;

export const FACTORY_ADDRESS = deployment.contracts.SundownMarketFactory;
export const FACTORY_URL = `https://sepolia.arbiscan.io/address/${FACTORY_ADDRESS}#code`;
