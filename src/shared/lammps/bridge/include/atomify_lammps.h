// C interface between the Atomify apps and LAMMPS.
//
// This header is the only public interface of the CLammps library.
//
// One atomify_sim owns one LAMMPS instance. Script execution
// (atomify_sim_run_file, atomify_sim_command, atomify_sim_execute_queued,
// atomify_sim_publish) blocks and must run on one dedicated simulation
// thread. Everything else is thread safe and may be called from the render
// or UI thread while a run is in progress.
//
// Atoms are always identified by their LAMMPS atom ID (tag). Local indices
// change whenever LAMMPS re-sorts or migrates atoms, so snapshots are
// published sorted by tag and bonds and per-atom values refer to positions
// in that sorted order.
//
// LAMMPS is GPLv2; anything linking this library is GPL.

#ifndef ATOMIFY_LAMMPS_H
#define ATOMIFY_LAMMPS_H

#include <stddef.h>
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

// What an observable is.
typedef enum {
  ATOMIFY_OBSERVABLE_THERMO = 0,     // a keyword of the last thermo output line
  ATOMIFY_OBSERVABLE_COMPUTE = 1,
  ATOMIFY_OBSERVABLE_FIX = 2,
  ATOMIFY_OBSERVABLE_VARIABLE = 3
} atomify_observable_kind;

// A compute, fix, variable or thermo keyword and its current global values.
// Values are only ever read where LAMMPS has them available: computes are
// invoked on steps where the energy and virial they need were tallied (the
// bridge requests such steps at the observable interval), fixes and
// variables are evaluated on those steps, and errors raised while evaluating
// are swallowed (the observable then has no value). Thermo keywords come from
// the last thermo output line.
typedef struct {
  int32_t kind;                // atomify_observable_kind
  const char *name;            // compute/fix ID, variable name or thermo keyword
  const char *style;           // compute/fix style ("msd"), variable style ("equal"); "" for thermo
  int64_t timestep;            // step the values were computed on; -1 if never
  double time;                 // simulation time at that step
  int32_t has_scalar;          // 1 if `scalar` holds a value
  double scalar;
  int32_t vector_length;       // global vector values in `vector` (0 if none)
  const double *vector;
  int32_t array_rows;          // global array, row major in `array` (0 if none)
  int32_t array_columns;
  const double *array;
  int32_t has_per_atom;        // 1 if it provides per-atom values (c_ID, f_ID, v_name)
  int32_t per_atom_columns;    // 0: a per-atom vector; N: per-atom array with N columns
} atomify_observable;

// What LAMMPS is doing (update->whichflag).
typedef enum {
  ATOMIFY_RUN_IDLE = 0,       // between commands
  ATOMIFY_RUN_DYNAMICS = 1,   // a run
  ATOMIFY_RUN_MINIMIZE = 2    // a minimization
} atomify_run_mode;

// A plane of a `fix wall/*` (lj93, lj126, lj1043, harmonic, morse, colloid,
// table, ...) at a fixed position: on a box face (EDGE) or at a constant
// coordinate. Walls whose position is a variable are not listed.
typedef struct {
  int32_t face;       // 0 xlo, 1 xhi, 2 ylo, 3 yhi, 4 zlo, 5 zhi: axis = face / 2
  double position;    // coordinate along that axis
} atomify_wall;

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
  double box_lo[3];         // box origin; for triclinic boxes the restricted triclinic lo
  double box_hi[3];         // lo + (xprd, yprd, zprd)
  double tilt[3];           // xy, xz, yz tilt factors; zero for orthogonal boxes
  double bounds_lo[3];      // axis aligned bounding box (equal to box_lo/hi if orthogonal)
  double bounds_hi[3];
  double temperature;       // from kinetic energy, in LAMMPS temperature units
  double kinetic_energy;    // in LAMMPS energy units
  double potential_energy;  // total, in LAMMPS energy units; valid if has_potential_energy
  int32_t has_potential_energy;
  int32_t frozen;           // 1 while atomify_sim_set_frozen is on
  int64_t grab_tag;         // atom being pulled (the first held, of two), or 0
  double grab_force[3];     // force from the other atoms on the grabbed atom (frozen only)
  double steps_per_second;  // measured wall clock rate

  // Run status, as lammps.js reports it. The step counts cover the whole
  // `run N` (or minimization) even when queued commands split it up.
  int32_t run_mode;          // atomify_run_mode
  int64_t run_step;          // steps done in the current run; 0 when idle
  int64_t run_steps;         // steps the current run will take; 0 when idle
  const char *input_line;    // the input line LAMMPS is executing (e.g. "run 10000")
  const int64_t *tags;      // natoms, sorted ascending
  const int32_t *types;     // natoms, 1-based LAMMPS atom types
  const float *positions;   // 3 * natoms, xyz, wrapped into the periodic box
  const float *radii;       // natoms per-atom radii (atom_style sphere), else NULL
  const uint32_t *bonds;    // 2 * nbonds, index pairs into the arrays above

  // The quantity chosen with atomify_sim_set_per_atom_quantity.
  const char *per_atom_name;    // "" when none is chosen
  const char *per_atom_error;   // "" or why the quantity has no values
  const float *per_atom_values; // natoms values (NaN where unknown), or NULL

  // Observables, as of observables_timestep (the last sampled step).
  int64_t observables_timestep;
  int32_t nobservables;
  const atomify_observable *observables;

  // Planes of fix wall/* commands, in fix order.
  int32_t nwalls;
  const atomify_wall *walls;
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

// Lifecycle. echo != 0 also copies LAMMPS output to stdout (debugging).
atomify_sim *atomify_sim_create(int echo);
void atomify_sim_destroy(atomify_sim *sim);

// Blocking script execution. Relative paths in the script resolve against
// the process working directory, so change it to the script's folder first.
atomify_status atomify_sim_run_file(atomify_sim *sim, const char *path);
atomify_status atomify_sim_command(atomify_sim *sim, const char *command);
// Message of the last failed call, or "" (owned by sim, valid until the next
// blocking call).
const char *atomify_sim_last_error(atomify_sim *sim);
// The input line that failed call was executing (for errors during a run,
// the run command), or "". Same lifetime as atomify_sim_last_error.
const char *atomify_sim_last_error_line(atomify_sim *sim);

// Command queue. Any thread may queue commands (one per line; a string with
// newlines queues several). During a run, fix atomify stops integrating at
// the next step boundary, executes them, re-initializes LAMMPS and continues
// the same run for its remaining steps, as `run N every M "command"` does.
// This also happens while the run is paused. Commands that would start or
// leave a run (run, minimize, rerun, clear, include, jump, label, quit,
// read_restart, write_restart) are rejected there, as is touching fix
// atomify. Outside runs the simulation thread executes them with
// atomify_sim_execute_queued. Failures are written to the output.
void atomify_sim_enqueue_command(atomify_sim *sim, const char *command);
int atomify_sim_queued_command_count(atomify_sim *sim);
// Simulation thread, outside runs: executes all queued commands. Returns
// ATOMIFY_ERROR (with atomify_sim_last_error) if any of them failed.
atomify_status atomify_sim_execute_queued(atomify_sim *sim);
// Blocks up to timeout seconds until a command is queued or the simulation
// is cancelled. Returns 1 if commands are queued (and not cancelled).
int atomify_sim_wait_for_commands(atomify_sim *sim, double timeout);

// Simulation thread, outside runs: publishes a snapshot of the current state
// (e.g. after a script without a final run, or after queued commands).
// Computes are not invoked here; observables keep their last values.
// Returns 1 if a snapshot was published (the box must exist).
int atomify_sim_publish(atomify_sim *sim);

// LAMMPS screen output (thermo lines, warnings, errors, print commands).
// Copies up to capacity bytes of not yet read output into buffer, removes
// them, and returns the number copied. Not NUL terminated. Holds at most
// the last 4 MB.
size_t atomify_sim_read_output(atomify_sim *sim, char *buffer, size_t capacity);

// Run control. Cancelling makes the running script return ATOMIFY_CANCELLED
// at its next timestep; the instance should then be destroyed.
void atomify_sim_set_paused(atomify_sim *sim, int paused);
void atomify_sim_cancel(atomify_sim *sim);
int atomify_sim_is_cancelled(atomify_sim *sim);
// Seconds since the engine last completed a step (or was created).
double atomify_sim_seconds_since_progress(atomify_sim *sim);
void atomify_sim_set_max_steps_per_second(atomify_sim *sim, double steps); // <= 0: unlimited
void atomify_sim_set_publish_interval(atomify_sim *sim, double seconds);
// How often observables are sampled (wall clock); <= 0 samples for every
// published snapshot. Each sample makes LAMMPS tally energy and virial on
// one step. Default 0.05 s.
void atomify_sim_set_observable_interval(atomify_sim *sim, double seconds);

// The per-atom quantity published with each snapshot, e.g. for coloring:
// "vx", "vy", "vz", "fx", "fy", "fz", "speed", "q", "mass", "type",
// "c_ID", "c_ID[n]", "f_ID", "f_ID[n]" or "v_name" (atom-style variable).
// NULL or "" publishes none. Computes that need energy or virial are
// evaluated on sampled steps; in between atoms keep their last value.
void atomify_sim_set_per_atom_quantity(atomify_sim *sim, const char *name);

// Bonds. Topology bonds come from the LAMMPS bond list (molecular systems).
// Distance bonds connect atoms of the given types closer than cutoff.
void atomify_sim_set_topology_bonds(atomify_sim *sim, int enabled);
void atomify_sim_set_bond_cutoff(atomify_sim *sim, int type1, int type2, double cutoff);
void atomify_sim_clear_bond_cutoffs(atomify_sim *sim);

// Interaction forces, applied every timestep until replaced. Hand input
// (spheres and grabs) that is not refreshed for 0.35 s is released.
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
// arrays and strings stay valid until atomify_sim_snapshot_unlock, which
// must then be called exactly once. Returns 0 (and holds no lock) before the
// first one. Keep the lock short: the simulation thread waits for it when
// publishing.
int atomify_sim_snapshot_lock(atomify_sim *sim, atomify_snapshot *out);
void atomify_sim_snapshot_unlock(atomify_sim *sim);

#ifdef __cplusplus
}
#endif

#endif
