# Hype Muzik — Monetization Strategy

**Date:** 2026-10-26  
**Scope:** Mobile (Flutter), Desktop (Tauri), Web Remote (SvelteKit), Backend (NestJS)

---

## 1. Executive Summary

Monetize Hype Muzik via a **Freemium + "Supporter" one-time payment** model using **Paddle** (for desktop) and **Google Play Billing** (for mobile Android).

**Core principle:** Core playback + library + basic EQ are **free forever**. Advanced DSP suite, stem separation, cloud sync, and exclusive supporter content require a **$5+ one-time payment**.

---

## 2. Current Architecture Overview

| Component | Tech Stack | Key Capabilities | Monetization Status |
|-----------|------------|------------------|---------------------|
| **Mobile (hype/)** | Flutter 3.38 / Dart 3.10, C++ DSP, Android/iOS | 32-band EQ, parametric EQ, MBC, reverb, stereo expander, crossfeed, stem separation (Android only), cloud streaming via Google Drive/Dropbox, lyrics, fingerprint, lyrics editor, 15+ visualizers, milkdrop presets, speaker correction (6,028 AutoEq profiles), global EQ (system-wide on Android) | Published free on Google Play (v1.0.23); **no payment system implemented** |
| **Web Remote (hypemuzik-web/)** | SvelteKit 5 (runes), Tailwind v4, pnpm | Spotify Connect-style remote, QR/code linking, device selection, media control, synced lyrics display, visualizer output | Free, no authentication required |
| **Desktop (hypemuzik-desktop/)** | Tauri 2, React 19, TypeScript, Tailwind v4, Rust | System-wide equalizer via real-time DSP, volume mixer, radio/TV browsing, local player, AutoEq integration, session-wide latency | Paid spec designed; **shipping a local mock trial/license only** |
| **Backend (hypemuzik-management/backend/)** | NestJS 10, Prisma, Postgres | Email OTP auth, trial/usage tracking, license endpoint, admin dashboard, analytics | `User` model exists; **anonymous tracking + Supporter spec drafted, not coded** |

---

## 3. Freemium + Supporter Model

### Why This Fits

- **Paddle** is the **only Merchant-of-Record that pays out to Uganda** (via Payoneer) — already verified
- "Supporter" is a **one-time "pay what you want"** ($5/$10/$25 quick picks), avoiding subscription billing
- Paddle requires it to be a **real product unlock** (not "donations"); Advanced DSP/Stems/Cloud are perfect perks
- **Anonymous-first** flow: users get full core value before ever deciding to pay

### Free Tier (Forever)

- Core playback (gapless, crossfade, replay gain, DVC on Android)
- Library browsing, playlists, folders (Android), search
- Basic 10-band graphic EQ + preamp
- Cloud streaming (Google Drive, Dropbox) — **requires auth but no payment**
- Lyrics (synced LRC display, shimmer reveal, editor)
- Audio fingerprinting (AcoustID, MusicBrainz, ACRCloud)
- Tag editing (ID3)
- 15+ built-in visualizers + MilkDrop engine
- Global EQ (system-wide on Android)
- Radio/TV stations (desktop)
- Per-app volume mixer (Windows already; macOS graceful notice)

### Supporter Perk ($5+ one-time)

**Unlock with Paddle (desktop) or Google Play Billing (mobile):**

| Category | Features Unlocked |
|----------|-------------------|
| **Advanced DSP Suite** | Full 32-band parametric EQ, multiband compressor (10-band), FDN reverb, stereo expander, crossfeed (BS2B), tone controls (bass/treble shelves), speaker correction |
| **Stem Separation** | 4-track WAV separation (vocals/drums/bass/other) with real-time mixer; presets: Karaoke, Acapella, Instrumental |
| **Cloud Sync** | Sync playlists, play counts, EQ presets, playback position, favorites across devices |
| **Supporter Exclusives** | Badge, exclusive EQ preset pack, exclusive visualizer themes |
| **Mobile EQ-Only Mode (Pro)** | System-wide 32-band EQ for any app; parametric EQ, reverb, crossfeed |

---

## 4. Implementation Roadmap (Phased & Shippable)

### Phase 0: Paddle Account Setup (START NOW)
- **One-time, manual:** Paddle account → business verification → **domain verification** for `hypemuzik-site` → create "HypeMuzik Supporter" product with $5/$10/$25 prices → webhook notification → `pdl_ntfset_...` secret
- **Risk:** Domain approval takes 1–3 weeks; blocks Phase 3

### Phase 1: Anonymous Tracking (Backend + Desktop)
- **Work:**
  - Add Prisma models: `Install`, `Heartbeat`, `Donation`, `Supporter`
  - `POST /v1/installs` — upsert Install; returns `{ supporter: boolean, supporterKind }`
  - `POST /v1/installs/:id/ping` — heartbeat (upserts daily count)
  - Desktop: keychain-backed `install_id` (survives reinstall), IPC `install_register`, `install_ping`
  - Admin dashboard tiles: DAU/MAU, version distribution, country breakdown
- **Effort:** ~1 week
- **Outcome:** Real user counting; zero payment dependency

### Phase 2: Supporter Flag + Perk UI
- **Work:**
  - `GET /me/entitlements` — `{ premium: boolean }`
  - Desktop: `PremiumGate` component, `entitlement` store (`usePremium()` hook), IPC `entitlements()`
  - Supporter exclusive asset: **EQ preset pack** (reuse `autoeq.json` + visualizer themes)
  - Mobile: Stub the Pro unlock button, hardcode `supporter=false` until Paddle live
- **Effort:** ~1 week
- **Outcome:** Gate UI ready; perk ready to unlock

### Phase 3: Paddle Checkout
- **Work:**
  - `POST /v1/support/checkout` — custom amount or tier → Paddle `POST /transactions`
  - `POST /v1/webhooks/paddle` — raw-body, HMAC-SHA256 verify, upsert `Donation`, create `Supporter`
  - `hypemuzik-site` → `/support` route: Paddle.js, `?install=&tier=`, checkout button
  - Terms / Privacy / Refund pages (Paddle requirement)
- **Effort:** ~1 week (after Paddle account verified)
- **Outcome:** Users can pay → become Supporter

### Phase 4: Mobile EQ-Only Pro (Google Play Billing)
- **Work:**
  - Flutter IAP implementation (`in_app_purchase` package)
  - SKU: `pro_eq_unlock` ($4.99 one-time)
  - Backend: link purchase token to `Install` → mark as Supporter
  - Store receipt on device; restore purchases on reinstall
- **Effort:** ~1 week
- **Outcome:** Immediate revenue per Android user

### Phase 5: Cross-Device Email Claim
- **Work:**
  - `POST /auth/claim/request` — send OTP to email
  - `POST /auth/claim/verify` — upgrade anonymous → verified user
  - Sync cloud credentials, restore Supporter status
- **Effort:** ~1 week
- **Outcome:** Seamless cross-platform experience

---

## 5. Tech Implementation Notes

### Prisma Schema Additions

```prisma
enum SupporterKind {
  ONE_TIME
  MONTHLY // reserved for future recurring tier
}

model Install {
  id         String    @id // client UUID v4 (not @default)
  os         String?
  arch       String?
  appVersion String?
  country    String?  // ISO-3166 from request IP; IP discarded after derivation
  firstSeen  DateTime @default(now())
  lastSeenAt DateTime @default(now())
  userId     String?
  user       User?    @relation(fields: [userId], references: [id], onDelete: SetNull)
  heartbeats Heartbeat[]
  donations  Donation[]
  supporter  Supporter?

  @@index([lastSeenAt])
  @@index([country])
  @@index([userId])
}

model Heartbeat {
  installId  String
  install    Install @relation(fields: [installId], references: [id], onDelete: Cascade)
  day        DateTime @db.Date
  count      Int      @default(1)
  appVersion String?

  @@id([installId, day])
  @@index([day])
}

model Donation {
  id                    String        @id @default(cuid())
  processor             String        @default("paddle")
  processorTxId         String        @unique
  eventId               String?
  installId             String?
  install               Install?      @relation(fields: [installId], references: [id], onDelete: SetNull)
  email                 String?
  amount                Decimal       @db.Decimal(12, 2)
  currency              String
  kind                  SupporterKind @default(ONE_TIME)
  processorSubscriptionId String?
  status                String
  raw                   Json
  createdAt             DateTime      @default(now())

  @@index([installId])
  @@index([email])
}

model Supporter {
  installId               String        @id
  install                 Install       @relation(fields: [installId], references: [id], onDelete: Cascade)
  since                   DateTime      @default(now())
  kind                    SupporterKind @default(ONE_TIME)
  expiresAt               DateTime?
  processorSubscriptionId String?       @unique

  @@index([expiresAt])
}
```

### Backend Controller Snippets

**InstallsController (`POST /v1/installs`)**
```typescript
@Post()
async register(@Body() dto: RegisterInstallDto, @Req() req) {
  const country = this.geoService.lookup(req.ip);
  const install = await this.installsService.register({
    ...dto, country, userAgent: req.headers['user-agent'],
  });
  const { supporter, supporterKind } = await this.installsService.entitlements(install);
  return { supporter, supporterKind };
}
```

**SupportController (`POST /v1/webhooks/paddle`)**
```typescript
@Post('webhooks/paddle')
@Header('content-type', 'application/json')
async paddleWebhook(@Req() req) {
  verifyPaddleSignature(req.headers['paddle-signature'], req.rawBody);
  await this.supportService.process(req.body); // upsert Donation + Supporter
  return {}; // 200 OK for Paddle
}
```

### Desktop IPC Commands

```typescript
// src-tauri/src/commands/account.rs
#[tauri::command]
async fn account_bootstrap_anonymous(
  app: AppHandle,
  install_id: String,
) -> Result<AuthResponse, String> {
  // POST /auth/anonymous -> store session
}

#[tauri::command]
async fn account_entitlements(app: AppHandle) -> Result<Entitlements, String> {
  // GET /me/entitlements
}
```

---

## 6. Revenue Projection (Conservative)

| Metric | Assumption |
|--------|------------|
| Monthly Active Installs (MAI) | 5,000 (after Play Store optimization) |
| Supporter conversion rate | 1.5% (typical for pay-what-you-want utility apps) |
| Average payment | $12 (mix of $5/$10/$25 quick picks) |
| **Monthly Gross Revenue** | 5,000 × 1.5% × $12 = **$900/mo** |
| Paddle fees (5% + $0.50/transaction) | ~$150 |
| **Monthly Net Revenue** | **~$750/mo** |

| Scale | MAI = 20,000 → ~$3,000/mo net |

---

## 7. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Paddle account rejection | Start verification early; ensure domain passes; have Dodo Payments as Plan B |
| Paddle webhook latency | Ack 200 immediately; process asynchronously; use idempotency key (`processorTxId`) |
| Android per-app EQ complexity | Ship file playback loopback capture first; virtual driver as future enhancement |
| Payment → entitlement sync failure | Heartbeat endpoint returns `{ supporter }`; client re-fetches on launch + focus |
| Privacy concerns | Publish one-line note: "Anonymous id (UUID), OS, version, country; no PII stored or shared. Settings → opt-out heartbeat." |

---

## 8. Next Steps (Priority Order)

1. **Start Paddle business + domain verification** — blocks Phase 3
2. **Implement Phase 1 (Anonymous Tracking)** — immediate visibility
3. **Build Phase 2 (Supporter UI + perk)**: `PremiumGate`, `entitlement` store, exclusive presets
4. **Add mobile EQ-Only Pro IAP** — revenue as soon as app is updated
5. **Go live with Phase 3** — when Paddle approves

---

## 9. Quick Reference — What to Build, Where

| File / Module | Purpose |
|---------------|---------|
| `backend/prisma/schema.prisma` | Add `Install`, `Heartbeat`, `Donation`, `Supporter` models |
| `backend/src/installs/` | `POST /v1/installs`, `POST /v1/installs/:id/ping`, `GET /v1/installs/:id/supporter` |
| `backend/src/support/` | `POST /v1/support/checkout`, `POST /v1/webhooks/paddle`, `POST /v1/support/restore` |
| `backend/src/auth/dto/auth.dto.ts` | Add `AnonymousDto`, `ClaimRequestDto`, `ClaimVerifyDto` |
| `hypemuzik-desktop/src-tauri/src/commands/` | `install_*.rs`, `account_*.rs`, `entitlements.rs` |
| `hypemuzik-desktop/src/stores/entitlement.ts` | Zustand store: `premium`, `loading`, `refresh()` |
| `hypemuzik-desktop/src/components/PremiumGate.tsx` | Gate features, show upsell card |
| `hype/android/` | Google Play Billing setup for EQ-Only Pro |
| `hype/lib/services/` | `license_service.dart` → `GET /me/license`, `GET /me/entitlements` |

---

## 10. Document History

- **2026-10-26** Created this strategy file.
- **2026-07-24** `frictionless-auth-premium-gating-spec.md` — design spec for frictionless auth + Supporter gating.
- **2026-07-XX** `donations-anonymous-tracking-spec.md` — Paddle-based anonymous tracking + donations spec.