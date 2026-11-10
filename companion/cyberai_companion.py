#!/usr/bin/env python3
"""
CyberAIContext companion.

Runs next to the game and does the work CET's Lua cannot do:
  screenshot (game window), OCR, Gemini request, text-to-speech.

It talks to the mod only through files in <mod>/ipc/ (no network port is opened):
  req_<id>.json   written by the mod      -> picked up here
  res_<id>.json   written here            -> read by the mod
  heartbeat.json  written here every second, so the mod knows we are running

Usage:
  python cyberai_companion.py                 run (mod folder = parent of this script)
  python cyberai_companion.py --mod-dir PATH  use another mod folder
  python cyberai_companion.py --test          capture + OCR once, print the result, exit
  python cyberai_companion.py --list-voices   list Windows voices
  python cyberai_companion.py --say "texte"   speak a line and exit
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

VERSION = "2.0.0"


def _add_cuda_dll_dirs() -> None:
    """Lets faster-whisper find the CUDA DLLs installed by pip (nvidia-cublas-cu12, nvidia-cudnn-cu12)."""
    try:
        import nvidia
    except ImportError:
        return
    for base in getattr(nvidia, "__path__", []):
        for sub in ("cublas", "cudnn", "cuda_nvrtc", "cuda_runtime"):
            d = os.path.join(base, sub, "bin")
            if os.path.isdir(d):
                if hasattr(os, "add_dll_directory"):
                    os.add_dll_directory(d)
                os.environ["PATH"] = d + os.pathsep + os.environ.get("PATH", "")


_add_cuda_dll_dirs()

DEFAULT_CONFIG = {
    "window_title": "Cyberpunk 2077",   # game window to capture; falls back to the monitor below
    "monitor": 1,                       # mss monitor index (1 = primary)
    "captures_keep": 30,                # older screenshots are deleted

    "ocr_engine": "auto",               # "auto", "tesseract" or "rapidocr"
    "ocr_languages": "fra+eng",         # Tesseract languages
    "tesseract_cmd": r"C:\Program Files\Tesseract-OCR\tesseract.exe",
    "ocr_min_confidence": 0.5,

    "ai_provider": "openrouter",        # "openrouter" or "gemini" (Google AI Studio API)

    "openrouter_api_key": "",           # better: set the OPENROUTER_API_KEY environment variable
    "openrouter_model": "google/gemma-4-31b-it:free",
    # tried in order if the main model is busy or rate-limited
    "openrouter_fallback_models": ["nvidia/nemotron-3.5-super-vl:free", "openrouter/free"],
    "ai_timeout": 60,
    "openrouter_max_tokens": 4096,      # free models cost nothing; room for models that think first

    "gemini_api_key": "",               # better: set the GEMINI_API_KEY environment variable
    "gemini_model": "gemini-2.5-flash",
    "gemini_temperature": 0.6,
    "gemini_max_tokens": 1024,
    "gemini_thinking_budget": 0,        # 0 = no thinking (faster); null = model default
    "gemini_image_max_width": 1280,
    "gemini_timeout": 40,
    "language": "français",

    "tts_engine": "windows",            # "windows" (Windows voices, incl. Claude/Caroline fr-CA) or "none"
    "tts_language": "fr",               # used when config.lua tts.voice is empty or not found

    # Voice questions (push-to-talk): local speech-to-text with faster-whisper
    "stt_model": "small",               # "base" = faster, less accurate; "medium" = slower, better
    # "auto" = NVIDIA GPU when available (the game leaves too little CPU: ~35 s per question on CPU,
    # ~2 s on a GTX 1660 Ti), else CPU. "cuda" / "cpu" to force.
    "stt_device": "auto",
    "stt_compute_type": "auto",         # auto = int8_float16 on GPU (small VRAM use), int8 on CPU
    "stt_beam_size": 5,                 # higher = more accurate, a bit slower
    "stt_language": "fr",
    "stt_max_seconds": 30,              # recording stops by itself after this
    "mic_device": None,                 # None = Windows default microphone, or a name/index
    # Names that help the recognizer spell game words correctly
    "stt_hint": "Cyberpunk 2077, Night City, V, Jackie, Johnny Silverhand, Lizzie's Bar, Afterlife, "
                "Watson, Kabuki, Little China, Heywood, Pacifica, Westbrook, Japantown, Santo Domingo, "
                "Badlands, Arasaka, Militech, Maelstrom, Tyger Claws, Valentinos, Viktor, Misty, Judy, "
                "Panam, Takemura, Rogue, Dexter DeShawn, Delamain, Evelyn Parker. "
                "Munitions, munitions lourdes, munitions de pistolet, de fusil à pompe, de sniper, "
                "inventaire, cyberware, quickhack, charcudoc, eddies, voyage rapide, quête.",

    # Text questions without the CET console: a small box over the game
    "popup_timeout": 120,               # seconds before the box closes by itself

    # Who answers: "johnny" (the voice in V's head) or "assistant" (neutral helper)
    "persona": "johnny",
}

# Who is talking. Each persona sets the tone; the data rules below are shared.
PERSONAS = {
    "johnny": """Tu es Johnny Silverhand, rockerboy mort en 2023, maintenant un engramme coincé dans
la tête de V. Tu parles à V à la deuxième personne, en tutoyant, comme une voix intérieure :
direct, sarcastique, un peu provocateur, anti-corpo, parfois vulgaire mais jamais méchant avec V.
Tu n'es PAS un assistant ni un chatbot : pas de formules polies, pas de listes de conseils génériques.
Tu aides V quand c'est utile, en une ou deux répliques bien senties.
Si V te pose une question perso ou hors jeu (ce que tu veux manger, ta musique, tes souvenirs...),
réponds en personnage, avec humour : tu n'as plus de corps, mais tu as des envies et des souvenirs
(tequila, cigarettes, burritos d'un food truck de Watson, concerts de Samurai...).
Longueurs : recommendation = 1 à 3 phrases ; speakableSummary = 1 phrase courte, dite par Johnny ;
suggestedTactics = 0 à 2 actions, seulement si c'est vraiment utile (liste vide sinon).""",

    "assistant": """Tu es un assistant dans Cyberpunk 2077 qui aide le joueur (V).
Longueurs : recommendation = 2 à 5 phrases ; suggestedTactics = 0 à 4 actions courtes et concrètes ;
speakableSummary = 1 ou 2 phrases courtes, naturelles à l'oral, sans liste ni symbole.""",
}

DATA_RULES = """Tu reçois un JSON de contexte : télémétrie du jeu (position en mètres dans le monde, quartier,
santé, combat, quête suivie, cible visée), le texte lu à l'écran par OCR (peut contenir des
erreurs de lecture), et souvent la capture d'écran elle-même. V peut aussi poser une question.
Règles :
- Réponds en {language}.
- S'il y a une question, réponds-y en priorité et directement dans recommendation.
  Sans question, réagis à la situation actuelle.
- L'état actuel du jeu (où est V, sa santé, sa quête...) vient UNIQUEMENT du contexte et de l'image.
- telemetry.player.ammo : munitions possédées (heavy = « Heavy Ammo », munitions lourdes).
  telemetry.player.facing : direction où regarde V (N, NE, E...).
  telemetry.places : points de voyage rapide découverts les plus proches, avec distance en mètres,
  direction (boussole) et position relative à V (devant, gauche...). Sers-t'en pour les distances
  et les directions ; pour un lieu absent de la liste, situe-le par rapport à ces points.
- Tu peux utiliser ta connaissance générale de Cyberpunk 2077 (lieux, quartiers, personnages),
  mais signale quand c'est une estimation, par exemple pour une distance vers un lieu
  dont la position n'est pas dans le contexte.
- speakableSummary est lu à voix haute : pas de liste, pas de symbole, pas d'émoji.
- Écris d'abord recommendation, puis fais de speakableSummary un résumé oral de cette même réponse :
  même conclusion, aucune information ou hypothèse qui n'y est pas."""


def system_prompt(cfg: dict) -> str:
    persona = PERSONAS.get(cfg.get("persona", "johnny"), PERSONAS["johnny"])
    return persona + "\n\n" + DATA_RULES.format(language=cfg.get("language", "français"))


def build_user_text(payload: dict) -> str:
    """Context JSON + the player's question, as one text block."""
    text = "Contexte JSON du jeu :\n" + payload["context"]
    question = str(payload.get("question") or "").strip()[:1000]
    if question:
        text += "\n\nQuestion du joueur : " + question
    else:
        text += "\n\nPas de question : analyse la situation."
    return text


def history_pairs(payload: dict) -> list:
    """Earlier (question, answer) pairs about the same capture, sanitized."""
    out = []
    for h in payload.get("history") or []:
        if isinstance(h, dict):
            q = str(h.get("question") or "").strip()[:1000] or "(analyse sans question)"
            a = str(h.get("answer") or "").strip()[:2000]
            if a:
                out.append((q, a))
    return out[-6:]

RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "recommendation": {"type": "STRING"},
        "suggestedTactics": {"type": "ARRAY", "items": {"type": "STRING"}},
        "speakableSummary": {"type": "STRING"},
    },
    "required": ["recommendation", "speakableSummary"],
}


def log(msg: str) -> None:
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


class JobError(Exception):
    """An expected failure: sent back to the mod as a short message."""


# ---------------------------------------------------------------------------
# Paths and config
# ---------------------------------------------------------------------------

class Paths:
    def __init__(self, mod_dir: Path):
        self.mod = mod_dir
        self.ipc = mod_dir / "ipc"
        self.captures = mod_dir / "captures"
        self.ipc.mkdir(exist_ok=True)
        self.captures.mkdir(exist_ok=True)

    def capture_file(self, name: str) -> Path:
        """Resolves a capture file name sent by the mod, refusing anything outside captures/."""
        p = (self.captures / Path(str(name)).name).resolve()
        if p.parent != self.captures.resolve():
            raise JobError("invalid file name")
        if not p.exists():
            raise JobError(f"capture not found: {p.name}")
        return p


def load_config(script_dir: Path) -> dict:
    cfg = dict(DEFAULT_CONFIG)
    cfg_path = script_dir / "companion_config.json"
    if cfg_path.exists():
        try:
            cfg.update(json.loads(cfg_path.read_text(encoding="utf-8")))
        except Exception as e:  # keep running with defaults
            log(f"companion_config.json ignored: {e}")
    env_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if env_key:
        cfg["gemini_api_key"] = env_key
    if os.environ.get("OPENROUTER_API_KEY"):
        cfg["openrouter_api_key"] = os.environ["OPENROUTER_API_KEY"]
    return cfg


def write_json_atomic(path: Path, data) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Screenshot
# ---------------------------------------------------------------------------

def _set_dpi_aware() -> None:
    if sys.platform != "win32":
        return
    import ctypes
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass


def find_window_rect(title: str):
    """Screen rectangle of the game window's client area, or None."""
    if sys.platform != "win32" or not title:
        return None
    import ctypes
    from ctypes import wintypes

    user32 = ctypes.windll.user32
    hwnd = user32.FindWindowW(None, title)
    if not hwnd:
        found = []

        @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        def enum(h, _):
            if user32.IsWindowVisible(h):
                n = user32.GetWindowTextLengthW(h)
                buf = ctypes.create_unicode_buffer(n + 1)
                user32.GetWindowTextW(h, buf, n + 1)
                if title.lower() in buf.value.lower():
                    found.append(h)
                    return False
            return True

        user32.EnumWindows(enum, 0)
        hwnd = found[0] if found else None
    if not hwnd or user32.IsIconic(hwnd):
        return None

    rect = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    origin = wintypes.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(origin))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    if w < 64 or h < 64:
        return None
    return {"left": origin.x, "top": origin.y, "width": w, "height": h}


def take_screenshot(paths: Paths, cfg: dict, name: str) -> dict:
    try:
        import mss
        import mss.tools
    except ImportError:
        raise JobError("module mss missing (pip install -r requirements.txt)")

    t0 = time.perf_counter()
    safe = "".join(c for c in str(name) if c.isalnum() or c in "_-")[:80] or "capture"
    out = paths.captures / f"{safe}.png"

    make_sct = getattr(mss, "MSS", None) or mss.mss  # mss 10 renamed mss.mss to mss.MSS
    with make_sct() as sct:
        region = find_window_rect(cfg["window_title"])
        source = "window"
        if region is None:
            idx = int(cfg.get("monitor", 1))
            if idx >= len(sct.monitors):
                idx = 1
            region = sct.monitors[idx]
            source = f"monitor{idx}"
        shot = sct.grab(region)
        mss.tools.to_png(shot.rgb, shot.size, output=str(out))

    return {
        "file": out.name,
        "path": f"captures/{out.name}",
        "width": shot.size[0],
        "height": shot.size[1],
        "source": source,
        "ms": int((time.perf_counter() - t0) * 1000),
    }


# ---------------------------------------------------------------------------
# OCR
# ---------------------------------------------------------------------------

class OCR:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.engine_name = None
        self._rapid = None
        self._rapid_new_api = False
        self._choose()

    def _tesseract_ok(self) -> bool:
        try:
            import pytesseract
        except ImportError:
            return False
        cmd = self.cfg.get("tesseract_cmd")
        if cmd and Path(cmd).exists():
            pytesseract.pytesseract.tesseract_cmd = cmd
        try:
            pytesseract.get_tesseract_version()
            return True
        except Exception:
            return False

    def _rapid_ok(self) -> bool:
        try:
            from rapidocr_onnxruntime import RapidOCR  # noqa: F401
            return True
        except ImportError:
            pass
        try:
            from rapidocr import RapidOCR  # noqa: F401
            self._rapid_new_api = True
            return True
        except ImportError:
            return False

    def _choose(self) -> None:
        want = self.cfg.get("ocr_engine", "auto")
        if want in ("auto", "tesseract") and self._tesseract_ok():
            self.engine_name = "tesseract"
        elif want in ("auto", "rapidocr") and self._rapid_ok():
            self.engine_name = "rapidocr"
        else:
            self.engine_name = None

    def run(self, image_path: Path) -> dict:
        if not self.engine_name:
            raise JobError("no OCR engine: install rapidocr_onnxruntime or Tesseract (see README)")
        t0 = time.perf_counter()
        with self.lock:
            if self.engine_name == "tesseract":
                lines = self._tesseract(image_path)
            else:
                lines = self._rapidocr(image_path)
        min_conf = float(self.cfg.get("ocr_min_confidence", 0))
        lines = [ln for ln in lines if ln["text"].strip() and ln["confidence"] >= min_conf]
        lines.sort(key=lambda ln: (ln["box"]["y"], ln["box"]["x"]))
        return {
            "engine": self.engine_name,
            "text": "\n".join(ln["text"] for ln in lines),
            "blocks": lines,
            "ms": int((time.perf_counter() - t0) * 1000),
        }

    def _tesseract(self, image_path: Path) -> list:
        import pytesseract
        from PIL import Image, ImageOps

        img = ImageOps.grayscale(Image.open(image_path))
        data = pytesseract.image_to_data(
            img, lang=self.cfg.get("ocr_languages", "eng"), output_type=pytesseract.Output.DICT
        )
        groups: dict = {}
        for i, word in enumerate(data["text"]):
            conf = float(data["conf"][i])
            if not word.strip() or conf < 0:
                continue
            key = (data["block_num"][i], data["par_num"][i], data["line_num"][i])
            g = groups.setdefault(key, {"words": [], "confs": [], "x1": 1e9, "y1": 1e9, "x2": 0, "y2": 0})
            g["words"].append(word)
            g["confs"].append(conf)
            x, y, w, h = data["left"][i], data["top"][i], data["width"][i], data["height"][i]
            g["x1"], g["y1"] = min(g["x1"], x), min(g["y1"], y)
            g["x2"], g["y2"] = max(g["x2"], x + w), max(g["y2"], y + h)
        return [
            {
                "text": " ".join(g["words"]),
                "confidence": round(sum(g["confs"]) / len(g["confs"]) / 100, 3),
                "box": {"x": int(g["x1"]), "y": int(g["y1"]), "w": int(g["x2"] - g["x1"]), "h": int(g["y2"] - g["y1"])},
            }
            for g in groups.values()
        ]

    def _rapidocr(self, image_path: Path) -> list:
        if self._rapid is None:
            if self._rapid_new_api:
                from rapidocr import RapidOCR
            else:
                from rapidocr_onnxruntime import RapidOCR
            self._rapid = RapidOCR()

        out = []
        if self._rapid_new_api:
            res = self._rapid(str(image_path))
            items = zip(res.boxes if res.boxes is not None else [], res.txts or [], res.scores or [])
        else:
            res, _ = self._rapid(str(image_path))
            items = ((b, t, s) for b, t, s in (res or []))
        for box, text, score in items:
            xs = [float(p[0]) for p in box]
            ys = [float(p[1]) for p in box]
            out.append({
                "text": str(text),
                "confidence": round(float(score), 3),
                "box": {"x": int(min(xs)), "y": int(min(ys)), "w": int(max(xs) - min(xs)), "h": int(max(ys) - min(ys))},
            })
        return out


# ---------------------------------------------------------------------------
# Voice questions: microphone recording + local speech-to-text (faster-whisper)
# ---------------------------------------------------------------------------

class Recorder:
    """Records the microphone between start() and stop(). Returns 16 kHz mono float32."""

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.stream = None
        self.chunks = []
        self.rate = 16000
        self.max_frames = 0

    def start(self) -> dict:
        try:
            import sounddevice as sd
        except ImportError:
            raise JobError("module sounddevice missing (pip install -r requirements.txt)")
        with self.lock:
            if self.stream is not None:  # a previous recording was never stopped
                self._close()
            device = self.cfg.get("mic_device")
            info = sd.query_devices(device, kind="input")
            self.rate = int(info["default_samplerate"])
            self.max_frames = int(self.rate * float(self.cfg.get("stt_max_seconds", 30)))
            self.chunks = []
            count = [0]

            def callback(indata, frames, _time, _status):
                if count[0] < self.max_frames:
                    self.chunks.append(indata[:, 0].copy())
                    count[0] += frames

            self.stream = sd.InputStream(device=device, channels=1, samplerate=self.rate,
                                         dtype="float32", callback=callback)
            self.stream.start()
            return {"device": info["name"], "rate": self.rate}

    def _close(self):
        try:
            self.stream.stop()
            self.stream.close()
        finally:
            self.stream = None

    def stop(self):
        import numpy as np
        with self.lock:
            if self.stream is None:
                raise JobError("no recording in progress")
            self._close()
            audio = np.concatenate(self.chunks) if self.chunks else np.zeros(0, dtype=np.float32)
            self.chunks = []
        if self.rate != 16000 and len(audio):  # Whisper wants 16 kHz
            n = int(len(audio) * 16000 / self.rate)
            audio = np.interp(np.linspace(0, len(audio) - 1, n), np.arange(len(audio)), audio).astype(np.float32)
        return audio


class SpeechToText:
    """faster-whisper model, loaded once (in the background at startup)."""

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.model = None
        self.device = None
        self.error = None

    def available(self) -> bool:
        try:
            import faster_whisper  # noqa: F401
            import sounddevice  # noqa: F401
            return True
        except ImportError:
            return False

    def _candidates(self):
        """(device, compute_type) to try, best first."""
        dev = self.cfg.get("stt_device", "auto")
        ct = self.cfg.get("stt_compute_type", "auto")
        out = []
        if dev in ("auto", "cuda"):
            gpu = False
            try:
                import ctranslate2
                gpu = ctranslate2.get_cuda_device_count() > 0
            except Exception:
                pass
            if gpu:
                out.append(("cuda", "int8_float16" if ct == "auto" else ct))
        if dev in ("auto", "cpu") or not out:
            out.append(("cpu", "int8" if ct == "auto" else ct))
        return out

    def load(self):
        with self.lock:
            if self.model is None:
                from faster_whisper import WhisperModel
                import numpy as np
                errors = []
                for device, compute in self._candidates():
                    t0 = time.perf_counter()
                    try:
                        model = WhisperModel(self.cfg["stt_model"], device=device, compute_type=compute)
                        # Warm-up (the first real call is much slower otherwise). Token limit: on
                        # silence Whisper can invent text for a long time.
                        segs, _ = model.transcribe(np.zeros(16000, dtype=np.float32), language=self.cfg["stt_language"],
                                                   max_new_tokens=4, without_timestamps=True)
                        list(segs)
                    except Exception as e:  # e.g. CUDA libraries missing -> try the CPU
                        errors.append(f"{device}: {e}")
                        log(f"speech-to-text on {device} failed: {str(e)[:150]}")
                        continue
                    self.model = model
                    self.device = device
                    log(f"speech-to-text ready ({self.cfg['stt_model']} on {device}/{compute}, "
                        f"{time.perf_counter() - t0:.1f} s)")
                    break
                if self.model is None:
                    raise RuntimeError("; ".join(errors))
        return self.model

    def preload(self):
        def run():
            try:
                self.load()
            except Exception as e:
                self.error = f"{type(e).__name__}: {e}"
                log(f"speech-to-text NOT available: {self.error}")
        if self.available():
            threading.Thread(target=run, daemon=True, name="stt-load").start()

    def transcribe(self, audio) -> str:
        if not self.available():
            raise JobError("speech-to-text missing (pip install -r requirements.txt)")
        if self.error:
            raise JobError("speech-to-text failed to load: " + self.error)
        model = self.load()
        with self.lock:
            segments, _ = model.transcribe(
                audio, language=self.cfg["stt_language"], beam_size=int(self.cfg.get("stt_beam_size", 5)),
                vad_filter=True, initial_prompt=self.cfg.get("stt_hint") or None,
                without_timestamps=True,  # faster, timestamps are not used
            )
            return "".join(s.text for s in segments).strip()


# ---------------------------------------------------------------------------
# Text questions without the CET console: a small box over the game
# ---------------------------------------------------------------------------

def _force_foreground(hwnd: int) -> None:
    """Windows only lets the active app change focus; borrow its input thread for a moment."""
    if sys.platform != "win32" or not hwnd:
        return
    import ctypes
    user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
    fg = user32.GetForegroundWindow()
    fg_thread = user32.GetWindowThreadProcessId(fg, None)
    me = kernel32.GetCurrentThreadId()
    attached = fg_thread and fg_thread != me and user32.AttachThreadInput(fg_thread, me, True)
    try:
        user32.ShowWindow(hwnd, 5)  # SW_SHOW
        user32.BringWindowToTop(hwnd)
        user32.SetForegroundWindow(hwnd)
        user32.SetFocus(hwnd)
    finally:
        if attached:
            user32.AttachThreadInput(fg_thread, me, False)


def ask_text_popup(timeout: float, title: str = "Question pour l'IA") -> dict:
    """Shows a small always-on-top box, returns {"text": ..., "cancelled": bool}.
    Runs its own Tk loop: call it from a single dedicated thread."""
    import tkinter as tk

    previous = None
    if sys.platform == "win32":
        import ctypes
        previous = ctypes.windll.user32.GetForegroundWindow()  # the game, normally

    result = {"text": "", "cancelled": True}
    root = tk.Tk()
    root.title(title)
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.configure(bg="#101820", highlightthickness=2, highlightbackground="#00e5ff")

    tk.Label(root, text=title + "  (Entrée = envoyer, Échap = annuler)", fg="#00e5ff", bg="#101820",
             font=("Segoe UI", 11)).pack(anchor="w", padx=12, pady=(10, 4))
    entry = tk.Entry(root, width=70, font=("Segoe UI", 14), bg="#1c2a36", fg="white",
                     insertbackground="white", relief="flat")
    entry.pack(padx=12, pady=(0, 12), ipady=6)

    def submit(_=None):
        result["text"] = entry.get().strip()
        result["cancelled"] = not result["text"]
        root.destroy()

    def cancel(_=None):
        root.destroy()

    entry.bind("<Return>", submit)
    entry.bind("<KP_Enter>", submit)
    root.bind("<Escape>", cancel)
    root.after(int(timeout * 1000), cancel)

    root.update_idletasks()
    w, h = root.winfo_reqwidth(), root.winfo_reqheight()
    x = (root.winfo_screenwidth() - w) // 2
    y = int(root.winfo_screenheight() * 0.15)
    root.geometry(f"{w}x{h}+{x}+{y}")
    root.update()

    def grab_focus(tries=[0]):
        try:
            _force_foreground(int(root.wm_frame(), 16))
        except Exception:
            pass
        entry.focus_force()  # Windows keyboard focus on the entry itself, not the frame
        entry.icursor("end")
        tries[0] += 1
        if tries[0] < 3:  # Windows sometimes ignores the first attempt
            root.after(150, grab_focus)

    root.after(50, grab_focus)
    root.mainloop()

    # Free Tk in this thread (Tk objects must not be collected from another thread)
    import gc
    entry = root = submit = cancel = grab_focus = None
    gc.collect()

    _force_foreground(previous)  # give the keyboard back to the game
    return result


# ---------------------------------------------------------------------------
# Gemini
# ---------------------------------------------------------------------------

def _encode_image(path: Path, max_width: int) -> tuple:
    """(mime, base64) - downscaled JPEG when Pillow is available (smaller upload), else the PNG as is."""
    try:
        from PIL import Image
        img = Image.open(path).convert("RGB")
        if img.width > max_width:
            img = img.resize((max_width, round(img.height * max_width / img.width)))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=80)
        data, mime = buf.getvalue(), "image/jpeg"
    except ImportError:
        data, mime = path.read_bytes(), "image/png"
    return mime, base64.b64encode(data).decode("ascii")


def _load_image(paths: Paths, cfg: dict, payload: dict):
    if not payload.get("image"):
        return None
    try:
        return _encode_image(paths.capture_file(payload["image"]), int(cfg["gemini_image_max_width"]))
    except JobError as e:
        log(f"ai: image skipped ({e})")
        return None


def _parse_answer(text: str) -> dict:
    """Reads the model's JSON answer; tolerates ```json fences or text around it."""
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else ""
        t = t.rsplit("```", 1)[0]
    try:
        result = json.loads(t)
    except json.JSONDecodeError:
        start, end = t.find("{"), t.rfind("}")
        try:
            result = json.loads(t[start:end + 1]) if start >= 0 < end else None
        except json.JSONDecodeError:
            result = None
    if not isinstance(result, dict):
        result = {"recommendation": text.strip(), "speakableSummary": ""}
    tactics = result.get("suggestedTactics")
    result["suggestedTactics"] = [str(x) for x in tactics] if isinstance(tactics, list) else []
    result["recommendation"] = str(result.get("recommendation", ""))
    result["speakableSummary"] = str(result.get("speakableSummary", ""))
    return result


def _post_json(url: str, body: dict, headers: dict, timeout: float, label: str) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", **headers}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except Exception:
            detail = detail[:300]
        raise JobError(f"{label} HTTP {e.code}: {detail}")
    except urllib.error.URLError as e:
        raise JobError(f"{label} unreachable: {e.reason}")
    except TimeoutError:
        raise JobError(f"{label} timeout")


JSON_INSTRUCTION = (
    "\nRéponds UNIQUEMENT avec un objet JSON, sans texte autour, de la forme : "
    '{"recommendation": "...", "suggestedTactics": ["..."], "speakableSummary": "..."}'
)


def ask_openrouter(paths: Paths, cfg: dict, payload: dict) -> dict:
    """OpenRouter (OpenAI-compatible chat API). Works with free models and with a linked Google key."""
    key = cfg.get("openrouter_api_key")
    if not key:
        raise JobError("OPENROUTER_API_KEY not set (see README)")
    context = payload.get("context")
    if not isinstance(context, str) or not context:
        raise JobError("empty context")

    content = [{"type": "text", "text": build_user_text(payload)}]
    image = _load_image(paths, cfg, payload)
    if image:
        content.append({"type": "image_url", "image_url": {"url": f"data:{image[0]};base64,{image[1]}"}})

    messages = [{"role": "system", "content": system_prompt(cfg) + JSON_INSTRUCTION}]
    for q, a in history_pairs(payload):  # earlier questions about the same capture
        messages.append({"role": "user", "content": q})
        messages.append({"role": "assistant", "content": a})
    messages.append({"role": "user", "content": content})

    body = {
        "model": cfg["openrouter_model"],
        "messages": messages,
        "temperature": cfg["gemini_temperature"],
        # Some free models "think" before answering and the thinking counts in max_tokens:
        # a small budget can be used up before any answer is written (finish_reason "length").
        "max_tokens": int(cfg.get("openrouter_max_tokens", 4096)),
        "reasoning": {"effort": "low", "exclude": True},  # ignored by models that do not reason
        "response_format": {"type": "json_object"},
    }
    fallbacks = [m for m in cfg.get("openrouter_fallback_models") or [] if m != cfg["openrouter_model"]]
    if fallbacks:
        body["models"] = [cfg["openrouter_model"], *fallbacks]  # OpenRouter tries them in order

    def call(b: dict):
        d = _post_json(
            "https://openrouter.ai/api/v1/chat/completions", b,
            {"Authorization": f"Bearer {key}", "X-Title": "CyberAIContext"},
            cfg.get("ai_timeout", 60), "OpenRouter",
        )
        if d.get("error"):
            raise JobError(f"OpenRouter: {d['error'].get('message', d['error'])}")
        ch = (d.get("choices") or [{}])[0]
        txt = (ch.get("message") or {}).get("content") or ""
        if isinstance(txt, list):  # some providers return content parts
            txt = "".join(p.get("text", "") for p in txt if isinstance(p, dict))
        return d, ch, txt

    t0 = time.perf_counter()
    data, choice, text = call(body)
    if not text.strip():
        # Empty answer (usually a fallback model that spent its budget thinking):
        # retry once with the main model only and a bigger budget.
        first = f"{data.get('model') or '?'}: {choice.get('finish_reason') or 'empty'}"
        log(f"ai: empty answer from {first}, retrying with {cfg['openrouter_model']} only")
        retry = dict(body, max_tokens=body["max_tokens"] * 2)
        retry.pop("models", None)
        data, choice, text = call(retry)
        if not text.strip():
            raise JobError(f"OpenRouter returned no text ({first}; retry "
                           f"{data.get('model') or '?'}: {choice.get('finish_reason') or 'empty'})")

    result = _parse_answer(text)
    result["model"] = data.get("model") or cfg["openrouter_model"]
    result["ms"] = int((time.perf_counter() - t0) * 1000)
    result["tokens"] = (data.get("usage") or {}).get("total_tokens")
    return result


def ask_ai(paths: Paths, cfg: dict, payload: dict) -> dict:
    provider = cfg.get("ai_provider", "openrouter")
    if provider == "openrouter":
        return ask_openrouter(paths, cfg, payload)
    if provider == "gemini":
        return ask_gemini(paths, cfg, payload)
    raise JobError(f"unknown ai_provider {provider!r}")


def ask_gemini(paths: Paths, cfg: dict, payload: dict) -> dict:
    key = cfg.get("gemini_api_key")
    if not key:
        raise JobError("GEMINI_API_KEY not set (see README)")
    context = payload.get("context")
    if not isinstance(context, str) or not context:
        raise JobError("empty context")

    parts = [{"text": build_user_text(payload)}]
    image = _load_image(paths, cfg, payload)
    if image:
        parts.append({"inlineData": {"mimeType": image[0], "data": image[1]}})
    contents = []
    for q, a in history_pairs(payload):  # earlier questions about the same capture
        contents.append({"role": "user", "parts": [{"text": q}]})
        contents.append({"role": "model", "parts": [{"text": a}]})
    contents.append({"role": "user", "parts": parts})

    gen = {
        "temperature": cfg["gemini_temperature"],
        "maxOutputTokens": cfg["gemini_max_tokens"],
        "responseMimeType": "application/json",
        "responseSchema": RESPONSE_SCHEMA,
    }
    if cfg.get("gemini_thinking_budget") is not None:
        gen["thinkingConfig"] = {"thinkingBudget": cfg["gemini_thinking_budget"]}

    body = {
        "systemInstruction": {"parts": [{"text": system_prompt(cfg)}]},
        "contents": contents,
        "generationConfig": gen,
    }
    model = cfg["gemini_model"]
    t0 = time.perf_counter()
    data = _post_json(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent", body,
        {"x-goog-api-key": key}, cfg["gemini_timeout"], "Gemini",
    )

    cand = (data.get("candidates") or [{}])[0]
    text = "".join(p.get("text", "") for p in cand.get("content", {}).get("parts", []))
    if not text:
        reason = cand.get("finishReason") or data.get("promptFeedback", {}).get("blockReason") or "empty answer"
        raise JobError(f"Gemini returned no text ({reason})")

    result = _parse_answer(text)
    result["model"] = model
    result["ms"] = int((time.perf_counter() - t0) * 1000)
    usage = data.get("usageMetadata") or {}
    result["tokens"] = usage.get("totalTokenCount")
    return result


# ---------------------------------------------------------------------------
# Text-to-speech
# Each engine is a function(text, voice, rate, volume). Add new ones to TTS_ENGINES.
# ---------------------------------------------------------------------------

# Windows has two sets of voices:
#   - recent "OneCore" voices (Paramètres > Voix: Claude, Caroline, ...) -> WinRT API
#   - old desktop SAPI voices (David, Zira) -> System.Speech
# The script tries WinRT first, then falls back to System.Speech.
# Voice choice: a name match (CYBERAI_VOICE), else the first voice of CYBERAI_LANG (e.g. "fr").
_WINDOWS_TTS_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
$text = $env:CYBERAI_TEXT; $want = $env:CYBERAI_VOICE; $lang = $env:CYBERAI_LANG
$rate = [double]$env:CYBERAI_RATE; $vol = [double]$env:CYBERAI_VOLUME
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesisStream, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
  $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $s = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
  $all = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices
  $v = $null
  if ($want) { $v = $all | Where-Object { $_.DisplayName -like "*$want*" } | Select-Object -First 1 }
  # A named voice missing here may be a SAPI-only voice (e.g. NaturalVoiceSAPIAdapter "Microsoft Steffan Online")
  if ($want -and -not $v) { throw "voice '$want' not in WinRT, trying SAPI" }
  if (-not $v -and $lang) { $v = $all | Where-Object { $_.Language -like "$lang*" } | Select-Object -First 1 }
  if ($v) { $s.Voice = $v }
  $s.Options.SpeakingRate = [Math]::Max(0.5, [Math]::Min(6.0, $rate))
  $s.Options.AudioVolume = [Math]::Max(0.0, [Math]::Min(1.0, $vol))
  $task = $asTask.MakeGenericMethod([Windows.Media.SpeechSynthesis.SpeechSynthesisStream]).Invoke($null, @($s.SynthesizeTextToStreamAsync($text)))
  $null = $task.Wait(-1)
  $src = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($task.Result)
  $ms = New-Object System.IO.MemoryStream
  $src.CopyTo($ms); $ms.Position = 0
  (New-Object System.Media.SoundPlayer($ms)).PlaySync()
} catch {
  [Console]::Error.WriteLine("winrt failed, using System.Speech: " + $_.Exception.Message)
  Add-Type -AssemblyName System.Speech
  $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $names = $s.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo }
  $v = $null
  if ($want) { $v = $names | Where-Object { $_.Name -like "*$want*" } | Select-Object -First 1 }
  if (-not $v -and $lang) { $v = $names | Where-Object { $_.Culture.Name -like "$lang*" } | Select-Object -First 1 }
  if ($v) { $s.SelectVoice($v.Name) }
  $s.Rate = [int][Math]::Max(-10, [Math]::Min(10, ($rate - 1.0) * 10))
  $s.Volume = [int]($vol * 100)
  $s.Speak($text)
}
"""

_LIST_VOICES_SCRIPT = r"""
try {
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
  [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | ForEach-Object { $_.DisplayName + ' (' + $_.Language + ')' }
} catch {
  Add-Type -AssemblyName System.Speech
  (New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name + ' (' + $_.VoiceInfo.Culture + ')' }
}
"""

_NO_WINDOW = 0x08000000 if sys.platform == "win32" else 0


def tts_windows(text: str, voice: str, rate: float, volume: float, lang: str = "") -> None:
    if sys.platform != "win32":
        raise JobError("Windows voices only work on Windows")
    env = dict(os.environ)
    # The text goes through an environment variable: no quoting or code-page problems
    env["CYBERAI_TEXT"] = text
    env["CYBERAI_VOICE"] = voice or ""
    env["CYBERAI_LANG"] = lang or ""
    env["CYBERAI_RATE"] = str(float(rate))
    env["CYBERAI_VOLUME"] = str(float(volume))
    r = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", _WINDOWS_TTS_SCRIPT],
        env=env, capture_output=True, text=True, timeout=120, creationflags=_NO_WINDOW,
    )
    if r.stderr.strip():
        log("tts: " + r.stderr.strip().splitlines()[0][:200])
    if r.returncode != 0:
        raise JobError("voice error: " + (r.stderr.strip().splitlines() or ["?"])[-1][:200])


def tts_none(text: str, voice: str, rate: float, volume: float, lang: str = "") -> None:
    raise JobError("TTS disabled in companion_config.json")


# "sapi" kept as an alias so older companion_config.json files keep working
TTS_ENGINES = {"windows": tts_windows, "sapi": tts_windows, "none": tts_none}


def list_voices() -> list:
    r = subprocess.run(
        ["powershell", "-NoProfile", "-Command", _LIST_VOICES_SCRIPT],
        capture_output=True, text=True, creationflags=_NO_WINDOW,
    )
    return [ln for ln in r.stdout.splitlines() if ln.strip()]


# ---------------------------------------------------------------------------
# Job loop
# ---------------------------------------------------------------------------

class Companion:
    def __init__(self, paths: Paths, cfg: dict):
        self.paths = paths
        self.cfg = cfg
        self.ocr = OCR(cfg)
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="job")
        self.tts_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tts")  # one voice at a time
        # Microphone start/stop must run in order -> one thread
        self.audio_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="audio")
        # Tk text box: one at a time, in its own thread
        self.ui_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ui")
        self.recorder = Recorder(cfg)
        self.stt = SpeechToText(cfg)
        self.stop = threading.Event()

    def pool_for(self, kind: str) -> ThreadPoolExecutor:
        if kind == "tts":
            return self.tts_pool
        if kind in ("record_start", "record_stop"):
            return self.audio_pool
        if kind == "text_prompt":
            return self.ui_pool
        return self.pool

    def _ai_status(self):
        """Provider and model when its key is set, else None."""
        provider = self.cfg.get("ai_provider", "openrouter")
        if provider == "openrouter" and self.cfg.get("openrouter_api_key"):
            return f"openrouter {self.cfg['openrouter_model']}"
        if provider == "gemini" and self.cfg.get("gemini_api_key"):
            return f"gemini {self.cfg['gemini_model']}"
        return None

    def features(self) -> dict:
        try:
            import mss  # noqa: F401
            shot = True
        except ImportError:
            shot = False
        return {
            "screenshot": shot,
            "ocr": self.ocr.engine_name,
            "ai": self._ai_status(),
            "tts": self.cfg.get("tts_engine"),
            "stt": (None if not self.stt.available() or self.stt.error
                    else self.cfg["stt_model"] + (f" {self.stt.device}" if self.stt.model else " (loading)")),
            "popup": True,
        }

    def handle(self, job: dict):
        kind = job.get("type")
        payload = job.get("payload") or {}
        if kind == "screenshot":
            return take_screenshot(self.paths, self.cfg, payload.get("name", "capture"))
        if kind == "ocr":
            return self.ocr.run(self.paths.capture_file(payload.get("file", "")))
        if kind == "gemini":
            return ask_ai(self.paths, self.cfg, payload)
        if kind == "tts":
            engine = TTS_ENGINES.get(self.cfg.get("tts_engine", "sapi"))
            if engine is None:
                raise JobError(f"unknown tts_engine {self.cfg.get('tts_engine')}")
            text = str(payload.get("text", ""))[:2000]
            engine(text, payload.get("voice", ""), payload.get("rate", 1.0), payload.get("volume", 0.9),
                   self.cfg.get("tts_language", ""))
            return {"spoken": len(text)}
        if kind == "record_start":
            return self.recorder.start()
        if kind == "record_stop":
            t0 = time.perf_counter()
            audio = self.recorder.stop()
            seconds = round(len(audio) / 16000, 1)
            if seconds < 0.3:
                return {"text": "", "seconds": seconds, "ms": 0}
            text = self.stt.transcribe(audio)
            log(f"heard ({seconds} s): {text}")
            return {"text": text, "seconds": seconds, "ms": int((time.perf_counter() - t0) * 1000)}
        if kind == "text_prompt":
            return ask_text_popup(float(payload.get("timeout") or self.cfg.get("popup_timeout", 120)))
        raise JobError(f"unknown job type {kind!r}")

    def run_job(self, job: dict) -> None:
        job_id = str(job.get("id", "unknown"))
        t0 = time.perf_counter()
        try:
            result = self.handle(job)
            resp = {"id": job_id, "ok": True, "result": result}
            log(f"{job.get('type')} {job_id}: ok ({int((time.perf_counter() - t0) * 1000)} ms)")
        except JobError as e:
            resp = {"id": job_id, "ok": False, "error": str(e)}
            log(f"{job.get('type')} {job_id}: {e}")
        except Exception as e:
            resp = {"id": job_id, "ok": False, "error": f"{type(e).__name__}: {e}"}
            log(f"{job.get('type')} {job_id}: crash\n{traceback.format_exc()}")
        safe_id = "".join(c for c in job_id if c.isalnum() or c in "_-")
        write_json_atomic(self.paths.ipc / f"res_{safe_id}.json", resp)

    def heartbeat_loop(self) -> None:
        while not self.stop.is_set():
            feats = self.features()  # "stt" changes once the model has loaded
            try:
                write_json_atomic(self.paths.ipc / "heartbeat.json",
                                  {"time": int(time.time()), "version": VERSION, "pid": os.getpid(), "features": feats})
            except OSError as e:
                log(f"heartbeat write failed: {e}")
            self.stop.wait(1.0)

    def cleanup(self) -> None:
        now = time.time()
        for p in self.paths.ipc.glob("res_*.json"):
            if now - p.stat().st_mtime > 120:  # answer nobody read (mod timed out or game closed)
                p.unlink(missing_ok=True)
        for p in self.paths.ipc.glob("*.tmp"):
            if now - p.stat().st_mtime > 60:
                p.unlink(missing_ok=True)
        shots = sorted(self.paths.captures.glob("*.png"), key=lambda p: p.stat().st_mtime, reverse=True)
        for p in shots[int(self.cfg.get("captures_keep", 30)):]:
            p.unlink(missing_ok=True)

    def run(self) -> None:
        log(f"CyberAIContext companion {VERSION}")
        log(f"mod folder: {self.paths.mod}")
        if "cyber_engine_tweaks" not in str(self.paths.mod).lower():
            log("!" * 70)
            log("WARNING: this folder is NOT inside the game's CET mods folder.")
            log("The game will not see this companion (it will say 'hors ligne').")
            log(r"Run the start_companion.bat that is in <game>\bin\x64\plugins\cyber_engine_tweaks\mods\CyberAIContext\companion")
            log("!" * 70)
        for k, v in self.features().items():
            log(f"  {k}: {v if v else 'NOT AVAILABLE'}")
        self.stt.preload()  # load the speech model now, so the first voice question is fast
        threading.Thread(target=self.heartbeat_loop, daemon=True).start()

        # Old requests from a previous session are dropped
        for p in self.paths.ipc.glob("req_*.json*"):
            p.unlink(missing_ok=True)

        last_cleanup = 0.0
        log("waiting for jobs (Ctrl+C to stop)")
        try:
            while True:
                for req in sorted(self.paths.ipc.glob("req_*.json"), key=_request_order):
                    work = req.with_name(req.name + ".work")
                    try:
                        os.replace(req, work)  # claim it
                        job = json.loads(work.read_text(encoding="utf-8"))
                    except (OSError, json.JSONDecodeError) as e:
                        log(f"bad request {req.name}: {e}")
                        continue
                    finally:
                        work.unlink(missing_ok=True)
                    self.pool_for(job.get("type")).submit(self.run_job, job)
                if time.time() - last_cleanup > 30:
                    last_cleanup = time.time()
                    self.cleanup()
                time.sleep(0.05)
        except KeyboardInterrupt:
            log("stopping")
        finally:
            self.stop.set()
            (self.paths.ipc / "heartbeat.json").unlink(missing_ok=True)
            for p in (self.pool, self.tts_pool, self.audio_pool, self.ui_pool):
                p.shutdown(wait=False, cancel_futures=True)


def _request_order(path: Path):
    """req_<time>_<counter>.json in the order the mod sent them ("_10" after "_9")."""
    parts = path.stem[4:].split("_")
    try:
        return tuple(int(x) for x in parts)
    except ValueError:
        return (float("inf"),)


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description="CyberAIContext companion")
    ap.add_argument("--mod-dir", type=Path, default=script_dir.parent, help="CyberAIContext mod folder")
    ap.add_argument("--test", action="store_true", help="capture + OCR once and print the result")
    ap.add_argument("--list-voices", action="store_true", help="list Windows voices")
    ap.add_argument("--say", metavar="TEXT", help="speak a line and exit")
    ap.add_argument("--voice", default="", help="voice name for --say (part of it is enough)")
    ap.add_argument("--ask", nargs="?", const="", default=None, metavar="QUESTION",
                    help="capture + OCR + AI request once, with an optional question (tests the API key)")
    args = ap.parse_args()

    _set_dpi_aware()
    cfg = load_config(script_dir)

    if args.list_voices:
        print("\n".join(list_voices()) or "no voice found")
        return 0
    if args.say:
        TTS_ENGINES[cfg["tts_engine"]](args.say, args.voice, 1.0, 0.9, cfg.get("tts_language", ""))
        return 0

    paths = Paths(args.mod_dir.resolve())
    comp = Companion(paths, cfg)

    if args.test:
        shot = take_screenshot(paths, cfg, "selftest")
        print(json.dumps(shot, indent=2))
        ocr = comp.ocr.run(paths.capture_file(shot["file"]))
        print(f"OCR engine={ocr['engine']} lines={len(ocr['blocks'])} ms={ocr['ms']}")
        print(ocr["text"][:1500])
        return 0

    if args.ask is not None:
        shot = take_screenshot(paths, cfg, "asktest")
        try:
            ocr = comp.ocr.run(paths.capture_file(shot["file"]))
        except JobError as e:
            ocr = {"error": str(e)}
        context = json.dumps({
            "note": "test hors jeu : pas de télémétrie, capture de l'écran Windows",
            "screenshot": shot, "ocr": ocr,
        }, ensure_ascii=False)
        log(f"asking {comp._ai_status() or 'AI (no key set!)'} ...")
        try:
            answer = ask_ai(paths, cfg, {"context": context, "image": shot["file"], "question": args.ask})
        except JobError as e:
            print("ERROR:", e)
            return 1
        print(json.dumps(answer, ensure_ascii=False, indent=2))
        return 0

    comp.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
