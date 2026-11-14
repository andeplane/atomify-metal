#include "atomify_lammps.h"

#include "atomify_shared.h"
#include "fix_atomify.h"

#include "atom.h"
#include "comm.h"
#include "error.h"
#include "exceptions.h"
#include "fix.h"
#include "force.h"
#include "input.h"
#include "integrate.h"
#include "lammps.h"
#include "library.h"
#include "modify.h"
#include "pair.h"
#include "timer.h"
#include "update.h"
#include "utils.h"
#include "variable.h"

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#ifdef _OPENMP
#include <omp.h>
#endif

using namespace LAMMPS_NS;

/* ---------------------------------------------------------------------- */

namespace LAMMPS_NS {
namespace {
std::mutex registry_mutex;
std::unordered_map<LAMMPS *, AtomifyShared *> registry;

constexpr size_t kMaxOutput = 4u << 20;
constexpr size_t kKeptOutput = 3u << 20;

std::string trimmed(const std::string &text)
{
  const size_t first = text.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return "";
  const size_t last = text.find_last_not_of(" \t\r\n");
  return text.substr(first, last - first + 1);
}
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

void AtomifyShared::append_output(const char *data, size_t size)
{
  if (!data || size == 0) return;
  std::lock_guard<std::mutex> lock(output_mutex);
  if (holding) {
    held.append(data, size);
    return;
  }
  output.append(data, size);
  if (output.size() > kMaxOutput) output.erase(0, output.size() - kKeptOutput);
  if (echo) {
    std::fwrite(data, 1, size, stdout);
    std::fflush(stdout);
  }
}

void AtomifyShared::hold_output()
{
  std::lock_guard<std::mutex> lock(output_mutex);
  holding = true;
}

void AtomifyShared::release_output(bool keep)
{
  std::string text;
  {
    std::lock_guard<std::mutex> lock(output_mutex);
    if (!holding) return;
    holding = false;
    text.swap(held);
  }
  if (keep) append_output(text.data(), text.size());
}

void AtomifyShared::mark_progress()
{
  progress_ns.store(std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now().time_since_epoch())
                        .count());
}

std::string atomify_command_rejection(const std::string &command, bool in_run)
{
  const std::string line = trimmed(command);
  if (line.find("__atomify") != std::string::npos)
    return "Atomify manages fix __atomify; commands may not change it";
  if (!in_run) return "";
  const std::string word = line.substr(0, line.find_first_of(" \t"));
  static const char *const forbidden[] = {"run",     "rerun", "minimize", "clear",
                                          "include", "jump",  "label",    "quit",
                                          "read_restart", "write_restart"};
  for (const char *name : forbidden)
    if (word == name)
      return "'" + word + "' cannot be used while a run is in progress";
  return "";
}

namespace {

std::string pop_command(AtomifyShared *shared)
{
  std::lock_guard<std::mutex> lock(shared->control_mutex);
  if (shared->commands.empty()) return "";
  std::string command = std::move(shared->commands.front());
  shared->commands.pop_front();
  shared->queued.store(static_cast<int>(shared->commands.size()));
  return command;
}

std::string current_input_line(LAMMPS *lmp)
{
  const char *line = lmp->input ? lmp->input->get_last_line() : nullptr;
  return line ? trimmed(line) : std::string();
}

bool has_commands(AtomifyShared *shared)
{
  return shared->queued.load() > 0;
}

// Executes the queued commands between two parts of a run, the way
// `run N every M "command"` does: with the run still active.
void execute_in_run(LAMMPS *lmp, AtomifyShared *shared)
{
  lmp->modify->clearstep_compute();
  while (has_commands(shared)) {
    const std::string command = pop_command(shared);
    if (trimmed(command).empty()) continue;
    const std::string rejection = atomify_command_rejection(command, true);
    if (!rejection.empty()) {
      shared->append_output(("ERROR: " + rejection + "\n").c_str(), rejection.size() + 8);
      continue;
    }
    try {
      lmp->input->one(command);
    } catch (LAMMPSException &) {
      // LAMMPS printed the message. The run goes on without this command.
      if (lmp->input->variable) lmp->input->variable->clear_in_progress();
    } catch (std::exception &e) {
      const std::string message = std::string("ERROR: ") + e.what() + "\n";
      shared->append_output(message.c_str(), message.size());
    }
    lmp->update->whichflag = 1;
  }
}

// Waits while the app keeps the run paused. True if commands were queued
// meanwhile (they run before any further step).
bool wait_while_paused(AtomifyShared *shared)
{
  std::unique_lock<std::mutex> lock(shared->control_mutex);
  shared->control_cv.wait(lock, [shared] {
    return !shared->paused || shared->cancelled.load() || !shared->commands.empty();
  });
  return !shared->cancelled.load() && !shared->commands.empty();
}

}    // namespace

int atomify_threads_for(int64_t atoms, int atoms_per_thread, int max_threads)
{
  const int64_t threads = atoms / std::max(1, atoms_per_thread);
  return static_cast<int>(std::clamp<int64_t>(threads, 1, std::max(1, max_threads)));
}

void atomify_before_init(LAMMPS *lmp)
{
  AtomifyShared *shared = atomify_find_shared(lmp);
  if (!shared) return;
  Comm *comm = lmp->comm;
  shared->threads = comm->nthreads;
  if (!shared->choosing_threads) return;
  // A system that starts empty (fix pour, fix deposit) chooses at the first
  // initialization with atoms, and runs again from the start only if that
  // costs few steps.
  if (lmp->atom->natoms == 0) {
    shared->release_output(true);
    return;
  }
  shared->choosing_threads = false;
  constexpr bigint kMaxStepsToRepeat = 2000;
  if (lmp->update->ntimestep > kMaxStepsToRepeat) {
    shared->release_output(true);
    return;
  }
  // Measured on Apple silicon with the bundled examples: pairwise potentials
  // gain from about 1500 atoms, ReaxFF from a few hundred, long range
  // Coulomb and manybody potentials from 200-300.
  int atoms_per_thread = 1000;
  Pair *pair = lmp->force->pair;
  if (pair && utils::strmatch(lmp->force->pair_style, "reaxff"))
    atoms_per_thread = 250;
  else if (lmp->force->kspace || (pair && pair->manybody_flag))
    atoms_per_thread = 100;
  const int threads = atomify_threads_for(lmp->atom->natoms, atoms_per_thread, comm->nthreads);
  if (threads == comm->nthreads) {
    shared->release_output(true);    // the run goes on: show its output
    return;
  }
  shared->restart_threads = threads;
  lmp->error->all(FLERR, "Atomify restarts on {} OpenMP thread(s)", threads);
}

void atomify_integrate(LAMMPS *lmp, int nsteps)
{
  AtomifyShared *shared = atomify_find_shared(lmp);
  Update *update = lmp->update;
  if (!shared) {
    update->integrate->run(nsteps);
    return;
  }

  struct Scope {
    LAMMPS *lmp;
    AtomifyShared *shared;
    bool previous;
    int64_t previous_first_step;
    std::string previous_line;
    std::string line;
    int exceptions = std::uncaught_exceptions();
    ~Scope()
    {
      shared->can_interrupt = previous;
      shared->run_first_step = previous_first_step;
      shared->run_line = previous_line;
      if (shared->interrupted) {
        // Never leave a forced timeout behind for the next run.
        lmp->timer->reset_timeout();
        shared->interrupted = false;
      }
      // An error ends the run: report the run command, not the last queued
      // command that LAMMPS executed in between.
      if (std::uncaught_exceptions() > exceptions && shared->error_line.empty()) shared->error_line = line;
    }
  } scope{lmp, shared, shared->can_interrupt, shared->run_first_step, shared->run_line,
          current_input_line(lmp)};
  shared->can_interrupt = true;
  shared->interrupted = false;
  shared->run_first_step = update->firststep;
  shared->run_line = scope.line;

  update->integrate->run(nsteps);
  while (shared->interrupted) {
    shared->interrupted = false;
    lmp->timer->reset_timeout();
    const bigint remaining = update->laststep - update->ntimestep;
    // The step that ended last is cleaned up by Run when nothing remains.
    if (remaining > 0) update->integrate->cleanup();
    execute_in_run(lmp, shared);
    if (shared->cancelled.load()) lmp->error->all(FLERR, "Atomify run cancelled");
    if (remaining <= 0) break;

    // Continue the same run: begin/end steps (for ramps) are unchanged.
    update->whichflag = 1;
    update->nsteps = static_cast<int>(remaining);
    update->firststep = update->ntimestep;
    lmp->init();
    update->integrate->setup(1);
    shared->mark_progress();
    bool paused;
    {
      std::lock_guard<std::mutex> lock(shared->control_mutex);
      paused = shared->paused;
    }
    if (paused && wait_while_paused(shared)) {
      shared->interrupted = true;
      continue;
    }
    if (has_commands(shared)) {
      shared->interrupted = true;
      continue;
    }
    if (shared->cancelled.load()) lmp->error->all(FLERR, "Atomify run cancelled");
    update->integrate->run(static_cast<int>(remaining));
  }
}

}    // namespace LAMMPS_NS

/* ---------------------------------------------------------------------- */

struct atomify_sim {
  // Declared first so it outlives the LAMMPS instance and its fix.
  std::unique_ptr<AtomifyShared> shared = std::make_unique<AtomifyShared>();
  void *lmp = nullptr;
  std::string last_error;
  std::string last_error_line;
  // What ran before the thread count was chosen (true: a file), to run
  // again on a new instance.
  std::vector<std::pair<bool, std::string>> journal;
};

namespace {

void clear_interactions(atomify_sim *sim)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  for (auto &grab : sim->shared->grabs) grab = AtomifyGrab{};
  sim->shared->force_spheres.clear();
  sim->shared->force_sphere_generation++;
}

// Error status of the last library call, which it also clears.
bool take_error(atomify_sim *sim, std::string &message)
{
  if (!lammps_has_error(sim->lmp)) return false;
  char buffer[2048];
  lammps_get_last_error_message(sim->lmp, buffer, sizeof(buffer));
  message = buffer;
  return true;
}

atomify_status finish(atomify_sim *sim)
{
  std::string message;
  std::string run_line;
  std::swap(run_line, sim->shared->error_line);
  if (!take_error(sim, message)) {
    sim->last_error.clear();
    sim->last_error_line.clear();
    return ATOMIFY_OK;
  }
  sim->last_error = message;
  sim->last_error_line = run_line.empty() ? current_input_line(static_cast<LAMMPS *>(sim->lmp)) : run_line;
  clear_interactions(sim);
  return sim->shared->cancelled.load() ? ATOMIFY_CANCELLED : ATOMIFY_ERROR;
}

// `clear` deletes every fix, so this is checked before each script call.
bool install_fix(atomify_sim *sim)
{
  if (lammps_has_id(sim->lmp, "fix", "__atomify")) return true;
  lammps_command(sim->lmp, "fix __atomify all atomify");
  return !lammps_has_error(sim->lmp);
}

#if defined(__APPLE__)
int write_output(void *cookie, const char *data, int size)
{
  static_cast<AtomifyShared *>(cookie)->append_output(data, size > 0 ? size : 0);
  return size;
}
FILE *open_output(AtomifyShared *shared)
{
  return funopen(shared, nullptr, write_output, nullptr, nullptr);
}
#else
ssize_t write_output(void *cookie, const char *data, size_t size)
{
  static_cast<AtomifyShared *>(cookie)->append_output(data, size);
  return static_cast<ssize_t>(size);
}
FILE *open_output(AtomifyShared *shared)
{
  cookie_io_functions_t functions = {nullptr, write_output, nullptr, nullptr};
  return fopencookie(shared, "w", functions);
}
#endif

// OpenMP keeps the thread count per calling thread, and LAMMPS sets it on
// the thread that created the instance. Scripts run on another thread, where
// the runtime default (every processor) would otherwise apply, overrunning
// the per-thread storage fix OMP sized for comm->nthreads.
void use_threads_on_this_thread(atomify_sim *sim)
{
#ifdef _OPENMP
  omp_set_num_threads(static_cast<LAMMPS *>(sim->lmp)->comm->nthreads);
#else
  (void) sim;
#endif
}

// Keeps the OpenMP runtime alive for the life of the process. A statically
// linked libomp shuts itself down when its last root thread exits, freeing
// every lock, yet the `omp critical` sections in LAMMPS cache pointers to
// theirs. Each script runs on its own thread that exits afterwards, so the
// next simulation's first critical section would read a freed lock. One
// thread that registers with the runtime and never exits prevents that.
void keep_openmp_alive()
{
#ifdef _OPENMP
  static std::once_flag once;
  std::call_once(once, [] {
    std::mutex mutex;
    std::condition_variable registered;
    bool ready = false;
    std::thread([&] {
      omp_set_num_threads(1);    // registers this thread as a root
      {
        std::lock_guard<std::mutex> lock(mutex);
        ready = true;
      }
      registered.notify_one();
      std::mutex idle;
      std::unique_lock<std::mutex> lock(idle);
      std::condition_variable never;
      never.wait(lock, [] { return false; });
    }).detach();
    std::unique_lock<std::mutex> lock(mutex);
    registered.wait(lock, [&] { return ready; });
  });
#endif
}

// A LAMMPS instance on `threads` threads, with its output captured.
bool open_instance(atomify_sim *sim, int threads)
{
  std::vector<std::string> args = {"liblammps", "-log", "none", "-screen", "none", "-nocite"};
  if (threads > 1) {
    // Command line settings survive "clear": LAMMPS applies them again to
    // each new instance. Styles without an /omp variant stay serial.
    for (const char *arg : {"-suffix", "omp", "-package", "omp"}) args.emplace_back(arg);
    args.push_back(std::to_string(threads));
  }
  std::vector<char *> argv;
  for (auto &arg : args) argv.push_back(arg.data());
  sim->lmp = lammps_open_no_mpi(static_cast<int>(argv.size()), argv.data(), nullptr);
  if (!sim->lmp) return false;
  auto *lmp = static_cast<LAMMPS *>(sim->lmp);
  // LAMMPS writes its screen output here; it closes the stream on exit.
  if (FILE *screen = open_output(sim->shared.get())) {
    std::setvbuf(screen, nullptr, _IONBF, 0);
    lmp->screen = screen;
  }
  sim->shared->threads = lmp->comm->nthreads;
  atomify_register_shared(lmp, sim->shared.get());
  return true;
}

void close_instance(atomify_sim *sim)
{
  if (!sim->lmp) return;
  use_threads_on_this_thread(sim);    // /omp styles free per-thread data
  atomify_unregister_shared(static_cast<LAMMPS *>(sim->lmp));
  lammps_close(sim->lmp);
  sim->lmp = nullptr;
}

void execute_once(atomify_sim *sim, bool file, const std::string &text)
{
  use_threads_on_this_thread(sim);
  if (file)
    lammps_file(sim->lmp, text.c_str());
  else
    lammps_command(sim->lmp, text.c_str());
}

// Runs a file or a command. Until the thread count is chosen, it is kept,
// and when the choice asks for fewer threads everything kept runs again on
// a new instance with that many (see atomify_before_init).
void execute(atomify_sim *sim, bool file, const std::string &text)
{
  AtomifyShared *shared = sim->shared.get();
  if (shared->choosing_threads) {
    sim->journal.emplace_back(file, text);
    shared->hold_output();
  }
  execute_once(sim, file, text);
  const int threads = shared->restart_threads;
  if (threads == 0) {
    if (!shared->choosing_threads) sim->journal.clear();
    shared->release_output(true);
    return;
  }
  shared->restart_threads = 0;
  shared->release_output(false);    // the input runs again below
  std::string ignored;
  take_error(sim, ignored);
  shared->error_line.clear();
  const std::string note = "Atomify: this system runs faster on " + std::to_string(threads) +
                           " OpenMP thread(s); running the input again with them.\n";
  shared->append_output(note.data(), note.size());
  auto journal = std::move(sim->journal);
  sim->journal.clear();
  close_instance(sim);
  if (!open_instance(sim, threads)) {
    // Should not happen; fall back to the serial engine.
    if (!open_instance(sim, 1)) std::abort();
  }
  if (!install_fix(sim)) return;
  for (const auto &[is_file, entry] : journal) {
    execute_once(sim, is_file, entry);
    if (lammps_has_error(sim->lmp)) break;
  }
}

}    // namespace

/* ---------------------------------------------------------------------- */

extern "C" {

int atomify_max_threads(void)
{
#ifdef _OPENMP
  return std::max(1, omp_get_num_procs());
#else
  return 1;
#endif
}

atomify_sim *atomify_sim_create(int echo)
{
  return atomify_sim_create_threaded(echo, 1);
}

atomify_sim *atomify_sim_create_threaded(int echo, int threads)
{
  auto *sim = new atomify_sim();
  sim->shared->mark_progress();
  sim->shared->echo = echo != 0;
  keep_openmp_alive();
  threads = std::clamp(threads, 1, atomify_max_threads());
  if (!open_instance(sim, threads)) {
    delete sim;
    return nullptr;
  }
  sim->shared->choosing_threads = threads > 1;
  if (!install_fix(sim)) finish(sim);
  return sim;
}

void atomify_sim_destroy(atomify_sim *sim)
{
  if (!sim) return;
  close_instance(sim);
  delete sim;
}

atomify_status atomify_sim_run_file(atomify_sim *sim, const char *path)
{
  if (!install_fix(sim)) return finish(sim);
  execute(sim, true, path);
  return finish(sim);
}

atomify_status atomify_sim_command(atomify_sim *sim, const char *command)
{
  if (!install_fix(sim)) return finish(sim);
  execute(sim, false, command);
  return finish(sim);
}

int atomify_sim_threads(atomify_sim *sim)
{
  return sim->shared->threads.load();
}

const char *atomify_sim_last_error(atomify_sim *sim)
{
  return sim->last_error.c_str();
}

const char *atomify_sim_last_error_line(atomify_sim *sim)
{
  return sim->last_error_line.c_str();
}

/* ---------------------------------------------------------------------- */

void atomify_sim_enqueue_command(atomify_sim *sim, const char *command)
{
  if (!command) return;
  {
    std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
    const std::string text = command;
    size_t start = 0;
    while (start <= text.size()) {
      size_t end = text.find('\n', start);
      if (end == std::string::npos) end = text.size();
      std::string line = text.substr(start, end - start);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.find_first_not_of(" \t") != std::string::npos) sim->shared->commands.push_back(line);
      start = end + 1;
    }
    sim->shared->queued.store(static_cast<int>(sim->shared->commands.size()));
  }
  sim->shared->control_cv.notify_all();
}

int atomify_sim_queued_command_count(atomify_sim *sim)
{
  return sim->shared->queued.load();
}

atomify_status atomify_sim_execute_queued(atomify_sim *sim)
{
  if (!install_fix(sim)) return finish(sim);
  std::string failure, failure_line;
  while (has_commands(sim->shared.get())) {
    const std::string command = pop_command(sim->shared.get());
    if (trimmed(command).empty()) continue;
    const std::string rejection = atomify_command_rejection(command, false);
    if (!rejection.empty()) {
      failure = rejection;
      failure_line = trimmed(command);
      sim->shared->append_output(("ERROR: " + rejection + "\n").c_str(), rejection.size() + 8);
      continue;
    }
    execute(sim, false, command);
    std::string message;
    if (take_error(sim, message)) {
      failure = message;
      failure_line = trimmed(command);
    }
    sim->shared->error_line.clear();
    if (sim->shared->cancelled.load()) break;
  }
  sim->last_error = failure;
  sim->last_error_line = failure_line;
  if (sim->shared->cancelled.load()) return ATOMIFY_CANCELLED;
  return failure.empty() ? ATOMIFY_OK : ATOMIFY_ERROR;
}

int atomify_sim_wait_for_commands(atomify_sim *sim, double timeout)
{
  std::unique_lock<std::mutex> lock(sim->shared->control_mutex);
  const auto ready = [sim] { return !sim->shared->commands.empty() || sim->shared->cancelled.load(); };
  if (timeout > 0.0 && std::isfinite(timeout))
    sim->shared->control_cv.wait_for(lock, std::chrono::duration<double>(timeout), ready);
  return !sim->shared->cancelled.load() && !sim->shared->commands.empty() ? 1 : 0;
}

int atomify_sim_publish(atomify_sim *sim)
{
  if (!install_fix(sim)) {
    finish(sim);
    return 0;
  }
  auto *lmp = static_cast<LAMMPS *>(sim->lmp);
  if (!lmp->update || lmp->update->whichflag != 0) return 0;
  auto *fix = dynamic_cast<FixAtomify *>(lmp->modify->get_fix_by_id("__atomify"));
  if (!fix) return 0;
  try {
    return fix->publish_idle() ? 1 : 0;
  } catch (LAMMPSException &e) {
    sim->last_error = e.what();
    sim->last_error_line.clear();
    return 0;
  }
}

size_t atomify_sim_read_output(atomify_sim *sim, char *buffer, size_t capacity)
{
  if (!buffer || capacity == 0) return 0;
  std::lock_guard<std::mutex> lock(sim->shared->output_mutex);
  const size_t count = std::min(capacity, sim->shared->output.size());
  std::memcpy(buffer, sim->shared->output.data(), count);
  sim->shared->output.erase(0, count);
  return count;
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

int atomify_sim_is_cancelled(atomify_sim *sim)
{
  return sim->shared->cancelled.load() ? 1 : 0;
}

double atomify_sim_seconds_since_progress(atomify_sim *sim)
{
  const int64_t now = std::chrono::duration_cast<std::chrono::nanoseconds>(
                          std::chrono::steady_clock::now().time_since_epoch())
                          .count();
  return (now - sim->shared->progress_ns.load()) * 1.0e-9;
}

void atomify_sim_set_max_steps_per_second(atomify_sim *sim, double steps)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->max_steps_per_second = std::isfinite(steps) && steps > 0.0 ? steps : 0.0;
}

void atomify_sim_set_publish_interval(atomify_sim *sim, double seconds)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->publish_interval = std::isfinite(seconds) && seconds > 0.0 ? seconds : 0.0;
}

void atomify_sim_set_observable_interval(atomify_sim *sim, double seconds)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->observable_interval = std::isfinite(seconds) && seconds > 0.0 ? seconds : 0.0;
}

void atomify_sim_set_per_atom_quantity(atomify_sim *sim, const char *name)
{
  std::lock_guard<std::mutex> lock(sim->shared->control_mutex);
  sim->shared->per_atom_quantity = name ? trimmed(name) : "";
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
  if (std::isfinite(cutoff) && cutoff > 0.0)
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
  AtomifySnapshotData &s = sim->shared->front;
  *out = atomify_snapshot{};
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
    out->tilt[k] = s.tilt[k];
    out->bounds_lo[k] = s.bounds_lo[k];
    out->bounds_hi[k] = s.bounds_hi[k];
  }
  out->temperature = s.temperature;
  out->kinetic_energy = s.kinetic_energy;
  out->potential_energy = s.potential_energy;
  out->has_potential_energy = s.has_potential_energy ? 1 : 0;
  out->frozen = s.frozen ? 1 : 0;
  out->grab_tag = s.grab_tag;
  for (int k = 0; k < 3; k++) out->grab_force[k] = s.grab_force[k];
  out->steps_per_second = s.steps_per_second;
  out->run_mode = s.run_mode;
  out->run_step = s.run_step;
  out->run_steps = s.run_steps;
  out->input_line = s.input_line.c_str();
  out->tags = s.tags.data();
  out->types = s.types.data();
  out->positions = s.positions.data();
  out->radii = s.radii.empty() ? nullptr : s.radii.data();
  out->bonds = s.bonds.data();

  out->per_atom_name = s.per_atom_name.c_str();
  out->per_atom_error = s.per_atom_error.c_str();
  out->per_atom_values = s.has_per_atom_values ? s.per_atom_values.data() : nullptr;

  s.observable_views.clear();
  if (s.observables) {
    s.observable_views.reserve(s.observables->items.size());
    for (const AtomifyObservable &o : s.observables->items) {
      atomify_observable view{};
      view.kind = o.kind;
      view.name = o.name.c_str();
      view.style = o.style.c_str();
      view.timestep = o.timestep;
      view.time = o.time;
      view.has_scalar = o.has_scalar ? 1 : 0;
      view.scalar = o.scalar;
      view.vector_length = static_cast<int32_t>(o.vector.size());
      view.vector = o.vector.empty() ? nullptr : o.vector.data();
      view.array_rows = o.rows;
      view.array_columns = o.columns;
      view.array = o.array.empty() ? nullptr : o.array.data();
      view.has_per_atom = o.has_per_atom ? 1 : 0;
      view.per_atom_columns = o.per_atom_columns;
      s.observable_views.push_back(view);
    }
  }
  out->observables_timestep = s.observables ? s.observables->timestep : -1;
  out->nobservables = static_cast<int32_t>(s.observable_views.size());
  out->observables = s.observable_views.empty() ? nullptr : s.observable_views.data();
  out->nwalls = static_cast<int32_t>(s.walls.size());
  out->walls = s.walls.empty() ? nullptr : s.walls.data();
  return 1;
}

void atomify_sim_snapshot_unlock(atomify_sim *sim)
{
  sim->shared->snapshot_mutex.unlock();
}

}    // extern "C"
