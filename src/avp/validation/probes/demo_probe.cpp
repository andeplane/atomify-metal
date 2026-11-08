// Actual engine smoke probe, not a renderer or a synthetic trajectory.
#include "atomify_lammps.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>

int main(int argc, char **argv)
{
  if (argc != 3 && argc != 4) return 2;
  auto *sim = atomify_sim_create(0);
  if (!sim) return 3;
  atomify_sim_set_publish_interval(sim, 0);
  auto command = [&](const char *text) {
    if (atomify_sim_command(sim, text) == ATOMIFY_OK) return true;
    std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim)); return false;
  };
  if (atomify_sim_run_file(sim, argv[1]) != ATOMIFY_OK) {
    std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim)); return 4;
  }
  const int expected = std::atoi(argv[2]);
  const int steps = argc == 4 ? std::atoi(argv[3]) : 2000;
  if (steps < 10 || steps > 1000000) return 2;
  char advance[64];
  std::snprintf(advance, sizeof(advance), "run %d", steps / 10);
  for (int stage = 0; stage < 11; stage++) {
    if (stage && !command(advance)) return 5;
    atomify_snapshot s;
    if (!atomify_sim_snapshot_lock(sim, &s)) return 6;
    bool valid = s.natoms == expected && std::isfinite(s.temperature) && std::isfinite(s.kinetic_energy);
    for (int i = 0; i < 3 * s.natoms; i++) valid &= std::isfinite(s.positions[i]);
    if (s.has_potential_energy) valid &= std::isfinite(s.potential_energy);
    std::printf("stage=%d atoms=%d step=%lld temperature=%.9g potential=%.9g finite=%d\n",
                stage, s.natoms, static_cast<long long>(s.timestep), s.temperature, s.potential_energy, valid);
    atomify_sim_snapshot_unlock(sim);
    if (!valid) return 7;
  }
  atomify_sim_destroy(sim);
}
