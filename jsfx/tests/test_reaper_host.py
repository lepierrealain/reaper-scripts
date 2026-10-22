"""Offline integration check in an isolated REAPER batch-converter instance.

Usage (Windows): python test_reaper_host.py --reaper 'path/to/reaper.exe'
Creates temporary Effects/config/audio files; never opens a user project.
The test generator and verifier surround the unmodified quantizer in REAPER.
The rendered WAV must report success through its audio samples.
"""

import argparse
from array import array
from pathlib import Path
import shutil
import subprocess
import tempfile
import wave


SOURCE = Path(__file__).resolve().parents[1] / "PA_MIDI Smart Quantizer.jsfx"

GENERATOR = """desc:Smart Quantizer test generator
@init
ext_noinit=1;
@block
test_block==0 ? (
  midisend(1,$x90,60,100);
) : test_block==1 ? (
  midisend(4,$x90,62,90);
  midisend(8,$x80,62,20);
) : test_block==2 ? (
  midisend(3,$x90,57,95);
  midisend(7,$x80,57,21);
) : test_block==3 ? (
  midisend(2,$x90,62,96);
  midisend(6,$x80,62,22);
) : test_block==4 ? (
  midisend(1,$x90,57,97);
  midisend(5,$x80,57,23);
) : test_block==5 ? (
  midisend(2,$x80,60,24);
  midisend(4,$x90,57,104);
  midisend(8,$x80,57,30);
) : test_block==6 ? (
  midisend(1,$x90,62,98);
  midisend(3,$x90,64,99);
  midisend(5,$x80,62,25);
  midisend(9,$x90,65,100);
) : test_block==7 ? (
  midisend(1,$x80,64,26);
  midisend(3,$x80,65,27);
) : test_block==8 ? (
  midisend(1,$x90,62,101);
  midisend(5,$xB0,123,0);
) : test_block==9 ? (
  midisend(2,$x90,62,102);
  midisend(10,$x80,62,28);
) : test_block==10 ? (
  midisend(1,$x90,62,103);
  midisend(3,$xB0,64,111);
  midisend(9,$x80,62,29);
) : test_block==11 ? (
  midisend(13,$xB0,64,41);
);
test_block+=1;
"""

VERIFIER = """desc:Smart Quantizer test verifier
@init
ext_noinit=1;
// offset, status, pitch, velocity for all expected events, in order.
mem_set_values(0,1,$x90,60,100,
                 4,$x80,60,0, 4,$x90,62,90, 8,$x80,62,20,
                 3,$x90,@@A_PITCH@@,95, 7,$x80,@@A_PITCH@@,21,
                 2,$x90,@@D_RETURN@@,96, 6,$x80,@@D_RETURN@@,22,
                 1,$x90,55,97, 5,$x80,55,23,
                 4,$x90,@@A_PITCH@@,104, 8,$x80,@@A_PITCH@@,30,
                 1,$x90,62,98, 3,$x80,62,0, 3,$x90,64,99,
                 9,$x80,64,0, 9,$x90,67,100, 3,$x80,67,27,
                 1,$x90,62,101, 5,$x80,62,0, 5,$xB0,64,0,
                 2,$x90,62,102, 10,$x80,62,28,
                 @@SUSTAIN_EVENTS@@);
@block
while(midirecv(at,status,note,vel)) (
  (status&$xF0)==$x90 || (status&$xF0)==$x80 || ((status&$xF0)==$xB0 && note==64) ? (
    p=events*4;
    at!=p[0] || status!=p[1] || note!=p[2] || vel!=p[3] ? error=1;
    events+=1;
  );
);
@sample
spl0=spl1=error ? -0.5 : events==@@EVENT_COUNT@@ ? 0.5 : 0.25;
"""


def quote_ps(value):
    return "'" + str(value).replace("'", "''") + "'"


def run_case(reaper, capture, last_note):
    with tempfile.TemporaryDirectory(prefix="pa-smart-quantizer-reaper-") as directory:
        root = Path(directory)
        effects = root / "Effects"
        effects.mkdir()
        shutil.copyfile(SOURCE, effects / SOURCE.name)
        (effects / "generator.jsfx").write_text(GENERATOR, encoding="utf-8")
        sustain_events = "1,$x90,62,103, 13,$x80,62,29" if capture else (
            "1,$x90,62,103, 3,$xB0,64,111, 9,$x80,62,29, 13,$xB0,64,41"
        )
        verifier = (VERIFIER.replace("@@SUSTAIN_EVENTS@@", sustain_events)
                    .replace("@@EVENT_COUNT@@", "25" if capture else "27")
                    .replace("@@A_PITCH@@", "55" if last_note else "57")
                    .replace("@@D_RETURN@@", "62" if last_note else "60"))
        (effects / "verifier.jsfx").write_text(verifier, encoding="utf-8")
        config = root / "reaper.ini"
        no_plugins = root / "NoPlugins"
        no_plugins.mkdir()
        config.write_text(
            f"[REAPER]\nportable=1\nvstpath64={no_plugins}\nvstpath={no_plugins}\n"
            f"clappath={no_plugins}\nclappath64={no_plugins}\nlv2path_win64={no_plugins}\n"
            "vst_scan=0\nusedxplugs=0\ndisabledxscan=1\nloadlastproj=0\n",
            encoding="utf-8",
        )
        license_file = reaper.resolve().parent / "reaper-license.rk"
        if license_file.exists():
            shutil.copyfile(license_file, root / license_file.name)
        # REAPER also scans system VST3 locations on a fresh resource path.
        # Reuse read-only scan caches to avoid starting unrelated plug-ins.
        for cache in reaper.resolve().parent.glob("reaper-*plugins*.ini"):
            shutil.copyfile(cache, root / cache.name)
        input_wav, output_wav = root / "input.wav", root / "output.wav"
        with wave.open(str(input_wav), "wb") as audio:
            audio.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            audio.writeframes(bytes(48000 * 2 * 2))
        chain = root / "test.RfxChain"
        chain.write_text(f'''BYPASS 0 0 0
<JS "generator.jsfx" 0
>
BYPASS 0 0 0
<JS "PA_MIDI Smart Quantizer.jsfx" 0
1 1 0 661 0 0 0 0 1 2 3 4 5 6 7 8 9 10 11 {int(capture)} {int(last_note)}
>
BYPASS 0 0 0
<JS "verifier.jsfx" 0
>
''', encoding="utf-8")
        batch = root / "batch.txt"
        batch.write_text(f'''{input_wav}\t{output_wav}
<CONFIG
  SRATE 48000
  NCH 2
  FXCHAIN '{chain}'
  FX_NCH 2
  CPULIMIT 1
>
''', encoding="utf-8")
        launch = root / "launch.ps1"
        # Start a separate, hidden process with its own resource directory.
        arg_line = f'-newinst -nosplash -noactivate -ignoreerrors -splashlog "{root / "startup.log"}" -cfgfile "{config}" -batchconvert "{batch}"'
        launch.write_text(
            f"$taskProcess = Start-Process -FilePath {quote_ps(reaper.resolve())} "
            f"-ArgumentList {quote_ps(arg_line)} -WindowStyle Hidden -PassThru\n"
            "if (-not $taskProcess.WaitForExit(45000)) {\n"
            "  & taskkill /PID $taskProcess.Id /T /F | Out-Null\n"
            "  throw 'Isolated REAPER batch conversion timed out'\n"
            "}\n"
            "exit $taskProcess.ExitCode\n",
            encoding="utf-8-sig",
        )
        result = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(launch)], capture_output=True, text=True, timeout=55)
        if result.returncode or not output_wav.exists():
            logs = "\n".join(f"{p.name}: {p.read_text(errors='replace')[-1800:]}" for p in root.glob("*.log"))
            raise SystemExit(f"REAPER batch conversion failed: {result.stdout}{result.stderr}\n{logs}")
        with wave.open(str(output_wav), "rb") as audio:
            width = audio.getsampwidth()
            samples = audio.readframes(audio.getnframes())
        if width not in (2, 3):
            raise SystemExit(f"Expected 16/24-bit PCM WAV, got {width * 8}-bit")
        values = array("h", samples) if width == 2 else [
            int.from_bytes(samples[i:i + 3], "little", signed=True) for i in range(0, len(samples), 3)
        ]
        threshold = int(0.49 * (1 << (width * 8 - 1)))
        if not values or min(values) < 0 or max(values) < threshold or min(values[-2000:]) < threshold:
            raise SystemExit(f"REAPER verifier did not pass: min={min(values, default=0)}, max={max(values, default=0)}")
        print(f"PASS REAPER host / {'Last note' if last_note else 'Base'} / sustain {'Capture' if capture else 'Thru'}: base Note Off before relative Note On, relative chain, memory after release, late base off, offsets/velocities, CC123 restart, CC64 policy")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reaper", required=True, type=Path)
    args = parser.parse_args()
    for last_note in (False, True):
        for capture in (False, True):
            run_case(args.reaper, capture, last_note)


if __name__ == "__main__":
    main()
