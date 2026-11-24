# Setting up Google sign-in for Google Drive sync

fweek syncs through Google Drive with a sign-in "client" registered in a
Google Cloud project. The client's id and secret go into the builds, never
into this repository. These steps need the developer's Google account; each
says why it is there.

What fweek asks a user's Google account for: `openid` and `email` (to show
which account is connected) and `https://www.googleapis.com/auth/drive.appdata`
(its own hidden folder in that account's Drive, nothing else). All three are
*non-sensitive* scopes: the app needs no Google review, users see no
"unverified app" warning, and the 100-user cap for unverified apps does not
apply.

Public pages the consent screen links to (repository
[`yourj4m/planner-oauth-site`](https://github.com/yourj4m/planner-oauth-site)):

- Home page: https://yourj4m.github.io/planner-oauth-site/
- Privacy policy: https://yourj4m.github.io/planner-oauth-site/privacy/
- Terms of service: https://yourj4m.github.io/planner-oauth-site/terms/

## 1. Prove that you own `yourj4m.github.io` (Google Search Console)

*Why:* Google wants the domain of the home page and privacy policy to be an
"authorized domain" that you have verified. For `github.io` only the address
`https://yourj4m.github.io/` can be verified (by a file at its root); the
whole-domain kind needs DNS access, which GitHub does not give.

1. Open https://search.google.com/search-console with the Google account
   that owns the Cloud project, choose *Add property* → **URL prefix** and
   enter `https://yourj4m.github.io/`.
2. Choose the **HTML file** method. It offers a file named like
   `google1234abcd5678ef90.html`. Its name and one-line content are not
   secret (anyone can read them once published).
3. Give that file name to the developer's helper (or create the repository
   yourself): a public repository **`yourj4m/yourj4m.github.io`** holding
   only that file and an empty `.nojekyll`, published with GitHub Pages
   from `main`. This makes `https://yourj4m.github.io/` itself exist; the
   project sites under it (`/recipes/`, `/planner-oauth-site/`) are not
   affected, as long as that repository has no folders of those names.
4. Back in Search Console, press **Verify**. Leave the file there for good:
   Google checks it again from time to time.

## 2. The Cloud project and the Drive API

1. https://console.cloud.google.com/ → select the project (create one called
   `fweek` if there is none; do not make a second one).
2. *APIs & Services* → *Library* → **Google Drive API** → **Enable**.
   *Why:* the sync reads and writes its files through it.

## 3. Google Auth Platform

https://console.cloud.google.com/auth/overview

**Branding**

| Field | Value |
|---|---|
| App name | `fweek` |
| User support email | your Google account's address |
| App logo | leave empty (a logo makes Google require brand verification) |
| Application home page | `https://yourj4m.github.io/planner-oauth-site/` |
| Application privacy policy link | `https://yourj4m.github.io/planner-oauth-site/privacy/` |
| Application terms of service link | `https://yourj4m.github.io/planner-oauth-site/terms/` |
| Authorized domains | `yourj4m.github.io` |
| Developer contact information | your email address |

*Why:* these are shown to people when they connect, and Google requires the
links for apps in production. Without brand verification the consent screen
shows the domain rather than the app name; that is expected.

**Audience:** User type **External** (people with their own Google
accounts). While testing, add your own account(s) under *Test users*.

**Data Access** → *Add or remove scopes*: tick exactly

- `openid`
- `.../auth/userinfo.email`
- `.../auth/drive.appdata`

and save. Do not add `.../auth/drive` or `.../auth/drive.readonly`.

**Clients** → *Create client* → Application type **Desktop app**, name
`fweek` → *Create* → **Download JSON**. Save the file as
`~/.config/fweek/google-oauth.json` (`chmod 600` it). *Why Desktop app:*
fweek signs in through the system's browser and receives the answer on a
one-time local address (loopback + PKCE), which is what Google's desktop
clients are for. `tools/desktop-build.sh` and `tools/android-build.sh` read
that file; GitHub Actions reads the same two values from secrets (step 5).

Note on Android: fweek uses the same browser sign-in on the phone, with the
same Desktop client, so that it works without Google Play services (as on
LineageOS). Google's policy asks for a separate client per platform and
recommends its Play-services sign-in on Android; Google does not block the
browser sign-in there, but it is a deviation from that policy, and a
separate Android client is the way to remove it.

## 4. Test, then publish

1. Build with the client: `tools/desktop-build.sh`, then
   Settings → Sync → Google Drive → **Connect Google account**. Try a second
   device or a second test account.
2. While the project is in **Testing**, Google lets a sign-in last 7 days.
   When it works: *Audience* → **Publish app** → *In production*. With only
   the three scopes above there is nothing to submit for verification.
   Sign-ins made while testing keep their 7-day limit; connect again once
   after publishing.

## 5. Builds on GitHub

Repository *Settings* → *Secrets and variables* → *Actions* → *New
repository secret*:

| Secret | Value |
|---|---|
| `FWEEK_GOOGLE_CLIENT_ID` | `client_id` from `google-oauth.json` |
| `FWEEK_GOOGLE_CLIENT_SECRET` | `client_secret` from `google-oauth.json` |
| `ANDROID_KEYSTORE_BASE64` | output of `base64 -w0 ~/.config/weektodo/android-release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | content of `~/.config/weektodo/android-release.password` |

The client secret of a Desktop app is not secret in Google's sense (every
copy of the app carries it); it is kept out of the repository all the same.
The Android signing key is: anyone with it could publish updates that phones
accept as fweek. Without the two Android secrets the workflow builds no APK.

## Limits

- No Google verification is needed or requested. If fweek ever asked for a
  sensitive scope (it does not), Google would show an "unverified app"
  warning and cap it at 100 new users until verified.
- Each person's planner lives in their own Google account; disconnecting in
  fweek withdraws its access and leaves the files in Drive (removable under
  Drive → Settings → Manage apps → fweek → Delete hidden app data).
