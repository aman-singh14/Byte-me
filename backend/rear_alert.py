"""rear.mode: software. Rear camera stream -> LGMD (lgmd.py, unchanged) -> spoken warning.

The product runs LGMD on the FPGA instead (rear.mode: fpga, docs/rear_event_protocol.md).
This path stays as a fallback and for development.

Every rear frame is reduced with lgmd.preprocess to 80x60 gray and fed to
lgmd.lgmd_step, so this runs exactly the integer model the ESP32 and FPGA ports
must match. When it fires, a short warning is spoken (macOS `say`, pyttsx3 or
print) with a cooldown. With rear.yolo.enabled, one YOLO pass on the full frame
names what is approaching ("Person approaching from behind, on your left").

    python -m backend.rear_alert                       # rear source from config, live window
    python -m backend.rear_alert --source synthetic --headless 10
"""

import argparse
import shutil
import subprocess
import threading
import time

import cv2

import lgmd

SIDE_WORDS = {"L": "on your left", "C": "", "R": "on your right"}
YOLO_LABELS = {"person", "bicycle", "car", "motorcycle", "bus", "truck", "dog", "skateboard"}


class Speaker:
    """Non-blocking text to speech. Drops a message if the previous one is still playing."""

    def __init__(self, mode="auto"):
        if mode == "auto":
            if shutil.which("say"):
                mode = "say"
            else:
                try:
                    import pyttsx3  # noqa: F401
                    mode = "pyttsx3"
                except ImportError:
                    mode = "print"
        self.mode = mode
        self._proc = None
        self._busy = threading.Lock()

    def say(self, text):
        print(f"[rear] SPEAK: {text}")
        if self.mode == "say":
            if self._proc is None or self._proc.poll() is not None:
                self._proc = subprocess.Popen(["say", text])
        elif self.mode == "pyttsx3":
            if self._busy.acquire(blocking=False):
                threading.Thread(target=self._pyttsx3, args=(text,), daemon=True).start()

    def _pyttsx3(self, text):
        try:
            import pyttsx3
            engine = pyttsx3.init()
            engine.say(text)
            engine.runAndWait()
        finally:
            self._busy.release()


class Labeler:
    """Optional YOLO pass: what is the biggest relevant thing in the frame?"""

    def __init__(self, model="yolov8n.pt", min_conf=0.4):
        from ultralytics import YOLO   # optional dependency
        self.model = YOLO(model)
        self.min_conf = min_conf

    def label(self, frame):
        res = self.model(frame, verbose=False)[0]
        best = None
        for box in res.boxes:
            name = res.names[int(box.cls)]
            conf = float(box.conf)
            if name not in YOLO_LABELS or conf < self.min_conf:
                continue
            x0, y0, x1, y1 = box.xyxy[0].tolist()
            area = (x1 - x0) * (y1 - y0)
            if best is None or area > best[0]:
                best = (area, name)
        return None if best is None else best[1]


class RearAlert:
    def __init__(self, cfg, speaker=None):
        r = cfg.get("rear", {})
        self.params = lgmd.Params(**r.get("lgmd", {}))
        self.params.check()
        self.flip = r.get("flip", True)
        self.cooldown_s = r.get("cooldown_s", 4.0)
        self.message = r.get("message", "Object approaching from behind")
        self.speaker = speaker or Speaker(r.get("speech", "auto"))
        if self.speaker.mode == "off":
            self.speaker = None
        y = r.get("yolo", {})
        self.labeler = None
        if y.get("enabled"):
            try:
                self.labeler = Labeler(y.get("model", "yolov8n.pt"), y.get("min_conf", 0.4))
            except ImportError:
                print("[rear] yolo.enabled but ultralytics is not installed (pip install ultralytics); skipping")
        self.state_lgmd = None
        self.out = None
        self.last_alert_t = -1e9
        self.fires = 0
        self.state = {}

    def side(self, out):
        """Wearer side with the most K: 'L', 'C' (straight behind) or 'R'."""
        sides = lgmd.wearer_sides(out, self.flip)
        return "LCR"[sides.index(max(sides))]

    def process(self, frame, t):
        """Full camera frame in. Returns (state dict, events). Event: ("alert", {...})."""
        small = lgmd.preprocess(frame)
        if self.state_lgmd is None:
            self.state_lgmd = lgmd.init_state(small)
        self.state_lgmd, out = lgmd.lgmd_step(small, self.state_lgmd, self.params)
        self.out = out
        events = []
        if out.fire:
            self.fires += 1
            if t - self.last_alert_t >= self.cooldown_s:
                self.last_alert_t = t
                side = self.side(out)
                label = self.labeler.label(frame) if self.labeler else None
                if label:
                    text = f"{label.capitalize()} approaching from behind"
                else:
                    text = self.message
                if SIDE_WORDS[side]:
                    text += f", {SIDE_WORDS[side]}"
                if self.speaker:
                    self.speaker.say(text)
                events.append(("alert", {"side": side, "k": out.K, "label": label, "text": text}))
        self.state = {
            "k": out.K, "f": out.F, "rise": out.rise, "fire": out.fire,
            "k_thresh": self.params.k_thresh, "fires_total": self.fires,
            "last_alert_age_s": round(t - self.last_alert_t, 1) if self.last_alert_t > 0 else None,
        }
        return self.state, events

    def annotate(self, img):
        o = self.out
        if o is None:
            return img
        firing = time.time() - self.last_alert_t < 1.0
        color = (0, 0, 255) if firing else (0, 255, 0)
        cv2.putText(img, f"K {o.K} / {self.params.k_thresh}  F {o.F}  rise {o.rise}",
                    (8, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)
        if firing:
            cv2.putText(img, "APPROACHING", (8, 60), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (0, 0, 255), 3)
        return img


def main(argv=None):
    from backend.config import load_config
    from backend.streams import FrameReader

    ap = argparse.ArgumentParser(description="Rear collision warning from LGMD")
    ap.add_argument("--source", default=None, help="camera source (default: cameras.rear in config.dev.yaml)")
    ap.add_argument("--headless", type=float, metavar="SECONDS", help="no window, run this long")
    ap.add_argument("--yolo", action="store_true", help="name the approaching object (needs ultralytics)")
    args = ap.parse_args(argv)
    cfg = load_config(dev=True)
    if args.yolo:
        cfg["rear"]["yolo"]["enabled"] = True
    alert = RearAlert(cfg)
    reader = FrameReader(args.source if args.source is not None else cfg["cameras"]["rear"]["source"])
    seq, t_end = 0, time.time() + (args.headless or 1e9)
    try:
        while time.time() < t_end:
            seq, frame, t = reader.wait_new(seq)
            if frame is None:
                continue
            _, events = alert.process(frame, t)
            for ev in events:
                print(ev)
            if not args.headless:
                cv2.imshow("rear", alert.annotate(frame.copy()))
                if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
                    break
    finally:
        reader.close()
        cv2.destroyAllWindows()
    print(f"fire frames: {alert.fires}")


if __name__ == "__main__":
    main()
