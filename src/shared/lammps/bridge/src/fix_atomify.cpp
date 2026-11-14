#include "fix_atomify.h"

#include "atom.h"
#include "atom_vec.h"
#include "compute.h"
#include "domain.h"
#include "error.h"
#include "exceptions.h"
#include "fix_wall.h"
#include "fix_wall_region.h"
#include "force.h"
#include "input.h"
#include "modify.h"
#include "output.h"
#include "region.h"
#include "region_block.h"
#include "thermo.h"
#include "timer.h"
#include "update.h"
#include "variable.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <limits>
#include <cstdlib>
#include <cstring>
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

// Upper bounds on published global vectors and arrays per observable.
constexpr int kMaxVector = 4096;
constexpr size_t kMaxArray = 65536;

// LAMMPS-internal fixes (fix STORE/ATOM, DUMMY, NEIGH_HISTORY, ...) have
// upper case styles; they are not shown as observables.
bool internal_style(const char *style)
{
  for (const char *c = style; c && *c; c++)
    if (*c >= 'a' && *c <= 'z') return false;
  return true;
}

// "c_ID", "c_ID[3]", "f_ID[2]", "v_name": prefix, ID and 1-based column
// (0 without brackets). False if the name does not have that shape.
bool parse_reference(const std::string &name, char &prefix, std::string &id, int &column)
{
  if (name.size() < 3 || name[1] != '_' || (name[0] != 'c' && name[0] != 'f' && name[0] != 'v'))
    return false;
  prefix = name[0];
  column = 0;
  const size_t open = name.find('[');
  id = name.substr(2, open == std::string::npos ? std::string::npos : open - 2);
  if (id.empty()) return false;
  for (char c : id)
    if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_')) return false;
  if (open != std::string::npos) {
    if (name.back() != ']' || open + 2 >= name.size()) return false;
    const std::string digits = name.substr(open + 1, name.size() - open - 2);
    for (char c : digits)
      if (!std::isdigit(static_cast<unsigned char>(c))) return false;
    column = std::atoi(digits.c_str());
    if (column < 1) return false;
  }
  return true;
}

// Thermo keeps the column headers ("PotEng"); report the thermo_style
// keywords ("pe") instead. References like c_ID[2] are kept as they are.
std::string thermo_keyword(const std::string &header)
{
  static const std::pair<const char *, const char *> renamed[] = {
      {"T/CPU", "tpcpu"},       {"S/CPU", "spcpu"},   {"%CPU", "cpuuse"},     {"CPULeft", "cpuremain"},
      {"TimeoutLeft", "timeremain"}, {"PotEng", "pe"}, {"KinEng", "ke"},       {"TotEng", "etotal"},
      {"E_vdwl", "evdwl"},      {"E_coul", "ecoul"},  {"E_pair", "epair"},    {"E_bond", "ebond"},
      {"E_angle", "eangle"},    {"E_dihed", "edihed"}, {"E_impro", "eimp"},   {"E_mol", "emol"},
      {"E_long", "elong"},      {"E_tail", "etail"},  {"Volume", "vol"},      {"Diheds", "dihedrals"},
      {"Impros", "impropers"}};
  for (const auto &entry : renamed)
    if (header == entry.first) return entry.second;
  if (header.size() > 2 && header[1] == '_' &&
      (header[0] == 'c' || header[0] == 'f' || header[0] == 'v' || header[0] == 'i' || header[0] == 'd'))
    return header;
  std::string keyword = header;
  for (char &c : keyword) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return keyword;
}

bool parse_number(const char *text, double &value)
{
  if (!text || !*text) return false;
  char *end = nullptr;
  value = std::strtod(text, &end);
  while (end && (*end == ' ' || *end == '\t' || *end == '\n')) end++;
  return end && *end == '\0' && std::isfinite(value);
}
}    // namespace

/* ---------------------------------------------------------------------- */

template <typename Body> bool FixAtomify::guarded(Body &&body)
{
  const int show = error->set_show_error(0);
  const int which = update->whichflag;
  bool ok = true;
  try {
    body();
  } catch (LAMMPSException &) {
    ok = false;
  } catch (std::exception &) {
    ok = false;
  }
  error->set_show_error(show);
  if (!ok) {
    // Error::all resets whichflag and may leave a variable marked busy.
    update->whichflag = which;
    if (input && input->variable) input->variable->clear_in_progress();
  }
  return ok;
}

/* ---------------------------------------------------------------------- */

FixAtomify::FixAtomify(LAMMPS *lmp, int narg, char **arg) :
    Fix(lmp, narg, arg), shared(nullptr), frozen(false), topology_bonds(true),
    observable_interval(0.05), grab_force{0, 0, 0}, potential_energy(0.0),
    has_potential_energy(false), sample_pending(false), sample_step(0)
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
  // Setup steps tally energy and virial (Modify::init asks for them), so
  // they are always sampled. A new run gets another chance at evaluating
  // what failed before.
  failed.clear();
  sample_pending = false;
  post_force(vflag);
  update_potential_energy();
  publish(false, true);
  remember_wall_positions();
}

void FixAtomify::min_setup(int vflag)
{
  failed.clear();
  sample_pending = false;
  sync_inputs();
  apply_forces();
  update_potential_energy();
  publish(true, true);
  (void) vflag;
}

bool FixAtomify::publish_idle()
{
  if (!domain->box_exist) return false;
  sync_inputs();
  publish(false, false);
  return true;
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
  // Energy is tallied on sampled steps (see request_sample); tallying it
  // every step would slow the run down.
  Compute *pe = modify->get_compute_by_id("thermo_pe");
  if (!pe || !pe->is_initialized()) return;
  if (pe->invoked_scalar == update->ntimestep) {
    potential_energy = pe->scalar;
    has_potential_energy = true;
  } else if (update->whichflag && update->eflag_global == update->ntimestep) {
    double value = 0.0;
    if (guarded([&] {
          value = pe->compute_scalar();
          pe->invoked_flag |= Compute::INVOKED_SCALAR;
        })) {
      potential_energy = value;
      has_potential_energy = true;
    }
  }
}

void FixAtomify::request_sample()
{
  // Computes with timeflag (pe, pressure, pe/atom, stress/atom, ...) make
  // the integrator tally energy and virial on the requested step.
  modify->addstep_compute(update->ntimestep + 1);
  sample_pending = true;
  sample_step = update->ntimestep + 1;
  last_sample = Clock::now();
}

bool FixAtomify::wants_interrupt() const
{
  return shared->can_interrupt && shared->queued.load() > 0;
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
  if (per_atom_quantity != shared->per_atom_quantity) per_atom_quantity = shared->per_atom_quantity;
  observable_interval = shared->observable_interval;
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
  shared->mark_progress();
  update_potential_energy();

  const auto now = Clock::now();
  if (shared->rate_window_steps == 0) shared->rate_window_start = now;
  shared->rate_window_steps++;
  const double window = seconds(now - shared->rate_window_start);
  if (window >= 0.5) {
    shared->steps_per_second = (shared->rate_window_steps - 1) / window;
    shared->rate_window_steps = 0;
  }

  // A requested sample is taken (and published) on the step it was
  // requested for, where energy and virial were tallied.
  const bool sample = sample_pending && update->ntimestep >= sample_step;
  if (sample) sample_pending = false;
  bool published = false;
  if (sample || seconds(now - shared->last_publish) >= shared->publish_interval) {
    publish(minimizing, sample);
    published = true;
  }
  if (!sample_pending && seconds(now - last_sample) >= observable_interval) request_sample();

  double max_rate;
  bool paced, out_of_steps = false;
  {
    std::unique_lock<std::mutex> lock(shared->control_mutex);
    if (shared->paused && !wants_interrupt()) {
      shared->control_cv.wait(lock, [this] {
        return !shared->paused || shared->cancelled.load() || wants_interrupt();
      });
      shared->rate_window_steps = 0;
      shared->last_step = Clock::now();
    }
    max_rate = shared->max_steps_per_second;
    paced = shared->frame_paced;
    if (paced) {
      shared->step_budget = std::max(shared->step_budget - 1.0, 0.0);
      out_of_steps = shared->step_budget < 1.0;
    }
  }
  check_cancelled();

  // Frame pacing: show where the grant ended, then wait for the next one.
  if (out_of_steps && !wants_interrupt()) {
    if (!published) publish(minimizing, false);
    std::unique_lock<std::mutex> lock(shared->control_mutex);
    shared->control_cv.wait(lock, [this] {
      return !shared->frame_paced || shared->step_budget >= 1.0 || shared->cancelled.load() ||
          wants_interrupt();
    });
    shared->last_step = Clock::now();
  }
  check_cancelled();

  // Queued commands: end the integrator here; atomify_integrate executes
  // them and continues the run (no further step runs before that).
  if (wants_interrupt()) {
    shared->interrupted = true;
    timer->force_timeout();
    return;
  }

  if (max_rate > 0.0 && !paced) {
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

void FixAtomify::publish(bool minimizing, bool sample)
{
  check_state();
  const bool in_run = update->whichflag != 0;
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
  // Outside runs the compute is only read if it is current.
  Compute *temperature = modify->get_compute_by_id("thermo_temp");
  if (temperature && temperature->tempflag && temperature->is_initialized()) {
    double measured_temperature = -1.0;
    if (temperature->invoked_scalar == update->ntimestep)
      measured_temperature = temperature->scalar;
    else if (in_run)
      guarded([&] {
        measured_temperature = temperature->compute_scalar();
        temperature->invoked_flag |= Compute::INVOKED_SCALAR;
      });
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
    out.box_lo[k] = domain->boxlo[k];
    out.box_hi[k] = domain->boxhi[k];
    out.bounds_lo[k] = domain->triclinic ? domain->boxlo_bound[k] : domain->boxlo[k];
    out.bounds_hi[k] = domain->triclinic ? domain->boxhi_bound[k] : domain->boxhi[k];
  }
  out.tilt[0] = domain->triclinic ? domain->xy : 0.0;
  out.tilt[1] = domain->triclinic ? domain->xz : 0.0;
  out.tilt[2] = domain->triclinic ? domain->yz : 0.0;
  out.steps_per_second = shared->steps_per_second;

  // Run status. atomify_integrate keeps the first step of the whole run
  // when queued commands split it.
  out.run_mode = update->whichflag;
  if (in_run) {
    const bigint first = shared->run_first_step >= 0 ? shared->run_first_step : update->firststep;
    out.run_step = std::max<bigint>(0, update->ntimestep - first);
    out.run_steps = std::max<bigint>(0, update->laststep - first);
  } else {
    out.run_step = out.run_steps = 0;
  }
  if (in_run && !shared->run_line.empty()) {
    out.input_line = shared->run_line;
  } else {
    const char *line = input ? input->get_last_line() : nullptr;
    out.input_line = line ? line : "";
    while (!out.input_line.empty() && std::isspace(static_cast<unsigned char>(out.input_line.back())))
      out.input_line.pop_back();
  }
  collect_walls(out);

  collect_per_atom(out, order, sample || !in_run);
  // Outside runs nothing is invoked: keep the last sample, or list what
  // exists if no run has been sampled yet.
  if (sample || !observables) observables = sample_observables(in_run && sample);
  out.observables = observables;

  std::lock_guard<std::mutex> lock(shared->snapshot_mutex);
  out.sequence = shared->next_sequence++;
  std::swap(shared->front, shared->back);
  shared->has_front = true;
}

/* ---------------------------------------------------------------------- */

namespace {
// fix wall/region and region block keep these protected. A pointer to member
// taken through a derived class reads them without patching LAMMPS.
struct WallRegionFields : FixWallRegion {
  static char *FixWallRegion::*region_id() { return &WallRegionFields::idregion; }
};
struct BlockFields : RegBlock {
  static double RegBlock::*lo(int axis)
  {
    return axis == 0 ? &BlockFields::xlo : axis == 1 ? &BlockFields::ylo : &BlockFields::zlo;
  }
  static double RegBlock::*hi(int axis)
  {
    return axis == 0 ? &BlockFields::xhi : axis == 1 ? &BlockFields::yhi : &BlockFields::zhi;
  }
};
}    // namespace

// Planes of fix wall/* at a fixed position, as lammps.js' getWalls lists
// them, and the blocks of fix wall/region. Variable positions are skipped:
// evaluating them is not safe here.
void FixAtomify::collect_walls(AtomifySnapshotData &out)
{
  out.walls.clear();
  out.wall_blocks.clear();
  for (Fix *fix : modify->get_fix_list()) {
    auto *wall = dynamic_cast<FixWallRegion *>(fix);
    if (!wall) continue;
    const char *id = wall->*WallRegionFields::region_id();
    auto *block = id ? dynamic_cast<RegBlock *>(domain->get_region_by_id(id)) : nullptr;
    if (!block || block->dynamic || block->varshape) continue;
    // Regions are in box units (lattice scaling was applied when the region
    // was made); EDGE and INF bounds end at the box, or its bounding box if triclinic.
    const double *box_lo = domain->triclinic ? domain->boxlo_bound : domain->boxlo;
    const double *box_hi = domain->triclinic ? domain->boxhi_bound : domain->boxhi;
    atomify_wall_block clipped{};
    bool empty = false;
    for (int axis = 0; axis < 3; axis++) {
      clipped.lo[axis] = std::max(block->*BlockFields::lo(axis), box_lo[axis]);
      clipped.hi[axis] = std::min(block->*BlockFields::hi(axis), box_hi[axis]);
      if (!(clipped.lo[axis] <= clipped.hi[axis])) empty = true;
    }
    if (!empty) out.wall_blocks.push_back(clipped);
  }
  for (Fix *fix : modify->get_fix_list()) {
    auto *wall = dynamic_cast<FixWall *>(fix);
    if (!wall) continue;
    for (int m = 0; m < wall->nwall && m < 6; m++) {
      const int face = wall->wallwhich[m];
      if (face < 0 || face > 5) continue;
      double position;
      if (wall->xstyle[m] == FixWall::EDGE)
        position = face % 2 == 0 ? domain->boxlo[face / 2] : domain->boxhi[face / 2];
      else if (wall->xstyle[m] == FixWall::CONSTANT)
        position = wall->coord0[m];
      else
        continue;
      out.walls.push_back(atomify_wall{face, position});
    }
  }
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

/* ----------------------------------------------------------------------
   Per-atom quantity
------------------------------------------------------------------------- */

void FixAtomify::collect_per_atom(AtomifySnapshotData &out, const std::vector<int> &order,
                                  bool evaluate)
{
  out.per_atom_name = per_atom_quantity;
  out.per_atom_error.clear();
  out.per_atom_values.clear();
  out.has_per_atom_values = false;
  if (per_atom_quantity.empty()) {
    last_per_atom_name.clear();
    return;
  }

  std::vector<double> values;
  std::string problem;
  const bool current = per_atom_source(per_atom_quantity, evaluate, values, problem);
  if (!problem.empty()) {
    out.per_atom_error = problem;
    last_per_atom_name.clear();
    return;
  }

  const size_t natoms = order.size();
  out.per_atom_values.resize(natoms);
  out.has_per_atom_values = true;
  const float nan = std::numeric_limits<float>::quiet_NaN();
  if (current && values.size() >= natoms) {
    for (size_t n = 0; n < natoms; n++) out.per_atom_values[n] = static_cast<float>(values[order[n]]);
    last_per_atom_name = per_atom_quantity;
    last_per_atom_tags = out.tags;
    last_per_atom_values = out.per_atom_values;
    return;
  }
  // Not available on this step: atoms keep the value of the last sample.
  const bool reuse = last_per_atom_name == per_atom_quantity;
  for (size_t n = 0; n < natoms; n++) {
    float value = nan;
    if (reuse) {
      auto it = std::lower_bound(last_per_atom_tags.begin(), last_per_atom_tags.end(), out.tags[n]);
      if (it != last_per_atom_tags.end() && *it == out.tags[n])
        value = last_per_atom_values[it - last_per_atom_tags.begin()];
    }
    out.per_atom_values[n] = value;
  }
}

// Values of `name` for the owned atoms by local index. Returns false when
// they are not available on this step (and sets `problem` if they never
// will be, e.g. an unknown compute).
bool FixAtomify::per_atom_source(const std::string &name, bool evaluate,
                                 std::vector<double> &values, std::string &problem)
{
  const int nlocal = atom->nlocal;
  const bool in_run = update->whichflag != 0;
  values.assign(nlocal, 0.0);
  double **v = atom->v;
  double **f = atom->f;

  auto component = [&](double **array, int k) {
    for (int i = 0; i < nlocal; i++) values[i] = array[i][k];
    return true;
  };
  if (name == "vx") return component(v, 0);
  if (name == "vy") return component(v, 1);
  if (name == "vz") return component(v, 2);
  if (name == "fx") return component(f, 0);
  if (name == "fy") return component(f, 1);
  if (name == "fz") return component(f, 2);
  if (name == "speed") {
    for (int i = 0; i < nlocal; i++)
      values[i] = std::sqrt(v[i][0] * v[i][0] + v[i][1] * v[i][1] + v[i][2] * v[i][2]);
    return true;
  }
  if (name == "type") {
    for (int i = 0; i < nlocal; i++) values[i] = atom->type[i];
    return true;
  }
  if (name == "q") {
    if (!atom->q_flag || !atom->q) {
      problem = "The atom style has no charges (q)";
      return false;
    }
    for (int i = 0; i < nlocal; i++) values[i] = atom->q[i];
    return true;
  }
  if (name == "mass") {
    if (atom->rmass) {
      for (int i = 0; i < nlocal; i++) values[i] = atom->rmass[i];
    } else if (atom->mass) {
      for (int i = 0; i < nlocal; i++) values[i] = atom->mass[atom->type[i]];
    } else {
      problem = "Masses are not set";
      return false;
    }
    return true;
  }

  char prefix;
  std::string id;
  int column;
  if (!parse_reference(name, prefix, id, column)) {
    problem = "Unknown per-atom quantity '" + name +
        "'; use vx, vy, vz, fx, fy, fz, speed, q, mass, type, c_ID, c_ID[n], f_ID, f_ID[n] or v_name";
    return false;
  }

  auto check_columns = [&](const char *what, int columns) {
    if (columns == 0 && column > 0) {
      problem = std::string(what) + " '" + id + "' has one per-atom value; use " + prefix + "_" + id;
      return false;
    }
    if (columns > 0 && (column < 1 || column > columns)) {
      problem = std::string(what) + " '" + id + "' has " + std::to_string(columns) +
          " per-atom columns; use " + prefix + "_" + id + "[1] to [" + std::to_string(columns) + "]";
      return false;
    }
    return true;
  };
  auto copy = [&](double *vector, double **array) {
    if (column == 0 && vector) {
      for (int i = 0; i < nlocal; i++) values[i] = vector[i];
      return true;
    }
    if (column > 0 && array) {
      for (int i = 0; i < nlocal; i++) values[i] = array[i][column - 1];
      return true;
    }
    return nlocal == 0;
  };

  if (prefix == 'c') {
    Compute *compute = modify->get_compute_by_id(id);
    if (!compute) {
      problem = "No compute with ID '" + id + "'";
      return false;
    }
    if (!compute->peratom_flag) {
      problem = "Compute '" + id + "' (" + compute->style + ") has no per-atom values";
      return false;
    }
    if (!check_columns("Compute", compute->size_peratom_cols)) return false;
    if (compute->invoked_peratom != update->ntimestep) {
      // Only invoke during runs, on steps that tallied what it needs.
      if (!evaluate || !in_run || !compute_is_current(compute, true)) return false;
      if (!guarded([&] {
            compute->compute_peratom();
            compute->invoked_flag |= Compute::INVOKED_PERATOM;
          }))
        return false;
    }
    return copy(compute->vector_atom, compute->array_atom);
  }

  if (prefix == 'f') {
    Fix *fix = modify->get_fix_by_id(id);
    if (!fix) {
      problem = "No fix with ID '" + id + "'";
      return false;
    }
    if (!fix->peratom_flag) {
      problem = "Fix '" + id + "' (" + fix->style + ") has no per-atom values";
      return false;
    }
    if (!check_columns("Fix", fix->size_peratom_cols)) return false;
    // Fixes keep their per-atom arrays in step with atom migration.
    return copy(fix->vector_atom, fix->array_atom);
  }

  Variable *variable = input->variable;
  const int index = variable->find(id.c_str());
  if (index < 0) {
    problem = "No variable named '" + id + "'";
    return false;
  }
  if (!variable->atomstyle(index)) {
    problem = "Variable '" + id + "' is not an atom-style variable";
    return false;
  }
  if (column > 0) {
    problem = "Variable '" + id + "' has one per-atom value; use v_" + id;
    return false;
  }
  if (!evaluate) return false;
  return guarded([&] { variable->compute_atom(index, 0, values.data(), 1, 0); });
}

/* ----------------------------------------------------------------------
   Observables
------------------------------------------------------------------------- */

bool FixAtomify::compute_is_current(Compute *compute, bool peratom) const
{
  if (!compute->is_initialized() || update->whichflag == 0) return false;
  const bigint now = update->ntimestep;
  if (compute->peflag && update->eflag_global != now) return false;
  if (compute->pressflag && update->vflag_global != now) return false;
  if (peratom && compute->peatomflag && update->eflag_atom != now) return false;
  if (peratom && compute->pressatomflag && update->vflag_atom != now) return false;
  return true;
}

std::shared_ptr<const AtomifyObservableList> FixAtomify::sample_observables(bool in_run)
{
  auto list = std::make_shared<AtomifyObservableList>();
  list->timestep = update->ntimestep;
  sample_thermo(*list);

  for (Compute *compute : modify->get_compute_list()) {
    AtomifyObservable item;
    item.kind = ATOMIFY_OBSERVABLE_COMPUTE;
    item.name = compute->id;
    item.style = compute->style;
    item.has_per_atom = compute->peratom_flag != 0;
    item.per_atom_columns = compute->size_peratom_cols;
    sample_compute(compute, item, in_run);
    list->items.push_back(std::move(item));
  }

  for (Fix *fix : modify->get_fix_list()) {
    if (fix == this || internal_style(fix->style)) continue;
    AtomifyObservable item;
    item.kind = ATOMIFY_OBSERVABLE_FIX;
    item.name = fix->id;
    item.style = fix->style;
    item.has_per_atom = fix->peratom_flag != 0;
    item.per_atom_columns = fix->size_peratom_cols;
    if (in_run) sample_fix(fix, item);
    list->items.push_back(std::move(item));
  }

  sample_variables(*list, in_run);
  // Simulation time of each value's step (exact since the last timestep change).
  for (AtomifyObservable &item : list->items)
    if (item.timestep >= 0)
      item.time = update->atime + (item.timestep - update->atimestep) * update->dt;
  return list;
}

void FixAtomify::sample_thermo(AtomifyObservableList &list)
{
  if (!output || !output->thermo) return;
  Thermo *thermo = output->thermo;
  const bigint timestep = *thermo->get_timestep();
  const int nfield = *thermo->get_nfield();
  const auto &keywords = thermo->get_keywords();
  const auto &fields = thermo->get_fields();
  for (int i = 0; i < nfield && i < static_cast<int>(keywords.size()); i++) {
    AtomifyObservable item;
    item.kind = ATOMIFY_OBSERVABLE_THERMO;
    item.name = thermo_keyword(keywords[i]);
    if (timestep >= 0 && i < static_cast<int>(fields.size())) {
      const multitype &field = fields[i];
      item.has_scalar = true;
      item.timestep = timestep;
      if (field.type == multitype::LAMMPS_DOUBLE)
        item.scalar = field.data.d;
      else if (field.type == multitype::LAMMPS_INT)
        item.scalar = field.data.i;
      else if (field.type == multitype::LAMMPS_INT64)
        item.scalar = static_cast<double>(field.data.b);
      else
        item.has_scalar = false;
      if (item.has_scalar && !std::isfinite(item.scalar)) item.has_scalar = false;
      if (!item.has_scalar) item.timestep = -1;
    }
    list.items.push_back(std::move(item));
  }
}

void FixAtomify::sample_compute(Compute *compute, AtomifyObservable &item, bool in_run)
{
  if (!compute->is_initialized()) return;
  const std::string key = std::string("c_") + compute->id;
  const bigint now = update->ntimestep;
  // Invoked here only during runs on steps with what it needs; otherwise the
  // values of its last invocation (by anyone) are reported with their step.
  const bool can = in_run && !failed.count(key) && compute_is_current(compute, false);
  auto invoke = [&](bigint invoked, auto &&body) {
    if (invoked == now || !can) return;
    if (!guarded(body)) failed.insert(key);
  };

  if (compute->scalar_flag) {
    invoke(compute->invoked_scalar, [&] {
      compute->compute_scalar();
      compute->invoked_flag |= Compute::INVOKED_SCALAR;
    });
    if (compute->invoked_scalar >= 0 && std::isfinite(compute->scalar)) {
      item.has_scalar = true;
      item.scalar = compute->scalar;
      item.timestep = compute->invoked_scalar;
    }
  }
  if (compute->vector_flag && !failed.count(key)) {
    invoke(compute->invoked_vector, [&] {
      compute->compute_vector();
      compute->invoked_flag |= Compute::INVOKED_VECTOR;
    });
    if (compute->invoked_vector >= 0 && compute->vector && compute->size_vector > 0) {
      const int n = std::min(compute->size_vector, kMaxVector);
      item.vector.assign(compute->vector, compute->vector + n);
      if (!item.has_scalar) item.timestep = compute->invoked_vector;
    }
  }
  if (compute->array_flag && !failed.count(key)) {
    invoke(compute->invoked_array, [&] {
      compute->compute_array();
      compute->invoked_flag |= Compute::INVOKED_ARRAY;
    });
    const int rows = compute->size_array_rows, columns = compute->size_array_cols;
    if (compute->invoked_array >= 0 && compute->array && rows > 0 && columns > 0) {
      const int kept = static_cast<int>(std::min<size_t>(rows, kMaxArray / columns));
      item.rows = kept;
      item.columns = columns;
      item.array.resize(static_cast<size_t>(kept) * columns);
      for (int r = 0; r < kept; r++)
        for (int c = 0; c < columns; c++) item.array[static_cast<size_t>(r) * columns + c] = compute->array[r][c];
      if (!item.has_scalar && item.vector.empty()) item.timestep = compute->invoked_array;
    }
  }
}

void FixAtomify::sample_fix(Fix *fix, AtomifyObservable &item)
{
  const std::string key = std::string("f_") + fix->id;
  if (failed.count(key)) return;
  AtomifyObservable values;
  const bool ok = guarded([&] {
    if (fix->scalar_flag) {
      values.scalar = fix->compute_scalar();
      values.has_scalar = std::isfinite(values.scalar);
    }
    if (fix->vector_flag && fix->size_vector > 0) {
      const int n = std::min(fix->size_vector, kMaxVector);
      values.vector.resize(n);
      for (int i = 0; i < n; i++) values.vector[i] = fix->compute_vector(i);
    }
    const int rows = fix->size_array_rows, columns = fix->size_array_cols;
    if (fix->array_flag && rows > 0 && columns > 0) {
      const int kept = static_cast<int>(std::min<size_t>(rows, kMaxArray / columns));
      values.rows = kept;
      values.columns = columns;
      values.array.resize(static_cast<size_t>(kept) * columns);
      for (int r = 0; r < kept; r++)
        for (int c = 0; c < columns; c++)
          values.array[static_cast<size_t>(r) * columns + c] = fix->compute_array(r, c);
    }
  });
  if (!ok) {
    failed.insert(key);
    return;
  }
  item.has_scalar = values.has_scalar;
  item.scalar = values.scalar;
  item.vector = std::move(values.vector);
  item.rows = values.rows;
  item.columns = values.columns;
  item.array = std::move(values.array);
  // Global values only change every global_freq steps (nfreq of fix
  // ave/time), so report the step they were produced on: plots then get one
  // point per output rather than repeated points in between.
  if (item.has_scalar || !item.vector.empty() || item.rows > 0) {
    const bigint now = update->ntimestep;
    const bigint every = fix->global_freq > 1 ? fix->global_freq : 1;
    item.timestep = now - now % every;
  }
}

void FixAtomify::sample_variables(AtomifyObservableList &list, bool in_run)
{
  Variable *variable = input ? input->variable : nullptr;
  if (!variable) return;
  const bigint now = update->ntimestep;
  for (int i = 0; i < variable->get_nvar(); i++) {
    const char *name = variable->get_name(i);
    const char *style_name = variable->get_style(i);
    if (!name || !style_name) continue;    // unassigned (e.g. a deleted variable)
    AtomifyObservable item;
    item.kind = ATOMIFY_OBSERVABLE_VARIABLE;
    item.name = name;
    item.style = style_name;
    const std::string key = "v_" + item.name;
    const std::string &style = item.style;
    if (style == "atom" || style == "atomfile") {
      item.has_per_atom = true;
    } else if (!failed.count(key)) {
      bool ok = true;
      if (style == "equal" || style == "internal" || style == "timer") {
        double value = 0.0;
        ok = guarded([&] { value = variable->compute_equal(i); });
        if (ok && std::isfinite(value)) {
          item.has_scalar = true;
          item.scalar = value;
        }
      } else if (style == "vector") {
        double *data = nullptr;
        int n = 0;
        ok = guarded([&] { n = variable->compute_vector(i, &data); });
        if (ok && data && n > 0) item.vector.assign(data, data + std::min(n, kMaxVector));
      } else if (style == "index" || style == "loop" || style == "world" || style == "universe" ||
                 style == "uloop" || style == "string" || style == "getenv" || style == "file" ||
                 style == "format") {
        const char *text = nullptr;
        ok = guarded([&] { text = variable->retrieve(item.name.c_str()); });
        double value;
        if (ok && parse_number(text, value)) {
          item.has_scalar = true;
          item.scalar = value;
        }
      }
      // Outside runs, failures (e.g. computes that are not current) are
      // expected and retried on the next sample.
      if (!ok && in_run) failed.insert(key);
      if (item.has_scalar || !item.vector.empty()) item.timestep = now;
    }
    list.items.push_back(std::move(item));
  }
}
