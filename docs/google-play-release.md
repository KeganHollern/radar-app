# Google Play release guide for HyprRadar

Last reviewed against Google Play requirements: **August 21, 2026**.

This is the release checklist for Android package `dev.lystic.radar`. Work from
top to bottom. Do not upload a production release until every **Required** item
is complete.

## Current technical baseline

- App name: `HyprRadar`
- Package name: `dev.lystic.radar` (permanent after Play setup)
- Current version: `1.0.6` (`versionCode` 20)
- Minimum Android version: API 24
- Target Android version: API 36
- Production API: `https://radar.lystic.dev`
- Privacy policy URL: `https://radar.lystic.dev/privacy`
- Permanent existing Android certificate SHA-256:
  `F8:1C:8C:60:14:56:4E:B9:BE:08:66:FE:E6:0C:1F:7F:66:9A:29:A3:43:8A:C8:58:7A:EC:0B:D0:0F:E1:9F:1D`

The repository can build a signed Android App Bundle (`.aab`). The GitHub
release workflow validates the package, version, signing certificates,
notification icon, and checksums. Google Play still requires Console setup, declarations,
store assets, testing, and human review.

## 1. Choose and verify the developer account — Required

1. Sign in at <https://play.google.com/console/> or create an account.
2. Record whether it is a **Personal** or **Organization** account and its
   creation date.
3. Complete legal identity, address, email, phone, payment-profile, and device
   verification tasks shown on the Console home page.
4. If using an Organization account, start D-U-N-S verification early. Google
   says obtaining a D-U-N-S number can take up to 30 days.
5. Resolve the Health declaration/account-type question before choosing a
   Personal account. Google's Health declaration defines **Emergency and First
   Aid** to include emergency and disaster-response information, which HyprRadar
   can display from NWS alerts even though it collects no health records and
   gives no diagnosis. Play's current Console Requirements route health-app
   providers to Organization accounts. Get written Play support guidance if its
   classification is unclear, or use a verified Organization account and D-U-N-S.
6. Complete Android developer identity verification and confirm that
   `dev.lystic.radar` is registered. All Play packages must be registered by
   **September 30, 2026**.

**Conditional wait:** A Personal account created after November 13, 2023 must
also verify a real, non-rooted Android 10+ phone and later run the 12-tester
closed test in step 10.

## 2. Make the signing decision before the first upload — Required

The app already has sideloaded GitHub APKs signed by the certificate above.
Android accepts an update only when its app-signing certificate matches.

1. Make two encrypted, offline backups of the existing keystore and passwords.
2. In Play App Signing setup, decide whether existing GitHub users must be able
   to install Play updates without uninstalling.
   - **Keep update compatibility:** provide the existing permanent key as the
     Play **app-signing key** during first-app setup. Use a separate Play upload
     key after enrollment so routine Play uploads never use the permanent key.
     The current GitHub APK workflow still needs the permanent key as a GitHub
     secret; if the key must remain fully offline, sign GitHub APKs in a separate
     offline process instead.
   - **Use a new Google-generated key:** simpler, but existing GitHub installs
     cannot update from Play in place.
3. Do not confuse the **app-signing key** (identity of installed apps) with the
   **upload key** (identity Google accepts for future uploads).
4. Never commit a keystore or `android/key.properties`.
5. Keep the GitHub APK on the permanent key. When Play uses a separate upload
   key, add the four `PLAY_UPLOAD_*` repository secrets and the public
   `PLAY_UPLOAD_CERT_SHA256` repository variable described in `mobile/README.md`.
   The workflow signs and checks the APK and AAB independently; partial setup
   fails rather than silently changing either identity.

This choice is difficult to reverse. Confirm it before accepting the Play App
Signing screen.

## 3. Publish the audited code and policy — Required

1. Review and merge the release-readiness changes.
2. Build and publish a new backend image with patched Go 1.25.13 or newer.
3. Let the production deployment roll to that image, then verify:

   ```sh
   curl -fsS https://radar.lystic.dev/healthz
   curl -fsS https://radar.lystic.dev/privacy | grep 'HyprRadar Privacy Policy'
   kubectl get ingress radar-api -n default \
     -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/enable-access-log}'
   ```

   The last command must print `false`. The audited app sends Near me coordinates
   in a POST body, and this ingress setting also protects older GET clients from
   raw query-URL logging. Apply the operator's retention/deletion procedure to
   historical ingress logs that predate this fix. Also review Cloudflare HTTP
   logs/Logpush retention for old GET query URLs; the audit token did not have
   permission to verify that account-level setting.
4. Open the privacy URL in a private browser window. It must work without login,
   geoblocking, a downloadable PDF, or edit permission.
5. Confirm that the developer name and privacy contact in the policy match the
   identity that will appear on Google Play. Update them before submission if
   the listing uses a company rather than Kegan Hollern.
6. Recheck OpenFreeMap's current terms and attribution. Its public site currently
   permits free website/app use with no request limit; the app shows the required
   OpenFreeMap, OpenMapTiles, and OpenStreetMap credits.

Do not submit while `/privacy` returns 404 or while the old backend image is
still running.

## 4. Create and verify the release App Bundle — Required

1. Increase the build number in `mobile/pubspec.yaml` above every version code
   ever uploaded to this Play app. Version codes cannot be reused, even after a
   rejected or test upload.
2. Run the **Android release** GitHub workflow. It creates:
   - a signed universal APK for GitHub users;
   - a signed `.aab` for Google Play; and
   - SHA-256 files for both.
3. Download the workflow artifact and retain it with the source commit/tag.
4. Confirm the workflow passed its checks for:
   - package `dev.lystic.radar`;
   - expected version name/code;
   - target API 36;
   - non-debug certificate;
   - no undeclared location foreground-service type;
   - retained notification icon; and
   - valid AAB signature.
5. Locally, the equivalent command is:

   ```sh
   cd mobile
   flutter build appbundle --release
   ```

   The result is `build/app/outputs/bundle/release/app-release.aab`. This local
   command signs only when the release keystore variables or an untracked
   `android/key.properties` are configured. Prefer the verified CI artifact, and
   never upload an unsigned or throwaway-key audit bundle.

Google Play requires the AAB. The universal APK is not the Play upload.

## 5. Prepare the store listing — Required

Create truthful assets from the real app. Do not show features that are absent.

- App title: at most 30 characters (`HyprRadar` fits).
- Short description: at most 80 characters.
- Full description: at most 4,000 characters.
- Store icon: 512 × 512, 32-bit PNG with alpha, at most 1 MB.
- Feature graphic: 1,024 × 500, JPEG or 24-bit PNG without alpha.
- Phone screenshots: at least 2; use at least 4 clear 1080px-or-larger images.
  Include the map, alert details, sources/attribution, and notification settings.
- Support email: a monitored address that Google Play can display publicly.
- Website: `https://radar.lystic.dev/`.
- Privacy URL: `https://radar.lystic.dev/privacy`.
- Category: normally **Weather**.
- Availability: start with the United States because data/features are U.S.-only.

The listing must clearly say:

- Near me alerts can use location while the app is closed or not in use;
- checks are periodic and Android can delay them;
- HyprRadar uses NOAA/NWS data but is not affiliated with or endorsed by the
  U.S. government;
- sources include `https://www.weather.gov/` and `https://www.noaa.gov/`; and
- the app does not replace Wireless Emergency Alerts, NOAA Weather Radio, local
  authorities, or safe driving judgment.

Do not claim “instant,” “guaranteed,” exact lightning strikes, forecasts, or
government endorsement.

## 6. Create the Play Console app — Required

1. Choose **Create app**.
2. Set the default language, name, app/game type, and free/paid status carefully.
3. Reserve/confirm package `dev.lystic.radar`. Never create a second package by
   accident; the package name cannot be changed after publication.
4. Choose countries/regions and finish the main store listing.
5. Complete Play App Signing using the decision from step 2.
6. Upload the AAB first to **Internal testing**, not Production.

## 7. Complete every App content declaration — Required

Use the behavior of the uploaded AAB, not guesses. Expected answers from the
current audited source are:

- **Privacy policy:** enter `https://radar.lystic.dev/privacy`.
- **App access:** all functionality is available without login or a special
  account. Give reviewers exact steps to open Settings → Background
  notifications → Near me.
- **Ads:** No. The app has no ad SDK or advertising ID permission.
- **Data safety:** disclose optional location collection for app functionality.
  Near me obtains device location in background, rounds it to three decimal
  places, sends it in a non-URL HTTPS POST body through the HyprRadar service to
  NWS, and actively expires its short-lived memory-cache entry. Also evaluate
  map viewport requests,
  OpenFreeMap, Cloudflare, Google Play services, and IP/network processing.
  Conservatively evaluate both approximate and precise location and whether the
  NWS transfer counts as “shared” under Google's definitions.
- **Data deletion:** there are no user accounts or persistent server profiles.
  Local data is removed by clear-storage/uninstall; expired startup location is
  deleted on a later read; server request caches expire automatically. Provide
  the privacy contact for questions.
- **Target audience:** choose the real audience. Do not select under-13 groups
  unless the app is deliberately redesigned for children and Families policy.
- **Content rating:** finish the IARC questionnaire; an unrated app is not
  allowed.
- **Financial features:** “My app doesn't provide any financial features.”
- **Government apps:** not a government app. Provide the `.gov` sources and the
  no-affiliation statement because the app communicates government weather
  information.
- **Health apps:** HyprRadar has no health-data access, diagnosis, or
  medical-device function, but that alone does not settle the declaration.
  Resolve **Emergency and First Aid** because NWS alerts can include emergency
  and disaster-response instructions. Follow the account decision from step 1
  rather than filing an inaccurate No answer.
- **News/Magazine, COVID, and other surfaced forms:** answer No unless the app is
  changed before upload.
- **Foreground services:** the app's periodic alert job is ordinary WorkManager
  work, not a declared user-visible location foreground service. The release
  manifest removes Geolocator's unused location-foreground-service marker, and
  CI checks that no foreground-service type returns. Confirm the uploaded-bundle
  report agrees; do not file a foreground-service use declaration unless the app
  behavior and manifest are deliberately changed first.

Keep the policy, Data safety answers, permission declaration, and listing copy
consistent. A contradiction is a common rejection reason.

## 8. Submit the background-location declaration — Required for Near me

The manifest requests `ACCESS_BACKGROUND_LOCATION`, so this review cannot be
skipped while Near me alerts remain.

1. In **App content → Sensitive app permissions → Location permissions**, declare
   one feature only: **Near me NWS alerts while the app is closed**.
2. Explain why periodic background location is necessary: the phone can move,
   and alerts must be checked for the user's recent position while the app is not
   visible. Nationwide alerts are the non-location alternative.
3. Record a reviewer-accessible Android video that aims for **30 seconds or
   shorter**, as Play recommends, and shows:
   - the normal path to enable the feature;
   - HyprRadar's prominent disclosure;
   - the Android permission flow, including “Allow all the time”;
   - Near me selected and monitoring active;
   - HyprRadar closed or otherwise not in use; and
   - an actual background check outcome, normally a real notification. Do not
     submit a setup-only video. Wait for a real matching alert if needed. You may
     cut out the WorkManager wait, but do not fake the resulting notification.
4. On Android 11+, the tested order is: HyprRadar disclosure → foreground
   location prompt → Android location settings → choose “Allow all the time” →
   return to HyprRadar → notification prompt. Do not pre-grant permissions or
   skip these screens in the recording.
5. Use an unlisted YouTube link or another direct link that works without a
   reviewer login, access request, or geoblock.
6. Copy the prominent location purpose into the store description.
7. Allow extra review time; sensitive-permission review can take weeks.

Google's own acceptable disclosure example is local weather alerts “even when
the app is closed or not in use.” HyprRadar now uses that explicit wording.

## 9. Test the Play-generated install — Required

Install from the Internal testing opt-in link. This tests the APKs Google creates
from the AAB, not a locally sideloaded APK.

Test at least:

- Android 10, 11, 12, 13, 14, 15, and 16 where available;
- cold start and denied/approximate/precise location paths;
- Android 11+ “Allow all the time” recovery;
- notification denial and later enablement;
- a real background notification after the app is closed;
- reboot and background-job rescheduling;
- map/radar/alerts/lightning in portrait, landscape, and a small screen;
- TalkBack, source links, and the in-app privacy link;
- offline, stale-data, backend failure, and retry behavior; and
- the Play pre-launch report, crashes, ANRs, security warnings, and accessibility
  warnings.

Recheck that the release notification icon appears. This catches the optimizer
bug that existed before the resource keep rule.

## 10. Complete the required closed test when applicable — Conditional

For a Personal developer account created after November 13, 2023:

1. Create a Closed testing track.
2. Recruit at least 12 testers.
3. Keep at least 12 testers continuously opted in for 14 days.
4. Gather and respond to real feedback.
5. Apply for Production access in Play Console after the test.

Older Personal accounts and Organization accounts normally do not have this
mandatory wait, but should still run a closed test.

## 11. Prepare and submit Production — Required

1. Fix every blocking Internal/Closed testing and policy issue.
2. Increment `versionCode` and build a fresh signed AAB if any code or asset
   changed after the prior upload.
3. Add concise release notes.
4. Upload to Production, complete the review summary, and use Managed publishing
   if you want control over the exact launch time.
5. Start with a staged rollout rather than 100% when Console permits it.
6. Watch Android Vitals, reviews, API health, cache freshness, background-job
   delivery, Cloudflare/backend load, and policy messages before expanding.
7. Archive the source tag, exact AAB, checksum, R8 mapping/native symbols, Play
   release record, and signing-key backups.

## 12. Near-term policy dates after launch

- **August 31, 2026:** new apps and updates must target API 36. HyprRadar does.
- **September 30, 2026:** Play package registration/identity requirements take
  effect; the new Play Console Requirements policy also affects account types.
- **November 2026:** Play's precise foreground-location declaration becomes
  available. Prepare to justify ongoing fine location for the opt-in live map
  position/follow mode rather than regional weather alone.
- **January 28, 2027:** precise-location minimum-scope compliance becomes
  mandatory, with a 30-day self-extension available.
- **February 1, 2027:** 64-bit apps targeting API 35+ must support 16 KB page
  sizes for updates. The current HyprRadar native libraries pass alignment
  checks; repeat the check on each release.

## Primary official references

- Target API: <https://support.google.com/googleplay/android-developer/answer/11926878>
- Background location: <https://support.google.com/googleplay/android-developer/answer/9799150>
- Foreground precise location/minimum scope: <https://support.google.com/googleplay/android-developer/answer/17033915>
- User Data/privacy: <https://support.google.com/googleplay/android-developer/answer/10144311>
- Data safety: <https://support.google.com/googleplay/android-developer/answer/10787469>
- Android App Bundles: <https://support.google.com/googleplay/android-developer/answer/9844279>
- Play App Signing: <https://support.google.com/googleplay/android-developer/answer/9842756>
- Create/set up an app: <https://support.google.com/googleplay/android-developer/answer/9859152>
- Store assets: <https://support.google.com/googleplay/android-developer/answer/9866151>
- New Personal account testing: <https://support.google.com/googleplay/android-developer/answer/14151465>
- Device verification: <https://support.google.com/googleplay/android-developer/answer/14316361>
- Package registration: <https://support.google.com/googleplay/android-developer/answer/16984799>
- Health declaration: <https://support.google.com/googleplay/android-developer/answer/14738291>
- Government information: <https://support.google.com/googleplay/android-developer/answer/9514050>
- Foreground services: <https://support.google.com/googleplay/android-developer/answer/13392821>
- 16 KB pages: <https://developer.android.com/guide/practices/page-sizes>
