import React from 'react';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { HelperPage, describe } from './page.jsx';
class Socket {
  static OPEN = 1;
  static all = [];
  readyState = 1;
  sent = [];
  constructor() { Socket.all.push(this); }
  send(data) { this.sent.push(JSON.parse(data)); }
  close() { this.readyState = 3; }
  message(data) { act(() => this.onmessage({ data: typeof data === 'object' && !(data instanceof ArrayBuffer) ? JSON.stringify(data) : data })); }
}
beforeEach(() => {
  Socket.all = [];
  vi.stubGlobal('WebSocket', Socket);
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, json: async () => ({ wearer_name: 'Aman' }) }));
  URL.createObjectURL = vi.fn(() => 'blob:frame'); URL.revokeObjectURL = vi.fn();
  history.replaceState(null, '', '/h/test?t=secret');
});
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });
async function join() {
  render(<HelperPage />);
  await screen.findByText('Be there for Aman.');
  expect(Socket.all).toHaveLength(0);
  fireEvent.click(screen.getByRole('button', { name: /Join call/ }));
  const ws = Socket.all[0]; act(() => ws.onopen()); ws.message({ t: 'wearer', on: true });
  return ws;
}
function frame() {
  const buffer = new ArrayBuffer(13), bytes = new Uint8Array(buffer);
  bytes[0] = 70; new DataView(buffer).setBigUint64(1, BigInt(Date.now())); bytes.set([255, 216, 255, 217], 9);
  return buffer;
}
test('consent gates connection; stale video gates guidance, but Stop works', async () => {
  const ws = await join();
  expect(screen.getByRole('button', { name: /Guide left/ }).disabled).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: /Stop the wearer/ }));
  expect(ws.sent.at(-1)).toEqual({ t: 'guide', dir: 'stop' });
  ws.message(frame());
  fireEvent.click(screen.getByRole('button', { name: /Guide left/ }));
  fireEvent.keyDown(window, { key: 'ArrowUp' });
  expect(ws.sent.slice(-2)).toEqual([{ t: 'guide', dir: 'L' }, { t: 'guide', dir: 'fwd' }]);
  vi.spyOn(Date, 'now').mockReturnValue(Date.now() + 4000);
  await act(() => new Promise(resolve => setTimeout(resolve, 1100)));
  expect(screen.getByRole('button', { name: /Guide left/ }).disabled).toBe(true);
  fireEvent.keyDown(window, { key: ' ' });
  expect(ws.sent.at(-1)).toEqual({ t: 'guide', dir: 'stop' });
});
test('camera changes, readable alerts, and ending release the video and stop reconnects', async () => {
  const ws = await join(); ws.message(frame());
  fireEvent.click(screen.getByRole('button', { name: 'Rear' }));
  expect(ws.sent.at(-1)).toEqual({ t: 'cam', which: 'R' });
  expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:frame');
  ws.message({ t: 'tap', kind: 'stopped', side: 'L' });
  expect(screen.getByText('Someone stopped behind them, left.')).toBeTruthy();
  ws.message(frame());
  fireEvent.click(screen.getByRole('button', { name: 'End call' }));
  expect(ws.sent.at(-1)).toEqual({ t: 'end' });
  expect(screen.getByText('This call has ended')).toBeTruthy();
  expect(screen.queryByRole('img')).toBeNull();
  act(() => ws.onclose({ code: 1006 })); expect(Socket.all).toHaveLength(1);
});
test('network loss reconnects; occupied or expired rooms do not', async () => {
  const ws = await join(); vi.useFakeTimers();
  act(() => ws.onclose({ code: 1006 }));
  act(() => vi.advanceTimersByTime(1500)); expect(Socket.all).toHaveLength(2);
  const second = Socket.all[1]; act(() => second.onclose({ code: 4409 }));
  expect(screen.getByText('Someone else is already helping')).toBeTruthy();
  act(() => vi.advanceTimersByTime(10000)); expect(Socket.all).toHaveLength(2);
});
test('following and urgent events use readable wearer-relative directions', () => {
  expect(describe({ t: 'alert', kind: 'following', side: 'R', minutes: 4 })).toBe('Someone has been behind them, right for 4 minutes.');
  expect(describe({ t: 'alert', label: 'Car', level: 2, side: 'B' })).toBe('Urgent: Car approaching behind them.');
});
