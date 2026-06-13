const HUB      = '/.well-known/mercure';
const TOPIC    = 'https://oliva.dev/live';
const PUBLISH  = '/live.php';
const myColor  = `hsl(${Math.floor(Math.random() * 360)}, 65%, 62%)`;
const myId     = Math.random().toString(36).slice(2, 8);

let source, canvas, ctx;
let drawing = false, lastX = 0, lastY = 0, lastSent = 0;
const strokes = [];

// ─── Bootstrap ───────────────────────────────────────────────────────────────

export function initLive() {
    canvas = document.getElementById('live-canvas');
    if (!canvas) return;
    ctx = canvas.getContext('2d');

    resizeCanvas();
    window.addEventListener('resize', resizeCanvas);
    bindCanvas();
    bindReactions();
    document.getElementById('live-clear')?.addEventListener('click', () => {
        strokes.length = 0;
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        send('clear', {});
    });

    connect();
    send('join', {});
    window.addEventListener('beforeunload', () =>
        navigator.sendBeacon(PUBLISH, JSON.stringify({ type: 'leave' }))
    );
}

// ─── Mercure subscription ────────────────────────────────────────────────────

function connect() {
    const url = new URL(HUB, window.location.origin);
    url.searchParams.append('topic', TOPIC);

    source = new EventSource(url.toString());
    source.onopen    = () => setStatus(true);
    source.onerror   = () => { setStatus(false); source.close(); setTimeout(connect, 3000); };
    source.onmessage = ({ data }) => { try { handle(JSON.parse(data)); } catch (_) {} };
}

function handle(evt) {
    switch (evt.type) {
        case 'clients':
            updateCount(evt.payload?.count ?? 0);
            feed(evt.payload?.joined ? '👤' : '👋',
                 evt.payload?.joined ? 'Someone joined' : 'Someone left', 'join');
            break;
        case 'draw':
            if (evt.payload?.id !== myId) { renderStroke(evt.payload); strokes.push(evt.payload); }
            break;
        case 'reaction':
            spawnFloat(evt.payload?.emoji);
            feed(evt.payload?.emoji, 'reaction broadcasted', 'react');
            break;
        case 'clear':
            strokes.length = 0;
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            feed('🧹', 'Canvas cleared', 'clear');
            break;
    }
}

// ─── Canvas ───────────────────────────────────────────────────────────────────

function resizeCanvas() {
    const w = canvas.parentElement.clientWidth;
    canvas.width  = w;
    canvas.height = Math.min(340, Math.round(w * 0.55));
    strokes.forEach(renderStroke);
}

function bindCanvas() {
    const start = (x, y) => { drawing = true; lastX = x; lastY = y; };
    const move  = (x, y) => {
        if (!drawing) return;
        const s = { x1: lastX, y1: lastY, x2: x, y2: y, c: myColor, w: 2.5, id: myId };
        renderStroke(s); strokes.push(s);
        lastX = x; lastY = y;
        const now = Date.now();
        if (now - lastSent > 45) { send('draw', s); lastSent = now; }
    };
    const stop = () => { drawing = false; };

    canvas.addEventListener('mousedown',  e => { const r = rel(e); start(r.x, r.y); });
    canvas.addEventListener('mousemove',  e => { const r = rel(e); move(r.x, r.y); });
    canvas.addEventListener('mouseup',    stop);
    canvas.addEventListener('mouseleave', stop);
    canvas.addEventListener('touchstart', e => { e.preventDefault(); const r = rel(e.touches[0]); start(r.x, r.y); }, { passive: false });
    canvas.addEventListener('touchmove',  e => { e.preventDefault(); const r = rel(e.touches[0]); move(r.x, r.y); }, { passive: false });
    canvas.addEventListener('touchend',   stop);
}

function rel(e) {
    const r = canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
}
function renderStroke({ x1, y1, x2, y2, c, w }) {
    ctx.beginPath();
    ctx.strokeStyle = c; ctx.lineWidth = w;
    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
}

// ─── Reactions ────────────────────────────────────────────────────────────────

function bindReactions() {
    document.querySelectorAll('.live-react').forEach(btn =>
        btn.addEventListener('click', () => {
            const emoji = btn.dataset.emoji;
            spawnFloat(emoji);
            send('reaction', { emoji });
        })
    );
}
function spawnFloat(emoji) {
    const c = document.getElementById('live-floats');
    if (!c) return;
    const el = document.createElement('span');
    el.className = 'live-float';
    el.textContent = emoji;
    el.style.left = `${8 + Math.random() * 84}%`;
    c.appendChild(el);
    el.addEventListener('animationend', () => el.remove());
}

// ─── Feed ─────────────────────────────────────────────────────────────────────

function feed(icon, text, type = 'info') {
    const ul = document.getElementById('live-feed');
    if (!ul) return;
    ul.querySelector('.live-feed-empty')?.remove();
    const li = document.createElement('li');
    li.className = `live-feed-item live-feed-${type}`;
    li.innerHTML = `<span class="fi">${icon}</span><span class="ft">${text}</span><span class="fts">${new Date().toLocaleTimeString()}</span>`;
    ul.prepend(li);
    while (ul.children.length > 22) ul.lastChild.remove();
}

// ─── UI helpers ──────────────────────────────────────────────────────────────

function setStatus(on) {
    document.querySelector('.live-dot')?.classList.toggle('live-dot--off', !on);
    const lbl = document.querySelector('.live-label');
    if (lbl) lbl.textContent = on ? 'LIVE' : 'RECONNECTING';
}
function updateCount(n) {
    const el = document.querySelector('.live-count');
    if (el) el.textContent = `${n} ${n === 1 ? 'user' : 'users'} online`;
}

// ─── Transport ────────────────────────────────────────────────────────────────

async function send(type, payload) {
    try {
        await fetch(PUBLISH, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type, payload }),
        });
    } catch (_) {}
}
