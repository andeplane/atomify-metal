#include "atomify_lammps.h"

#include "atomify_shared.h"

#include "lammps.h"
#include "library.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <unordered_map>

using namespace LAMMPS_NS;

/* ---------------------------------------------------------------------- */

namespace LAMMPS_NS {
namespace {
std::mutex registry_mutex;
std::unordered_map<LAMMPS *, AtomifyShared *> registry;
}    // namespace

void atomify_register_shared(LAMMPS *lmp, AtomifyShared *shared)
{
  std::lock_guard<std::mutex> lock(registry_mutex);
  registry[lmp] = shared;
}

void atomify_unregister_shared(LAMMPS *lmp)
{
  std::lock_guard<std::mutex> lock(registry_mutex);
  registry.erase(lmp);
}

AtomifyShared *atomify_find_shared(LAMMPS *lmp)
{
  std::lock_guard<std::mutex> lock(registry_mutex);
  auto it = registry.find(lmp);
  return it == registry.end() ? nullptr : it->second;
}
}    // namespace LAMMPS_NS

/* ---------------------------------------------------------------------- */

struct atomify_sim {
  // Declared first so it outlives the LAMMPS instance and its fix.
  std::unique_ptr<AtomifyShared> shared = std::make_unique<AtomifyShared>();
  void *lmp = nullptr;
  std::string last_error;
  bool fix_installed = false;
};

namespace {

int64_t now_ns()
{
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
}

void clear_interactions(atomify_sim *sim)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  for (auto &grab : sim->shared->grabs) grab = AtomifyGrab{};
  sim->shared->force_spheres.clear();
  sim->shared->force_sphere_generation++;
}

atomify_status finish(atomify_sim *sim)
{
  if (!lammps_has_error(sim->lmp)) {
    sim->last_error.clear();
    return ATOMIFY_OK;
  }
  char buffer[2048];
  lammps_get_last_error_message(sim->lmp, buffer, sizeof(buffer));
  sim->last_error = buffer;
  clear_interactions(sim);
  return sim->shared->cancelled.load() ? ATOMIFY_CANCELLED : ATOMIFY_ERROR;
}

bool install_fix(atomify_sim *sim)
{
  if (sim->fix_installed) return true;
  lammps_command(sim->lmp, "fix __atomify all atomify");
  if (lammps_has_error(sim->lmp)) return false;
  sim->fix_installed = true;
  return true;
}

}    // namespace

/* ---------------------------------------------------------------------- */

extern "C" {

atomify_sim *atomify_sim_create(int echo)
{
  auto *sim = new atomify_sim();
  sim->shared->progress_ns.store(now_ns());
  const char *quiet[] = {"liblammps", "-log", "none", "-screen", "none", "-nocite"};
  const char *loud[] = {"liblammps", "-log", "none", "-nocite"};
  const char **argv = echo ? loud : quiet;
  const int argc = echo ? 4 : 6;
  sim->lmp = lammps_open_no_mpi(argc, const_cast<char **>(argv), nullptr);
  if (!sim->lmp) {
    delete sim;
    return nullptr;
  }
  atomify_register_shared(static_cast<LAMMPS *>(sim->lmp), sim->shared.get());
  if (!install_fix(sim)) finish(sim);
  return sim;
}

void atomify_sim_destroy(atomify_sim *sim)
{
  if (!sim) return;
  if (sim->lmp) {
    atomify_unregister_shared(static_cast<LAMMPS *>(sim->lmp));
    lammps_close(sim->lmp);
  }
  delete sim;
}

atomify_status atomify_sim_run_file(atomify_sim *sim, const char *path)
{
  if (!install_fix(sim)) return finish(sim);
  lammps_file(sim->lmp, path);
  return finish(sim);
}

atomify_status atomify_sim_command(atomify_sim *sim, const char *command)
{
  if (!install_fix(sim)) return finish(sim);
  lammps_command(sim->lmp, command);
  return finish(sim);
}

const char *atomify_sim_last_error(atomify_sim *sim)
{
  return sim->last_error.c_str();
}

/* ---------------------------------------------------------------------- */

void atomify_sim_set_paused(atomify_sim *sim, int paused)
{
  {
    std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
    sim->shared->paused = paused != 0;
  }
  sim->shared->control_cv.notify_all();
}

void atomify_sim_cancel(atomify_sim *sim)
{
  clear_interactions(sim);
  {
    std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
    sim->shared->cancelled.store(true);
  }
  sim->shared->control_cv.notify_all();
}

double atomify_sim_seconds_since_progress(atomify_sim *sim)
{
  return (now_ns() - sim->shared->progress_ns.load()) * 1.0e-9;
}

void atomify_sim_set_max_steps_per_second(atomify_sim *sim, double steps)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->max_steps_per_second = steps > 0.0 ? steps : 0.0;
}

void atomify_sim_set_publish_interval(atomify_sim *sim, double seconds)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->publish_interval = seconds > 0.0 ? seconds : 0.0;
}

void atomify_sim_set_topology_bonds(atomify_sim *sim, int enabled)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->topology_bonds = enabled != 0;
}

void atomify_sim_set_bond_cutoff(atomify_sim *sim, int type1, int type2, double cutoff)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  const auto key = std::make_pair(std::min(type1, type2), std::max(type1, type2));
  if (cutoff > 0.0)
    sim->shared->bond_cutoffs[key] = cutoff;
  else
    sim->shared->bond_cutoffs.erase(key);
}

void atomify_sim_clear_bond_cutoffs(atomify_sim *sim)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->bond_cutoffs.clear();
}

void atomify_sim_set_force_spheres(atomify_sim *sim, const atomify_force_sphere *spheres, int count)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->force_spheres.clear();
  if (spheres) {
    for (int i = 0; i < std::min(std::max(count, 0), 512); i++) {
      const auto &s = spheres[i];
      if (std::isfinite(s.radius) && s.radius > 0 && std::isfinite(s.strength) && s.strength >= 0 &&
          std::isfinite(s.center[0]) && std::isfinite(s.center[1]) && std::isfinite(s.center[2]))
        sim->shared->force_spheres.push_back(s);
    }
  }
  sim->shared->interaction_updated = std::chrono::steady_clock::now();
  sim->shared->force_sphere_generation++;
}

void atomify_sim_set_grab(atomify_sim *sim, int64_t tag, const double target[3], double stiffness)
{
  atomify_sim_set_grab_slot(sim, 0, tag, target, stiffness);
}

void atomify_sim_set_grab_slot(atomify_sim *sim, int slot, int64_t tag, const double target[3],
                               double stiffness)
{
  if (slot < 0 || slot >= kGrabSlots) return;
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  AtomifyGrab &grab = sim->shared->grabs[slot];
  const bool valid = target && std::isfinite(stiffness) && stiffness > 0.0 &&
      std::isfinite(target[0]) && std::isfinite(target[1]) && std::isfinite(target[2]);
  grab.tag = valid ? tag : 0;
  grab.stiffness = stiffness;
  if (valid)
    for (int k = 0; k < 3; k++) grab.target[k] = target[k];
  sim->shared->interaction_updated = std::chrono::steady_clock::now();
}

void atomify_sim_set_frozen(atomify_sim *sim, int frozen)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->frozen = frozen != 0;
}

void atomify_sim_set_wall_grid(atomify_sim *sim, const double origin[3], double spacing,
                               const int32_t dims[3], const float *distances, double cutoff,
                               double strength)
{
  std::shared_ptr<AtomifyWallGrid> grid;
  if (distances && origin && dims && spacing > 0.0 && dims[0] > 1 && dims[1] > 1 && dims[2] > 1) {
    grid = std::make_shared<AtomifyWallGrid>();
    for (int k = 0; k < 3; k++) {
      grid->origin[k] = origin[k];
      grid->dims[k] = dims[k];
    }
    grid->spacing = spacing;
    grid->cutoff = cutoff;
    grid->strength = strength;
    grid->distances.assign(distances, distances + static_cast<size_t>(dims[0]) * dims[1] * dims[2]);
  }
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->wall_grid = std::move(grid);
}

/* ---------------------------------------------------------------------- */

int atomify_sim_snapshot_lock(atomify_sim *sim, atomify_snapshot *out)
{
  sim->shared->snapshot_mutex.lock();
  if (!sim->shared->has_front) {
    sim->shared->snapshot_mutex.unlock();
    return 0;
  }
  const AtomifySnapshotData &s = sim->shared->front;
  out->sequence = s.sequence;
  out->timestep = s.timestep;
  out->time = s.time;
  out->natoms = static_cast<int32_t>(s.types.size());
  out->ntypes = s.ntypes;
  out->nbonds = static_cast<int32_t>(s.bonds.size() / 2);
  out->dimension = s.dimension;
  out->triclinic = s.triclinic;
  out->minimizing = s.minimizing;
  std::snprintf(out->units, sizeof(out->units), "%s", s.units.c_str());
  for (int k = 0; k < 3; k++) {
    out->periodic[k] = s.periodic[k];
    out->box_lo[k] = s.box_lo[k];
    out->box_hi[k] = s.box_hi[k];
  }
  out->temperature = s.temperature;
  out->kinetic_energy = s.kinetic_energy;
  out->potential_energy = s.potential_energy;
  out->has_potential_energy = s.has_potential_energy ? 1 : 0;
  out->frozen = s.frozen ? 1 : 0;
  out->grab_tag = s.grab_tag;
  for (int k = 0; k < 3; k++) out->grab_force[k] = s.grab_force[k];
  out->steps_per_second = s.steps_per_second;
  out->tags = s.tags.data();
  out->types = s.types.data();
  out->positions = s.positions.data();
  out->radii = s.radii.empty() ? nullptr : s.radii.data();
  out->bonds = s.bonds.data();
  return 1;
}

void atomify_sim_snapshot_unlock(atomify_sim *sim)
{
  sim->shared->snapshot_mutex.unlock();
}

}    // extern "C"
