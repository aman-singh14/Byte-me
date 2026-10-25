import React, { useEffect, useRef, useState } from 'react';
import { Room, RoomEvent, Track } from 'livekit-client';

const directions = { ArrowLeft: 'L', ArrowUp: 'fwd', ArrowRight: 'R', ' ': 'stop' };
// 'P' is the wearer's phone camera, which the app uses while no glasses camera is connected.
const cameraNames = { F: 'Front camera', R: 'Rear camera', P: 'Phone camera' };
const names = { L: 'Left', fwd: 'Forward', R: 'Right', stop: 'Stop' };
export function describe(event) {
  const side = { L: 'behind them, left', R: 'behind them, right', B: 'behind them' }[event.side] || 'near them';
  if (event.kind === 'following') return `Someone has been ${side} for ${event.minutes || 3} minutes.`;
  if (event.t === 'tap') {
    const doing = typeof event.action === 'string' && event.action.trim() ? ` (${event.action.trim()})` : '';
    const lookUp = event.kind === 'lookup' ? ' They were asked to look up.' : '';
    return `Someone stopped ${side}${doing}.${lookUp}`;
  }
  if (event.t === 'alert') return `${event.level === 2 ? 'Urgent: ' : ''}${event.label || 'Something'} approaching ${side}.`;
  return null;
}
export function HelperPage() {
  const roomId = location.pathname.split('/').pop();
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
  const [audio, setAudio] = useState('off');
  const [audioNote, setAudioNote] = useState(null);
  const [muted, setMuted] = useState(false);
  const [speaking, setSpeaking] = useState([]);
  const [needsTap, setNeedsTap] = useState(false);
  const socket = useRef(null), retry = useRef(null), url = useRef(null), stopped = useRef(false);
  const room = useRef(null), sounds = useRef(null);
  const feedId = useRef(0);
  const addEvent = text => setEvents(old => [{ id: ++feedId.current, at: Date.now(), text }, ...old].slice(0, 30));
  const clearFrame = () => {
    if (url.current) URL.revokeObjectURL(url.current);
    url.current = null; setFrame(null); setDelay(null); setLastFrameAt(0);
  };
  useEffect(() => {
    const abort = new AbortController();
    fetch(`/room-info/${encodeURIComponent(roomId)}?t=${encodeURIComponent(token)}`, { signal: abort.signal, cache: 'no-store' })
      .then(r => { if (r.status === 404) setPhase('ended'); return r.ok ? r.json() : null; })
      .then(info => { if (info) setName(info.wearer_name); })
      .catch(() => {}); // A temporary metadata failure must not end a valid call.
    return () => abort.abort();
  }, []);
  useEffect(() => {
    const tick = setInterval(() => setNow(Date.now()), 1000);
    return () => { clearInterval(tick); stopped.current = true; clearTimeout(retry.current); socket.current?.close(); stopAudio(); if (url.current) URL.revokeObjectURL(url.current); };
  }, []);
  function send(message) {
    if (socket.current?.readyState !== WebSocket.OPEN) return false;
    socket.current.send(JSON.stringify(message)); return true;
  }
  function finish(next = 'ended') {
    stopped.current = true; clearTimeout(retry.current); setWearer(false); clearFrame();
    setPhase(next); socket.current?.close(); stopAudio();
  }
  // Two-way audio through LiveKit. Started from the Join click, so the browser
  // lets it use the microphone and play the wearer's voice.
  async function startAudio() {
    setAudio('connecting'); setAudioNote(null);
    try {
      const r = await fetch(`/livekit-token?room=${encodeURIComponent(roomId)}&t=${encodeURIComponent(token)}`, { cache: 'no-store' });
      if (stopped.current) return;
      if (r.status === 503) { setAudio('unavailable'); setAudioNote("Audio isn't set up for this call. Video and directions still work."); return; }
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const { url: server, token: jwt } = await r.json();
      const lk = new Room({ audioCaptureDefaults: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
      room.current = lk;
      lk.on(RoomEvent.TrackSubscribed, track => {
        if (track.kind !== Track.Kind.Audio) return;
        const element = track.attach(); sounds.current?.appendChild(element);
      });
      lk.on(RoomEvent.TrackUnsubscribed, track => track.detach().forEach(element => element.remove()));
      lk.on(RoomEvent.ActiveSpeakersChanged, speakers => setSpeaking(speakers.map(p => p.identity)));
      lk.on(RoomEvent.AudioPlaybackStatusChanged, () => setNeedsTap(!lk.canPlaybackAudio));
      lk.on(RoomEvent.Disconnected, () => { if (room.current === lk) { setAudio('off'); setSpeaking([]); } });
      await lk.connect(server, jwt);
      if (stopped.current || room.current !== lk) { lk.disconnect(); return; }
      await lk.localParticipant.setMicrophoneEnabled(true);
      setMuted(false); setAudio('on'); setNeedsTap(!lk.canPlaybackAudio);
    } catch (error) {
      if (stopped.current) return;
      room.current?.disconnect(); room.current = null;
      setAudio('unavailable');
      setAudioNote(error?.name === 'NotAllowedError' ? 'Microphone blocked. Allow it in your browser to talk.' : "Couldn't start audio. Video and directions still work.");
    }
  }
  function stopAudio() {
    const lk = room.current; room.current = null;
    lk?.disconnect(); setAudio('off'); setSpeaking([]); setNeedsTap(false);
  }
  async function toggleMute() {
    const lk = room.current; if (!lk || audio !== 'on') return;
    const next = !muted; setMuted(next);
    await lk.localParticipant.setMicrophoneEnabled(!next);
  }
  function connect() {
    if (stopped.current) return;
    setPhase('connecting');
    const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws/helper/${encodeURIComponent(roomId)}?t=${encodeURIComponent(token)}`);
    socket.current = ws; ws.binaryType = 'arraybuffer';
    ws.onopen = () => { if (!stopped.current) setPhase('connected'); };
    ws.onmessage = message => {
      if (stopped.current || socket.current !== ws) return;
      if (message.data instanceof ArrayBuffer) {
        const bytes = new Uint8Array(message.data);
        if (bytes.length < 11 || !cameraNames[String.fromCharCode(bytes[0])] || bytes[9] !== 255 || bytes[10] !== 216) return;
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
        if (cameraNames[event.camera]) setCamera(event.camera);
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
  const wearerTalking = speaking.includes('wearer'), youTalking = speaking.includes('helper') && !muted;
  const audioTitle = { on: muted ? 'You are muted' : 'Audio on', connecting: 'Connecting audio…', unavailable: 'No audio', off: 'Audio off' }[audio];
  const audioDetail = audio === 'on'
    ? (wearerTalking ? `${name || 'The wearer'} is speaking` : youTalking ? 'You are speaking' : 'Nobody is speaking')
    : audioNote || 'Video & haptic guidance are available.';
  return <main>
    <header><a className="wordmark" href="#">◉ <span>omni</span></a><span className="eyebrow">CALL A HELPER</span><span className="private">Private session</span></header>
    {phase === 'ready' || ended ? <section className="join panel">
      <span className="eyebrow">A LITTLE HELP. A SHARED VIEW.</span>
      <h1>{ended ? status : name ? `Be there for ${name}.` : 'Be their eyes for a moment.'}</h1>
      {ended ? <p>{phase === 'taken' ? 'Only one helper can join at a time. Ask the wearer for another link when they are ready.' : 'The live view is closed. Ask the wearer for a new link to help again.'}</p> : <>
        <p>{name ? `You'll see and hear ${name}'s glasses live.` : "You'll see and hear the wearer's glasses live."} Nothing is recorded.</p>
        <p className="secondary">Talk with them, and send gentle directions with the buttons or your keyboard.</p>
        <button className="primary" onClick={() => { stopped.current = false; connect(); startAudio(); }}>Join call <span aria-hidden="true">↗</span></button>
        <small>Joining starts the live camera and your microphone. You can mute or end the call at any time.</small>
      </>}
    </section> : <>
      <section className="heading"><div><span className="eyebrow">YOU’RE HERE TO HELP</span><h1>{name ? `With ${name}` : 'A shared point of view'}</h1></div><button className="end" onClick={() => { send({ t: 'end' }); finish(); }}>End call</button></section>
      <div className="workspace"><section className="vision panel" aria-label="Glasses camera">
        <div className="viewbar"><span className={live && fresh ? 'badge live' : 'badge'}>{live && fresh ? '● LIVE' : '● CONNECTING'}</span><span>{timer}</span><span className="delay" title="Estimated from phone and browser clocks; clock differences affect this value.">{fresh && delay !== null ? delay < 0 ? 'Delay unavailable · clocks differ' : `Est. delay ~${delay} ms` : 'Delay —'}</span></div>
        <div className="view">{fresh ? <img src={frame} alt={camera === 'P' ? "Live view from the wearer's phone camera" : `${cameraNames[camera]} live view from the glasses`} /> : <div className="placeholder"><span aria-hidden="true">◎</span><p>{status}</p><small>The live view will appear here.</small></div>}<span className="camera-label">{cameraNames[camera] || 'Camera'}</span></div>
        <div className="viewfooter"><span role="status">{status}</span>{camera === 'P' ? <small className="secondary">No glasses camera is connected, so you're seeing their phone's camera.</small> : <div className="toggle" role="group" aria-label="Select camera">{['F', 'R'].map(which => <button key={which} disabled={!live} aria-pressed={camera === which} onClick={() => { if (send({ t: 'cam', which })) { clearFrame(); setVideo('waiting'); setCamera(which); } }}>{which === 'F' ? 'Front' : 'Rear'}</button>)}</div>}</div>
      </section>
      <aside className="panel controls"><span className="eyebrow">A NUDGE IN THE RIGHT DIRECTION</span><h2>Guide the wearer</h2><p className="secondary">Each direction sends a distinct buzz to their glasses.</p>
        <div className="arrows" role="group" aria-label="Haptic guidance">{[['L', '←', 'Left arrow'], ['fwd', '↑', 'Up arrow'], ['R', '→', 'Right arrow']].map(([dir, arrow, key]) => <button key={dir} disabled={!fresh} aria-label={`Guide ${names[dir].toLowerCase()} (${key})`} onClick={() => guide(dir)}><span aria-hidden="true">{arrow}</span>{names[dir]}</button>)}</div>
        <button className="stop" disabled={!live} aria-label="Stop the wearer (Space)" onClick={() => guide('stop')}><span aria-hidden="true">■</span> Stop <kbd>Space</kbd></button>
        <p className="keyhint">Arrow keys to guide · Space to stop</p><p className="sent" role="status">{lastGuide ? `${lastGuide} guidance sent` : 'Ready to send a direction'}</p>
        <div className="audio"><span aria-hidden="true">{audio === 'on' && !muted ? '♪' : '♩'}</span><div role="status"><strong>{audioTitle}</strong><small>{audioDetail}</small></div>{needsTap ? <button onClick={() => room.current?.startAudio().then(() => setNeedsTap(false))}>Hear them</button> : <button disabled={audio !== 'on'} aria-pressed={muted} onClick={toggleMute}>{muted ? 'Unmute' : 'Mute'}</button>}</div>
        <div ref={sounds} hidden />
      </aside></div>
      <section className="panel events"><div><h2>Along the way</h2><span className="secondary">Alerts from the glasses</span></div><ul aria-live="polite" aria-relevant="additions">{events.length ? events.map(event => <li key={event.id}><time>{new Date(event.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</time><span>{event.text}</span></li>) : <li className="secondary">No alerts yet. You’re all caught up.</li>}</ul></section>
      <footer>Nothing is recorded. <span>Directions always refer to the wearer’s left and right.</span></footer>
    </>}
  </main>;
}
