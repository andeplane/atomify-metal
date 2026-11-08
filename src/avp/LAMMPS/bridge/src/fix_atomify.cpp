#include "fix_atomify.h"

#include "atom.h"
#include "atom_vec.h"
#include "compute.h"
#include "modify.h"
#include "domain.h"
#include "error.h"
#include "force.h"
#include "update.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <thread>

using namespace LAMMPS_NS;
using namespace FixConst;

namespace {
using Clock = std::chrono::steady_clock;

double seconds(Clock::duration d)
{
  return std::chrono::duration<double>(d).count();
}

// Upper bound on published bonds, so a too generous cutoff cannot exhaust
// memory or stall the simulation thread.
constexpr size_t kMaxBonds = 4000000;
}    // namespace

/* ---------------------------------------------------------------------- */

FixAtomify::FixAtomify(LAMMPS *lmp, int narg, char **arg) :
    Fix(lmp, narg, arg), shared(nullptr), frozen(false), topology_bonds(true), grab_force{0, 0, 0},
    potential_energy(0.0), has_potential_energy(false)
{
  if (narg != 3) error->all(FLERR, "Illegal fix atomify command: expected no arguments");
  shared = atomify_find_shared(lmp);
  if (!shared) error->all(FLERR, "Fix atomify can only be created by the Atomify app");
  nevery = 1;
  sphere_generation = 0;
  move_step = move_steps = 1;
  steps_since_update = 0;
}

int FixAtomify::setmask()
{
  return POST_INTEGRATE | POST_FORCE | MIN_POST_FORCE | END_OF_STEP;
}

/* ---------------------------------------------------------------------- */

void FixAtomify::setup(int vflag)
{
  post_force(vflag);
  publish(false);
  remember_wall_positions();
}

void FixAtomify::min_setup(int vflag)
{
  sync_inputs();
  apply_forces();
  publish(true);
  (void) vflag;
}

void FixAtomify::post_integrate()
{
  check_cancelled();
  check_state();
  sync_inputs();
  move_spheres();
  if (!frozen) collide_with_walls();
}

void FixAtomify::post_force(int /*vflag*/)
{
  check_cancelled();
  check_state();
  sync_inputs();
  if (frozen) {
    // Positions are held fixed; report the force the other atoms exert on
    // the grabbed atom instead of applying interaction forces.
    grab_force[0] = grab_force[1] = grab_force[2] = 0.0;
    const AtomifyGrab *grab = first_grab();
    const int i = grab ? local_index(grab->tag) : -1;
    if (i >= 0)
      for (int k = 0; k < 3; k++) grab_force[k] = atom->f[i][k];
    return;
  }
  frozen_positions.clear();
  apply_forces();
  apply_wall_grid();
}

void FixAtomify::min_post_force(int vflag)
{
  post_force(vflag);
  after_step(true);
}

void FixAtomify::end_of_step()
{
  if (frozen) hold_frozen_positions();
  after_step(false);
}

/* ---------------------------------------------------------------------- */

void FixAtomify::hold_frozen_positions()
{
  double **x = atom->x;
  double **v = atom->v;
  const int nlocal = atom->nlocal;
  const bool have_tags = atom->tag_enable && atom->tag;
  for (int i = 0; i < nlocal; i++) {
    const int64_t tag = have_tags ? static_cast<int64_t>(atom->tag[i]) : i + 1;
    auto it = frozen_positions.find(tag);
    if (it == frozen_positions.end()) {
      frozen_positions[tag] = {x[i][0], x[i][1], x[i][2]};
    } else {
      for (int k = 0; k < 3; k++) x[i][k] = it->second[k];
    }
    for (const AtomifyGrab &grab : grabs) {
      if (tag != grab.tag || grab.stiffness <= 0.0) continue;
      double d[3] = {grab.target[0] - x[i][0], grab.target[1] - x[i][1], grab.target[2] - x[i][2]};
      minimum_image(d);
      for (int k = 0; k < 3; k++) x[i][k] += d[k];
      frozen_positions[tag] = {x[i][0], x[i][1], x[i][2]};
    }
    v[i][0] = v[i][1] = v[i][2] = 0.0;
  }
}

void FixAtomify::update_potential_energy()
{
  Compute *pe = modify->get_compute_by_id("thermo_pe");
  if (!pe) return;
  if (update->eflag_global == update->ntimestep) {
    potential_energy = pe->compute_scalar();
    has_potential_energy = true;
  }
  // Ask LAMMPS to tally energy on the next step about ten times a second;
  // tallying it every step would slow the run down.
  const auto now = Clock::now();
  if (seconds(now - last_energy_request) >= 0.1) {
    last_energy_request = now;
    pe->addstep(update->ntimestep + 1);
  }
}

bool AtomifyWallGrid::sample(const double *x, double &distance) const
{
  double u[3];
  int i0[3];
  double t[3];
  for (int k = 0; k < 3; k++) {
    u[k] = (x[k] - origin[k]) / spacing;
    if (!(u[k] >= 0.0) || u[k] > dims[k] - 1) return false;
    i0[k] = std::min(static_cast<int>(u[k]), dims[k] - 2);
    if (i0[k] < 0) i0[k] = 0;
    t[k] = u[k] - i0[k];
  }
  auto at = [this](int i, int j, int k) {
    return static_cast<double>(distances[(static_cast<size_t>(k) * dims[1] + j) * dims[0] + i]);
  };
  double value = 0.0;
  for (int c = 0; c < 8; c++) {
    const int dx = c & 1, dy = (c >> 1) & 1, dz = (c >> 2) & 1;
    const double w = (dx ? t[0] : 1 - t[0]) * (dy ? t[1] : 1 - t[1]) * (dz ? t[2] : 1 - t[2]);
    value += w * at(std::min(i0[0] + dx, dims[0] - 1), std::min(i0[1] + dy, dims[1] - 1),
                    std::min(i0[2] + dz, dims[2] - 1));
  }
  distance = value;
  return true;
}

void FixAtomify::apply_wall_grid()
{
  if (!wall_grid || wall_grid->cutoff <= 0.0) return;
  const AtomifyWallGrid &grid = *wall_grid;
  double **x = atom->x;
  double **f = atom->f;
  const double h = 0.5 * grid.spacing;
  for (int i = 0; i < atom->nlocal; i++) {
    double d;
    if (!grid.sample(x[i], d) || d >= grid.cutoff) continue;
    // Direction away from the surface from the distance gradient.
    double gradient[3];
    for (int k = 0; k < 3; k++) {
      double plus[3] = {x[i][0], x[i][1], x[i][2]}, minus[3] = {x[i][0], x[i][1], x[i][2]};
      plus[k] += h;
      minus[k] -= h;
      double dp, dm;
      if (!grid.sample(plus, dp)) dp = d;
      if (!grid.sample(minus, dm)) dm = d;
      gradient[k] = dp - dm;
    }
    const double norm = std::sqrt(gradient[0] * gradient[0] + gradient[1] * gradient[1] +
                                  gradient[2] * gradient[2]);
    if (norm <= 0.0) continue;
    const double magnitude = grid.strength * (1.0 - std::max(d, 0.0) / grid.cutoff) / norm;
    for (int k = 0; k < 3; k++) f[i][k] += magnitude * gradient[k];
  }
}

/* ---------------------------------------------------------------------- */

void FixAtomify::remember_wall_positions()
{
  if (!wall_grid) { wall_previous.clear(); return; }
  wall_previous.clear();
  for (int i = 0; i < atom->nlocal; i++)
    wall_previous[static_cast<int64_t>(atom->tag[i])] = {atom->x[i][0], atom->x[i][1], atom->x[i][2]};
}

void FixAtomify::collide_with_walls()
{
  if (!wall_grid) return;
  const auto &grid = *wall_grid;
  // Half-cell sweep; bound work for extreme velocity. Unknown space is open.
  const double shell = std::min(grid.cutoff, 0.9 * grid.spacing);
  for (int i = 0; i < atom->nlocal; i++) {
    auto previous = wall_previous.find(static_cast<int64_t>(atom->tag[i]));
    if (previous == wall_previous.end()) continue;
    const auto &start = previous->second;
    double delta[3], length = 0;
    for (int k = 0; k < 3; k++) { delta[k] = atom->x[i][k] - start[k]; length = std::hypot(length, delta[k]); }
    if (length < 1e-12) continue;
    const double samples = std::ceil(length / (0.5 * grid.spacing));
    const int steps = static_cast<int>(std::min(samples, 64.0));
    double safe[3] = {start[0], start[1], start[2]};
    double lastDistance = 0;
    bool hadDistance = grid.sample(safe, lastDistance);
    bool hit = false;
    for (int step = 1; step <= steps; step++) {
      const double fraction = step / samples;
      double p[3];
      for (int k = 0; k < 3; k++) p[k] = start[k] + fraction * delta[k];
      double distance;
      if (!grid.sample(p, distance)) {
        for (int k = 0; k < 3; k++) safe[k] = p[k];
        hadDistance = false;
        continue;
      }
      if (distance <= shell && hadDistance && distance < lastDistance - 1e-10) {
        double normal[3], norm = 0;
        for (int k = 0; k < 3; k++) {
          double plus[3] = {p[0], p[1], p[2]}, minus[3] = {p[0], p[1], p[2]};
          plus[k] += 0.5 * grid.spacing; minus[k] -= 0.5 * grid.spacing;
          double dp = distance, dm = distance;
          grid.sample(plus, dp); grid.sample(minus, dm);
          normal[k] = dp - dm;
          norm = std::hypot(norm, normal[k]);
        }
        if (norm <= 1e-12) {
          for (int k = 0; k < 3; k++) normal[k] = -delta[k];
          norm = length;
        }
        double toward = 0;
        for (int k = 0; k < 3; k++) { normal[k] /= norm; toward += atom->v[i][k] * normal[k]; }
        if (toward < 0)
          for (int k = 0; k < 3; k++) atom->v[i][k] -= 1.75 * toward * normal[k];
        for (int k = 0; k < 3; k++) atom->x[i][k] = safe[k];
        hit = true;
        break;
      }
      lastDistance = distance;
      hadDistance = true;
      for (int k = 0; k < 3; k++) safe[k] = p[k];
    }
    if (!hit && samples > 64)
      for (int k = 0; k < 3; k++) atom->x[i][k] = safe[k];
  }
}

void FixAtomify::check_cancelled()
{
  if (shared->cancelled.load()) error->all(FLERR, "Atomify run cancelled");
}

void FixAtomify::check_state()
{
  // Validate before remapping, cell indexing or rendering can encounter NaN.
  // A finite double outside float range is also unusable by our renderer.
  const double limit = std::numeric_limits<float>::max() / 4.0;
  for (int k = 0; k < 3; k++)
    if (!std::isfinite(domain->boxlo[k]) || !std::isfinite(domain->boxhi[k]) ||
        domain->boxhi[k] <= domain->boxlo[k] || std::fabs(domain->boxlo[k]) > limit ||
        std::fabs(domain->boxhi[k]) > limit)
      error->all(FLERR, "Atomify detected invalid simulation bounds; reset the experiment");
  for (int i = 0; i < atom->nlocal; i++)
    for (int k = 0; k < 3; k++)
      if (!std::isfinite(atom->x[i][k]) || std::fabs(atom->x[i][k]) > limit ||
          !std::isfinite(atom->v[i][k]) || !std::isfinite(atom->f[i][k]))
        error->all(FLERR, "Atomify detected nonfinite simulation state; reset the experiment");
}

void FixAtomify::sync_inputs()
{
  std::lock_guard<std::mutex> lock(shared->control_mutex);
  // A suspended render loop must never leave hands pulling indefinitely.
  if (seconds(Clock::now() - shared->interaction_updated) > 0.35) {
    for (auto &grab : shared->grabs) grab = AtomifyGrab{};
    if (!shared->force_spheres.empty()) {
      shared->force_spheres.clear();
      shared->force_sphere_generation++;
    }
  }
  if (shared->force_sphere_generation != sphere_generation) {
    sphere_generation = shared->force_sphere_generation;
    const std::vector<atomify_force_sphere> &incoming = shared->force_spheres;
    if (!spheres.empty() && incoming.size() == spheres.size()) {
      // The same hand moved: slide there over as many steps as the last
      // update took, so the hand sweeps through the atoms in between.
      sphere_from = spheres;
      move_steps = std::min(std::max(steps_since_update, 1), 200);
    } else {
      sphere_from = incoming;
      move_steps = 1;
    }
    sphere_to = incoming;
    if (spheres.size() != incoming.size()) spheres = incoming;
    move_step = 0;
    steps_since_update = 0;
  }
  for (int slot = 0; slot < kGrabSlots; slot++) grabs[slot] = shared->grabs[slot];
  frozen = shared->frozen;
  wall_grid = shared->wall_grid;
  topology_bonds = shared->topology_bonds;
  bond_cutoffs.assign(shared->bond_cutoffs.begin(), shared->bond_cutoffs.end());
}

const AtomifyGrab *FixAtomify::first_grab() const
{
  for (const AtomifyGrab &grab : grabs)
    if (grab.tag > 0 && grab.stiffness > 0.0) return &grab;
  return nullptr;
}

int FixAtomify::local_index(int64_t tag) const
{
  int i = atom->map(static_cast<tagint>(tag));
  if (i < 0) {
    // Atomic systems often have no atom map; fall back to a scan.
    for (int j = 0; j < atom->nlocal; j++)
      if (atom->tag[j] == tag) return j;
  }
  return i < atom->nlocal ? i : -1;
}

void FixAtomify::minimum_image(double *delta) const
{
  if (domain->triclinic) return;
  for (int k = 0; k < 3; k++) {
    if (!domain->periodicity[k]) continue;
    const double prd = domain->prd[k];
    if (delta[k] > 0.5 * prd)
      delta[k] -= prd;
    else if (delta[k] < -0.5 * prd)
      delta[k] += prd;
  }
}

void FixAtomify::move_spheres()
{
  steps_since_update++;
  const size_t n = spheres.size();
  if (move_step >= move_steps || sphere_from.size() != n || sphere_to.size() != n) return;
  move_step++;
  const double t = static_cast<double>(move_step) / move_steps;
  for (size_t s = 0; s < n; s++) {
    spheres[s] = sphere_to[s];
    for (int k = 0; k < 3; k++) {
      const double delta = sphere_to[s].center[k] - sphere_from[s].center[k];
      spheres[s].center[k] = sphere_from[s].center[k] + t * delta;
    }
  }
}

void FixAtomify::apply_forces()
{
  if (spheres.empty() && !first_grab()) return;

  double **x = atom->x;
  double **f = atom->f;
  const int nlocal = atom->nlocal;

  // Contact is a bounded external force in both dynamics and minimization.
  // Never project a molecular atom to a hand's surface or convert hand motion
  // into atom velocity: a human frame spans femtosecond integration steps.
  // Overlapping fingers share one per-atom budget, rather than multiplying it.
  double contact_limit = 0.0;
  for (const auto &sphere : spheres) contact_limit = std::max(contact_limit, sphere.strength);
  for (int i = 0; i < nlocal && contact_limit > 0.0; i++) {
    double push[3] = {0, 0, 0};
    for (const auto &sphere : spheres) {
      if (sphere.radius <= 0.0 || sphere.strength <= 0.0) continue;
      double d[3] = {x[i][0] - sphere.center[0], x[i][1] - sphere.center[1],
                     x[i][2] - sphere.center[2]};
      minimum_image(d);
      const double r = std::hypot(std::hypot(d[0], d[1]), d[2]);
      if (r >= sphere.radius) continue;
      if (r > 1e-12) {
        for (int k = 0; k < 3; k++) d[k] /= r;
      } else {
        // A tracked hand can appear exactly on an atom. Deterministic normal
        // avoids NaN and does not require a velocity from an earlier frame.
        d[0] = 1.0; d[1] = d[2] = 0.0;
      }
      const double magnitude = sphere.strength * (1.0 - r / sphere.radius);
      for (int k = 0; k < 3; k++) push[k] += magnitude * d[k];
    }
    const double norm = std::hypot(std::hypot(push[0], push[1]), push[2]);
    const double scale = norm > 0.0 ? std::min(1.0, contact_limit / norm) : 1.0;
    for (int k = 0; k < 3; k++) f[i][k] += push[k] * scale;
  }

  for (const AtomifyGrab &grab : grabs) {
    if (grab.tag <= 0 || grab.stiffness <= 0.0) continue;
    const int i = local_index(grab.tag);
    if (i >= 0) {
      double d[3] = {x[i][0] - grab.target[0], x[i][1] - grab.target[1],
                     x[i][2] - grab.target[2]};
      minimum_image(d);
      // Damped spring at 0.7 of critical damping:
      // m x'' = ftm2v (-k x - c v)  =>  c = 2 zeta sqrt(ftm2v k / m) m / ftm2v.
      const double mass = atom->rmass ? atom->rmass[i] : atom->mass[atom->type[i]];
      const double ftm2v = force->ftm2v;
      const double damping = 2.0 * 0.7 * std::sqrt(ftm2v * grab.stiffness / mass) * mass / ftm2v;
      double **v = atom->v;
      double pull[3];
      double norm = 0;
      for (int k = 0; k < 3; k++) {
        pull[k] = -grab.stiffness * d[k] - damping * v[i][k];
        norm = std::hypot(norm, pull[k]);
      }
      // Cap only the force from the hand, never the experiment's forces.
      const double scale = norm > 0 ? std::min(1.0, grab.stiffness * 0.5 / norm) : 1.0;
      for (int k = 0; k < 3; k++) f[i][k] += pull[k] * scale;
    }
  }
}

/* ---------------------------------------------------------------------- */

void FixAtomify::after_step(bool minimizing)
{
  check_cancelled();
  check_state();
  remember_wall_positions();
  shared->progress_ns.store(std::chrono::duration_cast<std::chrono::nanoseconds>(
      Clock::now().time_since_epoch()).count());
  update_potential_energy();

  const auto now = Clock::now();
  if (shared->rate_window_steps == 0) shared->rate_window_start = now;
  shared->rate_window_steps++;
  const double window = seconds(now - shared->rate_window_start);
  if (window >= 0.5) {
    shared->steps_per_second = (shared->rate_window_steps - 1) / window;
    shared->rate_window_steps = 0;
  }

  if (seconds(now - shared->last_publish) >= shared->publish_interval) publish(minimizing);

  double max_rate;
  {
    std::unique_lock<std::mutex> lock(shared->control_mutex);
    if (shared->paused) {
      shared->control_cv.wait(lock, [this] { return !shared->paused || shared->cancelled.load(); });
      shared->rate_window_steps = 0;
      shared->last_step = Clock::now();
    }
    max_rate = shared->max_steps_per_second;
  }
  check_cancelled();

  if (max_rate > 0.0) {
    const auto next = shared->last_step +
        std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(1.0 / max_rate));
    const auto current = Clock::now();
    if (next > current) std::this_thread::sleep_for(next - current);
    shared->last_step = std::max(next, current);
  } else {
    shared->last_step = Clock::now();
  }
}

/* ---------------------------------------------------------------------- */

void FixAtomify::publish(bool minimizing)
{
  check_state();
  shared->last_publish = Clock::now();
  AtomifySnapshotData &out = shared->back;

  const int nlocal = atom->nlocal;
  const bool have_tags = atom->tag_enable && atom->tag;

  std::vector<int> order(nlocal);
  std::iota(order.begin(), order.end(), 0);
  if (have_tags)
    std::sort(order.begin(), order.end(),
              [this](int a, int b) { return atom->tag[a] < atom->tag[b]; });

  out.tags.resize(nlocal);
  out.types.resize(nlocal);
  out.positions.resize(3 * static_cast<size_t>(nlocal));
  const bool have_radii = atom->radius_flag && atom->radius;
  out.radii.resize(have_radii ? nlocal : 0);

  double **x = atom->x;
  double **v = atom->v;
  double kinetic = 0.0;
  for (int n = 0; n < nlocal; n++) {
    const int i = order[n];
    out.tags[n] = have_tags ? static_cast<int64_t>(atom->tag[i]) : n + 1;
    out.types[n] = atom->type[i];
    double position[3] = {x[i][0], x[i][1], x[i][2]};
    if (domain->box_exist) domain->remap(position);
    out.positions[3 * n + 0] = static_cast<float>(position[0]);
    out.positions[3 * n + 1] = static_cast<float>(position[1]);
    out.positions[3 * n + 2] = static_cast<float>(position[2]);
    if (have_radii) out.radii[n] = static_cast<float>(atom->radius[i]);
    const double mass = atom->rmass ? atom->rmass[i] : (atom->mass ? atom->mass[atom->type[i]] : 0.0);
    kinetic += mass * (v[i][0] * v[i][0] + v[i][1] * v[i][1] + v[i][2] * v[i][2]);
  }
  kinetic *= 0.5 * force->mvv2e;
  if (!std::isfinite(kinetic) || (has_potential_energy && !std::isfinite(potential_energy)))
    error->all(FLERR, "Atomify detected nonfinite energy; reset the experiment");

  out.bonds.clear();
  if (topology_bonds && have_tags) collect_topology_bonds(out, order);
  if (!bond_cutoffs.empty()) collect_distance_bonds(out);
  if (out.bonds.size() > 2 * kMaxBonds) out.bonds.resize(2 * kMaxBonds);

  const int dimension = domain->dimension;
  const double dof = static_cast<double>(dimension) * nlocal - dimension;
  out.kinetic_energy = kinetic;
  out.potential_energy = potential_energy;
  out.has_potential_energy = has_potential_energy;
  out.frozen = frozen;
  const AtomifyGrab *grab = first_grab();
  out.grab_tag = grab ? grab->tag : 0;
  for (int k = 0; k < 3; k++) out.grab_force[k] = frozen ? grab_force[k] : 0.0;
  out.temperature = (dof > 0 && force->boltz > 0) ? 2.0 * kinetic / (dof * force->boltz) : 0.0;
  // The default temperature compute accounts for constrained degrees of
  // freedom (e.g. SHAKE water). 3*N-dimension alone reports a spurious low
  // temperature for these systems. Compute setup precedes fix setup in both
  // dynamics and minimization; retain the finite kinetic fallback before an
  // initialized temperature compute exists. Kinetic energy above remains the
  // actual translational energy, independent of temperature normalization.
  Compute *temperature = modify->get_compute_by_id("thermo_temp");
  if (temperature && temperature->tempflag && temperature->is_initialized()) {
    const double measured_temperature = temperature->compute_scalar();
    if (std::isfinite(measured_temperature) && measured_temperature >= 0.0)
      out.temperature = measured_temperature;
  }
  out.timestep = update->ntimestep;
  out.time = update->atime + (update->ntimestep - update->atimestep) * update->dt;
  out.ntypes = atom->ntypes;
  out.dimension = dimension;
  out.triclinic = domain->triclinic;
  out.minimizing = minimizing ? 1 : 0;
  out.units = update->unit_style ? update->unit_style : "";
  for (int k = 0; k < 3; k++) {
    out.periodic[k] = domain->periodicity[k];
    out.box_lo[k] = domain->triclinic ? domain->boxlo_bound[k] : domain->boxlo[k];
    out.box_hi[k] = domain->triclinic ? domain->boxhi_bound[k] : domain->boxhi[k];
  }
  out.steps_per_second = shared->steps_per_second;

  std::lock_guard<std::mutex> lock(shared->snapshot_mutex);
  out.sequence = shared->next_sequence++;
  std::swap(shared->front, shared->back);
  shared->has_front = true;
}

/* ---------------------------------------------------------------------- */

void FixAtomify::collect_topology_bonds(AtomifySnapshotData &out, const std::vector<int> &order)
{
  if (atom->molecular != Atom::MOLECULAR || !atom->num_bond || !atom->bond_atom) return;

  const auto &tags = out.tags;
  auto index_of = [&tags](int64_t tag) -> int64_t {
    auto it = std::lower_bound(tags.begin(), tags.end(), tag);
    return (it != tags.end() && *it == tag) ? it - tags.begin() : -1;
  };

  const bool newton_bond = force->newton_bond;
  const float *p = out.positions.data();
  for (size_t n = 0; n < order.size(); n++) {
    const int i = order[n];
    const int64_t tag_i = out.tags[n];
    for (int b = 0; b < atom->num_bond[i]; b++) {
      const int64_t tag_j = atom->bond_atom[i][b];
      // Without newton_bond each bond is stored on both atoms.
      if (!newton_bond && tag_j < tag_i) continue;
      const int64_t m = index_of(tag_j);
      if (m < 0) continue;
      // Skip bonds that cross a periodic boundary in the wrapped picture.
      double d[3] = {p[3 * m] - p[3 * n], p[3 * m + 1] - p[3 * n + 1], p[3 * m + 2] - p[3 * n + 2]};
      bool crosses = false;
      for (int k = 0; k < 3; k++)
        if (domain->periodicity[k] && std::fabs(d[k]) > 0.5 * domain->prd[k]) crosses = true;
      if (crosses) continue;
      out.bonds.push_back(static_cast<uint32_t>(n));
      out.bonds.push_back(static_cast<uint32_t>(m));
      if (out.bonds.size() >= 2 * kMaxBonds) return;
    }
  }
}

void FixAtomify::collect_distance_bonds(AtomifySnapshotData &out)
{
  const size_t natoms = out.types.size();
  if (natoms < 2) return;

  const int ntypes = atom->ntypes;
  std::vector<double> cutsq((ntypes + 1) * (ntypes + 1), 0.0);
  double max_cut = 0.0;
  for (const auto &entry : bond_cutoffs) {
    const int a = entry.first.first, b = entry.first.second;
    if (a < 1 || b < 1 || a > ntypes || b > ntypes || entry.second <= 0.0) continue;
    cutsq[a * (ntypes + 1) + b] = cutsq[b * (ntypes + 1) + a] = entry.second * entry.second;
    max_cut = std::max(max_cut, entry.second);
  }
  if (max_cut <= 0.0) return;

  // Cell list over the wrapped positions. Wrapped coordinates mean bonds
  // never cross a periodic boundary, which matches how they are drawn.
  const float *p = out.positions.data();
  float lo[3] = {p[0], p[1], p[2]}, hi[3] = {p[0], p[1], p[2]};
  for (size_t n = 1; n < natoms; n++)
    for (int k = 0; k < 3; k++) {
      lo[k] = std::min(lo[k], p[3 * n + k]);
      hi[k] = std::max(hi[k], p[3 * n + k]);
    }
  double cell = max_cut;
  int dims[3];
  for (;;) {
    size_t total = 1;
    for (int k = 0; k < 3; k++) {
      dims[k] = std::max(1, static_cast<int>((hi[k] - lo[k]) / cell) + 1);
      total *= dims[k];
    }
    if (total <= 4 * natoms + 64) break;
    cell *= 1.5;
  }
  auto cell_of = [&](size_t n, int k) {
    return std::min(dims[k] - 1, static_cast<int>((p[3 * n + k] - lo[k]) / cell));
  };
  std::vector<int> head(static_cast<size_t>(dims[0]) * dims[1] * dims[2], -1);
  std::vector<int> next(natoms, -1);
  for (size_t n = 0; n < natoms; n++) {
    const size_t c = (static_cast<size_t>(cell_of(n, 2)) * dims[1] + cell_of(n, 1)) * dims[0] + cell_of(n, 0);
    next[n] = head[c];
    head[c] = static_cast<int>(n);
  }

  // Merge with topology bonds without duplicates.
  std::vector<uint64_t> existing;
  existing.reserve(out.bonds.size() / 2);
  for (size_t b = 0; b + 1 < out.bonds.size(); b += 2) {
    const uint64_t i = std::min(out.bonds[b], out.bonds[b + 1]);
    const uint64_t j = std::max(out.bonds[b], out.bonds[b + 1]);
    existing.push_back((i << 32) | j);
  }
  std::sort(existing.begin(), existing.end());

  for (size_t n = 0; n < natoms; n++) {
    const int cx = cell_of(n, 0), cy = cell_of(n, 1), cz = cell_of(n, 2);
    const int ti = out.types[n];
    for (int dz = -1; dz <= 1; dz++) {
      const int z = cz + dz;
      if (z < 0 || z >= dims[2]) continue;
      for (int dy = -1; dy <= 1; dy++) {
        const int y = cy + dy;
        if (y < 0 || y >= dims[1]) continue;
        for (int dx = -1; dx <= 1; dx++) {
          const int xc = cx + dx;
          if (xc < 0 || xc >= dims[0]) continue;
          for (int m = head[(static_cast<size_t>(z) * dims[1] + y) * dims[0] + xc]; m >= 0; m = next[m]) {
            if (static_cast<size_t>(m) <= n) continue;
            const int tj = out.types[m];
            if (ti < 1 || tj < 1 || ti > ntypes || tj > ntypes) continue;
            const double limit = cutsq[ti * (ntypes + 1) + tj];
            if (limit <= 0.0) continue;
            const double ddx = p[3 * m] - p[3 * n], ddy = p[3 * m + 1] - p[3 * n + 1],
                         ddz = p[3 * m + 2] - p[3 * n + 2];
            if (ddx * ddx + ddy * ddy + ddz * ddz >= limit) continue;
            const uint64_t key = (static_cast<uint64_t>(n) << 32) | static_cast<uint64_t>(m);
            if (!existing.empty() && std::binary_search(existing.begin(), existing.end(), key)) continue;
            out.bonds.push_back(static_cast<uint32_t>(n));
            out.bonds.push_back(static_cast<uint32_t>(m));
            if (out.bonds.size() >= 2 * kMaxBonds) return;
          }
        }
      }
    }
  }
}
