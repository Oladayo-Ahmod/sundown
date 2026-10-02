/**
 * The Sundown sky: plain three.js, no wrappers, no postprocessing.
 *
 * Illustrative scene of one trading week: a sun that sets when the oracle's blind window starts and rises when it
 * ends, a thin price ribbon that freezes flat through the window and then jumps, a faint dashed trace of what the
 * real price did meanwhile, stars and drifting dust, over a shader grid horizon. All state is a single number, the
 * model time `t` (see week.ts); the caller sets it and the scene eases toward it.
 */
import * as THREE from "three";

import { skyColours } from "./palette";
import { T_CLOSE, T_END, T_RESUME, pricePath, sunAltitude } from "./week";

export interface SkyOptions {
  canvas: HTMLCanvasElement;
  /** fewer particles, no antialiasing: phones and low-memory devices */
  low: boolean;
  /** hero: full-bleed with the content shifted right of the headline; compact: centred accent */
  layout?: "hero" | "compact";
  /** model hour to start at (the first frame is drawn there) */
  startT?: number;
}

const X0 = -6.6;
const X1 = 6.6;
const xOf = (t: number) => X0 + ((X1 - X0) * t) / T_END;
const yOf = (p: number) => 1.05 + p * 2.3;
const RIBBON_Z = 0;

const SKY_VERT = /* glsl */ `
varying vec2 vUv;
void main() { vUv = uv; gl_Position = vec4(position.xy, 0.999, 1.0); }
`;

const SKY_FRAG = /* glsl */ `
precision highp float;
varying vec2 vUv;
uniform vec3 uTop; uniform vec3 uMid; uniform vec3 uHor;
uniform float uHorizon; uniform float uAspect; uniform float uAlt; uniform float uTime;
uniform vec2 uSun;
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void main() {
  float h = clamp((vUv.y - uHorizon) / (1.0 - uHorizon), 0.0, 1.0);
  vec3 col = mix(uHor, uMid, smoothstep(0.0, 0.34, h));
  col = mix(col, uTop, smoothstep(0.22, 1.0, h));
  vec2 d2 = (vUv - uSun) * vec2(uAspect, 1.0);
  float d = length(d2);
  float vis = smoothstep(-0.62, 0.1, uAlt);
  float r = 0.052;
  float disc = smoothstep(r, r * 0.9, d);
  float glow = exp(-d * d * 22.0) * 0.55 + exp(-d * 3.4) * 0.22 + exp(-d * d * 3.0) * 0.1;
  vec3 sunCol = mix(vec3(1.0, 0.45, 0.16), vec3(1.0, 0.93, 0.8), smoothstep(-0.1, 0.55, uAlt));
  col += sunCol * glow * vis;
  col = mix(col, sunCol * 1.05, disc * vis);
  float band = exp(-pow((vUv.y - uHorizon) * 9.0, 2.0)) * 0.22 * (1.0 - smoothstep(0.35, 0.9, uAlt));
  col += vec3(0.85, 0.28, 0.5) * band * vis;
  col += (hash(gl_FragCoord.xy + uTime) - 0.5) / 255.0 * 1.6;
  gl_FragColor = vec4(col, 1.0);
}
`;

const GROUND_VERT = /* glsl */ `
varying vec3 vW;
void main() { vec4 w = modelMatrix * vec4(position, 1.0); vW = w.xyz; gl_Position = projectionMatrix * viewMatrix * w; }
`;

const GROUND_FRAG = /* glsl */ `
precision highp float;
varying vec3 vW;
uniform vec3 uHaze; uniform float uSunX; uniform float uAlt; uniform float uTime; uniform vec3 uCam;
void main() {
  float dist = length(vW.xz - uCam.xz);
  float fog = 1.0 - exp(-dist * 0.034);
  vec3 base = mix(vec3(0.012, 0.01, 0.028), uHaze * 0.55, fog);
  vec2 p = vec2(vW.x, vW.z + uTime * 0.12) / 1.2;
  vec2 g = abs(fract(p - 0.5) - 0.5) / max(fwidth(p), vec2(0.0005));
  float line = 1.0 - min(min(g.x, g.y), 1.0);
  vec3 gridCol = vec3(0.45, 0.58, 0.85);
  base += gridCol * line * 0.16 * (1.0 - fog * 0.7);
  float sd = (vW.x - uSunX) / (0.5 + dist * 0.06);
  float streak = exp(-sd * sd) * smoothstep(-0.25, 0.3, uAlt) * (0.55 + 0.45 * sin(vW.z * 2.6 - uTime * 1.4));
  base += vec3(1.0, 0.5, 0.2) * streak * 0.24 * fog;
  gl_FragColor = vec4(base, 1.0);
}
`;

const RIBBON_VERT = /* glsl */ `
attribute float aT; attribute float aSide;
varying float vT; varying float vSide;
void main() { vT = aT; vSide = aSide; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }
`;

const RIBBON_FRAG = /* glsl */ `
precision highp float;
varying float vT; varying float vSide;
uniform float uProgress; uniform float uAlpha; uniform float uTime; uniform float uDash;
void main() {
  float shown = smoothstep(uProgress + 0.5, uProgress - 0.2, vT);
  float alpha = mix(0.07, 1.0, shown);
  vec3 live = vec3(1.0, 0.77, 0.42);
  vec3 frozen = vec3(0.53, 0.66, 0.86);
  float inWin = step(${T_CLOSE}.0, vT) * (1.0 - step(${T_RESUME}.0, vT));
  vec3 col = mix(live, frozen, inWin);
  float jump = step(${T_RESUME}.0 - 0.001, vT);
  col = mix(col, vec3(1.0, 0.55, 0.25), jump * 0.35);
  float head = exp(-pow((vT - uProgress) * 0.7, 2.0));
  col += vec3(1.0, 0.9, 0.7) * head * 0.55;
  float dash = uDash > 0.5 ? step(0.5, fract(vT * 0.9)) : 1.0;
  gl_FragColor = vec4(col, alpha * uAlpha * dash);
}
`;

const POINTS_VERT = /* glsl */ `
attribute float aSize; attribute float aPhase;
uniform float uTime; uniform float uPx; uniform float uAmp;
varying float vTw;
void main() {
  vec3 p = position;
  p.x += sin(uTime * 0.05 + aPhase * 6.28) * uAmp;
  p.y += mod(uTime * 0.04 * uAmp + aPhase * 10.0, 6.0) * uAmp * 0.0;
  vTw = 0.55 + 0.45 * sin(uTime * (0.6 + aPhase) + aPhase * 40.0);
  vec4 mv = modelViewMatrix * vec4(p, 1.0);
  gl_Position = projectionMatrix * mv;
  gl_PointSize = aSize * uPx;
}
`;

const STAR_FRAG = /* glsl */ `
precision highp float;
varying float vTw; uniform float uNight; uniform float uDusk;
void main() {
  vec2 c = gl_PointCoord - 0.5;
  float a = smoothstep(0.5, 0.0, length(c));
  gl_FragColor = vec4(vec3(0.85, 0.9, 1.0), a * vTw * (uNight * 0.95 + uDusk * 0.18));
}
`;

const DUST_FRAG = /* glsl */ `
precision highp float;
varying float vTw; uniform float uNight;
void main() {
  vec2 c = gl_PointCoord - 0.5;
  float a = smoothstep(0.5, 0.0, length(c));
  vec3 col = mix(vec3(1.0, 0.72, 0.4), vec3(0.6, 0.7, 1.0), uNight);
  gl_FragColor = vec4(col, a * a * 0.5 * vTw);
}
`;

function ribbonGeometry(points: { t: number; p: number }[], width: number): THREE.BufferGeometry {
  const n = points.length;
  const pos = new Float32Array(n * 2 * 3);
  const aT = new Float32Array(n * 2);
  const aSide = new Float32Array(n * 2);
  const xy = points.map((q) => [xOf(q.t), yOf(q.p)] as const);
  for (let i = 0; i < n; i++) {
    const a = xy[Math.max(i - 1, 0)]!;
    const b = xy[Math.min(i + 1, n - 1)]!;
    let tx = b[0] - a[0];
    let ty = b[1] - a[1];
    const l = Math.hypot(tx, ty) || 1;
    tx /= l;
    ty /= l;
    const nx = -ty * width;
    const ny = tx * width;
    const [x, y] = xy[i]!;
    pos.set([x + nx, y + ny, RIBBON_Z, x - nx, y - ny, RIBBON_Z], i * 6);
    aT[i * 2] = aT[i * 2 + 1] = points[i]!.t;
    aSide[i * 2] = 1;
    aSide[i * 2 + 1] = -1;
  }
  const idx: number[] = [];
  for (let i = 0; i < n - 1; i++) {
    const a = i * 2;
    idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
  g.setAttribute("aT", new THREE.BufferAttribute(aT, 1));
  g.setAttribute("aSide", new THREE.BufferAttribute(aSide, 1));
  g.setIndex(idx);
  return g;
}

export class SkyScene {
  private renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private camera = new THREE.PerspectiveCamera(38, 1, 0.1, 220);
  private skyMat: THREE.ShaderMaterial;
  private groundMat: THREE.ShaderMaterial;
  private ribbonMats: THREE.ShaderMaterial[] = [];
  private starMat: THREE.ShaderMaterial;
  private dustMat: THREE.ShaderMaterial;
  private head: THREE.Mesh;
  private disposables: { dispose(): void }[] = [];
  private raf = 0;
  private running = false;
  private last = 0;
  private clock = 0;
  private shown = 102;
  private target = 102;
  private offX = 0;
  private offY = 0;
  private sunU0 = 0.3;
  private sunSpan = 0.42;
  private px = 1;
  private width = 1;
  private height = 1;

  constructor(private opts: SkyOptions) {
    this.renderer = new THREE.WebGLRenderer({
      canvas: opts.canvas,
      antialias: !opts.low,
      alpha: false,
      powerPreference: "high-performance",
    });
    this.renderer.setClearColor(0x07060f, 1);
    this.shown = this.target = opts.startT ?? 102;
    this.camera.position.set(0, 1.5, 11);

    // sky: a full-screen quad drawn first
    this.skyMat = new THREE.ShaderMaterial({
      vertexShader: SKY_VERT,
      fragmentShader: SKY_FRAG,
      depthTest: false,
      depthWrite: false,
      uniforms: {
        uTop: { value: new THREE.Color() },
        uMid: { value: new THREE.Color() },
        uHor: { value: new THREE.Color() },
        uHorizon: { value: 0.4 },
        uAspect: { value: 1 },
        uAlt: { value: 0 },
        uTime: { value: 0 },
        uSun: { value: new THREE.Vector2(0.5, 0.5) },
      },
    });
    const skyGeo = new THREE.PlaneGeometry(2, 2);
    const sky = new THREE.Mesh(skyGeo, this.skyMat);
    sky.frustumCulled = false;
    sky.renderOrder = -10;
    this.scene.add(sky);
    this.disposables.push(skyGeo, this.skyMat);

    // ground: dark plane with a shader grid fading into the horizon haze
    const groundGeo = new THREE.PlaneGeometry(220, 260);
    groundGeo.rotateX(-Math.PI / 2);
    this.groundMat = new THREE.ShaderMaterial({
      vertexShader: GROUND_VERT,
      fragmentShader: GROUND_FRAG,
      uniforms: {
        uHaze: { value: new THREE.Color() },
        uSunX: { value: 0 },
        uAlt: { value: 0 },
        uTime: { value: 0 },
        uCam: { value: new THREE.Vector3() },
      },
    });
    const ground = new THREE.Mesh(groundGeo, this.groundMat);
    ground.position.set(0, 0, -100);
    this.scene.add(ground);
    this.disposables.push(groundGeo, this.groundMat);

    // price ribbon (feed), its glow, and the dashed trace of the real price during the blind window
    const path = pricePath();
    const pts: { t: number; p: number }[] = [];
    for (let h = 0; h <= T_END; h++) {
      if (h === T_RESUME) pts.push({ t: h, p: path.frozen });
      pts.push({ t: h, p: path.feed[h]! });
    }
    const mkRibbon = (geo: THREE.BufferGeometry, alpha: number, additive: boolean, dash = false) => {
      const m = new THREE.ShaderMaterial({
        vertexShader: RIBBON_VERT,
        fragmentShader: RIBBON_FRAG,
        transparent: true,
        depthWrite: false,
        blending: additive ? THREE.AdditiveBlending : THREE.NormalBlending,
        side: THREE.DoubleSide,
        uniforms: {
          uProgress: { value: 0 },
          uAlpha: { value: alpha },
          uTime: { value: 0 },
          uDash: { value: dash ? 1 : 0 },
        },
      });
      this.ribbonMats.push(m);
      const mesh = new THREE.Mesh(geo, m);
      mesh.frustumCulled = false;
      mesh.renderOrder = 5;
      this.scene.add(mesh);
      this.disposables.push(geo, m);
      return mesh;
    };
    mkRibbon(ribbonGeometry(pts, 0.02), 1, false);
    mkRibbon(ribbonGeometry(pts, 0.06), 0.12, true);
    const ghost: { t: number; p: number }[] = [];
    for (let h = T_CLOSE; h <= T_RESUME; h++) ghost.push({ t: h, p: path.truth[h]! });
    mkRibbon(ribbonGeometry(ghost, 0.008), 0.55, false, true);

    // head marker on the ribbon
    const headGeo = new THREE.CircleGeometry(0.075, 24);
    const headMat = new THREE.MeshBasicMaterial({ color: 0xfff1d6, transparent: true, depthWrite: false });
    this.head = new THREE.Mesh(headGeo, headMat);
    this.head.renderOrder = 6;
    this.scene.add(this.head);
    this.disposables.push(headGeo, headMat);

    // stars and dust
    const nStars = opts.low ? 240 : 760;
    const nDust = opts.low ? 36 : 130;
    this.starMat = this.pointsMaterial(STAR_FRAG, { uNight: { value: 0 }, uDusk: { value: 0 } });
    this.dustMat = this.pointsMaterial(DUST_FRAG, { uNight: { value: 0 } });
    this.scene.add(this.points(nStars, this.starMat, (r) => [(r() - 0.5) * 120, 2 + r() * 60, -80 - r() * 20], 1.1, 2.6, 0.0));
    this.scene.add(this.points(nDust, this.dustMat, (r) => [(r() - 0.5) * 22, 0.4 + r() * 6, -3 + r() * 10], 3, 8, 0.6));
  }

  private pointsMaterial(frag: string, extra: Record<string, THREE.IUniform>) {
    const m = new THREE.ShaderMaterial({
      vertexShader: POINTS_VERT,
      fragmentShader: frag,
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
      uniforms: { uTime: { value: 0 }, uPx: { value: 1 }, uAmp: { value: 0 }, ...extra },
    });
    this.disposables.push(m);
    return m;
  }

  private points(
    n: number,
    mat: THREE.ShaderMaterial,
    place: (r: () => number) => [number, number, number],
    s0: number,
    s1: number,
    amp: number,
  ) {
    let seed = 7 + n;
    const r = () => {
      seed = (seed * 1664525 + 1013904223) >>> 0;
      return seed / 4294967296;
    };
    const pos = new Float32Array(n * 3);
    const size = new Float32Array(n);
    const phase = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      pos.set(place(r), i * 3);
      size[i] = s0 + r() * (s1 - s0);
      phase[i] = r();
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    g.setAttribute("aSize", new THREE.BufferAttribute(size, 1));
    g.setAttribute("aPhase", new THREE.BufferAttribute(phase, 1));
    mat.uniforms.uAmp!.value = amp;
    const p = new THREE.Points(g, mat);
    p.frustumCulled = false;
    p.renderOrder = 4;
    this.disposables.push(g);
    return p;
  }

  /** Where the scene should be, in model hours. The displayed value eases toward it. */
  setTarget(t: number, immediate = false) {
    this.target = Math.min(Math.max(t, 0), T_END);
    if (immediate) this.shown = this.target;
  }

  setSize(w: number, h: number) {
    this.width = Math.max(1, w);
    this.height = Math.max(1, h);
    const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    this.px = dpr;
    this.renderer.setPixelRatio(dpr);
    this.renderer.setSize(this.width, this.height, false);
    const aspect = this.width / this.height;
    this.camera.aspect = aspect;
    const hero = (this.opts.layout ?? "hero") === "hero";
    const wide = hero && this.width >= 900 && aspect > 1.2;
    const portrait = hero && aspect < 0.9;
    this.offX = wide ? 0.24 : 0;
    this.offY = portrait ? 0.3 : 0;
    this.sunU0 = wide ? 0.5 : 0.3;
    this.sunSpan = wide ? 0.32 : 0.42;
    // half-width of the scene that must fit: the ribbon spans about 13 units
    const half = wide ? 11.4 : portrait ? 7.6 : 7.1;
    const fit = half / (Math.tan((this.camera.fov * Math.PI) / 360) * aspect);
    this.camera.position.z = Math.min(Math.max(fit, 11), 34);
    this.camera.lookAt(0, 1.35, 0);
    if (this.offX || this.offY) {
      this.camera.setViewOffset(this.width, this.height, -this.width * this.offX, -this.height * this.offY, this.width, this.height);
    } else {
      this.camera.clearViewOffset();
    }
    this.camera.updateProjectionMatrix();
    this.skyMat.uniforms.uAspect!.value = aspect;
    this.starMat.uniforms.uPx!.value = dpr;
    this.dustMat.uniforms.uPx!.value = dpr * (this.width < 700 ? 0.8 : 1);
  }

  private frame = (now: number) => {
    if (!this.running) return;
    const dt = Math.min((now - this.last) / 1000, 0.1);
    this.last = now;
    this.draw(dt);
    this.raf = requestAnimationFrame(this.frame);
  };

  private draw(dt: number) {
    this.clock += dt;
    const k = 1 - Math.exp(-dt * 2.2);
    this.shown += (this.target - this.shown) * k;
    if (Math.abs(this.target - this.shown) < 0.005) this.shown = this.target;
    const t = this.shown;
    const alt = sunAltitude(t);
    const c = skyColours(alt);

    // horizon in uv: project a far point on the ground plane
    const far = new THREE.Vector3(0, 0, -200).project(this.camera);
    const horizon = (far.y + 1) / 2;
    const u = this.skyMat.uniforms;
    (u.uTop!.value as THREE.Color).setRGB(...c.top);
    (u.uMid!.value as THREE.Color).setRGB(...c.mid);
    (u.uHor!.value as THREE.Color).setRGB(...c.hor);
    u.uHorizon!.value = horizon;
    u.uAlt!.value = alt;
    u.uTime!.value = this.clock;
    const sunU = this.sunU0 + this.sunSpan * (t / T_END);
    const sunV = horizon + alt * 0.4;
    (u.uSun!.value as THREE.Vector2).set(sunU, sunV);

    const gu = this.groundMat.uniforms;
    (gu.uHaze!.value as THREE.Color).setRGB(...c.hor);
    gu.uAlt!.value = alt;
    gu.uTime!.value = this.clock;
    (gu.uCam!.value as THREE.Vector3).copy(this.camera.position);
    // world x of the sun on the ground (screen u mapped through the camera at z = 0)
    const halfW = Math.tan((this.camera.fov * Math.PI) / 360) * this.camera.position.z * this.camera.aspect;
    gu.uSunX!.value = (sunU - 0.5 - this.offX) * 2 * halfW;

    for (const m of this.ribbonMats) {
      m.uniforms.uProgress!.value = t;
      m.uniforms.uTime!.value = this.clock;
    }
    const path = pricePath();
    const hi = Math.min(Math.floor(t), T_END);
    const frac = t - hi;
    const shownP = t >= T_RESUME && t < T_RESUME + 0.0001 ? path.frozen : (path.feed[hi] ?? 0.5) * (1 - frac) + (path.feed[Math.min(hi + 1, T_END)] ?? 0.5) * frac;
    const atP = t < T_RESUME ? (hi >= T_CLOSE ? path.frozen : shownP) : shownP;
    this.head.position.set(xOf(t), yOf(atP), RIBBON_Z + 0.01);
    const pulse = 1 + 0.25 * Math.sin(this.clock * 3);
    this.head.scale.setScalar(pulse * (t >= T_CLOSE && t < T_RESUME ? 1.15 : 1));
    (this.head.material as THREE.MeshBasicMaterial).color.set(t >= T_CLOSE && t < T_RESUME ? 0xa9c4ee : 0xfff1d6);

    this.starMat.uniforms.uTime!.value = this.clock;
    this.starMat.uniforms.uNight!.value = c.night;
    this.starMat.uniforms.uDusk!.value = Math.max(0, 1 - c.night - c.day);
    this.dustMat.uniforms.uTime!.value = this.clock;
    this.dustMat.uniforms.uNight!.value = c.night;

    this.renderer.render(this.scene, this.camera);
  }

  /** One frame (used for a still when idle or in a screenshot). */
  renderOnce() {
    this.draw(0.016);
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.last = performance.now();
    this.raf = requestAnimationFrame(this.frame);
  }

  stop() {
    this.running = false;
    cancelAnimationFrame(this.raf);
  }

  dispose() {
    this.stop();
    this.scene.traverse((o) => {
      const m = o as THREE.Mesh;
      if (m.geometry) m.geometry.dispose();
    });
    for (const d of this.disposables) d.dispose();
    this.renderer.dispose();
    this.renderer.forceContextLoss();
  }
}
