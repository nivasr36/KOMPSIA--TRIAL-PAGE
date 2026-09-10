(function configureKompsia(global) {
  "use strict";

  global.KOMPSIA_CONFIG = Object.freeze({
    supabaseUrl: "https://dkdebolrgpufryasvsvs.supabase.co",
    supabasePublishableKey: "sb_publishable_po_3uQzx1_-rTZ5_1oE7gw_CVjZMyY8",
    features: Object.freeze({
      checkout: false,
      googleAuth: false,
    }),
  });
})(window);
