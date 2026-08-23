# usetip.xyz

Everything served from the domain. Deploy the whole folder; the contents of
`site/` become the site root.

## What has to be there, and why

    /index.html
    /.well-known/apple-app-site-association
    /.well-known/assetlinks.json

The two `.well-known` files are what make a tapped tip link open the app rather
than a browser. Until they are live the app still answers to `tip://claim`,
which needs nothing hosted, so this is polish rather than a blocker.

## The Apple file is fussy

It must be served:

- over https, at exactly that path
- with no redirect, including no http to https bounce and no trailing slash fix
- as `application/json`
- with no file extension

Apple fetches it directly. A 404, a redirect, or the wrong content type is a
silent failure: the link opens Safari and nothing anywhere says why.

Check it after deploying:

    curl -sSI https://usetip.xyz/.well-known/apple-app-site-association

Look for `200` and `content-type: application/json`. If the host will not set
the content type for an extensionless file, the file has to move to a host that
will. Cloudflare Pages and Vercel both allow a header rule; most drag-and-drop
static hosts do not.

## The Android file needs the release fingerprint

The fingerprint currently listed is this machine's debug keystore. A release
build is signed with a different key, and installed release builds will not
verify until its fingerprint is added to the array:

    keytool -list -v -keystore <release.keystore> -alias <alias>

Both entries can sit in the array at once, which is what you want while
testing.

## Verifying

Apple, after deploying and reinstalling the app:

    https://app-site-association.cdn-apple.com/a/v1/usetip.xyz

Android:

    https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://usetip.xyz&relation=delegate_permission/common.handle_all_urls
