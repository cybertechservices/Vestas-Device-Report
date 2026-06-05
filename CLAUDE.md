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


