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

struct Snapshot {
  uint64_t sequence = 0;
  int64_t timestep = 0;
  double temperature = 0;
  std::string units;
  double box_lo[3] = {0, 0, 0}, box_hi[3] = {0, 0, 0};
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
  bool valid = false;
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
  CHECK(atomify_sim_run_file(sim, "/nonexistent/in.script") == ATOMIFY_ERROR);
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
  test_rejects_nonfinite_hand_input_and_preserves_last_good_frame();
  test_tracking_timeout_releases_grabs();
  test_swept_room_collision_stops_a_fast_atom();
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("All bridge tests passed\n");
  return 0;
}
