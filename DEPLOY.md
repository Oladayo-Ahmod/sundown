# Deploying the web app (steps you do by hand)

Nothing in this repository pushes or deploys on its own. The web app (`web/`) is a static-rendered Next.js 15 site: research pages only, no contract calls, **no environment variables and no secrets are required**.

## 0. Before you start

1. Decide which branch to deploy (the merged `main`, or this branch for a preview).
2. From the repo root run `scripts/check_pending.sh`. It lists unresolved placeholder tokens. Deploying does not require it to be clean, but submitting does.
3. Confirm locally (optional, needs Node 22 and Chrome): the exact build commands are in `web/README.md` section "Build from a fresh clone".

## 1. Push to GitHub

```bash
# create an EMPTY repository on github.com first (no README, no license), then:
git remote add origin git@github.com:<you>/<repo>.git
git push -u origin <branch>
```

- `contracts/lib/*` are git submodules pointing at public repositories; the web build does not use them, so leave "Include submodules" **off** in Vercel.
- `.env` files are git-ignored. Do not commit one.

## 2. Import into Vercel

1. Vercel dashboard, **Add New... > Project**, import the GitHub repository.
2. **Root Directory:** `web`.
3. **Framework Preset:** Next.js (detected). The install and build commands come from `web/vercel.json`; the UI should show them as overridden:
   - Install: `cd .. && npx -y pnpm@12.8.1 install --frozen-lockfile` (the lockfile lives at the repo root, so install runs from there)
   - Build: `npx -y pnpm@12.8.1 build`
4. Enable **Include source files outside of the Root Directory in the Build Step** (Settings > General; on by default for monorepo imports).
5. **Node.js Version:** 22.x (Settings > General).
6. **Environment Variables:** add none. If you later add any, only `NEXT_PUBLIC_*` names, never keys (see `web/.env.example`).
7. Deploy.

## 3. After the first deploy

1. Open `/`, `/risk` and `/replay` on the deployment URL; each must render without console errors.
2. Check headers: `curl -sI https://<deployment-url>/ | grep -i -E "x-content-type-options|referrer-policy|x-frame-options"` (all three should appear; they come from `web/vercel.json`).
3. Measure Lighthouse on the deployed URL (performance is a recorded measurement, not a gate):
   `npx -y lighthouse https://<deployment-url>/ --only-categories=performance,accessibility,best-practices,seo --chrome-flags="--headless=new"`
4. Replace the placeholder tokens that depend on this step (run `scripts/check_pending.sh` to list them): the Vercel URL, the repository URL and the deployed Lighthouse result.

## What is not in this version

No wallet connection is exercised and no RPC endpoint is configured; the "Connect wallet" button loads on click and makes no contract calls. Arbitrum Sepolia addresses, replay transaction links and the demo video link are placeholders until Session A's deployment exists.
