import React, { useEffect, useRef, useState } from 'react';

const directions = { ArrowLeft: 'L', ArrowUp: 'fwd', ArrowRight: 'R', ' ': 'stop' };
const names = { L: 'Left', fwd: 'Forward', R: 'Right', stop: 'Stop' };
export function describe(event) {
  const side = { L: 'behind them, left', R: 'behind them, right', B: 'behind them' }[event.side] || 'near them';
  if (event.kind === 'following') return `Someone has been ${side} for ${event.minutes || 3} minutes.`;
  if (event.t === 'tap') return `Someone ${event.kind === 'stopped' ? 'stopped' : 'tapped'} ${side}.`;
  if (event.t === 'alert') return `${event.level === 2 ? 'Urgent: ' : ''}${event.label || 'Something'} approaching ${side}.`;
  return null;
}
export function HelperPage() {
  const room = location.pathname.split('/').pop();
  const token = new URLSearchParams(location.search).get('t') || '';
  const [name, setName] = useState(null);
  const [phase, setPhase] = useState('ready');
  const [wearer, setWearer] = useState(false);
  const [camera, setCamera] = useState('F');
  const [video, setVideo] = useState('waiting');
  const [frame, setFrame] = useState(null);
  const [delay, setDelay] = useState(null);
  const [events, setEvents] = useState([]);
  const [now, setNow] = useState(Date.now());
  const [since, setSince] = useState(null);
  const [lastFrameAt, setLastFrameAt] = useState(0);
  const [lastGuide, setLastGuide] = useState(null);
  const socket = useRef(null), retry = useRef(null), url = useRef(null), stopped = useRef(false);
  const feedId = useRef(0);
  const addEvent = text => setEvents(old => [{ id: ++feedId.current, at: Date.now(), text }, ...old].slice(0, 30));
  const clearFrame = () => {
    if (url.current) URL.revokeObjectURL(url.current);
    url.current = null; setFrame(null); setDelay(null); setLastFrameAt(0);
  };
  useEffect(() => {
    const abort = new AbortController();
    fetch(`/room-info/${encodeURIComponent(room)}?t=${encodeURIComponent(token)}`, { signal: abort.signal, cache: 'no-store' })
      .then(r => { if (r.status === 404) setPhase('ended'); return r.ok ? r.json() : null; })
      .then(info => { if (info) setName(info.wearer_name); })
      .catch(() => {}); // A temporary metadata failure must not end a valid call.
    return () => abort.abort();
  }, []);
  useEffect(() => {
    const tick = setInterval(() => setNow(Date.now()), 1000);
    return () => { clearInterval(tick); stopped.current = true; clearTimeout(retry.current); socket.current?.close(); if (url.current) URL.revokeObjectURL(url.current); };
  }, []);
  function send(message) {
    if (socket.current?.readyState !== WebSocket.OPEN) return false;
    socket.current.send(JSON.stringify(message)); return true;
  }
  function finish(next = 'ended') {
    stopped.current = true; clearTimeout(retry.current); setWearer(false); clearFrame();
    setPhase(next); socket.current?.close();
  }
  function connect() {
    if (stopped.current) return;
    setPhase('connecting');
    const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws/helper/${encodeURIComponent(room)}?t=${encodeURIComponent(token)}`);
    socket.current = ws; ws.binaryType = 'arraybuffer';
    ws.onopen = () => { if (!stopped.current) setPhase('connected'); };
    ws.onmessage = message => {
      if (stopped.current || socket.current !== ws) return;
      if (message.data instanceof ArrayBuffer) {
        const bytes = new Uint8Array(message.data);
        if (bytes.length < 11 || ![70, 82].includes(bytes[0]) || bytes[9] !== 255 || bytes[10] !== 216) return;
        const timestamp = Number(new DataView(message.data).getBigUint64(1));
        const next = URL.createObjectURL(new Blob([bytes.subarray(9)], { type: 'image/jpeg' }));
        if (url.current) URL.revokeObjectURL(url.current);
        url.current = next; setFrame(next); setCamera(String.fromCharCode(bytes[0]));
        setLastFrameAt(Date.now()); setVideo('on'); setDelay(Date.now() - timestamp); return;
      }
      let event; try { event = JSON.parse(message.data); } catch { return; }
      if (!event || typeof event !== 'object') return;
      if (event.t === 'ended') { finish(); return; }
      if (event.t === 'wearer') {
        setWearer(event.on === true);
        if (event.on) setSince(old => old ?? Date.now());
        else { clearFrame(); setVideo('waiting'); }
      } else if (event.t === 'status') {
        if (['F', 'R'].includes(event.camera)) setCamera(event.camera);
        if (event.video === 'waiting') { clearFrame(); setVideo('waiting'); }
      } else { const text = describe(event); if (text) addEvent(text); }
    };
    ws.onclose = event => {
      if (stopped.current || socket.current !== ws) return;
      setWearer(false); clearFrame();
      if ([4401, 4410].includes(event.code)) finish();
      else if (event.code === 4409) finish('taken');
      else { setPhase('reconnecting'); retry.current = setTimeout(connect, 1500); }
    };
    ws.onerror = () => ws.close();
  }
  const live = phase === 'connected' && wearer;
  const fresh = live && frame && now - lastFrameAt < 3000 && video === 'on';
  // Guidance stays disabled if the helper cannot see a current frame. Stop
  // remains available as soon as the wearer is connected.
  function guide(direction) {
    if (!live || (direction !== 'stop' && !fresh)) return;
    if (send({ t: 'guide', dir: direction })) setLastGuide(names[direction]);
  }
  useEffect(() => {
    const keydown = event => {
      if (event.repeat || event.altKey || event.ctrlKey || event.metaKey || event.target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(event.target.tagName)) return;
      const direction = directions[event.key];
      if (!direction || !live) return;
      // Preserve Space activation on focused buttons/links for keyboard users.
      if (event.key === ' ' && /^(BUTTON|A)$/.test(event.target.tagName)) return;
      event.preventDefault(); guide(direction);
    };
    window.addEventListener('keydown', keydown);
    return () => window.removeEventListener('keydown', keydown);
  }, [live, fresh]);
  const elapsed = Math.max(0, Math.floor((now - (since || now)) / 1000));
  const timer = `${Math.floor(elapsed / 60)}:${String(elapsed % 60).padStart(2, '0')}`;
  const status = { ready: 'Ready when you are', connecting: 'Connecting…', reconnecting: 'Connection lost · reconnecting…', ended: 'This call has ended', taken: 'Someone else is already helping' }[phase] || (wearer ? (fresh ? 'Connected' : 'Waiting for camera…') : 'Waiting for the wearer…');
  const ended = ['ended', 'taken'].includes(phase);
  return <main>
    <header><a className="wordmark" href="#">◉ <span>omni</span></a><span className="eyebrow">CALL A HELPER</span><span className="private">Private session</span></header>
    {phase === 'ready' || ended ? <section className="join panel">
      <span className="eyebrow">A LITTLE HELP. A SHARED VIEW.</span>
      <h1>{ended ? status : name ? `Be there for ${name}.` : 'Be their eyes for a moment.'}</h1>
      {ended ? <p>{phase === 'taken' ? 'Only one helper can join at a time. Ask the wearer for another link when they are ready.' : 'The live view is closed. Ask the wearer for a new link to help again.'}</p> : <>
        <p>{name ? `You'll see ${name}'s glasses live.` : "You'll see the wearer's glasses live."} Nothing is recorded.</p>
        <p className="secondary">Send gentle directions with the buttons or your keyboard. Two-way audio is coming soon.</p>
        <button className="primary" onClick={() => { stopped.current = false; connect(); }}>Join call <span aria-hidden="true">↗</span></button>
        <small>Joining starts the live camera. You can end the call at any time.</small>
      </>}
    </section> : <>
      <section className="heading"><div><span className="eyebrow">YOU’RE HERE TO HELP</span><h1>{name ? `With ${name}` : 'A shared point of view'}</h1></div><button className="end" onClick={() => { send({ t: 'end' }); finish(); }}>End call</button></section>
      <div className="workspace"><section className="vision panel" aria-label="Glasses camera">
        <div className="viewbar"><span className={live && fresh ? 'badge live' : 'badge'}>{live && fresh ? '● LIVE' : '● CONNECTING'}</span><span>{timer}</span><span className="delay" title="Estimated from phone and browser clocks; clock differences affect this value.">{fresh && delay !== null ? delay < 0 ? 'Delay unavailable · clocks differ' : `Est. delay ~${delay} ms` : 'Delay —'}</span></div>
        <div className="view">{fresh ? <img src={frame} alt={`${camera === 'F' ? 'Front' : 'Rear'} camera live view from the glasses`} /> : <div className="placeholder"><span aria-hidden="true">◎</span><p>{status}</p><small>The live view will appear here.</small></div>}<span className="camera-label">{camera === 'F' ? 'Front' : 'Rear'} camera</span></div>
        <div className="viewfooter"><span role="status">{status}</span><div className="toggle" role="group" aria-label="Select camera">{['F', 'R'].map(which => <button key={which} disabled={!live} aria-pressed={camera === which} onClick={() => { if (send({ t: 'cam', which })) { clearFrame(); setVideo('waiting'); setCamera(which); } }}>{which === 'F' ? 'Front' : 'Rear'}</button>)}</div></div>
      </section>
      <aside className="panel controls"><span className="eyebrow">A NUDGE IN THE RIGHT DIRECTION</span><h2>Guide the wearer</h2><p className="secondary">Each direction sends a distinct buzz to their glasses.</p>
        <div className="arrows" role="group" aria-label="Haptic guidance">{[['L', '←', 'Left arrow'], ['fwd', '↑', 'Up arrow'], ['R', '→', 'Right arrow']].map(([dir, arrow, key]) => <button key={dir} disabled={!fresh} aria-label={`Guide ${names[dir].toLowerCase()} (${key})`} onClick={() => guide(dir)}><span aria-hidden="true">{arrow}</span>{names[dir]}</button>)}</div>
        <button className="stop" disabled={!live} aria-label="Stop the wearer (Space)" onClick={() => guide('stop')}><span aria-hidden="true">■</span> Stop <kbd>Space</kbd></button>
        <p className="keyhint">Arrow keys to guide · Space to stop</p><p className="sent" role="status">{lastGuide ? `${lastGuide} guidance sent` : 'Ready to send a direction'}</p>
        <div className="audio"><span aria-hidden="true">♩</span><div><strong>Audio coming soon</strong><small>Video & haptic guidance are available.</small></div><button disabled aria-label="Mute microphone (audio not available yet)">Mute</button></div>
      </aside></div>
      <section className="panel events"><div><h2>Along the way</h2><span className="secondary">Alerts from the glasses</span></div><ul aria-live="polite" aria-relevant="additions">{events.length ? events.map(event => <li key={event.id}><time>{new Date(event.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</time><span>{event.text}</span></li>) : <li className="secondary">No alerts yet. You’re all caught up.</li>}</ul></section>
      <footer>Nothing is recorded. <span>Directions always refer to the wearer’s left and right.</span></footer>
    </>}
  </main>;
}
