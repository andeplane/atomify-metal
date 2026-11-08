#!/usr/bin/env python3
"""Ports the iOS gallery of Atomify 2 (the Qt app on the App Store) into an
examples.json catalog that AtomifyKit reads.

Usage: port_atomify2_examples.py ATOMIFY_CHECKOUT [OUTPUT_DIR]

ATOMIFY_CHECKOUT is a checkout of https://github.com/ovilab/atomify at the
branch the App Store build came from (mobile_5.6, commit 7828e89). OUTPUT_DIR
defaults to src/ios/Examples next to this script.

What is copied, and how:
- Sections and their order: `simulationsModel` in src/qml/mobile/MainMobile.qml.
- Each simulation folder (src/simulations/<group>/<id>): every file except the
  .qml metadata, unchanged, except that scripts refer to the shared potentials
  in ../../potentialparameters by file name (the app copies an example's files
  into one folder). The thumbnail is <id>.png.
- From <id>.qml: name (with spelling fixes) and description (HTML turned into Markdown), the
  initial camera (position, view center, up vector; Atomify 2 drew the box
  centered on the origin and used a 25 degree field of view, which spans the
  shorter side of the view since the app was landscape only; see
  CAMERA_FIXES for the cameras moved), periodic images
  and the dashboard controllers with their settings. The granular
  examples' custom color shaders become color ramps (see COLOR_SHADERS);
  any other shader is listed under "notPorted".
- LAMMPS has changed since 2017, so a few style names are updated (the
  physics is the same): `reax/c` is now `reaxff`, and the OPT package's
  `lj/cut/opt` is plain `lj/cut` (this build has no OPT package). Each change
  is listed in the example's "atomifyMetal.changes".
- Files that current LAMMPS cannot read are replaced by the copies in
  atomify2-replacements/<group>/<id> (see REPLACEMENTS), and listed in
  "changes" too.
- Speed: Atomify 2 ran one timestep per frame (simulationSpeed: 1 in
  MainMobile.qml) until a script's `#/speed N` line changed it.
"""

import html
import json
import pathlib
import re
import shutil
import sys

SUBSCRIPT = str.maketrans("0123456789+-", "₀₁₂₃₄₅₆₇₈₉₊₋")
SUPERSCRIPT = str.maketrans("0123456789+-", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻")
FIELD_OF_VIEW = 25.0    # SimVis CameraLens default
STEPS_PER_FRAME = 1     # AtomifySimulator.simulationSpeed in MainMobile.qml
POTENTIALS = "../../potentialparameters/"
# Style names LAMMPS has renamed since 2017, and the OPT package this build lacks.
COMPATIBILITY = [
    (r"^(\s*pair_style\s+)reax/c\b", r"\1reaxff", "pair_style reax/c is now reaxff"),
    (r"^(\s*fix\s+\S+\s+\S+\s+qeq/reax\b.*\s)reax/c(\s*)$", r"\1reaxff\2", "qeq/reax reads its parameters from reaxff"),
    (r"^(\s*pair_style\s+[\w/]+?)/opt\b", r"\1", "OPT package style replaced by the plain one"),
]
# Lines added to single scripts, keyed by their path: (pattern, replacement, note).
SCRIPT_FIXES = {
    "granular/maxwell/maxwell.in": [(
        r"^(thermo_style custom step v_atomify_left v_atomify_right)$",
        "# Atomify 2's counter panel defined these; the script needs them on its own.\n"
        "variable atomify_left equal count(left)/atoms\n"
        "variable atomify_right equal count(right)/atoms\n\\1",
        "defines v_atomify_left and v_atomify_right, which Atomify 2's counter panel added",
    )],
}
# Files regenerated with current LAMMPS, from atomify2-replacements next to this script.
REPLACEMENTS = {
    "granular/patterns_final/patterns_final.bin":
        "restart file regenerated with current LAMMPS by running granular/patterns to its end "
        "(the 2017 binary restart format is no longer readable)",
}
# Starting cameras moved back so the whole system stays in view (Atomify 2
# showed only part of it), with the reason.
CAMERA_FIXES = {
    "singlewater": ([0.0, 0.0, 6.0], "camera moved back from 2.65 to 6 Å so the rotating molecule stays in view"),
}
# Atomify 2's custom color shaders (GLSL run per atom), as AtomifyKit color
# ramps: the type color times factors blended from low to high between two
# coordinates (relative to the box center) along an axis.
COLOR_SHADERS = {
    "highp float zScaled = 0.2 + 0.8* (position.z + 7.5) / 5.0; zScaled = clamp(zScaled, 0.0, 1.0); "
    "customColor *= zScaled;":
        {"axis": 2, "from": -7.5, "to": -2.5, "low": [0.2, 0.2, 0.2], "high": [1.0, 1.0, 1.0]},
    "highp float yPosScaled = (position.y + 8.0) / 16.0; customColor.r *= yPosScaled; "
    "customColor.b *= (1.0 - yPosScaled); customColor.g *= 0.3;":
        {"axis": 1, "from": -8.0, "to": 8.0, "low": [0.0, 0.3, 1.0], "high": [1.0, 0.3, 0.0]},
}
# Spelling mistakes in the original titles.
TITLE_FIXES = {"Hydrocarbon oxcidation": "Hydrocarbon oxidation"}


def html_to_markdown(text: str) -> str:
    text = re.sub(r"<sub>(.*?)</sub>", lambda m: m.group(1).translate(SUBSCRIPT), text, flags=re.S)
    text = re.sub(r"<sup>(.*?)</sup>", lambda m: m.group(1).translate(SUPERSCRIPT), text, flags=re.S)
    text = re.sub(r"</?b>", "**", text)
    text = re.sub(r"</?i>", "*", text)
    text = re.sub(r"<br\s*/?>", "\n", text)
    paragraphs = re.split(r"</?p>", text)
    cleaned = []
    for paragraph in paragraphs:
        paragraph = re.sub(r"<[^>]+>", "", paragraph)
        paragraph = html.unescape(paragraph)
        paragraph = re.sub(r"[ \t]*\n[ \t]*", " ", paragraph.strip())
        paragraph = re.sub(r"[ \t]+", " ", paragraph)
        if paragraph:
            cleaned.append(paragraph)
    return "\n\n".join(cleaned)


def qml_strings(source: str, key: str):
    """The value of `key: "..." + "..."` (QML string literals joined by +)."""
    match = re.search(rf"^\s*{key}\s*:", source, flags=re.M)
    if not match:
        return None
    index = match.end()
    parts = []
    while True:
        while index < len(source) and source[index] in " \t\r\n":
            index += 1
        if index >= len(source) or source[index] != '"':
            break
        index += 1
        value = []
        while source[index] != '"':
            if source[index] == "\\":
                index += 1
                value.append({"n": "\n", "t": "\t"}.get(source[index], source[index]))
            else:
                value.append(source[index])
            index += 1
        index += 1
        parts.append("".join(value))
        rest = source[index:]
        plus = re.match(r"\s*\+", rest)
        if not plus:
            break
        index += plus.end()
    return "".join(parts)


def qml_vector(source: str, key: str):
    match = re.search(rf"\b{key}\s*:\s*Qt\.vector3d\(([^)]*)\)", source)
    if not match:
        return None
    return [float(v) for v in match.group(1).split(",")]


def qml_controllers(source: str):
    match = re.search(r"\bcontrollers\s*:\s*\[", source)
    if not match:
        return []
    depth, index, start = 1, match.end(), match.end()
    while depth:
        depth += {"[": 1, "]": -1}.get(source[index], 0)
        index += 1
    body = source[start:index - 1]
    body = "\n".join(line for line in body.splitlines() if not line.strip().startswith("//"))
    panels = []
    position = 0
    while True:
        item = re.compile(r"([A-Z]\w*)\s*\{").search(body, position)
        if not item:
            break
        depth, cursor = 1, item.end()
        while depth:
            depth += {"{": 1, "}": -1}.get(body[cursor], 0)
            cursor += 1
        inner = body[item.end():cursor - 1]
        parameters = {}
        for line in inner.splitlines():
            line = line.split("//")[0].strip()
            pair = re.match(r"(\w+)\s*:\s*(.+)$", line)
            if pair and pair.group(1) not in ("id", "system"):
                parameters[pair.group(1)] = pair.group(2).strip().strip('"')
        name = item.group(1)
        panel = {"kind": name[0].lower() + name[1:]}
        if parameters:
            panel["parameters"] = parameters
        panels.append(panel)
        position = cursor
    return panels


def sections_from(main_qml: str):
    model = main_qml[main_qml.index("simulationsModel"):]
    model = model[:model.index("\n    ]")]
    sections = []
    for name, block in re.findall(r'name:\s*"([^"]+)",\s*simulations:\s*\[(.*?)\]', model, flags=re.S):
        folders = [f for f in re.findall(r'^\s*"qrc:/simulations/([^"]+)"', block, flags=re.M)]
        sections.append((name, folders))
    return sections


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    checkout = pathlib.Path(sys.argv[1]).resolve()
    output = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parents[1] / "Examples"
    simulations = checkout / "src/simulations"
    sections = sections_from((checkout / "src/qml/mobile/MainMobile.qml").read_text())

    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    potentials_used = set()
    examples, section_entries, seen = [], [], set()
    for title, folders in sections:
        ids = []
        for folder in folders:
            identifier = folder.split("/")[-1]
            ids.append(identifier)
            if identifier in seen:
                continue
            seen.add(identifier)
            source = simulations / folder
            target = output / folder
            target.mkdir(parents=True)
            files, changes = [], []
            for path in sorted(source.iterdir()):
                if path.suffix == ".qml" or not path.is_file():
                    continue
                data = path.read_bytes()
                relative = f"{folder}/{path.name}"
                if relative in REPLACEMENTS:
                    data = (pathlib.Path(__file__).resolve().parent / "atomify2-replacements" / relative).read_bytes()
                    changes.append(f"{path.name}: {REPLACEMENTS[relative]}")
                if path.suffix == ".in" or path.name.startswith("system.in") or path.name.startswith("run.in"):
                    text = data.decode()
                    for name in re.findall(re.escape(POTENTIALS) + r"([\w.\-]+)", text):
                        potentials_used.add(name)
                        files.append({"fileName": name, "url": f"potentialparameters/{name}"})
                    text = text.replace(POTENTIALS, "")
                    for pattern, replacement, note in COMPATIBILITY + SCRIPT_FIXES.get(f"{folder}/{path.name}", []):
                        text, count = re.subn(pattern, replacement, text, flags=re.M)
                        if count:
                            changes.append(f"{path.name}: {note}")
                    data = text.encode()
                (target / path.name).write_bytes(data)
                if path.suffix != ".png":
                    files.append({"fileName": path.name, "url": f"{folder}/{path.name}"})
            qml = (source / f"{identifier}.qml").read_text()
            name = html_to_markdown(qml_strings(qml, "name") or identifier)
            name = TITLE_FIXES.get(name, name)
            description = html_to_markdown(qml_strings(qml, "description") or "")
            position = qml_vector(qml, "initialCameraPosition") or [0.0, 0.0, 10.0]
            if identifier in CAMERA_FIXES:
                position, note = CAMERA_FIXES[identifier]
                changes.append(f"{identifier}.qml: {note}")
            camera = {"position": position, "fieldOfView": FIELD_OF_VIEW, "relativeToBoxCenter": True}
            if (center := qml_vector(qml, "initialViewCenter")) is not None:
                camera["target"] = center
            camera["up"] = qml_vector(qml, "initialUpVector") or [0.0, 1.0, 0.0]
            options = {"dialect": "atomify2", "stepsPerFrame": STEPS_PER_FRAME, "camera": camera,
                       "dashboard": qml_controllers(qml)}
            unsupported = []
            if "customColorShaderCode" in qml:
                code = qml_strings(qml, "customColorShaderCode") or ""
                code = " ".join(line.strip() for line in code.splitlines()
                                if line.strip() and not line.strip().startswith("//"))
                if code in COLOR_SHADERS:
                    options["colorRamp"] = COLOR_SHADERS[code]
                else:
                    unsupported.append("customColorShaderCode")
            images = {axis: int(v) for axis, v in re.findall(r"periodicImages([XYZ])\s*:\s*(\d+)", qml)}
            if any(v > 1 for v in images.values()):
                options["periodicImages"] = [images.get(axis, 1) for axis in "XYZ"]
            if unsupported:
                options["notPorted"] = unsupported
            if changes:
                options["changes"] = changes
            seen_files = set()
            unique = [f for f in files if not (f["fileName"] in seen_files or seen_files.add(f["fileName"]))]
            example = {"id": identifier, "title": name, "description": description,
                       "inputScript": f"{identifier}.in", "files": unique, "atomifyMetal": options}
            if (source / f"{identifier}.png").exists():
                example["imageUrl"] = f"{folder}/{identifier}.png"
            examples.append(example)
        section_id = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        section_entries.append({"id": section_id, "title": title, "exampleIDs": ids})

    (output / "potentialparameters").mkdir()
    for name in sorted(potentials_used):
        shutil.copyfile(simulations / "potentialparameters" / name, output / "potentialparameters" / name)

    catalog = {"title": "Atomify", "examples": examples, "atomifyMetalSections": section_entries}
    (output / "examples.json").write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    print(f"{len(examples)} examples in {len(section_entries)} sections written to {output}")


if __name__ == "__main__":
    main()
