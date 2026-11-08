// Export a real initialized structure for the native library sculpture.
#include "atomify_lammps.h"
#include <cmath>
#include <cstdio>

int main(int argc, char **argv)
{
  if (argc != 2) return 2;
  auto *sim = atomify_sim_create(0);
  if (!sim) return 3;
  atomify_sim_set_publish_interval(sim, 0);
  atomify_sim_set_bond_cutoff(sim, 1, 1, 1.85);
  atomify_sim_set_bond_cutoff(sim, 1, 2, 1.3);
  if (atomify_sim_run_file(sim, argv[1]) != ATOMIFY_OK) {
    std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim));
    atomify_sim_destroy(sim);
    return 4;
  }
  atomify_snapshot snapshot;
  if (!atomify_sim_snapshot_lock(sim, &snapshot)) return 5;
  for (int i = 0; i < 3 * snapshot.natoms; i++)
    if (!std::isfinite(snapshot.positions[i])) return 6;
  std::printf("{\"positions\":[");
  for (int i = 0; i < snapshot.natoms; i++)
    std::printf("%s[%.8g,%.8g,%.8g]", i ? "," : "", snapshot.positions[3 * i],
                snapshot.positions[3 * i + 1], snapshot.positions[3 * i + 2]);
  std::printf("],\"types\":[");
  for (int i = 0; i < snapshot.natoms; i++) std::printf("%s%d", i ? "," : "", snapshot.types[i]);
  std::printf("],\"bonds\":[");
  for (int i = 0; i < snapshot.nbonds; i++)
    std::printf("%s[%u,%u]", i ? "," : "", snapshot.bonds[2 * i], snapshot.bonds[2 * i + 1]);
  std::printf("]}\n");
  atomify_sim_snapshot_unlock(sim);
  atomify_sim_destroy(sim);
}
