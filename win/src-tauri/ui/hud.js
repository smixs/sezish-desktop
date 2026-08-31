// The Rust side drives the page with `window.sezishPhase('recording' | 'transcribing' | 'idle')`.
(function () {
  var phases = { idle: true, recording: true, transcribing: true };
  window.sezishPhase = function (phase) {
    if (!phases[phase]) return;
    document.body.setAttribute("data-phase", phase);
  };
})();
