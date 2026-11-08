#!/usr/bin/env python3
"""Exercise the actual oxDNA2 engine, including its quaternion dynamics.

This is a finite-trajectory stability probe, not a melting-point or biological
validation. Requires a host library built with CG-DNA, ASPHERE and MOLECULE.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SHARED_LAMMPS = HERE.parent.parent / 'shared/lammps'
DEMO = HERE.parent / "Demos/dna-duplex"

# Check the published app snapshot, not only the LAMMPS dump. The live app must
# receive exactly the 38 real backbone bonds and no proximity-generated rungs.
PROBE_SOURCE = r"""
#include "atomify_lammps.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <set>
#include <utility>
int main(int argc, char **argv) {
  if (argc != 4) return 2;
  auto *sim = atomify_sim_create(0);
  if (!sim) return 3;
  atomify_sim_set_publish_interval(sim, 0);
  if (atomify_sim_run_file(sim, argv[1]) != ATOMIFY_OK) {
    std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim)); return 4;
  }
  std::set<std::pair<unsigned,unsigned>> expected;
  for (unsigned i=0; i<19; ++i) expected.insert({i,i+1});
  for (unsigned i=20; i<39; ++i) expected.insert({i,i+1});
  const int steps = std::atoi(argv[2]);
  char advance[64]; std::snprintf(advance, sizeof advance, "run %d", steps/20);
  for (int stage=0; stage<=20; ++stage) {
    if (stage && atomify_sim_command(sim, advance) != ATOMIFY_OK) {
      std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim)); return 5;
    }
    atomify_snapshot s;
    if (!atomify_sim_snapshot_lock(sim, &s)) return 6;
    bool valid=s.natoms==40 && s.nbonds==38 && std::isfinite(s.temperature) &&
      std::isfinite(s.kinetic_energy) && s.has_potential_energy && std::isfinite(s.potential_energy);
    for (int i=0; i<3*s.natoms; ++i) valid &= std::isfinite(s.positions[i]);
    std::set<std::pair<unsigned,unsigned>> bonds;
    for (int i=0; i<s.nbonds; ++i) {
      auto a=s.bonds[2*i], b=s.bonds[2*i+1];
      bonds.insert({std::min(a,b), std::max(a,b)});
    }
    valid &= bonds==expected;
    if (stage==0 && valid) {
      FILE *preview=std::fopen(argv[3], "w");
      if (!preview) return 8;
      std::fprintf(preview, "{\"positions\":[");
      for (int i=0; i<s.natoms; ++i)
        std::fprintf(preview, "%s[%.8g,%.8g,%.8g]", i?",":"", s.positions[3*i], s.positions[3*i+1], s.positions[3*i+2]);
      std::fprintf(preview, "],\"types\":[");
      for (int i=0; i<s.natoms; ++i) std::fprintf(preview, "%s%d", i?",":"", s.types[i]);
      std::fprintf(preview, "],\"bonds\":[");
      for (int i=0; i<s.nbonds; ++i)
        std::fprintf(preview, "%s[%u,%u]", i?",":"", s.bonds[2*i], s.bonds[2*i+1]);
      std::fprintf(preview, "]}\n");
      std::fclose(preview);
    }
    atomify_sim_snapshot_unlock(sim);
    if (!valid) return 7;
  }
  atomify_sim_destroy(sim);
}
"""


def body_axes(q):
    w, x, y, z = q
    return ([w*w+x*x-y*y-z*z, 2*(x*y+w*z), 2*(x*z-w*y)],
            [2*(x*y-w*z), w*w-x*x+y*y-z*z, 2*(y*z+w*x)])


def distance(a, b):
    return math.sqrt(sum((x-y)**2 for x, y in zip(a, b)))


def parse_dump(path):
    frames = []
    with path.open() as stream:
        while stream.readline():
            step = int(stream.readline())
            assert stream.readline().strip() == "ITEM: NUMBER OF ATOMS"
            count = int(stream.readline())
            assert count == 40
            assert stream.readline().startswith("ITEM: BOX BOUNDS")
            for _ in range(3):
                stream.readline()
            header = stream.readline().split()[2:]
            frame = []
            for _ in range(count):
                row = dict(zip(header, stream.readline().split()))
                point = [float(row[key]) for key in ("x", "y", "z")]
                quat = [float(row[f"c_dnaQuat[{i}]"]) for i in range(1, 5)]
                assert all(map(math.isfinite, point + quat)), "Nonfinite position/orientation"
                assert abs(sum(x*x for x in quat)-1) < 1e-8, "Quaternion normalization failed"
                e1, e2 = body_axes(quat)
                backbone = [point[k] - .34*e1[k] + .3408*e2[k] for k in range(3)]
                base = [point[k] + .4*e1[k] for k in range(3)]
                frame.append({"id":int(row["id"]), "mol":int(row["mol"]), "type":int(row["type"]),
                              "point":point, "quat":quat, "backbone":backbone, "base":base})
            assert [p["id"] for p in frame] == list(range(1, 41))
            frames.append((step, frame))
    return frames


def analyze(frames):
    assert len(frames) >= 21
    backbone_distances, intended_pair_distances, paired_counts = [], [], []
    topology = [(i, i+1) for i in range(19)] + [(i, i+1) for i in range(20, 39)]
    for _, frame in frames:
        paired = 0
        for i, j in topology:
            assert frame[i]["mol"] == frame[j]["mol"]
            d = distance(frame[i]["backbone"], frame[j]["backbone"])
            # The oxDNA2 FENE domain is r0 +/- delta = 0.7564 +/- 0.25.
            assert .5064 < d < 1.0064, f"Backbone outside FENE domain: {d}"
            backbone_distances.append(d)
        for i in range(20):
            a, b = frame[i], frame[39-i]
            assert a["type"] + b["type"] == 5 and a["mol"] != b["mol"]
            d = distance(a["base"], b["base"])
            intended_pair_distances.append(d)
            paired += d*d < .2
        paired_counts.append(paired)
    assert min(paired_counts) >= 12 and paired_counts[-1] >= 14, "Most intended base pairs no longer close"
    first, last = frames[0][1], frames[-1][1]
    rotated = [1-abs(sum(a*b for a,b in zip(p["quat"],q["quat"]))) for p,q in zip(first,last)]
    assert max(rotated) > 1e-4, "Orientations never changed: wrong integrator?"
    return {"frames":len(frames), "nucleotides":40, "backbone_bonds":38, "published_topology_exact":True,
            "backbone_site_distance_range":[min(backbone_distances), max(backbone_distances)],
            "intended_base_site_distance_range":[min(intended_pair_distances), max(intended_pair_distances)],
            "proximity_paired_count_range":[min(paired_counts), max(paired_counts)],
            "final_proximity_paired_count":paired_counts[-1],
            "maximum_orientation_change_1_minus_abs_dot":max(rotated),
            "quaternions_normalized":True, "positions_finite":True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=SHARED_LAMMPS/"build/host")
    parser.add_argument("--steps", type=int, default=100000)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--export-preview", action="store_true", help="Replace bundled preview with the actual initialized default-seed state")
    args = parser.parse_args()
    assert args.steps >= 20000 and args.steps % 10000 == 0
    receipt = {"model":"oxDNA2 sequence-dependent, 20 base pairs, 300 K, 0.2 M implicit salt",
               "steps_after_warmup":args.steps,
               "pair_count_definition":"Intended complementary base interaction sites within sqrt(0.2) reduced length units; geometric proxy, not hydrogen-bond energy or biological validation.",
               "sha256":{p.name:hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [DEMO/"experiment.in", DEMO/"data.duplex", DEMO/"oxdna2_lj.cgdna"]},
               "seeds":[]}
    with tempfile.TemporaryDirectory(prefix="atomify-dna-probe-") as temp:
        temp = Path(temp)
        probe = temp/"probe"
        (temp/"probe.cpp").write_text(PROBE_SOURCE)
        subprocess.run(["c++", "-std=c++17", "-O1", "-I"+str(SHARED_LAMMPS/"bridge/include"),
                        str(temp/"probe.cpp"), str(args.build.resolve()/"liblammps.a"),
                        "-lpthread", "-o", str(probe)], check=True)
        for seed in (457145, 49183, 82347):
            folder = temp/str(seed)
            folder.mkdir()
            for name in ("data.duplex", "oxdna2_lj.cgdna"):
                shutil.copy2(DEMO/name, folder/name)
            script = (DEMO/"experiment.in").read_text().replace("457145 angmom", f"{seed} angmom")
            script += "\ncompute dnaQuat all property/atom quatw quati quatj quatk\n"
            script += "dump dnaValidation all custom 5000 trajectory.dump id mol type x y z c_dnaQuat[1] c_dnaQuat[2] c_dnaQuat[3] c_dnaQuat[4]\n"
            script += "dump_modify dnaValidation sort id format float %.17g\nrun 0\n"
            (folder/"validation.in").write_text(script)
            result = subprocess.run([str(probe), "validation.in", str(args.steps), "preview.json"], cwd=folder,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(result.stdout)
            metrics = analyze(parse_dump(folder/"trajectory.dump"))
            if args.export_preview and seed == 457145:
                view=json.loads((folder/"preview.json").read_text())
                view.update(units="lj", representation="40 coarse-grained nucleotides; actual initialized 20-base-pair duplex with 38 backbone connections")
                (DEMO/"preview.json").write_text(json.dumps(view,separators=(",",":"))+"\n")
            metrics["seed"] = seed
            receipt["seeds"].append(metrics)
            print(json.dumps(metrics), flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2)+"\n")


if __name__ == "__main__":
    main()
