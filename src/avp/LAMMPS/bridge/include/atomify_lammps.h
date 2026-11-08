// C interface between the Atomify visionOS app and LAMMPS.
//
// One atomify_sim owns one LAMMPS instance. Script execution
// (atomify_sim_run_file / atomify_sim_command) blocks and is meant to run on
// a dedicated simulation thread. Everything else is thread safe and may be
// called from the render or UI thread while a run is in progress.
//
// Atoms are always identified by their LAMMPS atom ID (tag). Local indices
// change whenever LAMMPS re-sorts or migrates atoms, so snapshots are
// published sorted by tag and bonds refer to positions in that sorted order.

#ifndef ATOMIFY_LAMMPS_H
#define ATOMIFY_LAMMPS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct atomify_sim atomify_sim;

typedef enum {
  ATOMIFY_OK = 0,
  ATOMIFY_ERROR = 1,
  ATOMIFY_CANCELLED = 2
} atomify_status;

typedef struct {
  uint64_t sequence;        // increases by one for every published snapshot
  int64_t timestep;
  double time;              // simulation time in LAMMPS time units
  int32_t natoms;
  int32_t ntypes;
  int32_t nbonds;
  int32_t dimension;
  int32_t periodic[3];
  int32_t triclinic;
  int32_t minimizing;       // 1 while a minimization is running
  char units[16];           // LAMMPS unit style: "lj", "metal", "real", ...
  double box_lo[3];         // axis aligned bounds (bounding box if triclinic)
  double box_hi[3];
  double temperature;       // from kinetic energy, in LAMMPS temperature units
  double kinetic_energy;    // in LAMMPS energy units
  double potential_energy;  // total, in LAMMPS energy units; valid if has_potential_energy
  int32_t has_potential_energy;
  int32_t frozen;           // 1 while atomify_sim_set_frozen is on
  int64_t grab_tag;         // atom being pulled (the first held, of two), or 0
  double grab_force[3];     // force from the other atoms on the grabbed atom (frozen only)
  double steps_per_second;  // measured wall clock rate
  const int64_t *tags;      // natoms, sorted ascending
  const int32_t *types;     // natoms, 1-based LAMMPS atom types
  const float *positions;   // 3 * natoms, xyz, wrapped into the periodic box
  const float *radii;       // natoms per-atom radii (atom_style sphere), else NULL
  const uint32_t *bonds;    // 2 * nbonds, index pairs into the arrays above
} atomify_snapshot;

// Soft repulsive sphere in simulation coordinates, e.g. part of a hand.
// Every integration/minimization step adds strength * (1 - r / radius)
// outwards inside the radius. Overlapping spheres share a per-atom total
// force budget equal to the largest supplied strength (LAMMPS force units).
// No atom position or velocity is overwritten. Centres interpolate between
// equal-sized updates; hand speed is never converted to molecular velocity.
typedef struct {
  double center[3];
  double radius;
  double strength;
} atomify_force_sphere;

// Lifecycle. echo != 0 lets LAMMPS print to stdout (useful when debugging).
atomify_sim *atomify_sim_create(int echo);
void atomify_sim_destroy(atomify_sim *sim);

// Blocking script execution. Relative paths in the script resolve against
// the process working directory, so change it to the script's folder first.
atomify_status atomify_sim_run_file(atomify_sim *sim, const char *path);
atomify_status atomify_sim_command(atomify_sim *sim, const char *command);
// Message of the last failed call, or "" (owned by sim, valid until the next
// blocking call).
const char *atomify_sim_last_error(atomify_sim *sim);

// Run control. Cancelling makes the running script return ATOMIFY_CANCELLED
// at its next timestep; the instance should then be destroyed.
void atomify_sim_set_paused(atomify_sim *sim, int paused);
void atomify_sim_cancel(atomify_sim *sim);
// Seconds since the engine last completed a step (or was created).
double atomify_sim_seconds_since_progress(atomify_sim *sim);
void atomify_sim_set_max_steps_per_second(atomify_sim *sim, double steps); // <= 0: unlimited
void atomify_sim_set_publish_interval(atomify_sim *sim, double seconds);

// Bonds. Topology bonds come from the LAMMPS bond list (molecular systems).
// Distance bonds connect atoms of the given types closer than cutoff.
void atomify_sim_set_topology_bonds(atomify_sim *sim, int enabled);
void atomify_sim_set_bond_cutoff(atomify_sim *sim, int type1, int type2, double cutoff);
void atomify_sim_clear_bond_cutoffs(atomify_sim *sim);

// Interaction forces, applied every timestep until replaced.
void atomify_sim_set_force_spheres(atomify_sim *sim, const atomify_force_sphere *spheres, int count);
// Pull the atom with this tag towards target with a damped spring (force
// units per distance unit). tag <= 0 releases.
void atomify_sim_set_grab(atomify_sim *sim, int64_t tag, const double target[3], double stiffness);
// The same for one of two grabs (slot 0 or 1, one per hand), so two atoms
// can be held at once. atomify_sim_set_grab is slot 0.
void atomify_sim_set_grab_slot(atomify_sim *sim, int slot, int64_t tag, const double target[3],
                               double stiffness);

// Freeze: atoms stay where they are (a grabbed atom moves to its target)
// while forces keep being evaluated, so grab_force shows the force on the
// grabbed atom. Timesteps still advance. Velocities are zero after unfreezing.
void atomify_sim_set_frozen(atomify_sim *sim, int frozen);

// Walls from a distance field, e.g. a room mesh: distances[(k * ny + j) * nx + i]
// is the distance (simulation length units) from grid point
// origin + spacing * (i, j, k) to the nearest surface. Atoms closer than
// cutoff are pushed away from the surface with strength * (1 - d / cutoff).
// distances == NULL removes the walls. The data is copied.
void atomify_sim_set_wall_grid(atomify_sim *sim, const double origin[3], double spacing,
                               const int32_t dims[3], const float *distances, double cutoff,
                               double strength);

// Latest snapshot. Returns 1 and fills out if one has been published; the
// arrays stay valid until atomify_sim_snapshot_unlock, which must then be
// called exactly once. Returns 0 (and holds no lock) before the first one. Keep the lock short:
// the simulation thread waits for it when publishing.
int atomify_sim_snapshot_lock(atomify_sim *sim, atomify_snapshot *out);
void atomify_sim_snapshot_unlock(atomify_sim *sim);

#ifdef __cplusplus
}
#endif

#endif
