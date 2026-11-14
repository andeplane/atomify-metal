// State shared between the C interface (any thread) and fix atomify (the
// simulation thread). Internal to the bridge; not part of the public header.

#ifndef LMP_ATOMIFY_SHARED_H
#define LMP_ATOMIFY_SHARED_H

#include "atomify_lammps.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace LAMMPS_NS {
class LAMMPS;

// One observable as sampled by the fix. Immutable once published.
struct AtomifyObservable {
  int kind = ATOMIFY_OBSERVABLE_COMPUTE;
  std::string name;
  std::string style;
  int64_t timestep = -1;
  double time = 0.0;
  bool has_scalar = false;
  double scalar = 0.0;
  std::vector<double> vector;
  int rows = 0, columns = 0;
  std::vector<double> array;    // rows * columns, row major
  bool has_per_atom = false;
  int per_atom_columns = 0;
};

struct AtomifyObservableList {
  int64_t timestep = -1;
  std::vector<AtomifyObservable> items;
};

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
  double tilt[3] = {0, 0, 0};
  double bounds_lo[3] = {0, 0, 0};
  double bounds_hi[3] = {0, 0, 0};
  double temperature = 0.0;
  double kinetic_energy = 0.0;
  double potential_energy = 0.0;
  bool has_potential_energy = false;
  bool frozen = false;
  int64_t grab_tag = 0;
  double grab_force[3] = {0, 0, 0};
  double steps_per_second = 0.0;
  int run_mode = 0;
  int64_t run_step = 0;
  int64_t run_steps = 0;
  std::string input_line;
  std::vector<atomify_wall> walls;
  std::vector<int64_t> tags;
  std::vector<int32_t> types;
  std::vector<float> positions;
  std::vector<float> radii;
  std::vector<uint32_t> bonds;

  std::string per_atom_name;
  std::string per_atom_error;
  std::vector<float> per_atom_values;
  bool has_per_atom_values = false;

  // Shared between snapshots until the next sample replaces it.
  std::shared_ptr<const AtomifyObservableList> observables;
  // C views into `observables`, rebuilt under the snapshot lock.
  std::vector<atomify_observable> observable_views;
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
  // Frame pacing: the run takes only granted timesteps (see
  // atomify_sim_grant_steps) and waits for more when they run out.
  bool frame_paced = false;
  double step_budget = 0.0;
  double publish_interval = 1.0 / 90.0;
  double observable_interval = 0.05;

  // Inputs from the app, copied by the fix once per step under control_mutex.
  bool topology_bonds = true;
  std::map<std::pair<int, int>, double> bond_cutoffs;    // key has type1 <= type2
  std::vector<atomify_force_sphere> force_spheres;
  uint64_t force_sphere_generation = 0;
  AtomifyGrab grabs[kGrabSlots];
  bool frozen = false;
  std::shared_ptr<const AtomifyWallGrid> wall_grid;
  std::string per_atom_quantity;

  // Command queue (control_mutex). `queued` mirrors commands.size() so the
  // fix can poll it every step without locking.
  std::deque<std::string> commands;
  std::atomic<int> queued{0};

  // Simulation thread only: set while Run executes the integrator through
  // atomify_integrate, so the fix may end it early to run queued commands.
  bool can_interrupt = false;
  bool interrupted = false;
  // Simulation thread only: the first step of the run atomify_integrate is
  // executing (continuations move update->firststep), or -1.
  int64_t run_first_step = -1;
  // Simulation thread only: the input line of that run ("run 10000"), since
  // queued commands replace LAMMPS' last input line during it.
  std::string run_line;
  // Simulation thread only: the run command an error ended, which is what to
  // report rather than the last queued command LAMMPS executed.
  std::string error_line;

  // Published output. The fix fills `back` without the lock, then swaps it
  // with `front` under snapshot_mutex.
  std::mutex snapshot_mutex;
  AtomifySnapshotData front;
  bool has_front = false;
  AtomifySnapshotData back;
  uint64_t next_sequence = 1;

  // Captured screen output (output_mutex). While the thread count is being
  // chosen, output goes to `held` instead: a restart on fewer threads runs
  // the input again, so the first pass's output is dropped rather than shown
  // twice (with the internal error that ends it).
  std::mutex output_mutex;
  std::string output;
  std::string held;
  bool holding = false;
  bool echo = false;

  // OpenMP threads (see atomify_before_init): the count the instance runs
  // on, whether the first initialization with atoms is still to choose it,
  // and the count it chose that needs a new instance (simulation thread).
  std::atomic<int> threads{1};
  bool choosing_threads = false;
  int restart_threads = 0;

  // Wall clock bookkeeping for publishing and the measured step rate.
  std::chrono::steady_clock::time_point last_publish{};
  std::chrono::steady_clock::time_point rate_window_start{};
  int64_t rate_window_steps = 0;
  double steps_per_second = 0.0;
  std::chrono::steady_clock::time_point last_step{};

  void append_output(const char *data, size_t size);
  void hold_output();
  // Moves held output to `output` (keep) or drops it, and stops holding.
  void release_output(bool keep);
  void mark_progress();
};

// The fix finds the shared state of its LAMMPS instance through this registry
// so it never holds a pointer the app could free, and the app never holds a
// pointer to a fix that a `clear` or `unfix` could delete.
void atomify_register_shared(LAMMPS *lmp, AtomifyShared *shared);
void atomify_unregister_shared(LAMMPS *lmp);
AtomifyShared *atomify_find_shared(LAMMPS *lmp);

// Why a queued command may not run in the middle of a run, or "" if it may.
std::string atomify_command_rejection(const std::string &command, bool in_run);

// Called by the patched Run::command in place of integrate->run(nsteps):
// runs the integrator and, whenever fix atomify ended it early for queued
// commands, executes them, re-initializes and continues the remaining steps.
void atomify_integrate(LAMMPS *lmp, int nsteps);

// Called by the patched LAMMPS::init before anything initializes. The first
// time a simulation created with several threads initializes with atoms, it
// picks the thread count for the system (atomify_threads_for). LAMMPS cannot
// change the count once /omp styles exist, so a smaller count ends the
// command with an error and sets restart_threads; the bridge then builds a
// new instance on that many threads and runs the input again.
void atomify_before_init(LAMMPS *lmp);

int atomify_threads_for(int64_t atoms, int atoms_per_thread, int max_threads);

}    // namespace LAMMPS_NS

#endif
