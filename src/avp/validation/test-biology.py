#!/usr/bin/env python3
"""Validate constrained peptide temperatures and coarse-grained amphiphile dynamics.

Uses actual LAMMPS engine snapshots and an independently evaluated LAMMPS thermo
variable, not a synthetic trajectory or a preset bath-temperature override.
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
DEMOS = HERE.parent / "Demos"
PROBE = r'''
#include "atomify_lammps.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
int main(int argc, char **argv) {
  if (argc != 5) return 2;
  auto *sim=atomify_sim_create(0); if (!sim) return 3;
  atomify_sim_set_publish_interval(sim, 0);
  if (atomify_sim_run_file(sim, argv[1]) != ATOMIFY_OK) {
    std::fprintf(stderr,"%s\n",atomify_sim_last_error(sim)); return 4;
  }
  const int expected=std::atoi(argv[2]), steps=std::atoi(argv[3]);
  FILE *output=std::fopen(argv[4], "w"); if (!output) return 5;
  char advance[64]; std::snprintf(advance,sizeof advance,"run %d",steps/10);
  for (int stage=0; stage<=10; ++stage) {
    if (stage && atomify_sim_command(sim,advance)!=ATOMIFY_OK) return 6;
    if (atomify_sim_command(sim,"print \"$(temp:%.17g)\" file reference.dat screen no")!=ATOMIFY_OK) {
      std::fprintf(stderr,"%s\n",atomify_sim_last_error(sim));return 7;
    }
    double reference=0;std::ifstream ref("reference.dat");ref>>reference;
    atomify_snapshot s;if (!atomify_sim_snapshot_lock(sim,&s)) return 8;
    bool valid=s.natoms==expected && std::isfinite(s.temperature) && std::isfinite(reference) &&
      std::isfinite(s.kinetic_energy) && (!s.has_potential_energy || std::isfinite(s.potential_energy));
    for (int i=0;i<3*s.natoms;++i) valid &= std::isfinite(s.positions[i]);
    if (!valid) return 9;
    std::fprintf(output,"{\"step\":%lld,\"temperature\":%.17g,\"reference\":%.17g,\"kinetic\":%.17g,\"positions\":[",(long long)s.timestep,s.temperature,reference,s.kinetic_energy);
    for (int i=0;i<s.natoms;++i) std::fprintf(output,"%s[%.8g,%.8g,%.8g]",i?",":"",s.positions[3*i],s.positions[3*i+1],s.positions[3*i+2]);
    std::fprintf(output,"],\"types\":[");
    for (int i=0;i<s.natoms;++i) std::fprintf(output,"%s%d",i?",":"",s.types[i]);
    std::fprintf(output,"],\"bonds\":[");
    for (int i=0;i<s.nbonds;++i) std::fprintf(output,"%s[%u,%u]",i?",":"",s.bonds[2*i],s.bonds[2*i+1]);
    std::fprintf(output,"],\"boxLow\":[%.17g,%.17g,%.17g],\"boxHigh\":[%.17g,%.17g,%.17g],\"periodic\":[%d,%d,%d]}\n",s.box_lo[0],s.box_lo[1],s.box_lo[2],s.box_hi[0],s.box_hi[1],s.box_hi[2],s.periodic[0],s.periodic[1],s.periodic[2]);
    atomify_sim_snapshot_unlock(sim);
  }
  std::fclose(output);atomify_sim_destroy(sim);
}
'''
LJ_INPUT = '''units lj
atom_style atomic
lattice fcc 0.8
region box block 0 3 0 3 0 3
create_box 1 box
create_atoms 1 box
mass 1 1
pair_style lj/cut 2.5
pair_coeff * * 1 1 2.5
neighbor 0.3 bin
neigh_modify every 1 delay 0 check yes
minimize 1e-6 1e-6 100 1000
velocity all create 1.0 49183 mom yes rot yes
fix integrate all nvt temp 1.0 1.0 0.5
timestep 0.002
thermo 100
run 200
'''


def data_sections(path):
    sections={};current=None
    for raw in path.read_text().splitlines():
        line=raw.strip()
        if line in ("Atoms", "Bonds", "Angles", "Velocities"):
            current=line;sections[current]=[]
        elif current and line and line[0].isdigit():
            sections[current].append(line.split())
        elif line and not line[0].isdigit() and not line.startswith("#"):
            current=None
    return sections


def frame_checks(frames, topology, is_2d=False):
    # Atomify publishes before later end-of-step fixes. At the micelle's
    # 100-step temp/rescale boundary, post-run thermo observes a later velocity
    # projection. Compare on non-rescale steps, while retaining the actual
    # 1000-step starting frame for all geometry/topology checks and export.
    compared=[f for f in frames if not (is_2d and f["step"] % 100 == 0)]
    assert compared
    error=max(abs(f["temperature"]-f["reference"]) for f in compared)
    assert error < 1e-8, f"Bridge temperature disagrees with LAMMPS: {error}"
    all_distances=[]
    for frame in frames:
        points=frame["positions"]
        assert all(math.isfinite(x) for p in points for x in p)
        actual={tuple(sorted(edge)) for edge in frame["bonds"]}
        assert len(actual)==len(frame["bonds"]), "Duplicate displayed bond"
        assert actual <= topology, "Displayed graph contains invented covalent bonds"
        for a,b in topology:
            delta=[points[b][i]-points[a][i] for i in range(3)]
            wrapped=False
            for axis in range(3):
                if frame["periodic"][axis]:
                    length=frame["boxHigh"][axis]-frame["boxLow"][axis]
                    wrapped |= abs(delta[axis]) > length/2
                    delta[axis] -= round(delta[axis]/length)*length
            d=math.sqrt(sum(x*x for x in delta))
            assert 0.2 < d < 2.5, f"Implausible fixed bond separation: {d}"
            all_distances.append(d)
            if not wrapped:
                assert (a,b) in actual, "Non-wrapped topological bond missing"
        if is_2d:
            assert max(abs(p[2]) for p in points) < 1e-8, "2D amphiphiles left the plane"
    return {"snapshots":len(frames), "atom_count":len(frames[0]["positions"]),
            "topology_bonds":len(topology), "published_bond_count_range":[min(len(f["bonds"]) for f in frames),max(len(f["bonds"]) for f in frames)],
            "finite_coordinates":True, "displayed_topology_valid":True,
            "minimum_image_bond_distance_range":[min(all_distances), max(all_distances)] if all_distances else None,
            "temperature_range":[min(f["temperature"] for f in frames),max(f["temperature"] for f in frames)],
            "maximum_bridge_vs_lammps_temperature_error":error,
            "temperature_reference_samples":len(compared),
            "temperature_reference_excluded_steps":[f["step"] for f in frames if f not in compared],
            "first_step":frames[0]["step"], "last_step":frames[-1]["step"]}


def tail_cluster_metrics(frame):
    # A geometric association indicator for this toy, not a micelle phase label.
    indices=[i for i,t in enumerate(frame["types"]) if t in (3,4)]
    parents={i:i for i in indices}
    def root(i):
        while parents[i]!=i:
            parents[i]=parents[parents[i]];i=parents[i]
        return i
    positions=frame["positions"]
    lengths=[b-a for a,b in zip(frame["boxLow"],frame["boxHigh"])]
    for index,i in enumerate(indices):
        for j in indices[index+1:]:
            delta=[positions[i][a]-positions[j][a] for a in range(2)]
            delta=[v-round(v/lengths[a])*lengths[a] for a,v in enumerate(delta)]
            if sum(v*v for v in delta)<1.5**2:
                parents[root(i)]=root(j)
    counts={}
    for i in indices:
        key=root(i);counts[key]=counts.get(key,0)+1
    return {"tail_bead_groups_within_1_5":len(counts),"largest_group_tail_beads":max(counts.values())}


def preview_subset(frame, predicate):
    keep=[i for i,t in enumerate(frame["types"]) if predicate(t)]
    mapping={old:new for new,old in enumerate(keep)}
    return {"positions":[frame["positions"][i] for i in keep], "types":[frame["types"][i] for i in keep],
            "bonds":[[mapping[a],mapping[b]] for a,b in frame["bonds"] if a in mapping and b in mapping]}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=SHARED_LAMMPS/"build/host")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--export-previews", action="store_true")
    args=parser.parse_args()
    receipt={"tests":[], "temperature_reference":"LAMMPS immediate variable $(temp), evaluated independently after each sampled run",
             "bridge_source_sha256":hashlib.sha256((SHARED_LAMMPS/"bridge/src/fix_atomify.cpp").read_bytes()).hexdigest(),
             "sources":{str(p.relative_to(DEMOS)):hashlib.sha256(p.read_bytes()).hexdigest() for name in ("peptide","micelle")
                        for p in (DEMOS/name/f"in.{name}",DEMOS/name/f"data.{name}")}}
    with tempfile.TemporaryDirectory(prefix="atomify-biology-") as temporary:
        temp=Path(temporary);source=temp/"probe.cpp";source.write_text(PROBE);probe=temp/"probe"
        subprocess.run(["c++","-std=c++17","-O1","-I"+str(SHARED_LAMMPS/"bridge/include"),str(source),
                        str(args.build.resolve()/"liblammps.a"),"-lpthread","-o",str(probe)],check=True)
        for name,expected,steps in (("peptide",2004,10000),("micelle",1200,10010),("lj",108,1000),("cold-minimized-lj",108,0)):
            folder=temp/name;folder.mkdir()
            if name in ("lj", "cold-minimized-lj"):
                text=LJ_INPUT if name=="lj" else LJ_INPUT.split("velocity all")[0]+"run 0\n"
                (folder/"experiment.in").write_text(text);script="experiment.in";topology=set()
            else:
                for entry in (DEMOS/name).iterdir():
                    if entry.is_file():shutil.copy2(entry,folder/entry.name)
                script=f"in.{name}"
                data=data_sections(folder/f"data.{name}")
                topology={tuple(sorted((int(row[2])-1,int(row[3])-1))) for row in data["Bonds"]}
            result=subprocess.run([str(probe),script,str(expected),str(steps),"frames.jsonl"],cwd=folder,
                                  text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            if result.returncode:raise RuntimeError(f"{name}: {result.stdout}")
            frames=[json.loads(line) for line in (folder/"frames.jsonl").read_text().splitlines()]
            metrics=frame_checks(frames,topology,is_2d=name=="micelle")
            metrics["name"]=name
            if name=="cold-minimized-lj":
                assert max(f["temperature"] for f in frames)==0, "Cold minimization unexpectedly changed temperature"
            if name=="micelle":
                metrics["association_indicator"]=[{"step":f["step"],**tail_cluster_metrics(f)} for f in frames]
            receipt["tests"].append(metrics);print(json.dumps(metrics),flush=True)
            if args.output:
                args.output.parent.mkdir(parents=True,exist_ok=True)
                args.output.write_text(json.dumps(receipt,indent=2)+"\n")
            if args.export_previews and name in ("peptide","micelle"):
                view=preview_subset(frames[0],(lambda t:t<=12) if name=="peptide" else (lambda _:True))
                view["units"]="real" if name=="peptide" else "lj"
                view["representation"]="84 peptide atoms; 640 water molecules omitted from this preview, present in the 2004-atom live simulation" if name=="peptide" else "All 1200 coarse-grained solvent and amphiphile beads; 1000-step visible starting state"
                (DEMOS/name/"preview.json").write_text(json.dumps(view,separators=(",",":"))+"\n")
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(receipt,indent=2)+"\n")


if __name__=="__main__":main()
