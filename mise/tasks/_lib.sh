# shellcheck shell=bash
# Shared helpers for the mise tasks in this directory. Source it, do not run it:
#
#     . "$(dirname -- "${BASH_SOURCE[0]}")/_lib.sh"
#
# Not executable on purpose, so mise does not list it as a task.

# Absolute path to the repository root, so tasks work from any cwd.
task_repo_root() {
	( cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P )
}

# The shared DerivedData directory the app build writes into.
task_derived_data() {
	printf '.build/DerivedData\n'
}

# The built app bundle for a configuration (default Debug).
task_app_path() {
	printf '%s/Build/Products/%s/TidalSwift.app\n' "$(task_derived_data)" "${1:-Debug}"
}

# Run a command from inside the TidalSwiftLib Swift package.
task_in_lib() {
	cd -- "$(task_repo_root)/TidalSwiftLib" || exit 1
	exec "$@"
}
