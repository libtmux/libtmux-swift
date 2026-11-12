# Remove ignored build output. .gitignore decides what that is.
# https://just.systems/

# List available commands
default:
    @just --list

# Remove ignored build artifacts and caches. Untracked files and .env stay.
[group: 'clean']
clean:
    git clean -fdX -e '!.env' -e '!.env.*'

# Preview what clean will delete.
[group: 'clean']
clean-dry:
    git clean -ndX -e '!.env' -e '!.env.*'

# Remove ignored and untracked files. .env and .env.* stay.
# git clean -x ignores .gitignore and only preserves -e patterns, so .env is named here rather than negated.
[group: 'clean']
[confirm("This will delete all untracked and ignored files. Continue?")]
nuke:
    git clean -fdx -e '.env' -e '.env.*'
