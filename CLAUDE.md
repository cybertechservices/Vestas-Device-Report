# Vestas Report generator 
PO: Eric Cisternas · Author: Eric Cisternas · Version: 1.5.5 · Updated: 2026-06-04

## Quick Start (Read This First)
1. **New here?** → Read this file + `specs/requirements.md`
2. **Feature dev?** → Use prompt: `@CLAUDE.md + @spec/requirements.md`
3. **Bug fix?** → Use prompt: `@CLAUDE.md + @spec/requirements.md `
4. **Deep dive?** → Open specific appendix from Module Map below

---

## Project Goal
Automate daily reports from WPP Config

---

## Module Map (Open Only What You Need)
| File | Purpose | When to Open |
|------|---------|--------------|
| `specs/requirements.md` | FR1-FR16, NFR1-NFR13 | Always (baseline) |


---

## Agent Team

When reviewing this system, spawn three teammates in parallel:
- **Solution Architect** — validates system architecture, data flow, module boundaries, functions and integration points
- **Security manager** — validates all changes against security, architecture, code, exposure, data
- **Code Reviewer** — audits code for consistency, regressions, error handling, dead code, and security
- **Code tester** — creates test functions for code validation
- **Test Coverage Checker** — verifies edge cases, untested paths, and boundary conditions
- **No regression tester** — verifies the solution is working as it should, and no regression has been introduced when something has changed, added, updated or removed
- **Publisher** — checks the repo state and publishes validated code (by No regression tester and Code Reviewer) only
---


## Working Rules (Non-Negotiable)
| # | Rule | Violation Consequence |
|---|------|----------------------|
| 1 | Backup before edit (timestamped) | Data loss risk |
| 2 | Change ONLY what's requested | Scope creep |
| 3 | Propose → Team Review → Stage Gates → Commit | Bad releases |
| 4 | Bump version on ANY change (z=patches, y=features) | Traceability lost |
| 5 | Update `changelog.md` | Context lost |
| 6 | Strict tenant isolation; No PII | Security breach |
| 7 | Secrets in .env file  | Credential leak |

---

## Stage Gates (All Must Pass)
```
Build:  static_analysis=required; secrets_scan=zero_leaks; licenses=policy_compliant
Test:   unit=all_green; integration=all_green; coverage≥85%/70%; regression=none
Security: vulns=no_high/critical; data=no_pii; tenant_isolation=enforced
Release: approvals=[CodeReviewer, QA/Automation, SecurityManager]; 2_of_3_required
```

---

<!-- rtk-instructions v2 -->
# RTK (Rust Token Killer) - Token-Optimized Commands

## Golden Rule

**Always prefix commands with `rtk`**. If RTK has a dedicated filter, it uses it. If not, it passes through unchanged. This means RTK is always safe to use.

**Important**: Even in command chains with `&&`, use `rtk`:
```bash
# ❌ Wrong
git add . && git commit -m "msg" && git push

# ✅ Correct
rtk git add . && rtk git commit -m "msg" && rtk git push
```

## RTK Commands by Workflow

### Build & Compile (80-90% savings)
```bash
rtk cargo build         # Cargo build output
rtk cargo check         # Cargo check output
rtk cargo clippy        # Clippy warnings grouped by file (80%)
rtk tsc                 # TypeScript errors grouped by file/code (83%)
rtk lint                # ESLint/Biome violations grouped (84%)
rtk prettier --check    # Files needing format only (70%)
rtk next build          # Next.js build with route metrics (87%)
```

### Test (60-99% savings)
```bash
rtk cargo test          # Cargo test failures only (90%)
rtk go test             # Go test failures only (90%)
rtk jest                # Jest failures only (99.5%)
rtk vitest              # Vitest failures only (99.5%)
rtk playwright test     # Playwright failures only (94%)
rtk pytest              # Python test failures only (90%)
rtk rake test           # Ruby test failures only (90%)
rtk rspec               # RSpec test failures only (60%)
rtk test <cmd>          # Generic test wrapper - failures only
```

### Git (59-80% savings)
```bash
rtk git status          # Compact status
rtk git log             # Compact log (works with all git flags)
rtk git diff            # Compact diff (80%)
rtk git show            # Compact show (80%)
rtk git add             # Ultra-compact confirmations (59%)
rtk git commit          # Ultra-compact confirmations (59%)
rtk git push            # Ultra-compact confirmations
rtk git pull            # Ultra-compact confirmations
rtk git branch          # Compact branch list
rtk git fetch           # Compact fetch
rtk git stash           # Compact stash
rtk git worktree        # Compact worktree
```

Note: Git passthrough works for ALL subcommands, even those not explicitly listed.

### GitHub (26-87% savings)
```bash
rtk gh pr view <num>    # Compact PR view (87%)
rtk gh pr checks        # Compact PR checks (79%)
rtk gh run list         # Compact workflow runs (82%)
rtk gh issue list       # Compact issue list (80%)
rtk gh api              # Compact API responses (26%)
```

### JavaScript/TypeScript Tooling (70-90% savings)
```bash
rtk pnpm list           # Compact dependency tree (70%)
rtk pnpm outdated       # Compact outdated packages (80%)
rtk pnpm install        # Compact install output (90%)
rtk npm run <script>    # Compact npm script output
rtk npx <cmd>           # Compact npx command output
rtk prisma              # Prisma without ASCII art (88%)
```

### Files & Search (60-75% savings)
```bash
rtk ls <path>           # Tree format, compact (65%)
rtk read <file>         # Code reading with filtering (60%)
rtk grep <pattern>      # Search grouped by file (75%)
rtk find <pattern>      # Find grouped by directory (70%)
```

### Analysis & Debug (70-90% savings)
```bash
rtk err <cmd>           # Filter errors only from any command
rtk log <file>          # Deduplicated logs with counts
rtk json <file>         # JSON structure without values
rtk deps                # Dependency overview
rtk env                 # Environment variables compact
rtk summary <cmd>       # Smart summary of command output
rtk diff                # Ultra-compact diffs
```

### Infrastructure (85% savings)
```bash
rtk docker ps           # Compact container list
rtk docker images       # Compact image list
rtk docker logs <c>     # Deduplicated logs
rtk kubectl get         # Compact resource list
rtk kubectl logs        # Deduplicated pod logs
```

### Network (65-70% savings)
```bash
rtk curl <url>          # Compact HTTP responses (70%)
rtk wget <url>          # Compact download output (65%)
```

### Meta Commands
```bash
rtk gain                # View token savings statistics
rtk gain --history      # View command history with savings
rtk discover            # Analyze Claude Code sessions for missed RTK usage
rtk proxy <cmd>         # Run command without filtering (for debugging)
rtk init                # Add RTK instructions to CLAUDE.md
rtk init --global       # Add RTK to ~/.claude/CLAUDE.md
```

## Token Savings Overview

| Category | Commands | Typical Savings |
|----------|----------|-----------------|
| Tests | vitest, playwright, cargo test | 90-99% |
| Build | next, tsc, lint, prettier | 70-87% |
| Git | status, log, diff, add, commit | 59-80% |
| GitHub | gh pr, gh run, gh issue | 26-87% |
| Package Managers | pnpm, npm, npx | 70-90% |
| Files | ls, read, grep, find | 60-75% |
| Infrastructure | docker, kubectl | 85% |
| Network | curl, wget | 65-70% |

Overall average: **60-90% token reduction** on common development operations.
<!-- /rtk-instructions -->