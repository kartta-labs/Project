# Kartta App Shared Resources

The "public/assets" directory, served at the url "/assets/" in the Kartta Labs
Suite, contains css and JS files which implement some common UI components
intended to be shared across all apps in the suite.  This document gives
developer instructions for incorporating these components into an app, or for
working with a current app that uses them.

## Include CSS/JS Files

Apps should include the files `/assets/kartta-app.css` and `/assets/kartta-app.js` on every page, i.e.
include something like

```
  <link rel="stylesheet" href="/assets/kartta-app.css">
  <script src="/assets/kartta-app.js"></script>
```

in the `<head>` of every page.

## Install Cookie Bar

The "cookie bar" is a short horizontal strip that appears at the top of a page
alerting the user to the fact that the site uses cookies.  Once the user
confirms they've seen it by clicking on the "Got It" button, the bar is
dismissed, and a cookie gets set which prevents the bar from showing again.
Many countries require this kind of notice about cookies, so it should be a part
of every page.  The same cookie is used for all apps in the Kartta Labs suite,
so the user will only see and dismiss the cookie bar once, regardless of which
page/app they visit first.

The cookie bar should be visible on every page until the users dismisses it, so
it needs to be included on every page, even pages that require login -- the bar
does not prevent accessing any page ... it just sticks around at the top until
the user dismisses it.

To include the cookie bar, put the following at the top of the `<body>` section
in the app's html:

```
<div id="kartta-app-cookie-bar"></div>
```

When the page is finished loading, the `kartta-app.js` file looks for a DOM
element with this `id`, and replaces it with the cookie bar if the cookie is not
set, or removes it if the cookie is set.

It might be necessary to tweak the site's css for the other page elements in
order to allow the bar to display correctly.  In particular, apps can't use
absolute positioning to align content to the top of the screen.  The cookie
bar should appear at the top of the screen, and the rest of the page content should
appear below it.

Note that when the user clicks the "Got It" button in the cookie bar, the page will
be reloaded using the current page address after the cookie is set; aftef this reload
the page will render without the cookie bar.

## Install Logo and App Menu

To use the shared logo and app menu, the app should display a header bar at the
top of the page that is exactly 56 pixels tall and which has a 1px solid black
bottom border.  This header itself isn't managed with shared code because of the
variety of existing page layout requirements among the various apps.  Each app
is free to implement its header in any way --- it can be a `<div>` element, a `<header>`
element, or any other DOM element, as long as it has the desired common height,
background, and bottom border.

To install the shared Kartta Labs logo and app menu, include the following as the first thing
inside the header bar:

```
<div id="kartta-app-menu"></div>
```

Since each app can have page-wide css rules affecting all elements in the page,
you might need to surround that `<div>` inside another one with a custom class
that you can provide app-specific css positioning rules for, in order to get the
logo to show in exactly the right place.  Compare the logo position in the
current app to the other apps to confirm the position.

## Install App Common Footer

Kartta apps all have a common footer with links to informational pages such as
the site-wide FAQ, policy, about, and help pages.  There are two ways to use the footer:

### Flow Footer Display

To include a footer in the page after all the other content
on the page, include the following as the last thing in the `<body>`:

```
<div class="kartta-footer-opaque">
  <div class="kartta-footer-overlay-container">
    <div class="kartta-footer-background">
      <div id="kartta-footer-content"></div>
    </div>
  </div>
</div>
```

This will render the footer vertically after all the other content on the page;
the actual position of the footer will depend on how much other content is on
the page.  If there is a lot of content, the user might have to scroll down to
see the footer, and if there isn't much content, the footer might not be at the
bottom of the screen -- it'll come right after the other content in the page.

### Fixed Transparent Footer Display

To include a footer at a fixed position at the bottom of the screen, in a
semi-transparent display that is visible above whatever other page content is
present, include the following as the last thing in the `<body>`:

```
<div class="kartta-footer-overlay">
  <div class="kartta-footer-overlay-container">
    <div class="kartta-footer-background">
      <div id="kartta-footer-content"></div>
    </div>
  </div>
</div>
```

This kind of display is appropriate for full-screen apps such as a map.

### Custom Footer Display

The actual element that corresponds to the content of the footer in the above
two html snippets is `<div id="kartta-footer-content"></div>`; it is this
element which will get replaced with the footer links when the page loads.  If
an app needs to use a footer layout that's incompatible with either of the above
two approaches, it can simply include `<div id="kartta-footer-content"></div>`,
and use custom css to position it.
