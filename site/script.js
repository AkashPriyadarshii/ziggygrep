/* ziggygrep site interactions: terminal tabs plus copy keys */
(function () {
  "use strict";

  /* 1. Terminal tab switch (instant swap, no fade) */
  var tabBtns = document.querySelectorAll(".terminal-tab-btn");
  tabBtns.forEach(function (tab) {
    tab.addEventListener("click", function () {
      var targetId = tab.getAttribute("data-target");
      if (!targetId) return;
      tabBtns.forEach(function (b) { b.classList.remove("active"); });
      tab.classList.add("active");
      document.querySelectorAll(".terminal-body").forEach(function (body) {
        body.style.display = (body.id === targetId) ? "block" : "none";
      });
    });
  });

  /* 2. Copy keys (label tick, no animation) */
  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var text = btn.getAttribute("data-copy") || "";
      function done() {
        var original = btn.textContent;
        btn.textContent = "Copied";
        setTimeout(function () { btn.textContent = original; }, 1200);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, done);
      } else {
        var ta = document.createElement("textarea");
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); } catch (e) { /* noop */ }
        document.body.removeChild(ta);
        done();
      }
    });
  });
})();
