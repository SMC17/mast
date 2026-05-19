# "Tokens don't matter" — adjacent-voice cluster
Date: 2026-05-18
Source: steipete tweet (~/research/screenshot at /tmp/chromium-tweet.png)

## Anchor tweet (steipete, OpenClaw)

> People freaking out over my AI spend. What nobody sees: Part of what
> excites me so much about working on OpenClaw is that I'm trying to
> answer the question: How would we build software if tokens don't
> matter?
>
> We constant run ~100 codex in the cloud, reviewing every PR every
> issue. If a fix on main lands, @claxsweeper will eventually find
> that 6 month old issue and close it with an exact reference.
>
> We run codex on every commit to review for security issues (as it's
> far too easy to miss).
>
> We run codex to de-duplicate issues and find clusters and send
> reports for the most pressing issues.
>
> We have agents that can recreate complex setups, spin up ephemeral
> crabbox.sh machines, log into e.g. Telegram, make a video and post
> before/after fix on the PR.

## Named primitives in the steipete ecosystem
- OpenClaw — the umbrella project
- claxsweeper — auto-link-fixes-to-old-issues agent
- crabbox.sh — ephemeral sandbox/repro environments
- birdclaw — tweet-cache for agents (github.com/steipete/birdclaw)
- bird — github.com/steipete/bird

## Thesis decomposition
1. **Continuous review** — every PR, every commit, security-graded
2. **Issue clustering + dedup** — agents as triage layer
3. **Long-tail closure** — old issues auto-closed when relevant fixes land
4. **Ephemeral repro environments** — sandbox-per-agent
5. **Evidence capture** — agents post video before/after to PR
6. **Token-spend irrelevance** — design loop assumes free inference

## Mapping onto stax substrate
- Continuous review ← ultrareview already exists
- Issue clustering ← stax-search (M44 graph)
- Long-tail closure ← stax-experiment register (similar shape)
- Ephemeral repro ← stax-spawn (foundation present, container layer missing)
- Evidence capture ← stax-manifest --artifact (foundation present, video missing)
- Token-spend irrelevance ← Agent Dreams Lifecycle is the resource-aware variant

## Where mast fits
The buffer-as-protocol primitive IS the surface this workflow needs.
Each running codex agent = a buffer (kind: agent). The editor becomes
the air-traffic-control for the 100-agent farm. This is the concrete
"appliance-layer editor" thesis from project_editor_substrate.md.
