#!/usr/bin/env python3
"""Measure live-caption latency through the captions relay with a WAV file, streamed in
real time exactly like the app's microphone (100 ms PCM chunks).

    python -m backend.captions --port 8030                       # the relay (repo root)
    social/.venv/bin/python tools/caption_latency.py tools/samples/conversation.wav

For each speech segment in the file (found by loudness), it reports:
  first text   speech starts -> the first partial transcript arrives
  final text   speech ends   -> the turn's final text (speechComplete) arrives
plus the speaker label and the final text. Times are wall-clock on this machine, so
they include the trip to Meta and back. tools/samples/conversation.wav is three
turns by two synthetic voices (macOS `say`), with pauses between them.
"""

import argparse
import asyncio
import json
import statistics
import time
import wave

from websockets.asyncio.client import connect

CHUNK_S = 0.1


def speech_segments(pcm, rate, threshold=500, min_gap_s=0.6):
    """[(start_s, end_s)] of loud stretches in 16-bit mono PCM."""
    frame = rate // 50                                       # 20 ms
    loud = []
    for i in range(0, len(pcm) // 2 - frame, frame):
        samples = memoryview(pcm)[i * 2:(i + frame) * 2].cast("h")
        loud.append(max(abs(s) for s in samples) > threshold)
    segments, start = [], None
    for i, on in enumerate(loud + [False]):
        t = i * 0.02
        if on and start is None:
            start = t
        elif not on and start is not None:
            segments.append([start, t])
            start = None
    merged = []
    for s, e in segments:
        if merged and s - merged[-1][1] < min_gap_s:
            merged[-1][1] = e
        else:
            merged.append([s, e])
    return merged


async def run(path, url, mode):
    with wave.open(path, "rb") as w:
        rate, pcm = w.getframerate(), w.readframes(w.getnframes())
    encoding = {16000: "PCM_16KHZ", 24000: "PCM_24KHZ"}[rate]
    segments = speech_segments(pcm, rate)
    events = []                                              # (wall s since audio start, event)
    async with connect(url, max_size=2**20) as ws:
        await ws.send(json.dumps({"type": "start", "audioEncoding": encoding, "mode": mode}))
        ready = json.loads(await ws.recv())
        if ready.get("type") != "ready":
            raise SystemExit(f"relay refused: {ready}")
        print(f"session {ready['sessionId']} ({ready['source']}), {len(pcm) / rate / 2:.1f} s of audio, "
              f"{len(segments)} speech segments")
        t0 = time.monotonic()

        async def send():
            chunk = int(rate * 2 * CHUNK_S)
            tail = bytes(int(rate * 2 * 3))                  # 3 s of silence so the last turn completes
            audio = pcm + tail
            for i in range(0, len(audio), chunk):
                await ws.send(audio[i:i + chunk])
                await asyncio.sleep(max(0.0, t0 + (i + chunk) / (rate * 2) - time.monotonic()))
            await ws.send(json.dumps({"type": "endStream"}))

        sender = asyncio.create_task(send())
        async for message in ws:
            if isinstance(message, str):
                events.append((time.monotonic() - t0, json.loads(message)))
        await sender
        print(f"closed {ws.close_code} {ws.close_reason or ''}".rstrip())
    report(segments, events)


def report(segments, events):
    turns = {}                                               # turnId -> dict
    current = None
    for t, e in events:
        kind = e.get("type")
        if kind == "speechStart":
            current = turns.setdefault(e["turnId"], {"start": t, "first": None, "final": None, "speaker": None,
                                                     "text": ""})
        elif kind == "transcript" and current is not None:
            if current["first"] is None and e.get("transcript"):
                current["first"] = t
        elif kind == "speaker" and current is not None:
            current["speaker"] = current["speaker"] or e.get("label")
        elif kind == "speechComplete":
            turn = turns.get(e["turnId"])
            if turn:
                turn["final"], turn["text"] = t, e.get("transcript", "")
        elif kind == "error":
            print("error:", e.get("message"))
    ordered = [turns[k] for k in sorted(turns)]
    print(f"\n{'turn':>4}  {'speech':>11}  {'first text':>10}  {'final text':>10}  speaker  text")
    firsts, finals = [], []
    for i, turn in enumerate(ordered):
        seg = segments[i] if i < len(segments) else None
        first = turn["first"] - seg[0] if seg and turn["first"] else None
        final = turn["final"] - seg[1] if seg and turn["final"] else None
        firsts += [first] if first is not None else []
        finals += [final] if final is not None else []
        span = f"{seg[0]:4.1f}-{seg[1]:4.1f}s" if seg else "?"
        fmt = lambda v: f"{v * 1000:7.0f} ms" if v is not None else "        -"  # noqa: E731
        print(f"{i + 1:>4}  {span:>11}  {fmt(first)}  {fmt(final)}  {turn['speaker'] or '-':>7}  {turn['text']}")
    if len(ordered) != len(segments):
        print(f"\nnote: {len(ordered)} turns for {len(segments)} speech segments; pairing is by order")
    if firsts:
        print(f"\nfirst text: median {statistics.median(firsts) * 1000:.0f} ms, max {max(firsts) * 1000:.0f} ms")
    if finals:
        print(f"final text: median {statistics.median(finals) * 1000:.0f} ms, max {max(finals) * 1000:.0f} ms")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wav")
    ap.add_argument("--url", default="ws://localhost:8030/ws/captions")
    ap.add_argument("--mode", default="DIARIZATION", choices=("DIARIZATION", "ENDPOINTING"))
    args = ap.parse_args()
    asyncio.run(run(args.wav, args.url, args.mode))


if __name__ == "__main__":
    main()
