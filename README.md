# transcribe-pipeline

Free, local, diarized transcription for call recordings on macOS (Apple Silicon).
Built around [WhisperX](https://github.com/m-bain/whisperX): Whisper large-v3 for
transcription (best free model for Spanish/English/Spanglish code-switching) +
pyannote for speaker labels. Everything runs on-device — recordings never leave the Mac.

## Daily workflow

1. Record the call on iPhone (Voice Memos), AirDrop to the Mac.
2. Drop the file into `~/Vibecoding/Transcripts/inbox/`.
3. Wait for the macOS notification ("Transcript ready").
4. Open the dated folder in `~/Vibecoding/Transcripts/` — it contains the original
   audio, `transcript.md` (speaker-labeled, timestamped), and the raw JSON.
5. Point Claude at the transcript.

The inbox is watched by a launchd agent (`com.juan.transcribe-inbox`), so step 3
happens automatically. Files that fail land in `Transcripts/failed/`.

## Manual usage

```bash
transcribe call.m4a                 # transcribe one file
transcribe call.m4a --lang es       # force Spanish (default: auto-detect)
transcribe call.m4a --model large-v3  # higher accuracy, ~2-3x slower
transcribe call.m4a --max-speakers 2  # help diarization on 1:1 calls
transcribe call.m4a --clean         # + Claude cleanup pass for Spanglish artifacts
transcribe --inbox                  # drain the inbox manually
```

## Setup notes

- Config lives in `config.env` (HF token, default model, output dir).
- Speaker diarization needs a free Hugging Face token in `config.env`
  (`HF_TOKEN=hf_...`) after accepting terms at
  [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
  (pyannote.audio 4.x needs this repo even when using the older 3.1 pipeline).
  Without a token the pipeline still works, just without speaker labels.
- Python env: `.venv/` (created with `uv venv --python 3.12` + `uv pip install whisperx`).
- Watcher: `~/Library/LaunchAgents/com.juan.transcribe-inbox.plist`
  (reload with `launchctl unload/load` after edits).
- Logs: `~/Vibecoding/Transcripts/.logs/transcribe.log`
