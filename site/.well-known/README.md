# `.well-known`

## `assetlinks.json`

**The fingerprint published here is a debug keystore.** It is the one Android
generates automatically, and every debug keystore uses the password `android`,
so it is not a secret and it is not an app identity.

That means Android App Links for `usetip.xyz` are currently delegated to a key
that cannot be shipped. `tip://` deep links work regardless — they do not rely
on this file — so nothing is broken today, but an https link will not open the
app for a real install.

Before publishing a release build:

1. Make a release keystore and point `app/android/key.properties` at it. See
   `app/android/key.properties.example`.
2. Read the release fingerprint:

       keytool -list -v -keystore ~/tip-release.jks -alias tip | grep SHA256

3. Replace the fingerprint in `assetlinks.json` with it.

`sha256_cert_fingerprints` accepts a list, so both can sit there during a
transition. Leaving the debug one there afterwards would keep the delegation
open to a key that is not a secret, so remove it once the release key works.

## `apple-app-site-association`

Served as `application/octet-stream`, which Apple ignores, so iOS universal
links fall back to `tip://`. `site/_headers` is where the content type is set
if that is worth fixing.
