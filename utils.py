import logging
import numpy as np
from pydub import AudioSegment

logger = logging.getLogger(__name__)

def generate_waveform(file_path: str, num_samples: int = 60) -> list:
    """Generate waveform data from an audio file."""
    try:
        audio = AudioSegment.from_file(file_path, format="wav")
        audio = audio.set_channels(1).set_frame_rate(16000)
        samples = np.array(audio.get_array_of_samples())
        samples = samples.astype(np.float32) / np.max(np.abs(samples), initial=1)
        step = max(1, len(samples) // num_samples)
        waveform = [float(np.max(np.abs(samples[i:i + step]))) for i in range(0, len(samples), step)]
        waveform = waveform[:num_samples] + [0.0] * (num_samples - len(waveform))
        logger.info(f"Generated waveform with {len(waveform)} samples")
        return waveform
    except Exception as e:
        logger.error(f"Failed to generate waveform for {file_path}: {e}")
        return []

def convert_oga_to_wav(oga_path: str, wav_path: str, reverse: bool = False) -> None:
    """Convert between OGG and WAV formats."""
    try:
        audio = AudioSegment.from_file(oga_path, format="ogg" if not reverse else "wav")
        audio = audio.set_channels(1).set_sample_width(2).set_frame_rate(16000)
        audio.export(wav_path, format="wav" if not reverse else "ogg", codec="libopus" if reverse else None, bitrate="32k" if reverse else None)
        logger.info(f"Converted {oga_path} to {wav_path}")
    except Exception as e:
        logger.error(f"Failed to convert {oga_path} to {'WAV' if not reverse else 'OGG'}: {e}")
        raise