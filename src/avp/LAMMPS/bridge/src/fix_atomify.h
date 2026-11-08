/* ----------------------------------------------------------------------
   fix atomify: connects a LAMMPS run to the Atomify visionOS app.

   Installed by the bridge before any script runs (the patched Modify allows
   it before the simulation box exists). Every timestep it
     - adds the app's interaction forces (hand spheres, grabbed atom),
     - waits while the app has paused the run, throttles to a step rate,
       and stops the run when the app cancels it,
     - publishes a tag sorted snapshot of positions, types and bonds at most
       once per publish interval.
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
#include <unordered_map>
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

  // Freeze state: positions by tag, captured when freezing starts.
  std::unordered_map<int64_t, std::array<double, 3>> frozen_positions;
  std::unordered_map<int64_t, std::array<double, 3>> wall_previous;
  double grab_force[3];

  // Potential energy, read on timesteps where LAMMPS tallied it.
  double potential_energy;
  bool has_potential_energy;
  std::chrono::steady_clock::time_point last_energy_request;
  std::vector<std::pair<std::pair<int, int>, double>> bond_cutoffs;

  void sync_inputs();
  void apply_forces();
  void move_spheres();
  void after_step(bool minimizing);
  void publish(bool minimizing);
  void check_cancelled();
  void check_state();
  void hold_frozen_positions();
  void update_potential_energy();
  void apply_wall_grid();
  void collide_with_walls();
  void remember_wall_positions();

  void collect_topology_bonds(AtomifySnapshotData &, const std::vector<int> &order);
  void collect_distance_bonds(AtomifySnapshotData &);
  void minimum_image(double *delta) const;
  // The first active grab, or null.
  const AtomifyGrab *first_grab() const;
  // Index of the owned atom with this tag, or -1.
  int local_index(int64_t tag) const;
};

}    // namespace LAMMPS_NS

#endif
#endif
