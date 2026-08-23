# usetip.xyz

Two files that have to be served from the domain before a tip link opens the
app when it is tapped. Until they are, the app still answers to `tip://claim`,
which needs nothing hosted.

Serve both at the paths below, over https, with no redirect:

    https://usetip.xyz/.well-known/apple-app-site-association
    https://usetip.xyz/.well-known/assetlinks.json

The Apple file must be served as `application/json` and must not have a file
extension. Apple fetches it directly rather than through a CDN cache, so a 404
or a redirect is a silent failure: the link opens Safari and nothing says why.

The Android fingerprint currently listed is the local debug keystore. A release
build is signed with a different key, so its fingerprint has to be added to the
array before installed release builds will verify. Get it with:

    keytool -list -v -keystore <release.keystore> -alias <alias>

Both entries can coexist, which is what you want while testing.
