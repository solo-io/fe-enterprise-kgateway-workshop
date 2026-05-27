# Changelog

0.1.0 - (5-27-26)
---
- Update variable GLOO_VERSION > KGW_VERSION
- Update KGW_VERSION to `2.2.0`
- Minor fix in `003-tls-termination.md`

0.0.9 - (4-17-26)
---
- Updates to `014-waf.md` - add sectionName example for increased granularity when applying WAF policies

0.0.8 - (4-17-26)
---
- Updates to `014-waf.md`

0.0.7 - (4-17-26)
---
- Update `ENTERPRISE_KGATEWAY_VERSION` to `2.2.0-beta.19`
- Add `014-waf.md` - WAF lab covering Coraza IP allowlisting with `@ipMatch`, detection-only mode, and OWASP rule layering
- Update `000-image-list.md` for `2.2.0-beta.19`
- Update README.md lab list

0.0.6 - (3-13-26)
---
- Update `ENTERPRISE_KGATEWAY_VERSION` to `2.2.0-beta.9`
- Update GWAPI version to 1.5.0 experimental
- Rewrite `007b-multi-tenant-mtls-current.md` to demonstrate per-listener mTLS CA isolation using `ListenerPolicy` (`gateway.kgateway.dev/v1alpha1`)
- Replace shared CA trust pool pattern with per-listener `clientCertificateValidation` targeting each listener by `sectionName`
- Add Tenant C listener inheriting gateway-level default CA as a contrast case
- Rename `007b-multi-tenant-mtls-current.md` → `008-multi-tenant-mtls.md`
- Renumber labs 008–012 to 009–013 to accommodate new slot
- Update README.md lab list to reflect new filenames
- Update `000-image-list.md`

0.0.5 - (1-16-26)
---
- Minor updates

0.0.4 - (1-15-26)
---
- Update `ENTERPRISE_KGATEWAY_VERSION` to `2.1.0`
- Update 000-image-list.md
- Update image overrides with latest

0.0.3 - (1-13-26)
---
- Added `000-image-list.md`

0.0.2 - (1-12-26)
---
- Added README.md

0.0.1 - (1-12-26)
---
- First commit
  - 001-set-up-enterprise-kgateway.md
  - 002-deploy-and-route-to-httpbin.md
  - 003-tls-termination.md
  - 004-SNI-matching.md
  - 005-JWT-validation.md
  - 006-observability.md
  - 007-mtls-termination.md
  - 007b-multi-tenant-mtls-current.md
  - 008-buffering.md
  - 009-timeouts-and-retries.md
  - 010-global-policy-attachment.md
  - 011-backend-config-policy.md
  - 012-rate-limiting.md