"""Create a fixed, local-only synthetic 16 kHz mono PCM diagnostic input."""

import subprocess
import tempfile
import wave
from pathlib import Path

SYNTHETIC_PHRASE = "Yesterday I went to the park. What do you like to do outdoors?"


def make_synthetic_pcm(*, parent=None):
    try:
        with tempfile.TemporaryDirectory(prefix="simontalk-speech-", dir=parent) as folder:
            source = Path(folder) / "speech.aiff"
            output = Path(folder) / "speech.wav"
            subprocess.run(
                ["/usr/bin/say", "-v", "Samantha", "-o", str(source), SYNTHETIC_PHRASE],
                check=True,
                capture_output=True,
                timeout=20,
            )
            subprocess.run(
                [
                    "/usr/bin/afconvert",
                    "-f",
                    "WAVE",
                    "-d",
                    "LEI16@16000",
                    "-c",
                    "1",
                    str(source),
                    str(output),
                ],
                check=True,
                capture_output=True,
                timeout=20,
            )
            with wave.open(str(output), "rb") as wav:
                if (
                    wav.getnchannels() != 1
                    or wav.getsampwidth() != 2
                    or wav.getframerate() != 16000
                    or not 0 < wav.getnframes() <= 128_000
                    or wav.getcomptype() != "NONE"
                ):
                    raise ValueError("Invalid synthetic audio")
                audio = wav.readframes(wav.getnframes())
            if len(audio) % 2 or not audio:
                raise ValueError("Invalid synthetic audio")
            return audio + b"\0" * 64_000
    except (OSError, subprocess.SubprocessError, wave.Error):
        pass
    raise ValueError("Synthetic audio generation failed") from None
