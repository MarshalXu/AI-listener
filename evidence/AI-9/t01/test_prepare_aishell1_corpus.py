import math
import pathlib
import struct
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from prepare_aishell1_corpus import mix_at_snr, read_genders


class PrepareAISHELL1CorpusTests(unittest.TestCase):
    def test_noise_derivative_is_deterministic_and_distinct(self):
        samples = [round(8000 * math.sin(2 * math.pi * 440 * i / 16_000)) for i in range(16_000)]
        clean = struct.pack("<16000h", *samples)
        first = mix_at_snr(clean, 7)
        self.assertEqual(first, mix_at_snr(clean, 7))
        self.assertNotEqual(first, clean)
        self.assertEqual(len(first), len(clean))

    def test_parses_tabular_speaker_gender_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "speaker.info").write_text("S0001 F north\nS0002 male south\n", encoding="utf-8")
            self.assertEqual(read_genders(root), {"S0001": "female", "S0002": "male"})


if __name__ == "__main__":
    unittest.main()
