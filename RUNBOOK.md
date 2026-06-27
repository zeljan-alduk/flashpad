# FlashPad — Mac App Store Release Runbook

This is the exact, human-in-the-loop checklist for shipping FlashPad to the Mac
App Store. The automation (fastlane) does the build, sign, upload, and metadata
push. The steps below are the few things only a human with the Apple account can
do: generate an API key and accept the legal agreements once.

After the one-time setup, every release is a single command:
`fastlane mac release`.

---

## 0. Prerequisites (one time, on this Mac)

These are already installed in this repo's environment, but for a fresh machine:

```bash
brew install xcodegen          # generates FlashPad.xcodeproj from project.yml
brew install fastlane          # build + upload automation
xcode-select --install         # command line tools, if not present
```

You also need full Xcode (not just CLT) installed and launched once so it can
install its components. `sudo xcodebuild -license accept` if prompted.

---

## 1. Accept the agreements (one time, in a browser)

Automation cannot click through legal agreements. Do this once:

1. Sign in at <https://appstoreconnect.apple.com> with **zeljan.alduk@gmail.com**.
2. **Business → Agreements**: accept the **Apple Developer Program License
   Agreement** and the **Free Apps Agreement** (FlashPad is free, so the Free
   Apps Agreement — formerly "Paid Apps" — is the only one needed; if you ever
   add a price you'll also need the Paid Apps banking/tax setup).

If these are not accepted, uploads succeed but the app can never go live.

---

## 2. Generate an App Store Connect API key (one time, in a browser)

This is what makes the upload non-interactive — no Apple ID password or 2FA
prompts during `fastlane`.

1. Go to **App Store Connect → Users and Access → Integrations → App Store
   Connect API** (the "Team Keys" tab).
2. Click **+** (Generate API Key).
3. Name it e.g. `flashpad-ci`. Access role: **App Manager** (enough to upload
   builds and edit the listing). Click **Generate**.
4. **Download the `AuthKey_XXXXXXXXXX.p8` file.** You can only download it once.
   Save it somewhere safe and private, e.g. `~/.appstoreconnect/AuthKey_XXXX.p8`.
5. From the same page, copy two values:
   - **Key ID** — the 10-char string shown next to the key (also in the filename).
   - **Issuer ID** — the UUID shown at the top of the Keys list.

Keep the `.p8` out of git. (`.gitignore` already ignores `*.p8`.)

---

## 3. Find your Team ID (one time)

Either from the browser — **App Store Connect → Membership** (or
<https://developer.apple.com/account> → Membership details) — or, if you have a
distribution cert installed:

```bash
security find-identity -p basic -v | grep -i "Developer ID\|Apple Distribution"
```

It's the 10-character string in parentheses (e.g. `AB12CD34EF`).

---

## 4. Set environment variables

Put these in your shell session (or a private `~/.flashpad.env` you `source`).
**Do not commit them.**

```bash
export ASC_KEY_ID="XXXXXXXXXX"                       # from step 2
export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # from step 2
export ASC_KEY_PATH="$HOME/.appstoreconnect/AuthKey_XXXXXXXXXX.p8"  # from step 2
export DEVELOPMENT_TEAM="AB12CD34EF"                 # from step 3
```

Sanity check: `echo "$ASC_KEY_ID $DEVELOPMENT_TEAM"` and `ls "$ASC_KEY_PATH"`.

---

## 5. Provision signing assets (one time, automated)

Apple's App Store Connect API can't do Xcode "cloud signing" with our key role,
so instead we create the distribution assets directly via the API. This is
already done for this account, but on a fresh machine (or after a cert expires)
re-run the idempotent script — it reuses anything that already exists:

```bash
ruby Scripts/asc-provision.rb
```

This registers the Bundle ID `tech.aldo.flashpad`, creates an **Apple
Distribution** cert + a **Mac Installer Distribution** cert (imported into your
login keychain), and creates + installs the **Mac App Store** provisioning
profile. After this, `fastlane mac build` produces a fully signed
`build/FlashPad.pkg` with no interactive login.

## 5b. Create the app record (one time, MANUAL — Apple requires a human)

The App Store Connect API **forbids creating app records** (`apps` does not
allow CREATE), so this single step must be done in the browser:

1. <https://appstoreconnect.apple.com> → **Apps → + → New App**.
2. Platform **macOS**; Bundle ID **tech.aldo.flashpad** (it's already registered,
   so it appears in the dropdown); Name **FlashPad**; Primary language
   **English (U.S.)**; SKU **flashpad**.
3. **Create**.

If the name "FlashPad" is already taken on the store, pick another name in the
New App dialog and in `fastlane/metadata/en-US/name.txt`.

---

## 6. Release — build, sign, upload

```bash
fastlane mac release      # uploads the build + metadata, does NOT submit
# — or —
fastlane mac submit       # same, then submits for App Review
```

What this does (see `fastlane/Fastfile`):
1. `xcodegen generate` — regenerates `FlashPad.xcodeproj` from `project.yml`.
2. `build_mac_app` — Release build, `app-store` export, with
   `-allowProvisioningUpdates` so Xcode creates/refreshes the **Mac App
   Distribution** cert and provisioning profile automatically.
3. `upload_to_app_store` — uploads `build/FlashPad.pkg`, plus the metadata in
   `fastlane/metadata/` and screenshots in `fastlane/screenshots/`.

The first build will pause if Xcode needs to create signing assets and your
login keychain is locked — unlock it (`security unlock-keychain`) or run once
from the Xcode GUI to seed the certs.

---

## 7. Finish in the browser

After a successful `release`:

1. App Store Connect → **FlashPad → the new version**.
2. The build takes ~5–15 min to finish processing; once it appears, select it.
3. Fill **App Privacy** (answer: *no data collected* — see `PRIVACY.md`), set
   the **age rating** (4+), confirm screenshots/description look right.
4. **Add for Review → Submit**. (Or use `fastlane mac submit` to do this last
   step from the CLI.)

---

## What's automated vs. manual

| Step | Who |
|------|-----|
| Accept Developer + Free Apps agreements | **You**, once, in browser |
| Generate API key (.p8 + Key ID + Issuer ID) | **You**, once, in browser |
| Register Bundle ID + certs + provisioning profile | `ruby Scripts/asc-provision.rb` |
| Create the app record | **You**, once, in browser (API forbids it) |
| Build, sign, export `.pkg` | `fastlane mac build` / `release` |
| Upload binary + metadata + screenshots | `fastlane mac release` |
| App Privacy answers + age rating | **You**, once, in browser |
| Submit for review | `fastlane mac submit` (or browser button) |

---

## Files that drive this

- `project.yml` — xcodegen project: bundle id, entitlements, Info.plist, signing.
- `fastlane/Appfile` — app identifier, Apple ID, team id (from env).
- `fastlane/Fastfile` — the `bootstrap` / `release` / `submit` lanes.
- `fastlane/Deliverfile` + `fastlane/metadata/` — the store listing text.
- `fastlane/screenshots/en-US/` — the 2560×1600 store screenshots.
- `Resources/FlashPad.entitlements` — App Sandbox + file access + print.
- `Resources/PrivacyInfo.xcprivacy` — privacy manifest (no tracking/data).
- `PRIVACY.md` — the public privacy policy (link it as the Privacy URL).
