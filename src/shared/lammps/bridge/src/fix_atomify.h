/* ----------------------------------------------------------------------
   fix atomify: connects a LAMMPS run to the Atomify apps.

   Installed by the bridge before any script runs (the patched Modify allows
   it before the simulation box exists). Every timestep it
     - adds the app's interaction forces (hand spheres, grabbed atoms, walls),
     - waits while the app has paused the run, throttles to a step rate,
       and stops the run when the app cancels it,
     - ends the integrator early when the app queued commands (the patched
       Run executes them and continues, see atomify_integrate),
     - samples observables (computes, fixes, variables, thermo) at the
       observable interval, on steps where LAMMPS tallied energy and virial,
     - publishes a tag sorted snapshot of positions, types, bonds, one
       per-atom quantity and the observables at most once per publish
       interval.
------------------------------------------------------------------------- */

#ifdef FIX_CLASS
// clang-format off
FixStyle(atomify,FixAtomify);
// clang-format on
#else

#ifndef LMP_FIX_ATOMIFY_H
#define LMP_FIX_ATOMIFY_H

#include "fix.h"

#include "atomify_shared.h"

#include <array>
#include <chrono>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace LAMMPS_NS {

class FixAtomify : public Fix {
 public:
  FixAtomify(class LAMMPS *, int, char **);

  int setmask() override;
  void setup(int) override;
  void min_setup(int) override;
  void post_integrate() override;
  void post_force(int) override;
  void min_post_force(int) override;
  void end_of_step() override;

  // Publishes the current state outside of a run (no computes invoked).
  // Returns false if there is nothing to publish yet.
  bool publish_idle();

 private:
  AtomifyShared *shared;

  // Copies of the app's inputs, refreshed once per step.
  // Hand spheres where they are this step, and their motion: each slides
  // from `sphere_from` to `sphere_to` over `move_steps` steps.
  std::vector<atomify_force_sphere> spheres;
  std::vector<atomify_force_sphere> sphere_from, sphere_to;
  uint64_t sphere_generation;
  int move_step, move_steps, steps_since_update;
  AtomifyGrab grabs[kGrabSlots];
  bool frozen;
  std::shared_ptr<const AtomifyWallGrid> wall_grid;
  bool topology_bonds;
  std::string per_atom_quantity;
  double observable_interval;

  // Freeze state: positions by tag, captured when freezing starts.
  std::unordered_map<int64_t, std::array<double, 3>> frozen_positions;
  std::unordered_map<int64_t, std::array<double, 3>> wall_previous;
  double grab_force[3];

  // Potential energy, read on timesteps where LAMMPS tallied it.
  double potential_energy;
  bool has_potential_energy;
  std::vector<std::pair<std::pair<int, int>, double>> bond_cutoffs;

  // Observable sampling: a sample is requested for the next step (so LAMMPS
  // tallies energy and virial there) and taken when that step ends.
  bool sample_pending;
  bigint sample_step;
  std::chrono::steady_clock::time_point last_sample;
  std::shared_ptr<const AtomifyObservableList> observables;
  // Computes, fixes and variables whose evaluation raised an error; skipped
  // until the next run starts.
  std::unordered_set<std::string> failed;

  // Last per-atom values by tag, kept for steps where they cannot be computed.
  std::string last_per_atom_name;
  std::vector<int64_t> last_per_atom_tags;
  std::vector<float> last_per_atom_values;

  void sync_inputs();
  void apply_forces();
  void move_spheres();
  void after_step(bool minimizing);
  void publish(bool minimizing, bool sample);
  void check_cancelled();
  void check_state();
  void hold_frozen_positions();
  void update_potential_energy();
  void apply_wall_grid();
  void collide_with_walls();
  void remember_wall_positions();
  void request_sample();
  bool wants_interrupt() const;

  void collect_walls(AtomifySnapshotData &);
  void collect_topology_bonds(AtomifySnapshotData &, const std::vector<int> &order);
  void collect_distance_bonds(AtomifySnapshotData &);
  void collect_per_atom(AtomifySnapshotData &, const std::vector<int> &order, bool sample);
  bool per_atom_source(const std::string &name, bool sample, std::vector<double> &values,
                       std::string &error);
  std::shared_ptr<const AtomifyObservableList> sample_observables(bool in_run);
  void sample_compute(class Compute *, AtomifyObservable &, bool in_run);
  void sample_fix(class Fix *, AtomifyObservable &);
  void sample_variables(AtomifyObservableList &, bool in_run);
  void sample_thermo(AtomifyObservableList &);
  bool compute_is_current(class Compute *, bool peratom) const;
  // Runs body; a LAMMPS error inside is swallowed (not printed) and
  // reported as false. The run state LAMMPS resets on errors is restored.
  template <typename Body> bool guarded(Body &&body);

  void minimum_image(double *delta) const;
  // The first active grab, or null.
  const AtomifyGrab *first_grab() const;
  // Index of the owned atom with this tag, or -1.
  int local_index(int64_t tag) const;
};

}    // namespace LAMMPS_NS

#endif
#endif
