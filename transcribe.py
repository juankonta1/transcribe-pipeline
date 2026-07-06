#!/usr/bin/env python3
"""Local diarized transcription pipeline.

Drop audio files into ~/Vibecoding/Transcripts/inbox (or pass paths directly)
and get a speaker-labeled markdown transcript in a dated folder, fully offline
via WhisperX (Whisper + pyannote diarization).

Usage:
  transcribe.py FILE [FILE...]        transcribe specific files
  transcribe.py --inbox               process everything in the inbox (used by launchd)

Options:
  --model NAME          whisper model (default from config.env)
  --lang CODE           force language (es/en/...); default auto-detect
  --no-diarize          skip speaker labels
  --min-speakers N / --max-speakers N
  --clean               post-process transcript with claude CLI (fixes Spanglish artifacts)
"""

import argparse
import datetime as dt
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent
VENV_BIN = PROJECT_DIR / ".venv" / "bin"
AUDIO_EXTS = {".m4a", ".mp3", ".wav", ".aac", ".mp4", ".mov", ".aiff", ".aif",
              ".flac", ".ogg", ".opus", ".webm", ".caf", ".amr"}


def load_config():
    cfg = {
        "BACKEND": "local",
        "DEEPGRAM_API_KEY": "",
        "DEEPGRAM_MODEL": "nova-3",
        "HF_TOKEN": "",
        "MODEL": "large-v3-turbo",
        "DIARIZE_MODEL": "pyannote/speaker-diarization-community-1",
        "LANGUAGE": "auto",
        "OUTPUT_DIR": str(Path.home() / "Vibecoding" / "Transcripts"),
        "CLEAN": "false",
    }
    cfg_file = PROJECT_DIR / "config.env"
    if cfg_file.exists():
        for line in cfg_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


CFG = load_config()
OUTPUT_DIR = Path(CFG["OUTPUT_DIR"]).expanduser()
INBOX = OUTPUT_DIR / "inbox"
FAILED = OUTPUT_DIR / "failed"
LOGS = OUTPUT_DIR / ".logs"


def log(msg):
    stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {msg}"
    print(line, flush=True)
    LOGS.mkdir(parents=True, exist_ok=True)
    with open(LOGS / "transcribe.log", "a") as f:
        f.write(line + "\n")


def notify(title, message):
    try:
        subprocess.run(
            ["osascript", "-e",
             f'display notification "{message}" with title "{title}" sound name "Glass"'],
            capture_output=True, timeout=10,
        )
    except Exception:
        pass


def wait_until_stable(path, checks=3, interval=2):
    """Wait until file size stops changing (file may still be copying in)."""
    import time
    last = -1
    stable = 0
    while stable < checks:
        size = path.stat().st_size
        if size == last and size > 0:
            stable += 1
        else:
            stable = 0
        last = size
        time.sleep(interval)


def hms(seconds):
    s = int(seconds)
    h, m, sec = s // 3600, (s % 3600) // 60, s % 60
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


def audio_duration(path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        return float(out.stdout.strip())
    except Exception:
        return 0.0


def run_whisperx(audio, tmpdir, model, lang, diarize, min_spk, max_spk):
    cmd = [
        str(VENV_BIN / "whisperx"), str(audio),
        "--model", model,
        "--device", "cpu",
        "--compute_type", "int8",
        "--output_dir", str(tmpdir),
        "--output_format", "json",
    ]
    if lang and lang != "auto":
        cmd += ["--language", lang]
    if diarize:
        cmd += ["--diarize", "--diarize_model", CFG["DIARIZE_MODEL"],
                "--hf_token", CFG["HF_TOKEN"]]
        if min_spk:
            cmd += ["--min_speakers", str(min_spk)]
        if max_spk:
            cmd += ["--max_speakers", str(max_spk)]

    env = os.environ.copy()
    env["PATH"] = f"/opt/homebrew/bin:{env.get('PATH', '')}"
    if CFG["HF_TOKEN"]:
        env["HF_TOKEN"] = CFG["HF_TOKEN"]

    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        tail = "\n".join(proc.stderr.splitlines()[-15:])
        raise RuntimeError(f"whisperx failed (exit {proc.returncode}):\n{tail}")

    jsons = list(Path(tmpdir).glob("*.json"))
    if not jsons:
        raise RuntimeError("whisperx produced no JSON output")
    return json.loads(jsons[0].read_text())


MIME_TYPES = {
    ".m4a": "audio/mp4", ".mp4": "audio/mp4", ".mp3": "audio/mpeg",
    ".wav": "audio/wav", ".flac": "audio/flac", ".ogg": "audio/ogg",
    ".opus": "audio/ogg", ".webm": "audio/webm", ".aiff": "audio/aiff",
    ".aif": "audio/aiff", ".aac": "audio/aac", ".amr": "audio/amr",
    ".caf": "audio/x-caf", ".mov": "video/quicktime",
}


def load_meta(audio):
    """Optional sidecar written by the CallDrop app: <stem>.meta.json with
    {"context": "...", "channels": "split"|"mixed", "title": "..."}.
    channels=split means ch0 = user's mic, ch1 = other participants."""
    sidecar = audio.parent / (audio.stem + ".meta.json")
    if sidecar.exists():
        try:
            return json.loads(sidecar.read_text()), sidecar
        except Exception as e:
            log(f"  bad sidecar {sidecar.name}: {e}")
    return {}, None


def compress_for_upload(audio, tmpdir, split=False):
    """Opus re-encode — ~6x smaller upload so slow uplinks don't hit Deepgram's
    request timeout. Mono 24k normally; stereo 32k when channels carry speakers."""
    out = Path(tmpdir) / (audio.stem + ".ogg")
    env = os.environ.copy()
    env["PATH"] = f"/opt/homebrew/bin:{env.get('PATH', '')}"
    ch = ["-ac", "2", "-b:a", "32k"] if split else ["-ac", "1", "-b:a", "24k"]
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", str(audio),
         "-c:a", "libopus", *ch, str(out)],
        check=True, capture_output=True, env=env, timeout=300,
    )
    return out


def run_deepgram(audio, lang, split=False):
    params = {
        "model": CFG["DEEPGRAM_MODEL"],
        "language": "multi" if not lang or lang == "auto" else lang,
        "smart_format": "true",
        "utterances": "true",
    }
    if split:
        params["multichannel"] = "true"  # ch0=You, ch1=Them: exact attribution
    else:
        params["diarize"] = "true"
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    with tempfile.TemporaryDirectory() as tmpdir:
        upload = audio
        if audio.stat().st_size > 8 * 1024 * 1024:
            upload = compress_for_upload(audio, tmpdir, split)
            log(f"  compressed for upload: {audio.stat().st_size // 2**20}MB -> "
                f"{max(1, upload.stat().st_size // 2**20)}MB")
        body = upload.read_bytes()
        mime = MIME_TYPES.get(upload.suffix.lower(), "application/octet-stream")

        data = None
        for attempt in (1, 2):
            req = urllib.request.Request(
                f"https://api.deepgram.com/v1/listen?{qs}",
                data=body,
                headers={"Authorization": f"Token {CFG['DEEPGRAM_API_KEY']}",
                         "Content-Type": mime},
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=600) as resp:
                    data = json.loads(resp.read().decode())
                break
            except Exception as e:
                if attempt == 2:
                    raise
                log(f"  Deepgram attempt 1 failed ({e}); retrying")

    utts = data.get("results", {}).get("utterances", [])
    if not utts:
        raise RuntimeError("Deepgram returned no utterances")
    if split:
        segments = [
            {"start": u.get("start", 0), "end": u.get("end", 0),
             "text": u.get("transcript", ""),
             "speaker": "You" if u.get("channel", 0) == 0 else "Them"}
            for u in utts
        ]
        segments.sort(key=lambda s: s["start"])
    else:
        segments = [
            {"start": u.get("start", 0), "end": u.get("end", 0),
             "text": u.get("transcript", ""), "speaker": f"SPEAKER_{u.get('speaker', 0):02d}"}
            for u in utts
        ]
    channel = data["results"].get("channels", [{}])[0]
    language = channel.get("detected_language") or params["language"]
    return {"segments": segments, "language": language}


def to_markdown(result, title, rec_date, duration, model, diarized, context=""):
    lang = result.get("language", "?")
    lines = [
        f"# {title}",
        "",
        f"- **Date:** {rec_date.strftime('%Y-%m-%d %H:%M')}",
        f"- **Duration:** {hms(duration)}",
        f"- **Detected language:** {lang}",
        f"- **Model:** {model}"
        + ("" if diarized else " — no speaker labels"),
        "",
    ]
    if context:
        lines += ["## Context", "", context.strip(), ""]
    lines += ["---", ""]

    speaker_names = {}

    def name_for(raw):
        if raw is None:
            return "Speaker ?"
        if not str(raw).startswith("SPEAKER_"):
            return str(raw)  # already a friendly label (You/Them)
        if raw not in speaker_names:
            speaker_names[raw] = f"Speaker {len(speaker_names) + 1}"
        return speaker_names[raw]

    # merge consecutive same-speaker segments into turns (only when diarized,
    # otherwise every segment merges into one unreadable block)
    turns = []
    for seg in result.get("segments", []):
        text = seg.get("text", "").strip()
        if not text:
            continue
        spk = seg.get("speaker")
        if diarized and turns and turns[-1]["spk"] == spk:
            turns[-1]["text"] += " " + text
        else:
            turns.append({"spk": spk, "start": seg.get("start", 0), "text": text})

    for t in turns:
        if diarized:
            lines.append(f"**{name_for(t['spk'])}** [{hms(t['start'])}]: {t['text']}")
        else:
            lines.append(f"[{hms(t['start'])}] {t['text']}")
        lines.append("")

    return "\n".join(lines)


def clean_with_claude(md_path, clean_path, context=""):
    claude = shutil.which("claude") or str(Path.home() / ".local/bin/claude")
    if not Path(claude).exists():
        log("claude CLI not found; skipping cleanup pass")
        return False
    ctx = (f"Call context provided by the user: {context.strip()}\n"
           "Use it to correct names, companies, and topic-specific terms.\n\n") if context else ""
    prompt = (
        "Below is an auto-generated meeting transcript. The audio mixed Spanish and "
        "English (Spanglish), so some code-switched words were transcribed phonetically "
        "or in the wrong language. Fix obvious transcription errors using context, keep "
        "ALL speaker labels and timestamps exactly as they are, do not summarize, do not "
        "omit anything. Output ONLY the corrected markdown transcript, nothing else.\n\n"
        + ctx + md_path.read_text()
    )
    try:
        proc = subprocess.run([claude, "-p", prompt], capture_output=True,
                              text=True, timeout=900)
        if proc.returncode == 0 and proc.stdout.strip():
            clean_path.write_text(proc.stdout)
            return True
        log(f"claude cleanup failed: {proc.stderr[:300]}")
    except Exception as e:
        log(f"claude cleanup error: {e}")
    return False


def unique_dir(base):
    d = base
    i = 2
    while d.exists():
        d = base.parent / f"{base.name} ({i})"
        i += 1
    return d


def process_file(audio, args):
    audio = audio.resolve()
    t0 = time.time()
    log(f"processing: {audio.name}")
    wait_until_stable(audio)

    meta, sidecar = load_meta(audio)
    title = meta.get("title") or audio.stem
    context = meta.get("context", "")
    split = meta.get("channels") == "split"
    if meta:
        log(f"  meta: split={split} context={'yes' if context else 'no'}")

    lang = args.lang or CFG["LANGUAGE"]
    duration = audio_duration(audio)
    rec_date = dt.datetime.fromtimestamp(audio.stat().st_mtime)

    result = None
    if CFG["BACKEND"].lower() == "deepgram" and CFG["DEEPGRAM_API_KEY"] and not args.local:
        log(f"  backend=deepgram model={CFG['DEEPGRAM_MODEL']} lang={lang} duration={hms(duration)}")
        try:
            result = run_deepgram(audio, lang, split)
            diarize = not args.no_diarize
            model_desc = f"{CFG['DEEPGRAM_MODEL']} (Deepgram API)"
        except Exception as e:
            log(f"  Deepgram failed ({e}) — falling back to local WhisperX")

    if result is None:
        diarize = not args.no_diarize and bool(CFG["HF_TOKEN"])
        if not args.no_diarize and not CFG["HF_TOKEN"]:
            log("HF_TOKEN not set in config.env — transcribing WITHOUT speaker labels")
        model = args.model or CFG["MODEL"]
        model_desc = f"{model} (local WhisperX)"
        log(f"  backend=local model={model} lang={lang} diarize={diarize} duration={hms(duration)}")
        with tempfile.TemporaryDirectory() as tmpdir:
            result = run_whisperx(audio, tmpdir, model, lang, diarize,
                                  args.min_speakers, args.max_speakers)

    dest = unique_dir(OUTPUT_DIR / f"{rec_date.strftime('%Y-%m-%d')} - {title}")
    dest.mkdir(parents=True)
    md = to_markdown(result, title, rec_date, duration, model_desc, diarize, context)
    (dest / "transcript.md").write_text(md)
    (dest / "transcript.raw.json").write_text(json.dumps(result, ensure_ascii=False, indent=1))
    shutil.move(str(audio), dest / audio.name)
    if sidecar and sidecar.exists():
        shutil.move(str(sidecar), dest / sidecar.name)

    if args.clean or CFG["CLEAN"].lower() == "true":
        if clean_with_claude(dest / "transcript.md", dest / "transcript_clean.md", context):
            log("  claude cleanup pass done")

    log(f"  done in {int(time.time() - t0)}s -> {dest}")
    notify("Transcript ready", f"{title} ({hms(duration)})"
           + ("" if diarize else " — no speakers, HF token missing"))
    return dest


def inbox_files():
    if not INBOX.exists():
        return []
    return sorted(
        p for p in INBOX.iterdir()
        if p.is_file() and not p.name.startswith(".") and p.suffix.lower() in AUDIO_EXTS
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--inbox", action="store_true", help="process inbox folder")
    ap.add_argument("--model")
    ap.add_argument("--lang")
    ap.add_argument("--no-diarize", action="store_true")
    ap.add_argument("--local", action="store_true", help="force local WhisperX backend")
    ap.add_argument("--min-speakers", type=int)
    ap.add_argument("--max-speakers", type=int)
    ap.add_argument("--clean", action="store_true")
    args = ap.parse_args()

    INBOX.mkdir(parents=True, exist_ok=True)

    if args.inbox:
        LOGS.mkdir(parents=True, exist_ok=True)
        lock = open(LOGS / "inbox.lock", "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return  # another run is already draining the inbox
        while True:
            batch = inbox_files()
            if not batch:
                break
            for f in batch:
                try:
                    process_file(f, args)
                except Exception as e:
                    log(f"FAILED {f.name}: {e}")
                    notify("Transcription failed", f.name)
                    FAILED.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(f), FAILED / f.name)
                    stray = f.parent / (f.stem + ".meta.json")
                    if stray.exists():
                        shutil.move(str(stray), FAILED / stray.name)
    elif args.files:
        for f in args.files:
            if not f.exists():
                log(f"not found: {f}")
                continue
            process_file(f, args)
    else:
        ap.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
