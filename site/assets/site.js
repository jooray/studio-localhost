/* Localhost Recording Studio site. No dependencies, no tracking. */
(function () {
  'use strict';
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var MEDIA = {
    video: 'media/ad.mp4',
    poster: 'media/ad-poster.jpg',
    captions: 'media/ad.vtt',
    script: 'media/ad-script.txt',
    song: 'media/run-song.mp3',
    songMeta: 'media/run-song.json'
  };

  /* ---------- media probing ---------- */
  // HEAD check over http(s); element probe as a fallback (file://, or servers without HEAD).
  function head(url) {
    return fetch(url, { method: 'HEAD', cache: 'no-store' }).then(function (r) {
      if (!r.ok) return false;
      var t = (r.headers.get('content-type') || '').toLowerCase();
      return t.indexOf('text/html') === -1; // a 404 page served as 200 is not media
    });
  }
  function probeElement(tag, url) {
    return new Promise(function (resolve) {
      var el = document.createElement(tag);
      el.preload = 'metadata';
      el.muted = true;
      el.onloadedmetadata = function () { resolve(true); el.removeAttribute('src'); };
      el.onerror = function () { resolve(false); };
      el.src = url;
    });
  }
  function exists(url, tag) {
    return head(url).catch(function () { return tag ? probeElement(tag, url) : false; });
  }
  function getText(url) {
    return fetch(url, { cache: 'no-store' }).then(function (r) {
      var t = (r.headers.get('content-type') || '').toLowerCase();
      if (!r.ok || t.indexOf('text/html') !== -1) throw new Error('missing');
      return r.text();
    });
  }
  // Re-check every 20 s while something is still missing (handy during a local preview).
  function poll(check, done) {
    var tries = 0;
    function run() {
      check().then(function (ok) {
        if (ok) return done();
        if (++tries < 90) setTimeout(function () {
          if (document.hidden) document.addEventListener('visibilitychange', run, { once: true });
          else run();
        }, 20000);
      });
    }
    run();
  }

  /* ---------- hero story ---------- */
  (function story() {
    var hero = document.querySelector('.hero');
    var lines = Array.prototype.slice.call(document.querySelectorAll('#story li'));
    var skip = document.getElementById('story-skip');
    var replay = document.getElementById('story-replay');
    var timers = [];
    if (reduce) { hero.classList.add('static'); return; }
    function clear() { timers.forEach(clearTimeout); timers = []; }
    function finish() {
      clear();
      lines.forEach(function (l) { l.classList.remove('on'); l.classList.add('off'); });
      hero.classList.add('done');
    }
    function play() {
      clear();
      hero.classList.remove('done');
      lines.forEach(function (l) { l.classList.remove('on', 'off'); });
      var t = 400;
      lines.forEach(function (l, i) {
        timers.push(setTimeout(function () {
          if (i > 0) { lines[i - 1].classList.remove('on'); lines[i - 1].classList.add('off'); }
          l.classList.add('on');
        }, t));
        t += 1500 + l.textContent.length * 30;
      });
      timers.push(setTimeout(finish, t));
    }
    skip.addEventListener('click', function () { finish(); hero.querySelector('.punch a').focus({ preventScroll: true }); });
    replay.addEventListener('click', function () { play(); skip.focus({ preventScroll: true }); });
    play();
    // Anyone who scrolls away gets the punchline when they come back.
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (es) {
        es.forEach(function (e) { if (!e.isIntersecting && !hero.classList.contains('done')) finish(); });
      }, { threshold: 0.25 }).observe(hero);
    }
  })();

  /* ---------- the ad ---------- */
  (function ad() {
    var slot = document.getElementById('video-slot');
    function mount() {
      Promise.all([exists(MEDIA.poster, null), exists(MEDIA.captions, null)]).then(function (r) {
        var v = document.createElement('video');
        v.controls = true;
        v.playsInline = true;
        v.setAttribute('playsinline', '');
        v.preload = 'metadata';
        v.setAttribute('aria-label', 'Localhost Recording Studio ad: running from zombies, making a soundtrack on a phone');
        if (r[0]) v.poster = MEDIA.poster;
        v.src = MEDIA.video;
        if (r[1]) {
          var tr = document.createElement('track');
          tr.kind = 'captions'; tr.srclang = 'en'; tr.label = 'English'; tr.src = MEDIA.captions; tr.default = true;
          v.appendChild(tr);
        }
        slot.textContent = '';
        slot.appendChild(v);
        slot.classList.add('has-video');
      });
    }
    poll(function () { return exists(MEDIA.video, 'video'); }, mount);

    getText(MEDIA.script).then(function (txt) {
      var box = document.getElementById('transcript-text');
      txt.trim().split(/\n\s*\n/).forEach(function (para) {
        var p = document.createElement('p');
        p.textContent = para.replace(/\s*\n\s*/g, ' ');
        box.appendChild(p);
      });
      document.getElementById('transcript').hidden = false;
    }).catch(function () {});
  })();

  /* ---------- the song player ---------- */
  (function player() {
    var canvas = document.getElementById('plot');
    var g = canvas.getContext('2d');
    var btn = document.getElementById('p-play');
    var scrub = document.getElementById('p-scrub');
    var timeEl = document.getElementById('p-time');
    var stateEl = document.getElementById('p-state');
    var note = document.getElementById('p-note');
    var meta = document.getElementById('p-meta');
    var audio = null, ctx = null, analyser = null, freq = null, wave = null;
    var dragging = false, raf = 0, size = 0, dpr = 1;
    var INK = '#F2F2F0', GROUND = '#0A0A0B';
    var trace = new Float32Array(720).fill(-1), traced = false, ema = 0, lastSlot = -1;

    // Seeded noise so the idle plot looks the same every time.
    var idle = (function () {
      var s = 15, out = [];
      function rnd() { s = (s * 16807) % 2147483647; return s / 2147483647; }
      for (var i = 0; i < 360; i++) {
        var v = Math.pow(rnd(), 3) * 0.22;
        if (rnd() < 0.14) v += Math.pow(rnd(), 0.6) * 0.5;
        out.push({ o: v, i: rnd() * 0.05 });
      }
      return out;
    })();

    function fit() {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      var w = canvas.clientWidth || 320;
      size = Math.round(w * dpr);
      if (canvas.width !== size) { canvas.width = size; canvas.height = size; }
    }

    function fmt(s) {
      if (!isFinite(s)) s = 0;
      s = Math.floor(s);
      return Math.floor(s / 60) + ':' + ('0' + (s % 60)).slice(-2);
    }

    function draw() {
      var w = size, c = w / 2, R = w / 2 * 0.985, k, a;
      g.fillStyle = GROUND;
      g.fillRect(0, 0, w, w);
      // grid: hairline rings and spokes
      g.strokeStyle = 'rgba(242,242,240,.36)';
      g.lineWidth = Math.max(1, dpr * 0.8);
      g.beginPath();
      for (k = 1; k <= 11; k++) {
        var rr = R * (17 * k + 8) / 195;
        g.moveTo(c + rr, c); g.arc(c, c, rr, 0, Math.PI * 2);
      }
      for (k = 0; k < 24; k++) {
        a = k * Math.PI / 12;
        g.moveTo(c + R * 0.1 * Math.cos(a), c + R * 0.1 * Math.sin(a));
        g.lineTo(c + R * Math.cos(a), c + R * Math.sin(a));
      }
      g.stroke();

      // burst: the song's peaks laid around the circle, written as the playhead passes
      var M = 720, live = analyser && audio && !audio.paused;
      var bass = 0, i, v, r;
      if (live) {
        analyser.getByteFrequencyData(freq);
        analyser.getByteTimeDomainData(wave);
        var peak = 0;
        for (k = 0; k < wave.length; k++) peak = Math.max(peak, Math.abs(wave[k] - 128) / 128);
        for (k = 1; k < 9; k++) bass += freq[k] / 255 / 8;
        if (audio.duration) {
          var slot = Math.min(M - 1, Math.floor(audio.currentTime / audio.duration * M));
          var hit = Math.max(0, peak - ema) * 2.2;            // transients become spikes
          ema = ema * 0.85 + peak * 0.15;
          var from = slot > lastSlot && slot - lastSlot < 40 ? lastSlot + 1 : slot;
          for (var q = from; q <= slot; q++) {
            var grain = Math.abs(wave[(q * 37) % wave.length] - 128) / 128;
            trace[q] = Math.min(1, Math.pow(peak, 2.2) * (0.55 + 0.45 * grain) + (q === slot ? hit : 0));
          }
          lastSlot = slot;
        }
      }
      var base = R * 0.46, amp = R * 0.52, inner = R * 0.29 * (1 - bass * 0.12);
      g.beginPath();
      for (k = 0; k <= M; k++) {
        i = k % M;
        if (traced) v = trace[i] < 0 ? 0 : trace[i];
        else v = idle[i >> 1].o;
        a = i / M * Math.PI * 2 - Math.PI / 2;
        r = base + v * amp;
        if (k === 0) g.moveTo(c + r * Math.cos(a), c + r * Math.sin(a));
        else g.lineTo(c + r * Math.cos(a), c + r * Math.sin(a));
      }
      g.closePath();
      for (k = 360; k >= 0; k--) {
        i = k % 360;
        v = live ? (Math.abs(wave[(i * 5) % wave.length] - 128) / 128) * 0.1 : idle[i].i;
        a = i / 360 * Math.PI * 2 - Math.PI / 2;
        r = inner - v * R;
        if (k === 360) g.moveTo(c + r * Math.cos(a), c + r * Math.sin(a));
        else g.lineTo(c + r * Math.cos(a), c + r * Math.sin(a));
      }
      g.closePath();
      g.fillStyle = INK;
      g.fill('evenodd');

      // spindle and progress arc
      g.beginPath(); g.arc(c, c, Math.max(2, R * 0.013), 0, Math.PI * 2); g.fill();
      if (audio && audio.duration) {
        var p = audio.currentTime / audio.duration;
        if (p > 0) {
          g.strokeStyle = INK; g.lineWidth = 3 * dpr;
          g.beginPath(); g.arc(c, c, R - 1.5 * dpr, -Math.PI / 2, -Math.PI / 2 + p * Math.PI * 2); g.stroke();
        }
      }
    }

    function loop() {
      draw();
      syncTime();
      if (audio && !audio.paused) raf = requestAnimationFrame(loop);
      else raf = 0;
    }

    function syncTime() {
      if (!audio) return;
      var d = audio.duration || 0;
      timeEl.textContent = fmt(audio.currentTime) + ' / ' + fmt(d);
      if (!dragging && d) {
        scrub.max = d;
        scrub.value = audio.currentTime;
        scrub.setAttribute('aria-valuetext', fmt(audio.currentTime) + ' of ' + fmt(d));
      }
    }

    function setState(s, live) {
      stateEl.textContent = s;
      stateEl.classList.toggle('live', !!live);
    }

    function ensureGraph() {
      if (ctx) return;
      var AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      try {
        ctx = new AC();
        var src = ctx.createMediaElementSource(audio);
        analyser = ctx.createAnalyser();
        analyser.fftSize = 2048;
        analyser.smoothingTimeConstant = 0.72;
        freq = new Uint8Array(analyser.frequencyBinCount);
        wave = new Uint8Array(analyser.fftSize);
        src.connect(analyser);
        analyser.connect(ctx.destination);
      } catch (e) { analyser = null; }
    }

    function enable() {
      audio = new Audio();
      audio.preload = 'metadata';
      audio.src = MEDIA.song;
      btn.disabled = false;
      scrub.disabled = false;
      scrub.step = 'any';
      note.hidden = true;
      setState('Ready');
      audio.addEventListener('loadedmetadata', function () { syncTime(); draw(); });
      audio.addEventListener('play', function () {
        btn.classList.add('playing'); btn.setAttribute('aria-label', 'Pause'); setState('Playing', true);
        traced = true;
        if (!raf) raf = requestAnimationFrame(loop);
      });
      audio.addEventListener('pause', function () {
        btn.classList.remove('playing'); btn.setAttribute('aria-label', 'Play'); setState(audio.ended ? 'Ended' : 'Paused');
        syncTime(); draw();
      });
      audio.addEventListener('ended', function () { setState('Ended'); });
      audio.addEventListener('timeupdate', function () { if (audio.paused) { syncTime(); draw(); } });
      audio.addEventListener('error', function () { setState('Could not load'); });

      btn.addEventListener('click', function () {
        ensureGraph();
        if (ctx && ctx.state === 'suspended') ctx.resume();
        if (audio.paused) audio.play().catch(function () { setState('Tap play again'); });
        else audio.pause();
      });
      scrub.addEventListener('input', function () {
        dragging = true;
        timeEl.textContent = fmt(+scrub.value) + ' / ' + fmt(audio.duration);
      });
      scrub.addEventListener('change', function () {
        if (audio.duration) audio.currentTime = +scrub.value;
        lastSlot = -1;
        dragging = false;
        syncTime(); draw();
      });

      getText(MEDIA.songMeta).then(function (txt) {
        var m = JSON.parse(txt);
        var rows = [['style', 'Style', true], ['lyrics', 'Lyrics', true], ['model', 'Model'], ['device', 'Made on'],
                    ['steps', 'Steps'], ['seed', 'Seed'], ['render_time', 'Render time']];
        rows.forEach(function (r) {
          if (m[r[0]] == null || m[r[0]] === '') return;
          var existing = r[0] === 'device' ? meta.querySelector('div:nth-child(2) dd') : null;
          if (existing) { existing.textContent = String(m[r[0]]); return; }
          var d = document.createElement('div'), dt = document.createElement('dt'), dd = document.createElement('dd');
          dt.textContent = r[1]; dd.textContent = String(m[r[0]]);
          if (r[2]) dd.className = 'prose';
          d.appendChild(dt); d.appendChild(dd); meta.appendChild(d);
        });
      }).catch(function () {});
    }

    fit(); draw();
    window.addEventListener('resize', function () { fit(); draw(); });
    poll(function () { return exists(MEDIA.song, 'audio'); }, enable);
  })();
})();
