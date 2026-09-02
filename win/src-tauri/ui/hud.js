// The Rust side drives the page with `window.sezishPhase('recording' | 'transcribing' | 'idle')`.
(function () {
  var phases = { idle: true, recording: true, transcribing: true };
  var onPhase = null;

  window.sezishPhase = function (phase) {
    if (!phases[phase]) return;
    document.body.setAttribute("data-phase", phase);
    if (onPhase) onPhase(phase);
  };

  /* Plasma rim. Port of the metal-fx effect 1 shader, run in the sezish
     palette. Defaults match the reference "chromatic" preset. */

  var PRESET = {
    speed: 1.2,
    direction: 80, // degrees, converted to radians on upload
    intensity: 2,
    scale: 0.8, // inverse: the shader does (uv - 0.5) * u_scale, so halving it
                // doubles the on-screen size of the plasma blobs. 0.53 = 3x.
    softness: 0.18,
    distortion: 0.3,
    complexity: 0.68,
    shape: 1,
    blur: 1,
    vignette: 0.26,
    vigOpacity: 0.6,
    shaderOpacity: 1
  };

  // Stops at t = 0, 0.25, 0.5, 0.75, 1.0. Slots 6 and 7 are unused by effect 1.
  var COLORS = ["#000000", "#ffa700", "#ff3600", "#ff0087", "#0d0d0d", "#000000", "#000000"];
  var ALPHAS = [1, 1, 1, 1, 1, 1, 1];

  var STATIC_TIME = 7.0; // frozen frame for prefers-reduced-motion

  var UNIFORM_NAMES = [
    "u_resolution", "u_time",
    "u_color1", "u_color2", "u_color3", "u_color4", "u_color5", "u_color6", "u_color7",
    "u_alpha1", "u_alpha2", "u_alpha3", "u_alpha4", "u_alpha5", "u_alpha6", "u_alpha7",
    "u_intensity", "u_scale", "u_direction", "u_softness", "u_distortion",
    "u_complexity", "u_shape", "u_vignette", "u_vigOpacity", "u_blur", "u_shaderOpacity"
  ];

  var VERT_SRC =
    "attribute vec2 a_position;\n" +
    "void main() { gl_Position = vec4(a_position, 0.0, 1.0); }";

  var FRAG_SRC = `
  precision highp float;

  uniform vec2 u_resolution;
  uniform float u_time;
  uniform vec3 u_color1, u_color2, u_color3, u_color4, u_color5, u_color6, u_color7;
  uniform float u_alpha1, u_alpha2, u_alpha3, u_alpha4, u_alpha5, u_alpha6, u_alpha7;
  uniform float u_intensity, u_scale, u_direction;
  uniform float u_softness, u_distortion, u_complexity, u_shape;
  uniform float u_vignette, u_vigOpacity, u_blur, u_shaderOpacity;

  vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
  vec2 mod289v2(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
  vec3 permute(vec3 x) { return mod289((x * 34.0 + 1.0) * x); }

  float snoise(vec2 v) {
    const vec4 C = vec4(0.211324865405187, 0.366025403784439,
                        -0.577350269189626, 0.024390243902439);
    vec2 i = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289v2(i);
    vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m; m = m * m;
    vec3 x_ = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x_) - 0.5;
    vec3 ox = floor(x_ + 0.5);
    vec3 a0 = x_ - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    vec3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
  }

  float fbm(vec2 p, float oct) {
    float val = 0.0, amp = 0.5;
    int n = int(oct);
    for (int i = 0; i < 7; i++) {
      if (i >= n) break;
      val += amp * snoise(p);
      p *= 2.0;
      amp *= 0.5;
    }
    return val;
  }

  float nfbm(vec2 p) { return fbm(p, 3.0 + u_complexity * 4.0); }

  /* 5-stop palette used by effect 1 (Plasma). Stops at t = 0, 0.25, 0.5,
   * 0.75, 1.0. */
  vec3 palette(float t) {
    t = clamp(t, 0.0, 1.0);
    t = t * t * (3.0 - 2.0 * t);
    float k = 64.0;
    float w1 = u_alpha1 * exp(-k * t * t);
    float w2 = u_alpha2 * exp(-k * (t - 0.25) * (t - 0.25));
    float w3 = u_alpha3 * exp(-k * (t - 0.5)  * (t - 0.5));
    float w4 = u_alpha4 * exp(-k * (t - 0.75) * (t - 0.75));
    float w5 = u_alpha5 * exp(-k * (t - 1.0)  * (t - 1.0));
    float total = w1 + w2 + w3 + w4 + w5 + 0.0001;
    return (u_color1 * w1 + u_color2 * w2 + u_color3 * w3 +
            u_color4 * w4 + u_color5 * w5) / total;
  }

  /* Per-pixel alpha that re-introduces transparency when any palette stop's
   * alpha drops below 1. All-1 alphas make this return ~1 for every pixel. */
  float paletteAlpha(float t) {
    t = clamp(t, 0.0, 1.0);
    t = t * t * (3.0 - 2.0 * t);
    float k = 64.0;
    float w1 = u_alpha1 * exp(-k * t * t);
    float w2 = u_alpha2 * exp(-k * (t - 0.25) * (t - 0.25));
    float w3 = u_alpha3 * exp(-k * (t - 0.5)  * (t - 0.5));
    float w4 = u_alpha4 * exp(-k * (t - 0.75) * (t - 0.75));
    float w5 = u_alpha5 * exp(-k * (t - 1.0)  * (t - 1.0));
    float totalW = w1 + w2 + w3 + w4 + w5 + 0.0001;
    float rawW = exp(-k * t * t)
               + exp(-k * (t - 0.25) * (t - 0.25))
               + exp(-k * (t - 0.5)  * (t - 0.5))
               + exp(-k * (t - 0.75) * (t - 0.75))
               + exp(-k * (t - 1.0)  * (t - 1.0))
               + 0.0001;
    return totalW / rawW;
  }

  vec2 warp(vec2 p, float t) {
    float str = u_distortion * 2.0;
    return vec2(
      nfbm(p + vec2(t * 0.1, 0.0)),
      nfbm(p + vec2(0.0, t * 0.12) + 5.0)
    ) * str;
  }

  /* Plasma: four sine bands warped by an FBM field, mapped through the
   * 5-stop palette. */
  vec3 computeEffect(vec2 uv, float aspect, float t, float dist, float cpx) {
    vec2 p = (uv - 0.5) * u_scale;
    p.x *= aspect;
    p += vec2(cos(u_direction), sin(u_direction)) * t * 0.15;

    float freq = 3.0 + cpx * 8.0;
    float val = 0.0;
    val += sin(p.x * freq + t);
    val += sin(p.y * freq + t * 1.3);
    val += sin((p.x + p.y) * freq * 0.7 + t * 0.7);
    val += sin(length(p) * freq * 0.8 - t * 1.5);
    vec2 w = warp(p, t);
    val += (w.x + w.y) * dist;
    val = val * 0.2 * u_intensity + 0.5;

    return palette(clamp(val, 0.0, 1.0));
  }

  void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float aspect = u_resolution.x / u_resolution.y;
    float t = u_time;          // JS already multiplied u_time by preset.speed.
    float dist = u_distortion;
    float cpx = u_complexity;

    /* 5-tap cross blur (center + cardinal offsets). Active whenever blur > 0. */
    vec3 col;
    if (u_blur < 0.01) {
      col = computeEffect(uv, aspect, t, dist, cpx);
    } else {
      float r = u_blur * 0.02;
      col  = computeEffect(uv,                  aspect, t, dist, cpx) * 0.4;
      col += computeEffect(uv + vec2( r, 0.0),  aspect, t, dist, cpx) * 0.15;
      col += computeEffect(uv + vec2(-r, 0.0),  aspect, t, dist, cpx) * 0.15;
      col += computeEffect(uv + vec2(0.0,  r),  aspect, t, dist, cpx) * 0.15;
      col += computeEffect(uv + vec2(0.0, -r),  aspect, t, dist, cpx) * 0.15;
    }

    /* Gamma punch: the contrast pop that defines the chromatic highlights. */
    col = pow(col, vec3(1.3));

    /* Vignette. The 40-px scale is hard-coded in the reference engine. */
    float edgeDist = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    float vigPx = 40.0 / min(u_resolution.x, u_resolution.y);
    float vigRange = vigPx * (1.0 + u_vignette * 3.0);
    float vig = edgeDist * edgeDist / (vigRange * vigRange);
    vig = smoothstep(0.0, 1.0, vig);
    col *= mix(1.0, vig, u_vignette * u_vigOpacity);

    /* Per-pixel alpha. All-1 alphas collapse this to ~1. */
    float colorAlpha = (u_alpha1 + u_alpha2 + u_alpha3 + u_alpha4 + u_alpha5) / 5.0;
    if (colorAlpha < 0.999) {
      vec3 c1d = col - u_color1, c2d = col - u_color2, c3d = col - u_color3,
           c4d = col - u_color4, c5d = col - u_color5;
      float prox1 = exp(-8.0 * dot(c1d, c1d));
      float prox2 = exp(-8.0 * dot(c2d, c2d));
      float prox3 = exp(-8.0 * dot(c3d, c3d));
      float prox4 = exp(-8.0 * dot(c4d, c4d));
      float prox5 = exp(-8.0 * dot(c5d, c5d));
      float pTotal = prox1 + prox2 + prox3 + prox4 + prox5 + 0.0001;
      colorAlpha = (prox1 * u_alpha1 + prox2 * u_alpha2 + prox3 * u_alpha3 +
                    prox4 * u_alpha4 + prox5 * u_alpha5) / pTotal;
    }
    float alpha = colorAlpha;

    /* Keep the effect-1-unused uniforms live for drivers that strip them.
     * The contribution is provably zero. */
    alpha += 0.0 * (u_softness + u_shape +
                    u_alpha6 + u_alpha7 +
                    u_color6.x + u_color7.x);

    gl_FragColor = vec4(col, alpha * u_shaderOpacity);
  }
`;

  function hexToRgb(hex) {
    var h = hex.replace("#", "");
    return [
      parseInt(h.slice(0, 2), 16) / 255,
      parseInt(h.slice(2, 4), 16) / 255,
      parseInt(h.slice(4, 6), 16) / 255
    ];
  }

  function compile(gl, type, src) {
    var shader = gl.createShader(type);
    if (!shader) return null;
    gl.shaderSource(shader, src);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      gl.deleteShader(shader);
      return null;
    }
    return shader;
  }

  function link(gl, vert, frag) {
    var program = gl.createProgram();
    if (!program) return null;
    gl.attachShader(program, vert);
    gl.attachShader(program, frag);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      gl.deleteProgram(program);
      return null;
    }
    return program;
  }

  function initPlasma() {
    var canvas = document.querySelector(".rim-plasma");
    if (!canvas || !window.WebGLRenderingContext) return;

    var reduce =
      !!window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    var gl = null;
    try {
      gl = canvas.getContext("webgl", {
        alpha: true,
        premultipliedAlpha: false,
        antialias: false,
        // Frozen frames (reduced motion, transcribing) would be wiped on the
        // next composite without this.
        preserveDrawingBuffer: true
      });
    } catch (e) {
      gl = null;
    }
    if (!gl) return; // no .webgl-ok: the conic gradient keeps spinning

    var vert = compile(gl, gl.VERTEX_SHADER, VERT_SRC);
    var frag = compile(gl, gl.FRAGMENT_SHADER, FRAG_SRC);
    if (!vert || !frag) return;
    var program = link(gl, vert, frag);
    if (!program) return;

    gl.useProgram(program);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(
      gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
      gl.STATIC_DRAW
    );
    var aPosition = gl.getAttribLocation(program, "a_position");
    gl.enableVertexAttribArray(aPosition);
    gl.vertexAttribPointer(aPosition, 2, gl.FLOAT, false, 0, 0);

    var u = {};
    for (var i = 0; i < UNIFORM_NAMES.length; i++) {
      u[UNIFORM_NAMES[i]] = gl.getUniformLocation(program, UNIFORM_NAMES[i]);
    }

    for (var c = 0; c < 7; c++) {
      var rgb = hexToRgb(COLORS[c]);
      if (u["u_color" + (c + 1)]) gl.uniform3f(u["u_color" + (c + 1)], rgb[0], rgb[1], rgb[2]);
      if (u["u_alpha" + (c + 1)]) gl.uniform1f(u["u_alpha" + (c + 1)], ALPHAS[c]);
    }
    if (u.u_intensity) gl.uniform1f(u.u_intensity, PRESET.intensity);
    if (u.u_scale) gl.uniform1f(u.u_scale, PRESET.scale);
    if (u.u_direction) gl.uniform1f(u.u_direction, (PRESET.direction * Math.PI) / 180);
    if (u.u_softness) gl.uniform1f(u.u_softness, PRESET.softness);
    if (u.u_distortion) gl.uniform1f(u.u_distortion, PRESET.distortion);
    if (u.u_complexity) gl.uniform1f(u.u_complexity, PRESET.complexity);
    if (u.u_shape) gl.uniform1f(u.u_shape, PRESET.shape);
    if (u.u_vignette) gl.uniform1f(u.u_vignette, PRESET.vignette);
    if (u.u_vigOpacity) gl.uniform1f(u.u_vigOpacity, PRESET.vigOpacity);
    if (u.u_blur) gl.uniform1f(u.u_blur, PRESET.blur);
    if (u.u_shaderOpacity) gl.uniform1f(u.u_shaderOpacity, PRESET.shaderOpacity);

    // Swap the CSS fallback for the canvas before measuring it.
    document.body.classList.add("webgl-ok");

    function resize() {
      var dpr = window.devicePixelRatio || 1;
      var rect = canvas.getBoundingClientRect();
      var w = Math.max(1, Math.round((rect.width || canvas.clientWidth) * dpr));
      var h = Math.max(1, Math.round((rect.height || canvas.clientHeight) * dpr));
      if (canvas.width === w && canvas.height === h) return false;
      canvas.width = w;
      canvas.height = h;
      return true;
    }

    function draw(timeSec) {
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      if (u.u_resolution) gl.uniform2f(u.u_resolution, canvas.width, canvas.height);
      if (u.u_time) gl.uniform1f(u.u_time, timeSec);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    }

    var rafId = 0;

    function frame() {
      rafId = requestAnimationFrame(frame);
      resize();
      draw((performance.now() / 1000) * PRESET.speed);
    }

    function start() {
      if (reduce || rafId) return;
      rafId = requestAnimationFrame(frame);
    }

    function stop() {
      if (!rafId) return;
      cancelAnimationFrame(rafId);
      rafId = 0;
    }

    function drawStatic() {
      resize();
      draw(STATIC_TIME * PRESET.speed);
    }

    function freeze() {
      stop();
      // The window stays up while transcribing, so keep the last frame on
      // screen instead of blanking the rim.
      resize();
      draw((performance.now() / 1000) * PRESET.speed);
    }

    // Only recording animates; the other phases hold a still frame.
    onPhase = function (phase) {
      if (reduce) return;
      if (phase === "recording") start();
      else freeze();
    };

    window.addEventListener("resize", function () {
      if (!resize()) return;
      if (reduce) drawStatic();
      else if (!rafId) draw((performance.now() / 1000) * PRESET.speed);
    });

    canvas.addEventListener("webglcontextlost", function (event) {
      event.preventDefault();
      stop();
      document.body.classList.remove("webgl-ok");
    });

    if (reduce) drawStatic();
    else if (document.body.getAttribute("data-phase") === "recording") start();
    else freeze();
  }

  initPlasma();
})();
