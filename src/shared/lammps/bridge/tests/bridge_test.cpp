// Host tests for the Atomify LAMMPS bridge. Built and run by build-host.sh.

#include "atomify_lammps.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <thread>
#include <vector>

namespace {

int failures = 0;

#define CHECK(condition)                                                              \
  do {                                                                                \
    if (!(condition)) {                                                               \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition); \
      failures++;                                                                     \
    }                                                                                 \
  } while (0)

struct Observable {
  int kind = -1;
  std::string name, style;
  int64_t timestep = -1;
  double time = 0;
  bool has_scalar = false;
  double scalar = 0;
  std::vector<double> vector;
  int rows = 0, columns = 0;
  std::vector<double> array;
  bool has_per_atom = false;
  int per_atom_columns = 0;
};

struct Snapshot {
  uint64_t sequence = 0;
  int64_t timestep = 0;
  double temperature = 0;
  std::string units;
  double box_lo[3] = {0, 0, 0}, box_hi[3] = {0, 0, 0};
  double tilt[3] = {0, 0, 0}, bounds_lo[3] = {0, 0, 0}, bounds_hi[3] = {0, 0, 0};
  int triclinic = 0;
  double kinetic_energy = 0;
  std::string per_atom_name, per_atom_error;
  std::vector<float> per_atom_values;
  bool has_per_atom_values = false;
  int64_t observables_timestep = -1;
  std::vector<Observable> observables;
  std::vector<int64_t> tags;
  std::vector<int32_t> types;
  std::vector<float> positions;
  std::vector<uint32_t> bonds;
  std::vector<float> radii;
  double potential_energy = 0;
  bool has_potential_energy = false;
  bool frozen = false;
  int64_t grab_tag = 0;
  double grab_force[3] = {0, 0, 0};
  int run_mode = -1;
  int64_t run_step = -1, run_steps = -1;
  std::string input_line;
  std::vector<std::pair<int, double>> walls;
  bool valid = false;

  const Observable *find(int kind, const std::string &name) const
  {
    for (const auto &o : observables)
      if (o.kind == kind && o.name == name) return &o;
    return nullptr;
  }
};

Snapshot copy(atomify_sim *sim)
{
  Snapshot s;
  atomify_snapshot raw;
  if (!atomify_sim_snapshot_lock(sim, &raw)) return s;
  s.valid = true;
  s.sequence = raw.sequence;
  s.timestep = raw.timestep;
  s.temperature = raw.temperature;
  s.units = raw.units;
  for (int k = 0; k < 3; k++) {
    s.box_lo[k] = raw.box_lo[k];
    s.box_hi[k] = raw.box_hi[k];
    s.tilt[k] = raw.tilt[k];
    s.bounds_lo[k] = raw.bounds_lo[k];
    s.bounds_hi[k] = raw.bounds_hi[k];
  }
  s.triclinic = raw.triclinic;
  s.kinetic_energy = raw.kinetic_energy;
  s.per_atom_name = raw.per_atom_name;
  s.per_atom_error = raw.per_atom_error;
  s.has_per_atom_values = raw.per_atom_values != nullptr;
  if (raw.per_atom_values) s.per_atom_values.assign(raw.per_atom_values, raw.per_atom_values + raw.natoms);
  s.observables_timestep = raw.observables_timestep;
  for (int i = 0; i < raw.nobservables; i++) {
    const atomify_observable &o = raw.observables[i];
    Observable copy;
    copy.kind = o.kind;
    copy.name = o.name;
    copy.style = o.style;
    copy.timestep = o.timestep;
    copy.time = o.time;
    copy.has_scalar = o.has_scalar;
    copy.scalar = o.scalar;
    if (o.vector) copy.vector.assign(o.vector, o.vector + o.vector_length);
    copy.rows = o.array_rows;
    copy.columns = o.array_columns;
    if (o.array) copy.array.assign(o.array, o.array + o.array_rows * o.array_columns);
    copy.has_per_atom = o.has_per_atom;
    copy.per_atom_columns = o.per_atom_columns;
    s.observables.push_back(copy);
  }
  s.tags.assign(raw.tags, raw.tags + raw.natoms);
  s.types.assign(raw.types, raw.types + raw.natoms);
  s.positions.assign(raw.positions, raw.positions + 3 * raw.natoms);
  s.bonds.assign(raw.bonds, raw.bonds + 2 * raw.nbonds);
  if (raw.radii) s.radii.assign(raw.radii, raw.radii + raw.natoms);
  s.potential_energy = raw.potential_energy;
  s.has_potential_energy = raw.has_potential_energy;
  s.frozen = raw.frozen;
  s.grab_tag = raw.grab_tag;
  for (int k = 0; k < 3; k++) s.grab_force[k] = raw.grab_force[k];
  s.run_mode = raw.run_mode;
  s.run_step = raw.run_step;
  s.run_steps = raw.run_steps;
  s.input_line = raw.input_line;
  for (int i = 0; i < raw.nwalls; i++) s.walls.emplace_back(raw.walls[i].face, raw.walls[i].position);
  atomify_sim_snapshot_unlock(sim);
  return s;
}

bool run(atomify_sim *sim, const std::vector<std::string> &commands)
{
  for (const auto &command : commands) {
    if (atomify_sim_command(sim, command.c_str()) != ATOMIFY_OK) {
      std::fprintf(stderr, "command '%s' failed: %s\n", command.c_str(), atomify_sim_last_error(sim));
      return false;
    }
  }
  return true;
}

const std::vector<std::string> lj_melt = {
    "units lj",
    "atom_style atomic",
    "lattice fcc 0.8442",
    "region box block 0 4 0 4 0 4",
    "create_box 2 box",
    "create_atoms 1 box",
    "mass * 1.0",
    "region half block 0 2 INF INF INF INF",
    "set region half type 2",
    "velocity all create 3.0 87287 loop geom",
    "pair_style lj/cut 2.5",
    "pair_coeff * * 1.0 1.0 2.5",
    "neighbor 0.3 bin",
    "atom_modify sort 1 0.5",    // re-sort local atoms every step
    "fix 1 all nve",
};

std::string read_all_output(atomify_sim *sim)
{
  std::string text;
  char buffer[7];    // small on purpose: output is drained in pieces
  for (size_t n; (n = atomify_sim_read_output(sim, buffer, sizeof(buffer))) > 0;) text.append(buffer, n);
  return text;
}

template <typename Predicate> bool wait_until(Predicate predicate, double seconds = 5.0)
{
  const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
  while (std::chrono::steady_clock::now() < end) {
    if (predicate()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return predicate();
}

bool contains(const std::string &text, const std::string &part)
{
  return text.find(part) != std::string::npos;
}

void test_snapshot_is_sorted_by_tag()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(sim != nullptr);
  CHECK(!copy(sim).valid);
  CHECK(run(sim, lj_melt));
  CHECK(run(sim, {"run 0"}));
  const Snapshot first = copy(sim);
  CHECK(first.valid);
  CHECK(first.tags.size() == 256);
  CHECK(first.units == "lj");

  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 50"}));
  const Snapshot later = copy(sim);
  CHECK(later.sequence > first.sequence);
  CHECK(later.timestep == 50);
  CHECK(later.temperature > 0.5);
  CHECK(later.tags.size() == 256);

  std::map<int64_t, int> type_of;
  for (size_t n = 0; n < first.tags.size(); n++) type_of[first.tags[n]] = first.types[n];
  for (size_t n = 0; n < later.tags.size(); n++) {
    CHECK(later.tags[n] == static_cast<int64_t>(n + 1));
    CHECK(type_of[later.tags[n]] == later.types[n]);
    for (int k = 0; k < 3; k++) {
      const float p = later.positions[3 * n + k];
      CHECK(p >= later.box_lo[k] && p <= later.box_hi[k]);
    }
  }
  atomify_sim_destroy(sim);
}

void test_distance_bonds()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  const double cutoff = 1.2;    // fcc nearest neighbor distance at 0.8442 is ~1.12
  atomify_sim_set_bond_cutoff(sim, 1, 1, cutoff);
  CHECK(run(sim, {"run 0"}));
  Snapshot s = copy(sim);
  CHECK(!s.bonds.empty());
  size_t type11 = 0;
  for (size_t b = 0; b < s.bonds.size(); b += 2) {
    const uint32_t i = s.bonds[b], j = s.bonds[b + 1];
    CHECK(i < s.tags.size() && j < s.tags.size() && i != j);
    double rsq = 0;
    for (int k = 0; k < 3; k++) {
      const double d = s.positions[3 * i + k] - s.positions[3 * j + k];
      rsq += d * d;
    }
    CHECK(rsq < cutoff * cutoff);
    CHECK(s.types[i] == 1 && s.types[j] == 1);
    type11++;
  }
  CHECK(type11 > 100);

  atomify_sim_clear_bond_cutoffs(sim);
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 1"}));
  CHECK(copy(sim).bonds.empty());
  atomify_sim_destroy(sim);
}

void test_topology_bonds()
{
  const char *path = "/tmp/atomify_bridge_test.data";
  {
    std::ofstream data(path);
    data << "bonded pair\n\n3 atoms\n1 bonds\n2 atom types\n1 bond types\n\n"
            "0 10 xlo xhi\n0 10 ylo yhi\n0 10 zlo zhi\n\n"
            "Masses\n\n1 1.0\n2 1.0\n\n"
            "Atoms # bond\n\n7 1 1 5 5 5\n3 1 2 6 5 5\n5 2 1 2 2 2\n\n"
            "Bonds\n\n1 1 7 3\n";
  }
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, {"units lj", "atom_style bond", "bond_style harmonic",
                  std::string("read_data ") + path, "bond_coeff 1 100.0 1.0", "pair_style zero 2.0",
                  "pair_coeff * *", "fix 1 all nve", "run 0"}));
  Snapshot s = copy(sim);
  CHECK(s.tags == (std::vector<int64_t>{3, 5, 7}));
  CHECK(s.bonds.size() == 2);
  if (s.bonds.size() == 2) {
    const int64_t a = s.tags[s.bonds[0]], b = s.tags[s.bonds[1]];
    CHECK((a == 7 && b == 3) || (a == 3 && b == 7));
  }
  atomify_sim_set_topology_bonds(sim, 0);
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 1"}));
  CHECK(copy(sim).bonds.empty());
  atomify_sim_destroy(sim);
  std::remove(path);
}

const std::vector<std::string> single_atom = {
    "units lj", "atom_style atomic", "region box block -10 10 -10 10 -10 10",
    "create_box 1 box", "create_atoms 1 single 0 0 0", "mass 1 1.0",
    "pair_style zero 1.0", "pair_coeff * *", "fix 1 all nve",
};

void test_force_sphere_pushes_atom()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  atomify_force_sphere sphere = {{-0.5, 0, 0}, 1.0, 10.0};
  atomify_sim_set_force_spheres(sim, &sphere, 1);
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 100"}));
  Snapshot s = copy(sim);
  CHECK(s.positions.size() == 3 && s.positions[0] > 0.4f);
  CHECK(std::fabs(s.positions[1]) < 1e-5f && std::fabs(s.positions[2]) < 1e-5f);
  atomify_sim_destroy(sim);
}

void test_moving_sphere_sweeps_atom_along()
{
  // Interpolated contact pushes the atom without teleporting it to the
  // collider surface or imposing the collider's apparent integration speed.
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  atomify_sim_set_publish_interval(sim, 0);
  atomify_force_sphere sphere = {{-3, 0, 0}, 1.0, 10.0};
  atomify_sim_set_force_spheres(sim, &sphere, 1);
  CHECK(run(sim, {"run 100"}));
  sphere.center[0] = 3;
  atomify_sim_set_force_spheres(sim, &sphere, 1);
  CHECK(run(sim, {"run 100"}));
  Snapshot s = copy(sim);
  CHECK(s.positions.size() == 3 && s.positions[0] > 0.01f && s.positions[0] < 3.0f);
  atomify_sim_destroy(sim);
}

void test_contact_has_one_force_budget_for_overlapping_fingers()
{
  for (int count : {1, 6, 24}) {
    atomify_sim *sim = atomify_sim_create(0);
    CHECK(run(sim, single_atom));
    atomify_sim_set_publish_interval(sim, 0);
    // Exactly centred contact used to project x by an entire radius.
    std::vector<atomify_force_sphere> fingers(count, {{0, 0, 0}, 1.0, 2.0});
    atomify_sim_set_force_spheres(sim, fingers.data(), count);
    CHECK(run(sim, {"timestep 0.01", "run 1"}));
    const auto s = copy(sim);
    // x = 1/2 F/m dt²; contacts sum to <=2, independent of finger count.
    CHECK(s.positions.size() == 3 && std::fabs(s.positions[0] - 0.0001) < 1e-7);
    atomify_sim_set_force_spheres(sim, nullptr, 0);
    CHECK(run(sim, {"run 1"}));
    const auto released = copy(sim);
    CHECK(released.positions[0] >= s.positions[0] && released.positions[0] < 0.001);
    atomify_sim_destroy(sim);
  }
}

void test_grab_pulls_atom_by_tag()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  const double target[3] = {2, -1, 3};
  atomify_sim_set_grab(sim, 1, target, 50.0);
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 2000"}));
  Snapshot s = copy(sim);
  for (int k = 0; k < 3; k++) CHECK(std::fabs(s.positions[k] - target[k]) < 0.05);
  atomify_sim_destroy(sim);
}

void test_two_grabs_hold_two_atoms()
{
  atomify_sim *sim = atomify_sim_create(0);
  std::vector<std::string> two_atoms = single_atom;
  two_atoms.insert(two_atoms.begin() + 5, "create_atoms 1 single 1 0 0");
  CHECK(run(sim, two_atoms));
  const double left[3] = {-3, 1, 0}, right[3] = {4, -2, 1};
  atomify_sim_set_grab_slot(sim, 0, 1, left, 50.0);
  atomify_sim_set_grab_slot(sim, 1, 2, right, 50.0);
  atomify_sim_set_grab_slot(sim, 2, 1, right, 50.0);    // no third hand: ignored
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 2000"}));
  Snapshot s = copy(sim);
  CHECK(s.positions.size() == 6 && s.grab_tag == 1);
  for (int k = 0; k < 3; k++) {
    CHECK(std::fabs(s.positions[k] - left[k]) < 0.05);
    CHECK(std::fabs(s.positions[3 + k] - right[k]) < 0.05);
  }
  // Letting go of the first leaves the second reported.
  atomify_sim_set_grab_slot(sim, 0, 0, nullptr, 0);
  CHECK(run(sim, {"run 1"}));
  CHECK(copy(sim).grab_tag == 2);
  atomify_sim_destroy(sim);
}

void test_pause_and_cancel()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  atomify_sim_set_publish_interval(sim, 0);
  std::atomic<int> status{-1};
  std::thread worker([&] { status = atomify_sim_command(sim, "run 100000000"); });

  auto wait_for_steps = [&] {
    for (int i = 0; i < 200; i++) {
      if (copy(sim).timestep > 10) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
  };
  CHECK(wait_for_steps());
  atomify_sim_set_paused(sim, 1);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  const int64_t paused_at = copy(sim).timestep;
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  CHECK(copy(sim).timestep == paused_at);
  atomify_sim_set_paused(sim, 0);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  CHECK(copy(sim).timestep > paused_at);

  atomify_sim_set_paused(sim, 1);
  atomify_sim_cancel(sim);    // must also wake a paused run
  worker.join();
  CHECK(status == ATOMIFY_CANCELLED);
  atomify_sim_destroy(sim);
}

void test_per_atom_radii()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, {"units lj", "atom_style sphere", "region box block -5 5 -5 5 -5 5", "create_box 1 box",
                  "create_atoms 1 single 0 0 0", "create_atoms 1 single 2 0 0", "set atom 2 diameter 0.5",
                  "pair_style zero 1.0", "pair_coeff * *", "fix 1 all nve/sphere", "run 0"}));
  Snapshot s = copy(sim);
  CHECK(s.radii.size() == 2);
  if (s.radii.size() == 2) CHECK(s.radii[0] == 0.5f && s.radii[1] == 0.25f);
  atomify_sim_destroy(sim);

  sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  CHECK(run(sim, {"run 0"}));
  CHECK(copy(sim).radii.empty());
  atomify_sim_destroy(sim);
}

void test_potential_energy()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  atomify_sim_set_max_steps_per_second(sim, 1000);    // let wall clock energy requests happen
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 400"}));
  Snapshot s = copy(sim);
  CHECK(s.has_potential_energy);
  // Dense LJ liquid: roughly -5 epsilon per atom.
  CHECK(s.potential_energy < -1.0 * 256 && s.potential_energy > -8.0 * 256);
  atomify_sim_destroy(sim);
}

void test_freeze_holds_atoms_and_reports_grab_force()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 20"}));
  atomify_sim_set_frozen(sim, 1);
  CHECK(run(sim, {"run 2"}));
  const Snapshot before = copy(sim);
  CHECK(before.frozen);
  CHECK(run(sim, {"run 30"}));
  const Snapshot after = copy(sim);
  CHECK(after.timestep == before.timestep + 30);
  CHECK(after.positions == before.positions);
  CHECK(after.temperature < 1e-12);

  // Move atom 10 by half a lattice spacing; the force on it is reported.
  const size_t n = 9;    // tag 10
  const double target[3] = {before.positions[3 * n] + 0.35, before.positions[3 * n + 1],
                            before.positions[3 * n + 2]};
  atomify_sim_set_grab(sim, 10, target, 1.0);
  CHECK(run(sim, {"run 2"}));
  Snapshot moved = copy(sim);
  CHECK(std::fabs(moved.positions[3 * n] - target[0]) < 1e-4);
  CHECK(moved.grab_tag == 10);
  const double force = std::sqrt(moved.grab_force[0] * moved.grab_force[0] +
                                 moved.grab_force[1] * moved.grab_force[1] +
                                 moved.grab_force[2] * moved.grab_force[2]);
  CHECK(force > 1.0);
  CHECK(moved.grab_force[0] < 0.0);    // pushed back towards where it came from
  for (size_t m = 0; m < moved.tags.size(); m++)
    if (m != n) CHECK(moved.positions[3 * m] == before.positions[3 * m]);

  atomify_sim_set_grab(sim, 0, nullptr, 0);
  atomify_sim_set_frozen(sim, 0);
  CHECK(run(sim, {"run 20"}));
  Snapshot thawed = copy(sim);
  CHECK(!thawed.frozen);
  CHECK(thawed.positions != moved.positions);
  atomify_sim_destroy(sim);
}

void test_wall_grid_repels_atoms()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, {"units lj", "atom_style atomic", "boundary f f f", "region box block -10 10 -10 10 -10 10",
                  "create_box 1 box", "create_atoms 1 single 1 0 0", "mass 1 1.0", "pair_style zero 1.0",
                  "pair_coeff * *", "velocity all set -2 0 0", "fix 1 all nve"}));
  // A wall at x = 0: distance |x| on a grid covering [-5, 5]^3.
  const int nx = 21, ny = 21, nz = 21;
  const double origin[3] = {-5, -5, -5}, spacing = 0.5;
  const int32_t dims[3] = {nx, ny, nz};
  std::vector<float> distances(nx * ny * nz);
  for (int k = 0; k < nz; k++)
    for (int j = 0; j < ny; j++)
      for (int i = 0; i < nx; i++) distances[(k * ny + j) * nx + i] = std::fabs(origin[0] + spacing * i);
  atomify_sim_set_wall_grid(sim, origin, spacing, dims, distances.data(), 0.8, 200.0);
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 600"}));
  Snapshot s = copy(sim);
  CHECK(s.positions[0] > 0.2f);    // bounced back instead of crossing x = 0

  atomify_sim_set_wall_grid(sim, nullptr, 0, nullptr, nullptr, 0, 0);
  CHECK(run(sim, {"velocity all set -2 0 0", "run 1200"}));
  CHECK(copy(sim).positions[0] < -0.5f);    // walls removed
  atomify_sim_destroy(sim);
}

void test_throttle()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  atomify_sim_set_max_steps_per_second(sim, 200);
  const auto start = std::chrono::steady_clock::now();
  CHECK(run(sim, {"run 40"}));
  const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
  CHECK(elapsed > 0.15);
  atomify_sim_destroy(sim);
}

void test_errors_are_reported()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(atomify_sim_command(sim, "this_is_not_a_command") == ATOMIFY_ERROR);
  CHECK(std::string(atomify_sim_last_error(sim)).find("this_is_not_a_command") != std::string::npos);
  CHECK(std::string(atomify_sim_last_error_line(sim)) == "this_is_not_a_command");
  CHECK(atomify_sim_run_file(sim, "/nonexistent/in.script") == ATOMIFY_ERROR);
  CHECK(run(sim, {"units lj"}));
  CHECK(std::string(atomify_sim_last_error(sim)).empty());
  CHECK(std::string(atomify_sim_last_error_line(sim)).empty());
  atomify_sim_destroy(sim);
}

// Like lammps.js' getLastErrorInputLine: the line an error came from.
void test_error_input_line()
{
  atomify_sim *sim = atomify_sim_create(0);
  const char *path = "atomify_error_test.in";
  {
    std::ofstream script(path);
    script << "units lj\natom_style atomic\n# a comment\n\nlattice fcc 0.8442\n"
              "region box block 0 2 0 2 0 2\ncreate_box 1 box\n"
              "pair_style lj/cut   2.5   # with a comment\npair_coeff 1 1 1.0 1.0 2.5 extra junk\n"
              "run 10\n";
  }
  CHECK(atomify_sim_run_file(sim, path) == ATOMIFY_ERROR);
  CHECK(std::string(atomify_sim_last_error_line(sim)) == "pair_coeff 1 1 1.0 1.0 2.5 extra junk");
  std::remove(path);

  // An error that ends a run names the run, not a command queued during it.
  atomify_sim_destroy(sim);
  sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  atomify_sim_set_max_steps_per_second(sim, 2000);
  atomify_sim_set_publish_interval(sim, 0);
  std::atomic<int> status{-1};
  std::thread worker([&] { status = atomify_sim_command(sim, "run 100000000"); });
  CHECK(wait_until([&] { return copy(sim).timestep > 10; }));
  atomify_sim_enqueue_command(sim, "velocity all scale 1.1");
  CHECK(wait_until([&] { return atomify_sim_queued_command_count(sim) == 0; }));
  CHECK(wait_until([&] { return copy(sim).timestep > 30; }));
  CHECK(copy(sim).input_line == "run 100000000");    // still the run, not the queued command
  atomify_sim_cancel(sim);
  worker.join();
  CHECK(status == ATOMIFY_CANCELLED);
  CHECK(std::string(atomify_sim_last_error_line(sim)) == "run 100000000");
  atomify_sim_destroy(sim);

  // Queued commands outside runs report the command that failed.
  sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  atomify_sim_enqueue_command(sim, "variable a equal 1\nfix bad all nope\nvariable b equal 2");
  CHECK(atomify_sim_execute_queued(sim) == ATOMIFY_ERROR);
  CHECK(std::string(atomify_sim_last_error_line(sim)) == "fix bad all nope");
  atomify_sim_destroy(sim);
}

// Like lammps.js' getRunMode / getRunStepsDone / getRunStepsTotal.
void test_run_status()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  CHECK(run(sim, {"run 20"}));
  atomify_sim_set_publish_interval(sim, 0);
  atomify_sim_set_max_steps_per_second(sim, 1000);
  std::atomic<int> status{-1};
  std::thread worker([&] { status = atomify_sim_command(sim, "run 400"); });
  CHECK(wait_until([&] { return copy(sim).timestep > 60; }));
  Snapshot s = copy(sim);
  CHECK(s.run_mode == ATOMIFY_RUN_DYNAMICS);
  CHECK(s.run_steps == 400);
  CHECK(s.run_step == s.timestep - 20);
  CHECK(s.input_line == "run 400");
  // A queued command splits the run; the counts still cover all of it.
  atomify_sim_enqueue_command(sim, "velocity all scale 1.0");
  CHECK(wait_until([&] { return atomify_sim_queued_command_count(sim) == 0; }));
  CHECK(wait_until([&] { return copy(sim).timestep > s.timestep + 30; }));
  s = copy(sim);
  CHECK(s.run_mode == ATOMIFY_RUN_DYNAMICS);
  CHECK(s.run_steps == 400);
  CHECK(s.run_step == s.timestep - 20);
  worker.join();
  CHECK(status == ATOMIFY_OK);
  CHECK(atomify_sim_publish(sim) == 1);
  s = copy(sim);
  CHECK(s.run_mode == ATOMIFY_RUN_IDLE && s.run_step == 0 && s.run_steps == 0);
  CHECK(s.timestep == 420);
  atomify_sim_destroy(sim);
}

// Like lammps.js' getWalls: fix wall/* planes at fixed positions.
void test_walls()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, {"units lj", "atom_style atomic", "boundary f p f", "lattice fcc 0.8442",
                  "region box block 0 4 0 4 0 4", "create_box 1 box", "region inner block 0.5 3.5 0 4 0.5 3.5",
                  "create_atoms 1 region inner", "mass 1 1.0", "pair_style lj/cut 2.5",
                  "pair_coeff 1 1 1.0 1.0 2.5", "variable xw equal -2.0",
                  "fix w all wall/lj93 zlo EDGE 1.0 1.0 2.5 zhi 6.5 1.0 1.0 2.5 xlo v_xw 1.0 1.0 2.5 units box",
                  "fix r all wall/reflect xhi EDGE", "run 0"}));
  const Snapshot s = copy(sim);
  CHECK(s.walls.size() == 2);
  if (s.walls.size() == 2) {
    CHECK(s.walls[0].first == 4 && s.walls[0].second == s.box_lo[2]);
    CHECK(s.walls[1].first == 5 && s.walls[1].second == 6.5);
  }
  CHECK(run(sim, {"unfix w", "run 0"}));
  CHECK(copy(sim).walls.empty());
  atomify_sim_destroy(sim);
}

// lj/charmm/coul/charmm/inter comes from extra_src (as in lammps.js).
void test_extra_pair_style()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(atomify_sim_command(sim, "pair_style lj/charmm/coul/charmm/inter/nope 8.0 10.0") == ATOMIFY_ERROR);
  CHECK(contains(atomify_sim_last_error(sim), "Unrecognized pair style"));
  // Registered: whatever the arguments, LAMMPS does not call it unknown.
  atomify_sim_command(sim, "pair_style lj/charmm/coul/charmm/inter 8.0 10.0");
  CHECK(!contains(atomify_sim_last_error(sim), "Unrecognized pair style"));
  atomify_sim_destroy(sim);
}

void test_rejects_nonfinite_hand_input_and_preserves_last_good_frame()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  const double bad[3] = {NAN, 0, 0};
  atomify_sim_set_grab(sim, 1, bad, 50);
  atomify_force_sphere sphere = {{NAN, 0, 0}, 1, 10};
  atomify_sim_set_force_spheres(sim, &sphere, 1);
  atomify_sim_set_force_spheres(sim, nullptr, 0);
  CHECK(run(sim, {"run 0"}));
  const auto good = copy(sim);
  CHECK(good.valid && good.grab_tag == 0);
  CHECK(run(sim, {"velocity all set 1.0e200 0 0"}));
  CHECK(atomify_sim_command(sim, "run 0") == ATOMIFY_ERROR);
  CHECK(std::string(atomify_sim_last_error(sim)).find("nonfinite") != std::string::npos);
  CHECK(copy(sim).sequence == good.sequence);
  atomify_sim_destroy(sim);
}

void test_tracking_timeout_releases_grabs()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  const double target[3] = {1, 0, 0};
  atomify_sim_set_grab(sim, 1, target, 50);
  CHECK(run(sim, {"run 0"}));
  CHECK(copy(sim).grab_tag == 1);
  std::this_thread::sleep_for(std::chrono::milliseconds(400));
  CHECK(run(sim, {"run 0"}));
  CHECK(copy(sim).grab_tag == 0);
  CHECK(atomify_sim_seconds_since_progress(sim) >= 0);
  atomify_sim_destroy(sim);
}

void test_swept_room_collision_stops_a_fast_atom()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  CHECK(run(sim, {"set atom 1 x 1.0", "velocity all set -400 0 0", "timestep 0.005"}));
  const double origin[3] = {-4, -4, -4};
  const int32_t dims[3] = {17, 17, 17};
  std::vector<float> distances(17 * 17 * 17);
  // Offset wall: minimum lies halfway between grid nodes.
  for (int k = 0; k < 17; k++) for (int j = 0; j < 17; j++) for (int i = 0; i < 17; i++)
    distances[(k * 17 + j) * 17 + i] = std::fabs(-4.0 + 0.5 * i - 0.25);
  atomify_sim_set_wall_grid(sim, origin, 0.5, dims, distances.data(), 1.0, 0);
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 1"}));
  CHECK(copy(sim).positions[0] > 0.25f);
  CHECK(run(sim, {"run 1"}));
  CHECK(copy(sim).positions[0] > 0.25f);
  atomify_sim_destroy(sim);
}

void test_observables()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  CHECK(run(sim, {"compute msd all msd", "compute ke all ke/atom", "compute stress all stress/atom NULL",
                  "compute rdf all rdf 20", "fix ave all ave/time 10 1 10 c_thermo_temp",
                  "fix late all ave/time 1000 1 1000 c_thermo_temp", "variable t equal temp",
                  "variable e equal pe", "variable late equal f_late", "variable n index 7.5",
                  "variable label string hello", "variable xx atom x", "variable v vector [1,2,3]",
                  "thermo_style custom step temp pe c_msd[4]", "thermo 10"}));
  atomify_sim_set_publish_interval(sim, 0);
  atomify_sim_set_observable_interval(sim, 0);    // sample every step
  CHECK(run(sim, {"run 105"}));
  const Snapshot s = copy(sim);
  CHECK(s.observables_timestep == 105);

  const Observable *temp = s.find(ATOMIFY_OBSERVABLE_COMPUTE, "thermo_temp");
  CHECK(temp && temp->style == "temp" && temp->has_scalar && temp->timestep == 105);
  if (temp) {
    CHECK(std::fabs(temp->time - 105 * 0.005) < 1e-9);    // lj default timestep
    CHECK(std::fabs(temp->scalar - s.temperature) < 1e-9);
    CHECK(temp->vector.size() == 6);    // kinetic energy tensor
  }
  const Observable *thermo_pe = s.find(ATOMIFY_OBSERVABLE_THERMO, "pe");
  CHECK(thermo_pe && thermo_pe->has_scalar && thermo_pe->scalar < -1.0);
  const Observable *pe = s.find(ATOMIFY_OBSERVABLE_COMPUTE, "thermo_pe");
  CHECK(pe && pe->has_scalar && pe->scalar < -256.0 && pe->timestep == 105);
  const Observable *press = s.find(ATOMIFY_OBSERVABLE_COMPUTE, "thermo_press");
  CHECK(press && press->has_scalar && press->timestep == 105);
  const Observable *msd = s.find(ATOMIFY_OBSERVABLE_COMPUTE, "msd");
  CHECK(msd && msd->style == "msd" && msd->vector.size() == 4 && !msd->has_scalar);
  if (msd && msd->vector.size() == 4) CHECK(msd->vector[3] > 0.0);
  const Observable *rdf = s.find(ATOMIFY_OBSERVABLE_COMPUTE, "rdf");
  CHECK(rdf && rdf->rows == 20 && rdf->columns == 3 && rdf->array.size() == 60);
  const Observable *ke = s.find(ATOMIFY_OBSERVABLE_COMPUTE, "ke");
  CHECK(ke && ke->has_per_atom && ke->per_atom_columns == 0 && !ke->has_scalar);
  const Observable *stress = s.find(ATOMIFY_OBSERVABLE_COMPUTE, "stress");
  CHECK(stress && stress->has_per_atom && stress->per_atom_columns == 6);

  const Observable *ave = s.find(ATOMIFY_OBSERVABLE_FIX, "ave");
  CHECK(ave && ave->style == "ave/time" && ave->has_scalar && ave->scalar > 0.0);
  // Produced every 10 steps: reported on the step it was produced.
  CHECK(ave && ave->timestep == 100 && std::fabs(ave->time - 100 * 0.005) < 1e-9);
  CHECK(s.find(ATOMIFY_OBSERVABLE_FIX, "1") != nullptr);    // fix nve: listed, no values
  CHECK(s.find(ATOMIFY_OBSERVABLE_FIX, "__atomify") == nullptr);

  const Observable *t = s.find(ATOMIFY_OBSERVABLE_VARIABLE, "t");
  CHECK(t && t->style == "equal" && t->has_scalar && std::fabs(t->scalar - s.temperature) < 1e-9);
  const Observable *e = s.find(ATOMIFY_OBSERVABLE_VARIABLE, "e");
  CHECK(e && e->has_scalar && pe && std::fabs(e->scalar - pe->scalar / 256.0) < 1e-9);    // pe is normalized by atoms in lj
  const Observable *late = s.find(ATOMIFY_OBSERVABLE_VARIABLE, "late");
  CHECK(late && !late->has_scalar);    // fix not current: the error was swallowed
  const Observable *n = s.find(ATOMIFY_OBSERVABLE_VARIABLE, "n");
  CHECK(n && n->style == "index" && n->has_scalar && n->scalar == 7.5);
  const Observable *label = s.find(ATOMIFY_OBSERVABLE_VARIABLE, "label");
  CHECK(label && label->style == "string" && !label->has_scalar);
  const Observable *xx = s.find(ATOMIFY_OBSERVABLE_VARIABLE, "xx");
  CHECK(xx && xx->style == "atom" && xx->has_per_atom);
  const Observable *v = s.find(ATOMIFY_OBSERVABLE_VARIABLE, "v");
  CHECK(v && v->style == "vector" && v->vector == (std::vector<double>{1, 2, 3}));

  const Observable *step = s.find(ATOMIFY_OBSERVABLE_THERMO, "step");
  CHECK(step && step->has_scalar && step->scalar == 100 && step->timestep == 100);
  const Observable *msd4 = s.find(ATOMIFY_OBSERVABLE_THERMO, "c_msd[4]");
  CHECK(msd4 && msd4->has_scalar && msd4->timestep == 100);

  const std::string output = read_all_output(sim);
  CHECK(!contains(output, "ERROR"));
  CHECK(contains(output, "Loop time"));
  atomify_sim_destroy(sim);
}

void test_observables_are_sampled_at_the_interval()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  CHECK(run(sim, {"compute pea all pe/atom", "variable e equal pe"}));
  atomify_sim_set_publish_interval(sim, 0);
  atomify_sim_set_observable_interval(sim, 0.02);
  atomify_sim_set_max_steps_per_second(sim, 500);
  std::map<int64_t, double> sampled;    // observables timestep -> v_e
  atomify_sim_set_per_atom_quantity(sim, "c_pea");
  bool per_atom_ok = true;
  std::atomic<bool> done{false};
  std::thread worker([&] {
    CHECK(run(sim, {"run 300"}));
    done = true;
  });
  while (!done) {
    const Snapshot s = copy(sim);
    if (s.valid) {
      if (const Observable *e = s.find(ATOMIFY_OBSERVABLE_VARIABLE, "e"))
        if (e->has_scalar) sampled[e->timestep] = e->scalar;
      // pe/atom needs per-atom energy: between samples atoms keep values.
      if (!s.has_per_atom_values || s.per_atom_values.size() != s.tags.size()) per_atom_ok = false;
      for (float value : s.per_atom_values)
        if (!std::isfinite(value)) per_atom_ok = false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(3));
  }
  worker.join();
  CHECK(per_atom_ok);
  // About one sample per 10 steps at 500 steps/s; never one per step.
  CHECK(sampled.size() > 5 && sampled.size() < 150);
  for (const auto &entry : sampled) CHECK(entry.second < -1.0);
  CHECK(!contains(read_all_output(sim), "ERROR"));
  atomify_sim_destroy(sim);
}

void test_per_atom_quantity()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  CHECK(run(sim, {"compute ke all ke/atom", "compute stress all stress/atom NULL",
                  "compute msd all msd", "variable xx atom x", "variable t equal temp",
                  "fix avg all ave/atom 1 1 1 c_ke"}));
  atomify_sim_set_publish_interval(sim, 0);
  atomify_sim_set_observable_interval(sim, 0);

  auto values_of = [&](const char *name) {
    atomify_sim_set_per_atom_quantity(sim, name);
    CHECK(run(sim, {"run 2"}));
    return copy(sim);
  };

  Snapshot s = values_of("type");
  CHECK(s.per_atom_name == "type" && s.per_atom_error.empty() && s.has_per_atom_values);
  for (size_t n = 0; n < s.tags.size(); n++) CHECK(s.per_atom_values[n] == static_cast<float>(s.types[n]));

  s = values_of("mass");
  for (float value : s.per_atom_values) CHECK(value == 1.0f);

  s = values_of("c_ke");
  CHECK(s.per_atom_error.empty() && s.per_atom_values.size() == 256);
  double total = 0;
  for (float value : s.per_atom_values) total += value;
  CHECK(std::fabs(total - s.kinetic_energy) < 1e-3 * s.kinetic_energy);

  s = values_of("f_avg");
  CHECK(s.per_atom_error.empty() && s.per_atom_values.size() == 256);
  total = 0;
  for (float value : s.per_atom_values) total += value;
  // The fix averaged the previous step (its end_of_step follows ours).
  CHECK(std::fabs(total - s.kinetic_energy) < 0.15 * s.kinetic_energy);

  s = values_of("c_stress[1]");
  CHECK(s.per_atom_error.empty() && s.per_atom_values.size() == 256);
  bool any = false;
  for (float value : s.per_atom_values) any = any || value != 0.0f;
  CHECK(any);

  s = values_of("v_xx");
  CHECK(s.per_atom_error.empty() && s.per_atom_values.size() == 256);
  for (size_t n = 0; n < s.tags.size(); n++) {
    double d = s.per_atom_values[n] - s.positions[3 * n];
    const double length = s.box_hi[0] - s.box_lo[0];
    d -= length * std::round(d / length);    // wrapped vs not yet wrapped
    CHECK(std::fabs(d) < 1e-3);
  }

  s = values_of("speed");
  for (float value : s.per_atom_values) CHECK(value >= 0.0f);

  const char *invalid[][2] = {{"c_missing", "No compute"},       {"c_msd", "no per-atom"},
                              {"c_ke[2]", "one per-atom value"}, {"c_stress", "per-atom columns"},
                              {"c_stress[7]", "per-atom columns"}, {"v_t", "not an atom-style"},
                              {"v_none", "No variable"},          {"f_none", "No fix"},
                              {"q", "charges"},                   {"bogus", "Unknown per-atom"}};
  for (const auto &entry : invalid) {
    s = values_of(entry[0]);
    CHECK(s.per_atom_name == entry[0]);
    CHECK(!s.has_per_atom_values);
    CHECK(contains(s.per_atom_error, entry[1]));
  }

  s = values_of(nullptr);
  CHECK(s.per_atom_name.empty() && !s.has_per_atom_values && s.per_atom_error.empty());
  atomify_sim_destroy(sim);
}

void test_triclinic_tilt()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, {"units lj", "atom_style atomic", "region box prism 0 4 0 5 0 6 1.0 0.5 0.25",
                  "create_box 1 box", "create_atoms 1 random 20 4321 box", "mass 1 1.0",
                  "pair_style zero 1.0", "pair_coeff * *", "fix 1 all nve", "run 0"}));
  const Snapshot s = copy(sim);
  CHECK(s.triclinic == 1);
  CHECK(s.tilt[0] == 1.0 && s.tilt[1] == 0.5 && s.tilt[2] == 0.25);
  CHECK(s.box_lo[0] == 0 && s.box_hi[0] == 4 && s.box_hi[1] == 5 && s.box_hi[2] == 6);
  CHECK(s.bounds_lo[0] == 0 && s.bounds_hi[0] == 5.5 && s.bounds_hi[1] == 5.25);
  atomify_sim_destroy(sim);

  sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  CHECK(run(sim, {"run 0"}));
  const Snapshot orthogonal = copy(sim);
  CHECK(orthogonal.triclinic == 0 && orthogonal.tilt[0] == 0 && orthogonal.tilt[1] == 0 &&
        orthogonal.tilt[2] == 0);
  CHECK(orthogonal.bounds_lo[0] == -10 && orthogonal.bounds_hi[2] == 10);
  atomify_sim_destroy(sim);
}

void test_output_capture()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  CHECK(run(sim, {"print \"hello from atomify\"", "run 10"}));
  const std::string output = read_all_output(sim);
  CHECK(contains(output, "hello from atomify\n"));
  CHECK(contains(output, "Step"));
  CHECK(contains(output, "Loop time"));
  CHECK(read_all_output(sim).empty());    // drained
  CHECK(atomify_sim_command(sim, "pair_style nonsense") == ATOMIFY_ERROR);
  CHECK(contains(read_all_output(sim), "ERROR"));
  char byte;
  CHECK(atomify_sim_read_output(sim, &byte, 0) == 0);
  atomify_sim_destroy(sim);
}

void test_queued_commands_change_a_running_simulation()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  atomify_sim_set_publish_interval(sim, 0);
  atomify_sim_set_max_steps_per_second(sim, 2000);
  std::atomic<int> status{-1};
  std::thread worker([&] { status = atomify_sim_command(sim, "run 100000000"); });
  CHECK(wait_until([&] { return copy(sim).timestep > 20; }));
  read_all_output(sim);

  // Stop integrating and stop the atoms; the run goes on.
  atomify_sim_enqueue_command(sim, "unfix 1\nvelocity all set 0.0 0.0 0.0\n\n");
  CHECK(wait_until([&] { return atomify_sim_queued_command_count(sim) == 0; }));
  CHECK(wait_until([&] {
    const Snapshot s = copy(sim);
    return s.temperature == 0.0 && s.kinetic_energy == 0.0;
  }));
  const Snapshot still = copy(sim);
  CHECK(wait_until([&] { return copy(sim).timestep > still.timestep + 20; }));
  CHECK(copy(sim).positions == still.positions);

  // Commands that would leave the run are rejected; the run goes on.
  atomify_sim_enqueue_command(sim, "run 10");
  atomify_sim_enqueue_command(sim, "unfix __atomify");
  atomify_sim_enqueue_command(sim, "not_a_command");
  CHECK(wait_until([&] { return atomify_sim_queued_command_count(sim) == 0; }));
  atomify_sim_enqueue_command(sim, "fix 2 all nve");
  atomify_sim_enqueue_command(sim, "velocity all create 2.0 4928");
  CHECK(wait_until([&] { return copy(sim).temperature > 1.0; }));
  CHECK(wait_until([&] { return copy(sim).positions != still.positions; }));
  const std::string output = read_all_output(sim);
  CHECK(contains(output, "'run' cannot be used while a run is in progress"));
  CHECK(contains(output, "fix __atomify"));
  CHECK(contains(output, "not_a_command"));

  atomify_sim_cancel(sim);
  worker.join();
  CHECK(status == ATOMIFY_CANCELLED);
  atomify_sim_destroy(sim);
}

void test_queued_commands_keep_the_run_length()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  CHECK(run(sim, {"variable s equal step", "fix log all print 100 \"step ${s}\" screen yes"}));
  atomify_sim_set_max_steps_per_second(sim, 1000);
  atomify_sim_set_publish_interval(sim, 0);
  std::atomic<int> status{-1};
  std::thread worker([&] { status = atomify_sim_command(sim, "run 300"); });
  CHECK(wait_until([&] { return copy(sim).timestep > 50; }));
  atomify_sim_enqueue_command(sim, "velocity all scale 1.5");
  CHECK(wait_until([&] { return atomify_sim_queued_command_count(sim) == 0; }));
  atomify_sim_enqueue_command(sim, "thermo 7");
  worker.join();
  CHECK(status == ATOMIFY_OK);
  CHECK(atomify_sim_queued_command_count(sim) == 0);
  CHECK(run(sim, {"run 0"}));
  CHECK(copy(sim).timestep == 300);
  const std::string output = read_all_output(sim);
  CHECK(contains(output, "step 300"));
  // The next run starts normally (no timeout left behind).
  CHECK(run(sim, {"run 10"}));
  CHECK(copy(sim).timestep == 310);
  atomify_sim_destroy(sim);
}

void test_queued_commands_run_while_paused()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, lj_melt));
  atomify_sim_set_publish_interval(sim, 0);
  std::atomic<int> status{-1};
  std::thread worker([&] { status = atomify_sim_command(sim, "run 100000000"); });
  CHECK(wait_until([&] { return copy(sim).timestep > 10; }));
  atomify_sim_set_paused(sim, 1);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  const Snapshot paused = copy(sim);
  CHECK(paused.temperature > 0.5);
  atomify_sim_enqueue_command(sim, "velocity all set 0.0 0.0 0.0");
  CHECK(wait_until([&] { return copy(sim).temperature == 0.0; }));
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  const Snapshot after = copy(sim);
  CHECK(after.timestep == paused.timestep);    // still paused: no step taken
  CHECK(after.sequence > paused.sequence);     // but the change was published
  atomify_sim_set_paused(sim, 0);
  CHECK(wait_until([&] { return copy(sim).timestep > paused.timestep + 10; }));
  atomify_sim_cancel(sim);
  worker.join();
  CHECK(status == ATOMIFY_CANCELLED);
  atomify_sim_destroy(sim);
}

void test_queued_commands_outside_runs()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(atomify_sim_wait_for_commands(sim, 0.01) == 0);
  CHECK(atomify_sim_publish(sim) == 0);    // no box yet
  for (const auto &command : single_atom) atomify_sim_enqueue_command(sim, command.c_str());
  CHECK(atomify_sim_queued_command_count(sim) == static_cast<int>(single_atom.size()));
  CHECK(atomify_sim_wait_for_commands(sim, 1.0) == 1);
  CHECK(atomify_sim_execute_queued(sim) == ATOMIFY_OK);
  CHECK(atomify_sim_queued_command_count(sim) == 0);
  CHECK(!copy(sim).valid);

  atomify_sim_enqueue_command(sim, "variable answer equal 42");
  atomify_sim_enqueue_command(sim, "create_atoms 1 single 1 1 1");
  CHECK(atomify_sim_execute_queued(sim) == ATOMIFY_OK);
  CHECK(atomify_sim_publish(sim) == 1);
  Snapshot s = copy(sim);
  CHECK(s.valid && s.tags.size() == 2);
  const Observable *answer = s.find(ATOMIFY_OBSERVABLE_VARIABLE, "answer");
  CHECK(answer && answer->has_scalar && answer->scalar == 42);
  CHECK(s.find(ATOMIFY_OBSERVABLE_FIX, "1") != nullptr);

  atomify_sim_set_publish_interval(sim, 0);
  atomify_sim_enqueue_command(sim, "this_is_not_a_command");
  atomify_sim_enqueue_command(sim, "unfix __atomify");
  atomify_sim_enqueue_command(sim, "run 5");
  CHECK(atomify_sim_execute_queued(sim) == ATOMIFY_ERROR);
  CHECK(contains(atomify_sim_last_error(sim), "fix __atomify"));
  CHECK(copy(sim).timestep == 5);    // run is fine outside runs

  // A thread waiting for commands wakes for a command and for cancel.
  std::atomic<int> woke{-1};
  std::thread waiter([&] { woke = atomify_sim_wait_for_commands(sim, 10.0); });
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  atomify_sim_enqueue_command(sim, "print hi");
  waiter.join();
  CHECK(woke == 1);
  CHECK(atomify_sim_execute_queued(sim) == ATOMIFY_OK);
  std::thread canceller([&] {
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    atomify_sim_cancel(sim);
  });
  const auto start = std::chrono::steady_clock::now();
  CHECK(atomify_sim_wait_for_commands(sim, 10.0) == 0);
  CHECK(std::chrono::steady_clock::now() - start < std::chrono::seconds(5));
  canceller.join();
  CHECK(atomify_sim_is_cancelled(sim) == 1);
  atomify_sim_destroy(sim);
}

void test_clear_reinstalls_the_fix()
{
  atomify_sim *sim = atomify_sim_create(0);
  CHECK(run(sim, single_atom));
  CHECK(run(sim, {"clear"}));
  CHECK(run(sim, single_atom));
  atomify_sim_set_publish_interval(sim, 0);
  CHECK(run(sim, {"run 3"}));
  const Snapshot s = copy(sim);
  CHECK(s.valid && s.timestep == 3 && s.tags.size() == 1);
  atomify_sim_destroy(sim);
}

}    // namespace

int main()
{
  test_snapshot_is_sorted_by_tag();
  test_distance_bonds();
  test_topology_bonds();
  test_force_sphere_pushes_atom();
  test_moving_sphere_sweeps_atom_along();
  test_contact_has_one_force_budget_for_overlapping_fingers();
  test_grab_pulls_atom_by_tag();
  test_two_grabs_hold_two_atoms();
  test_pause_and_cancel();
  test_per_atom_radii();
  test_potential_energy();
  test_freeze_holds_atoms_and_reports_grab_force();
  test_wall_grid_repels_atoms();
  test_throttle();
  test_errors_are_reported();
  test_error_input_line();
  test_run_status();
  test_walls();
  test_extra_pair_style();
  test_rejects_nonfinite_hand_input_and_preserves_last_good_frame();
  test_tracking_timeout_releases_grabs();
  test_swept_room_collision_stops_a_fast_atom();
  test_observables();
  test_observables_are_sampled_at_the_interval();
  test_per_atom_quantity();
  test_triclinic_tilt();
  test_output_capture();
  test_queued_commands_change_a_running_simulation();
  test_queued_commands_keep_the_run_length();
  test_queued_commands_run_while_paused();
  test_queued_commands_outside_runs();
  test_clear_reinstalls_the_fix();
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("All bridge tests passed\n");
  return 0;
}
