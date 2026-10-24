"""Speech output for everything the glasses say. One queue, several outputs.

Outputs (config `speech`):
  laptop   macOS `say` (to whatever the Mac plays through: Bluetooth earbuds/speaker),
           pyttsx3 elsewhere, or print. `--speech print` silences it.
  browser  a "speak" event on /ws/live; the dashboard (or Aman's app) speaks it with
           the phone's own text-to-speech.
  esp32    placeholder for a MAX98357A I2S speaker on an ESP32 (not built yet).

Priorities: "urgent" (rear danger) interrupts whatever is playing and clears the
queue; "normal" messages play in order (a quick local answer, then Muse's answer).
"""

import queue
import shutil
import subprocess
import threading

URGENT, NORMAL = "urgent", "normal"


def pick_laptop_mode(mode="auto"):
    if mode != "auto":
        return mode
    if shutil.which("say"):
        return "say"
    try:
        import pyttsx3  # noqa: F401
        return "pyttsx3"
    except ImportError:
        return "print"


class LaptopVoice:
    """Speaks one message at a time; stop() cuts the current one short."""

    def __init__(self, mode="auto", rate=None):
        self.mode = pick_laptop_mode(mode)
        self.rate = rate
        self._proc = None

    def speak(self, text):
        """Blocks until done (runs on the Voice worker thread)."""
        if self.mode == "say":
            cmd = ["say"] + (["-r", str(self.rate)] if self.rate else []) + [text]
            self._proc = subprocess.Popen(cmd)
            self._proc.wait()
        elif self.mode == "pyttsx3":
            import pyttsx3
            engine = pyttsx3.init()
            engine.say(text)
            engine.runAndWait()

    def stop(self):
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()


class ESP32Speaker:
    """Future: stream TTS audio to an ESP32 driving a MAX98357A over I2S. Not built."""

    mode = "esp32"

    def speak(self, text):
        pass

    def stop(self):
        pass


class Voice:
    """say(text, priority) from any thread. Also has .mode so RearAlert can use it."""

    supports_priority = True

    def __init__(self, cfg=None, emit=None):
        s = (cfg or {}).get("speech", {})
        self.laptop = LaptopVoice(s.get("laptop", "auto"), s.get("rate"))
        self.mode = self.laptop.mode
        self.browser = s.get("browser", True)
        self.emit = emit                     # Runtime.emit, for the browser output
        self.esp32 = ESP32Speaker() if s.get("esp32") else None
        self.history = []                    # (priority, text), for tests and the dashboard
        self._q = queue.Queue()
        self._lock = threading.Lock()
        threading.Thread(target=self._worker, name="voice", daemon=True).start()

    def say(self, text, priority=NORMAL, source=None):
        print(f"[speak{'!' if priority == URGENT else ''}] {text}")
        with self._lock:
            self.history.append((priority, text))
            del self.history[:-50]
        if self.emit and self.browser:
            self.emit("speak", {"text": text, "priority": priority, "source": source})
        if priority == URGENT:
            self._drain()
            self.laptop.stop()
            if self.esp32:
                self.esp32.stop()
        if self.mode not in ("print", "off"):
            self._q.put(text)

    def _drain(self):
        try:
            while True:
                self._q.get_nowait()
        except queue.Empty:
            pass

    def _worker(self):
        while True:
            text = self._q.get()
            try:
                self.laptop.speak(text)
                if self.esp32:
                    self.esp32.speak(text)
            except Exception as e:             # a TTS hiccup must not kill the voice
                print(f"[speak] error: {e!r}")
