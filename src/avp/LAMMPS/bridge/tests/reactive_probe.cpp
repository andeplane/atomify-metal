// Controlled two-hand C-H pull and return with the app's Reshape springs.
// Separation is a structural metric, not electronic bond order or a rate.
#include "atomify_lammps.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <limits>

int main(int argc, char **argv)
{
  if (argc != 2) return 5;
  auto *sim = atomify_sim_create(0);
  if (!sim) return 1;
  atomify_sim_set_publish_interval(sim, 0);
  auto command = [&](const char *text) {
    if (atomify_sim_command(sim, text) == ATOMIFY_OK) return true;
    std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim));
    return false;
  };
  if (atomify_sim_run_file(sim, argv[1]) != ATOMIFY_OK) {
    std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim));
    atomify_sim_destroy(sim);
    return 1;
  }
  auto point = [&](int tag) {
    std::array<double, 3> point{NAN, NAN, NAN};
    atomify_snapshot snapshot;
    if (!atomify_sim_snapshot_lock(sim, &snapshot)) return point;
    for (int i = 0; i < snapshot.natoms; i++)
      if (snapshot.tags[i] == tag)
        for (int k = 0; k < 3; k++) point[k] = snapshot.positions[3 * i + k];
    atomify_sim_snapshot_unlock(sim);
    return point;
  };
  const auto carbon = point(1), hydrogen = point(7);
  bool ringRetained = true;
  bool detachedFromAllCarbons = false;
  int finalNearestCarbon = 0;
  auto measure = [&](const char *phase, int step) -> double {
    const auto c = point(1), h = point(7);
    double distance = 0;
    for (int k = 0; k < 3; k++) distance = std::hypot(distance, c[k] - h[k]);
    double nearestDistance = std::numeric_limits<double>::infinity();
    int neighbours = 0;
    for (int tag = 1; tag <= 6; tag++) {
      const auto a = point(tag), b = point(tag == 6 ? 1 : tag + 1);
      double ch = 0, cc = 0;
      for (int k = 0; k < 3; k++) {
        ch = std::hypot(ch, a[k] - h[k]);
        cc = std::hypot(cc, a[k] - b[k]);
      }
      if (ch < nearestDistance) { nearestDistance = ch; finalNearestCarbon = tag; }
      if (ch < 1.3) neighbours++;
      ringRetained &= std::isfinite(cc) && cc > 0.8 && cc < 1.85;
    }
    if (nearestDistance > 2.0) detachedFromAllCarbons = true;
    atomify_snapshot snapshot;
    if (!atomify_sim_snapshot_lock(sim, &snapshot)) return NAN;
    bool finite = snapshot.natoms == 12 && std::isfinite(snapshot.temperature) &&
        std::isfinite(snapshot.kinetic_energy) && snapshot.has_potential_energy &&
        std::isfinite(snapshot.potential_energy);
    for (int i = 0; i < 3 * snapshot.natoms; i++) finite &= std::isfinite(snapshot.positions[i]);
    std::printf("%s %d distance=%.6f temperature=%.6f energy=%.6f finite=%d nearest_carbon=%d CH_neighbours=%d ring_intact=%d\n",
                phase, step, distance, snapshot.temperature, snapshot.potential_energy, finite,
                finalNearestCarbon, neighbours, ringRetained);
    atomify_sim_snapshot_unlock(sim);
    return finite ? distance : std::numeric_limits<double>::quiet_NaN();
  };
  if (!std::isfinite(measure("initial", 0))) return 6;
  double farthest = 0, returned = 0;
  for (int phase = 0; phase < 2; phase++) {
    for (int step = 0; step <= 40; step++) {
      const double fraction = phase == 0 ? step / 40.0 : 1 - step / 40.0;
      const double target[3] = {hydrogen[0] + 3 * fraction, hydrogen[1], hydrogen[2]};
      atomify_sim_set_grab_slot(sim, 0, 1, carbon.data(), 80);
      atomify_sim_set_grab_slot(sim, 1, 7, target, 80);
      if (!command("run 100")) return 2;
      const double distance = measure(phase == 0 ? "pull" : "return", step);
      if (!std::isfinite(distance)) return 6;
      if (phase == 0) farthest = std::max(farthest, distance);
    }
  }
  atomify_sim_set_grab_slot(sim, 0, 0, nullptr, 0);
  atomify_sim_set_grab_slot(sim, 1, 0, nullptr, 0);
  // Five picoseconds without either hand force after guided return.
  for (int stage = 0; stage < 10; stage++) {
    if (!command("run 2000")) return 3;
    if (!std::isfinite(measure("relax", stage))) return 6;
  }
  returned = measure("released", 0);
  atomify_sim_destroy(sim);
  std::printf("max_distance=%.6f final_distance=%.6f\n", farthest, returned);
  return farthest > 2.0 && returned < 1.3 && finalNearestCarbon == 1 &&
      ringRetained && detachedFromAllCarbons ? 0 : 4;
}
