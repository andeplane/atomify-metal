// Real-engine geometry and NVE drift checks for the two small hydrocarbons.
#include "atomify_lammps.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

int main(int argc, char **argv)
{
  if (argc != 3) return 2;
  const bool ethane = std::strcmp(argv[2], "ethane") == 0;
  const int count = ethane ? 8 : 5, carbons = ethane ? 2 : 1;
  auto *sim = atomify_sim_create(0);
  atomify_sim_set_publish_interval(sim, 0);
  auto command = [&](const char *text) {
    if (atomify_sim_command(sim, text) == ATOMIFY_OK) return true;
    std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim)); return false;
  };
  if (atomify_sim_run_file(sim, argv[1]) != ATOMIFY_OK) return 3;
  double shortest = 100, longest = 0, minAngle = 180, maxAngle = 0;
  double energy0 = 0, drift = 0;
  bool valid = true;
  auto measure = [&](bool nve, bool first) {
    atomify_snapshot s;
    if (!atomify_sim_snapshot_lock(sim, &s)) return false;
    if (s.natoms != count) { atomify_sim_snapshot_unlock(sim); return false; }
    std::vector<std::array<double, 3>> x(count);
    for (int i = 0; i < count; i++)
      for (int k = 0; k < 3; k++) { x[i][k] = s.positions[3 * i + k]; valid &= std::isfinite(x[i][k]); }
    valid &= std::isfinite(s.kinetic_energy) && std::isfinite(s.temperature) &&
        s.has_potential_energy && std::isfinite(s.potential_energy);
    const double energy = s.kinetic_energy + s.potential_energy;
    if (nve) {
      if (first) energy0 = energy;
      drift = std::max(drift, std::fabs(energy - energy0) / count);
    }
    atomify_sim_snapshot_unlock(sim);
    auto distance = [&](int a, int b) {
      double d = 0;
      for (int k = 0; k < 3; k++) d = std::hypot(d, x[a][k] - x[b][k]);
      return d;
    };
    for (int c = 0; c < carbons; c++) {
      std::vector<int> neighbours;
      if (ethane) neighbours.push_back(1-c);
      for (int h = carbons; h < count; h++) {
        if (ethane && ((h < 5) != (c == 0))) continue;
        const double d = distance(c, h);
        shortest = std::min(shortest, d); longest = std::max(longest, d);
        valid &= d > 0.8 && d < 1.35;
        if (ethane) valid &= distance(1-c, h) > 1.35;
        neighbours.push_back(h);
      }
      if (ethane) valid &= distance(0, 1) > 1.2 && distance(0, 1) < 1.85;
      for (size_t a = 0; a < neighbours.size(); a++)
        for (size_t b = a+1; b < neighbours.size(); b++) {
          double dot = 0;
          for (int k = 0; k < 3; k++) dot += (x[neighbours[a]][k]-x[c][k]) * (x[neighbours[b]][k]-x[c][k]);
          const double angle = std::acos(std::clamp(dot / (distance(c, neighbours[a]) * distance(c, neighbours[b])), -1.0, 1.0)) * 180 / std::acos(-1);
          minAngle = std::min(minAngle, angle); maxAngle = std::max(maxAngle, angle);
        }
    }
    for (int a = carbons; a < count; a++)
      for (int b = a+1; b < count; b++) valid &= distance(a,b) > 1.2;
    return valid;
  };
  if (!measure(false, false)) return 4;
  if (minAngle < 99 || maxAngle > 120 || shortest < 0.99 || longest > 1.19) return 5;
  for (int stage = 0; stage < 80; stage++)
    if (!command("run 1000") || !measure(false, false)) return 6;
  if (!command("unfix thermal") || !command("run 0") || !measure(true, true)) return 7;
  for (int stage = 0; stage < 20; stage++)
    if (!command("run 1000") || !measure(true, false)) return 8;
  std::printf("molecule=%s steps=100000 CH_min_A=%.8g CH_max_A=%.8g angle_min_deg=%.8g angle_max_deg=%.8g NVE_max_energy_drift_eV_per_atom=%.8g connectivity_retained=%d\n",
              argv[2], shortest, longest, minAngle, maxAngle, drift, valid);
  atomify_sim_destroy(sim);
  return valid && drift < 0.001 ? 0 : 9;
}
