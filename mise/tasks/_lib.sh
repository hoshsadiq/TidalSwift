# shellcheck shell=bash
# Shared helpers for the mise tasks in this directory. Source it, do not run it:
#
#     . "$(dirname -- "${BASH_SOURCE[0]}")/_lib.sh"
#
# It holds the few facts every task needs but should not repeat: where the repository
# is, where the app build lands, and how to run something in the library package. The
# file is not executable on purpose, so mise does not list it as a task.

# Absolute path to the repository root (the directory holding mise.toml). Tasks use
# this instead of assuming mise started them from the root, so they work from any cwd.
task_repo_root() {
	( cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P )
}

# Path of the shared DerivedData directory that the app build writes into. Relative to
# the repository root, so callers cd there first.
task_derived_data() {
	printf '.build/DerivedData\n'
}

# Path of the built app bundle for a configuration (default Debug), relative to the
# repository root. Callers cd there first.
task_app_path() {
	printf '%s/Build/Products/%s/TidalSwift.app\n' "$(task_derived_data)" "${1:-Debug}"
}

# Run a command from inside the TidalSwiftLib Swift package.
task_in_lib() {
	cd -- "$(task_repo_root)/TidalSwiftLib" || exit 1
	exec "$@"
}
