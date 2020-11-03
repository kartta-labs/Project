// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

(()=>{
  const menuItems = [
      { "menuText": "home",
        "url": "/",
        "logo": "/assets/site-logo-long.png"
      },
      { "menuText": "editor",
        "url": "/e/",
        "logo": "/assets/editor-logo.png"
      },
      { "menuText": "warper",
        "url": "/w/",
        "logo": "/assets/warper-logo.png"
      },
      { "menuText": "reservoir",
        "url": "/r/",
        "logo": "/assets/reservoir-logo.png"
      }
  ];

  function currentPrefix() {
    const loc = window.location.pathname;
    const i = loc.indexOf("/", 1);
    if (i < 0) {
      return loc;
    }
    return loc.substring(0, i+1);
  }

  function currentLogoUrl() {
    url = currentPrefix();
    for (let i = 0; i < menuItems.length; ++i) {
      if (menuItems[i].url == url) {
        return menuItems[i].logo;
      }
    }
    return menuItems[0].logo;
  }

  function createElement(tag, attrs, text) {
    const el = document.createElement(tag);
    if (attrs != undefined) {
      for (const [attr, value] of Object.entries(attrs)) {
        el.setAttribute(attr, value);
      }
    }
    if (text) {
      el.innerHTML = text;
    }
    return el;
  }


  /**
   * Enhances a url with hash values and/or url parameters from the
   * current page, in order to preserve some state when switching
   * applications.
   *
   * @param url (String) A url from one of the 'menuItems' array above.
   *
   * @returns (String) the enhanced url
   */
  function enhancedMenuUrl(url) {
    // When navigating from kartta (location "/") to editor (url "/e/"), propagate
    // zoom,lat,lon to preserve the current map view.  Note that for some reason
    // the zoom levels differ by 1, and editor only recognizes integer zoom levels.
    if (window.location.pathname == "/" && url == "/e/") {
      const m = window.location.hash.match(/#([\d.]+)\/([-\d.]+)\/([-\d.]+)/);
      if (m.length == 4) {
        const zoom = Math.floor(parseFloat(m[1])) + 1;
        const lat = m[2];
        const lon = m[3];
        return url + "#map=" + zoom + "/" + lat + "/" + lon;
      }
    }

    // When navigating from editor or id (location prefix "/e/") to kartta (url = "/"),
    // propagate zoom,lat,lon to preserve the current map view.
    if (window.location.pathname.startsWith("/e/") && url == "/") {
      const m = window.location.hash.match(/#map=([\d.]+)\/([-\d.]+)\/([-\d.]+)/);
      if (m.length == 4) {
        const zoom = parseFloat(m[1]) - 1;
        const lat = m[2];
        const lon = m[3];
        return url + "#" + zoom + "/" + lat + "/" + lon;
      }
    }

    // Otherwise no enhancement
    return url;
  }

  function createMenuItem(text, url) {
    const elA = document.createElement("a");
    elA.setAttribute("href", url);
    const elDiv = document.createElement("div");
    elDiv.setAttribute("class", "kartta-menu-item");
    elDiv.innerHTML = text;
    elA.appendChild(elDiv);
    elDiv.addEventListener('click', (e) => {
    const href = (
       window.location.protocol
            + "//"
            + window.location.hostname
            + (window.location.port != "" ? (":" + window.location.port) : "")
            + enhancedMenuUrl(url)
    );
    window.location.href = href;
    e.preventDefault();
    });
    return elA;
  }

  function createDropDown() {
    const elDiv = createElement("div", {
      "class": "kartta-app-menu-dropdown",
    });
    menuItems.forEach(item => {
      elDiv.appendChild(createMenuItem(item.menuText, item.url));
    });
    return elDiv;
  }

  function installAppMenu() {
    const appMenuPlaceholder = document.getElementById("kartta-app-menu");

    if (!appMenuPlaceholder) {
      return;
    }

    const elem = createElement("div", {
      "class": "kartta-logo-wrapper",
    });
    const img = createElement("img", {
      "class": "kartta-app-menu-logo",
      "src": currentLogoUrl(),
    });
    elem.appendChild(img);

    const menu = createDropDown();
    const menuPlacer = createElement("div", {
      "class": "kartta-menu-placer kartta-app-menu-hidden"
    });
    menuPlacer.appendChild(menu);
    elem.appendChild(menuPlacer);

    const fudge = 5;
    const moveListener = (e) => {
      rect = menuPlacer.getBoundingClientRect();
      if ((e.clientX > rect.right + fudge)
          || (e.clientX < rect.left - fudge)
          || (e.clientY < rect.top - fudge)
          || (e.clientY > rect.bottom + fudge)) {
          menuPlacer.classList.add("kartta-app-menu-hidden");
          document.removeEventListener('mousemove', moveListener);
      }
    };

    const displayMenu = (e) => {
      menuPlacer.classList.remove("kartta-app-menu-hidden");
      document.addEventListener('mousemove', moveListener);
    };

    img.addEventListener('mouseenter', displayMenu);
    img.addEventListener('click', displayMenu);

    appMenuPlaceholder.parentNode.insertBefore(elem, appMenuPlaceholder);
    appMenuPlaceholder.parentNode.removeChild(appMenuPlaceholder);
  }

  function writeCookie(name, value) {
    document.cookie = encodeURIComponent(name) + "=" + encodeURIComponent(value) + "; path=/";
  }

  function readCookie(name) {
    const name_equals = encodeURIComponent(name) + "=";
    const words = document.cookie.split(';');
    for (var i = 0; i < words.length; i++) {
      let c = words[i];
      while (c.charAt(0) === ' ') {
        c = c.substring(1, c.length);
      }
      if (c.indexOf(name_equals) === 0) {
        return decodeURIComponent(c.substring(name_equals.length, c.length));
      }
    }
    return null;
  }

  function createCookieBar() {
    const outerDiv = createElement("div", {
      "class": "kartta-cookie-bar"
    });
    const leftDiv = createElement("div", {
      "class": "kartta-cookie-bar-left"
    }, "This site uses cookies from Google to deliver its services and to analyze traffic.");
    leftDiv.appendChild(createElement("a", {
      "class": "kartta-cookie-bar-learn-more-link",
      "href": "https://policies.google.com/technologies/cookies"
    }, "Learn more."));
    const rightDiv = createElement("div", {
      "class": "kartta-cookie-bar-right"
    });
    rightDiv.appendChild(createElement("a", {
      "class": "kartta-cookie-bar-ok-link",
      "href": "javascript:void(0)"
    }, "Ok, Got it."));
    rightDiv.addEventListener('click', (e) => {
      writeCookie("kartta_allow_cookies", "yes");
      // In a perfect world we would just do
      //    outerDiv.parentNode.removeChild(outerDiv);
      // here to dynamically remove the cookie bar, but instead we
      // force a page reload because some apps (e.g. editor) don't
      // correctly handle reflowing their content when an element is
      // removed.  Since the cookie is set at this point, the page
      // will be rendered without the cookie bar after reload.
      window.location.reload(false);
    });
    outerDiv.appendChild(leftDiv);
    outerDiv.appendChild(rightDiv);
    return outerDiv;
  }

  function installCookieBar() {
    const cookieBarPlaceholder = document.getElementById("kartta-app-cookie-bar");
    if (!cookieBarPlaceholder) {
      return;
    }
    if (readCookie("kartta_allow_cookies") != "yes") {
      cookieBarPlaceholder.parentNode.insertBefore(createCookieBar(), cookieBarPlaceholder);
    }
    cookieBarPlaceholder.parentNode.removeChild(cookieBarPlaceholder);
  }

  function createFooterItem(url, text) {
    const div = createElement("div", {
      "class": "kartta-footer-item"
    });
    const a = createElement("a", {
      "href": url
    }, text);
    div.appendChild(a);
    return div;
  }

  function createFooterSeparator() {
    return createElement("div", {
      "class": "kartta-footer-separator"
    }, "|");
  }

  function installFooter() {
    const footerPlaceholder = document.getElementById("kartta-footer-content");
    if (!footerPlaceholder) {
      return;
    }
    footerPlaceholder.parentNode.insertBefore(createFooterItem("/faq", "FAQ"), footerPlaceholder);
    footerPlaceholder.parentNode.insertBefore(createFooterSeparator(), footerPlaceholder);
    footerPlaceholder.parentNode.insertBefore(createFooterItem("https://policies.google.com/privacy", "DATA PRIVACY"), footerPlaceholder);
    footerPlaceholder.parentNode.insertBefore(createFooterSeparator(), footerPlaceholder);
    footerPlaceholder.parentNode.insertBefore(createFooterItem("https://policies.google.com/terms", "TERMS OF SERVICE"), footerPlaceholder);
    footerPlaceholder.parentNode.insertBefore(createFooterSeparator(), footerPlaceholder);
    footerPlaceholder.parentNode.insertBefore(createFooterItem("/help", "HELP"), footerPlaceholder);
    footerPlaceholder.parentNode.insertBefore(createFooterSeparator(), footerPlaceholder);
    footerPlaceholder.parentNode.insertBefore(createFooterItem("/about", "ABOUT"), footerPlaceholder);
    footerPlaceholder.parentNode.removeChild(footerPlaceholder);
  }

  document.addEventListener("DOMContentLoaded", () => {
    installAppMenu();
    installCookieBar();
    installFooter();
  });

})();
