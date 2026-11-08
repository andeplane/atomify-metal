// State shared between the C interface (any thread) and fix atomify (the
// simulation thread). Internal to the bridge; not part of the public header.

#ifndef LMP_ATOMIFY_SHARED_H
#define LMP_ATOMIFY_SHARED_H

#include "atomify_lammps.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace LAMMPS_NS {
class LAMMPS;

struct AtomifySnapshotData {
  uint64_t sequence = 0;
  int64_t timestep = 0;
  double time = 0.0;
  int ntypes = 0;
  int dimension = 3;
  int periodic[3] = {0, 0, 0};
  int triclinic = 0;
  int minimizing = 0;
  std::string units;
  double box_lo[3] = {0, 0, 0};
  double box_hi[3] = {0, 0, 0};
  double temperature = 0.0;
  double kinetic_energy = 0.0;
  double potential_energy = 0.0;
  bool has_potential_energy = false;
  bool frozen = false;
  int64_t grab_tag = 0;
  double grab_force[3] = {0, 0, 0};
  double steps_per_second = 0.0;
  std::vector<int64_t> tags;
  std::vector<int32_t> types;
  std::vector<float> positions;
  std::vector<float> radii;
  std::vector<uint32_t> bonds;
};

// One grab per hand.
constexpr int kGrabSlots = 2;

struct AtomifyGrab {
  int64_t tag = 0;
  double target[3] = {0, 0, 0};
  double stiffness = 0.0;
};

struct AtomifyWallGrid {
  double origin[3] = {0, 0, 0};
  double spacing = 1.0;
  int dims[3] = {0, 0, 0};
  double cutoff = 0.0;
  double strength = 0.0;
  std::vector<float> distances;

  // Trilinear interpolation; false outside the grid.
  bool sample(const double *x, double &distance) const;
};

struct AtomifyShared {
  // Run control.
  std::mutex control_mutex;
  std::condition_variable control_cv;
  bool paused = false;
  std::atomic<bool> cancelled{false};
  // Wall clock heartbeat, independent of rendering and the snapshot consumer.
  std::atomic<int64_t> progress_ns{0};
  std::chrono::steady_clock::time_point interaction_updated{};
  double max_steps_per_second = 0.0;
  double publish_interval = 1.0 / 90.0;

  // Inputs from the app, copied by the fix once per step under control_mutex.
  bool topology_bonds = true;
  std::map<std::pair<int, int>, double> bond_cutoffs;    // key has type1 <= type2
  std::vector<atomify_force_sphere> force_spheres;
  uint64_t force_sphere_generation = 0;
  AtomifyGrab grabs[kGrabSlots];
  bool frozen = false;
  std::shared_ptr<const AtomifyWallGrid> wall_grid;

  // Published output. The fix fills `back` without the lock, then swaps it
  // with `front` under snapshot_mutex.
  std::mutex snapshot_mutex;
  AtomifySnapshotData front;
  bool has_front = false;
  AtomifySnapshotData back;
  uint64_t next_sequence = 1;

  // Wall clock bookkeeping for publishing and the measured step rate.
  std::chrono::steady_clock::time_point last_publish{};
  std::chrono::steady_clock::time_point rate_window_start{};
  int64_t rate_window_steps = 0;
  double steps_per_second = 0.0;
  std::chrono::steady_clock::time_point last_step{};
};

// The fix finds the shared state of its LAMMPS instance through this registry
// so it never holds a pointer the app could free, and the app never holds a
// pointer to a fix that a `clear` or `unfix` could delete.
void atomify_register_shared(LAMMPS *lmp, AtomifyShared *shared);
void atomify_unregister_shared(LAMMPS *lmp);
AtomifyShared *atomify_find_shared(LAMMPS *lmp);

}    // namespace LAMMPS_NS

#endif
