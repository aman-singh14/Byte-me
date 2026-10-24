"""Switch the FaceTime camera between the Mac webcam and the glasses' front camera.

FaceTime on the Mac uses "OBS Virtual Camera"; OBS has two scenes ("Mac Webcam",
"Glasses POV"), and this flips between them over obs-websocket (built into OBS 28+).
OBS setup: a Media Source on the FRONT camera's MJPEG URL in scene "Glasses POV", the Mac
camera in "Mac Webcam", Tools > WebSocket Server Settings on (port 4455), Start Virtual
Camera, then FaceTime > Video > OBS Virtual Camera. Mac FaceTime only.

    python -m backend.facetime status | glasses | mac | toggle
"""

import argparse
import logging


class FaceTimeError(RuntimeError):
    pass


class FaceTimeSwitch:
    def __init__(self, cfg):
        o = cfg.get("obs", {})
        self.host = o.get("host", "localhost")
        self.port = o.get("port", 4455)
        self.password = o.get("password", "")
        self.scenes = {"mac": o.get("scene_mac", "Mac Webcam"), "glasses": o.get("scene_glasses", "Glasses POV")}

    def _client(self):
        try:
            import obsws_python as obs
            logging.getLogger("obsws_python").setLevel(logging.CRITICAL)   # we report errors ourselves
        except ImportError as e:
            raise FaceTimeError("obsws-python is not installed (pip install -r requirements.txt)") from e
        try:
            return obs.ReqClient(host=self.host, port=self.port, password=self.password, timeout=3)
        except Exception as e:   # obsws raises plain ConnectionRefusedError, TimeoutError, ...
            raise FaceTimeError(f"cannot reach OBS at {self.host}:{self.port} "
                                f"(is OBS open with Tools > WebSocket Server Settings enabled?): {e}") from e

    def status(self):
        c = self._client()
        try:
            scene = c.get_current_program_scene().current_program_scene_name
        finally:
            c.disconnect()
        view = next((k for k, v in self.scenes.items() if v == scene), None)
        return {"scene": scene, "view": view}

    def switch(self, target="toggle"):
        """target: 'glasses', 'mac' or 'toggle'. Returns the new status."""
        if target not in ("glasses", "mac", "toggle"):
            raise ValueError("target must be glasses, mac or toggle")
        c = self._client()
        try:
            if target == "toggle":
                scene = c.get_current_program_scene().current_program_scene_name
                target = "mac" if scene == self.scenes["glasses"] else "glasses"
            try:
                c.set_current_program_scene(self.scenes[target])
            except Exception as e:
                raise FaceTimeError(f"OBS has no scene named {self.scenes[target]!r}: {e}") from e
        finally:
            c.disconnect()
        return {"scene": self.scenes[target], "view": target}


def main(argv=None):
    from backend.config import load_config

    ap = argparse.ArgumentParser(description="Switch FaceTime between Mac webcam and glasses (via OBS)")
    ap.add_argument("action", choices=("status", "glasses", "mac", "toggle"))
    args = ap.parse_args(argv)
    sw = FaceTimeSwitch(load_config())
    try:
        print(sw.status() if args.action == "status" else sw.switch(args.action))
    except FaceTimeError as e:
        raise SystemExit(str(e))


if __name__ == "__main__":
    main()
