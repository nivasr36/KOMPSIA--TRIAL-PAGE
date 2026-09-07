(function restoreKompsiaTheme(document, storage) {
  "use strict";

  try {
    if (storage.getItem("kompsia_theme") === "light") {
      document.documentElement.classList.add("light");
    }
  } catch (_) {
    // A blocked storage API should not prevent the storefront from loading.
  }
})(document, window.localStorage);
